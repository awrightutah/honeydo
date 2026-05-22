import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../utils/permissions.dart';

/// Rewards screen with reward catalog, redemption, and history.
class RewardsScreen extends StatefulWidget {
  const RewardsScreen({super.key});

  @override
  State<RewardsScreen> createState() => _RewardsScreenState();
}

class _RewardsScreenState extends State<RewardsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  Map<String, dynamic>? _household;
  Map<String, dynamic>? _myMembership;
  List<Map<String, dynamic>> _rewards = [];
  List<Map<String, dynamic>> _redemptions = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);

    try {
      final user = Supabase.instance.client.auth.currentUser!;
      final memberships = await Supabase.instance.client
          .from('household_members')
          .select('*, households(*)')
          .eq('auth_user_id', user.id)
          .limit(1);

      if (memberships.isEmpty) {
        setState(() => _isLoading = false);
        return;
      }

      _myMembership = memberships[0];
      _household = memberships[0]['households'];
      final householdId = _household!['id'];

      final rewards = await Supabase.instance.client
          .from('rewards')
          .select('*')
          .eq('household_id', householdId)
          .eq('is_active', true)
          .order('point_cost', ascending: true);

      final redemptions = await Supabase.instance.client
          .from('reward_redemptions')
          .select('*, rewards(title, icon), household_members!reward_redemptions_member_id_fkey(display_name)')
          .eq('household_id', householdId)
          .order('redeemed_at', ascending: false)
          .limit(50);

      setState(() {
        _rewards = List<Map<String, dynamic>>.from(rewards);
        _redemptions = List<Map<String, dynamic>>.from(redemptions);
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading rewards: $e')),
        );
      }
    }
  }

  int get _myPoints => _myMembership?['points_balance'] ?? 0;

  Future<void> _redeemReward(Map<String, dynamic> reward) async {
    final pointCost = reward['point_cost'] as int;
    final currentPoints = _myPoints;

    if (currentPoints < pointCost) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Not enough points! You need $pointCost but have $currentPoints.',
          ),
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Redeem Reward'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${reward['icon'] ?? '🎁'} ${reward['title']}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            if (reward['description'] != null)
              Text(reward['description']),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.honeyGold.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Cost:'),
                  Text(
                    '${pointCost} points',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: AppColors.honeyGold,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.skyBlue.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Your balance:'),
                  Text(
                    '$currentPoints points',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.grassGreen.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('After redemption:'),
                  Text(
                    '${currentPoints - pointCost} points',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: AppColors.grassGreen,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.honeyGold,
              foregroundColor: Colors.white,
            ),
            child: const Text('Redeem'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final householdId = _household!['id'];
      final memberId = _myMembership!['id'];

      // Create redemption record
      await Supabase.instance.client.from('reward_redemptions').insert({
        'household_id': householdId,
        'reward_id': reward['id'],
        'member_id': memberId,
        'point_cost': pointCost,
        'status': 'pending',
      });

      // Deduct points from member balance
      await Supabase.instance.client
          .from('household_members')
          .update({'points_balance': currentPoints - pointCost})
          .eq('id', memberId);

      // Create point transaction for the spending
      await Supabase.instance.client.from('point_transactions').insert({
        'household_id': householdId,
        'member_id': memberId,
        'type': 'spent',
        'amount': -pointCost,
        'balance_after': currentPoints - pointCost,
        'source_table': 'reward_redemptions',
        'note': 'Redeemed: ${reward['title']}',
        'created_by_member_id': memberId,
      });

      await _loadData();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Redeemed ${reward['title']}! 🎉'),
            backgroundColor: AppColors.grassGreen,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error redeeming reward: $e')),
        );
      }
    }
  }

  Future<void> _approveRedemption(Map<String, dynamic> redemption) async {
    try {
      final householdId = _household!['id'];
      final memberId = _myMembership!['id'];

      await Supabase.instance.client
          .from('reward_redemptions')
          .update({
            'status': 'approved',
            'approved_by_member_id': memberId,
            'approved_at': DateTime.now().toIso8601String(),
          })
          .eq('id', redemption['id']);

      await _loadData();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Reward approved! ✅')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error approving: $e')),
        );
      }
    }
  }

  Future<void> _showCreateRewardSheet() async {
    final titleController = TextEditingController();
    final descriptionController = TextEditingController();
    final pointCostController = TextEditingController(text: '50');
    final iconController = TextEditingController(text: '🎁');

    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Container(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Create New Reward',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  SizedBox(
                    width: 60,
                    child: TextField(
                      controller: iconController,
                      decoration: const InputDecoration(
                        labelText: 'Icon',
                        border: OutlineInputBorder(),
                      ),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 24),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: titleController,
                      decoration: const InputDecoration(
                        labelText: 'Reward Title *',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: descriptionController,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  border: OutlineInputBorder(),
                ),
                maxLines: 2,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: pointCostController,
                decoration: const InputDecoration(
                  labelText: 'Point Cost',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.stars, color: AppColors.honeyGold),
                ),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () async {
                  if (titleController.text.trim().isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Please enter a title')),
                    );
                    return;
                  }

                  try {
                    final householdId = _household!['id'];
                    final memberId = _myMembership!['id'];

                    await Supabase.instance.client.from('rewards').insert({
                      'household_id': householdId,
                      'title': titleController.text.trim(),
                      'description': descriptionController.text.trim(),
                      'point_cost': int.tryParse(pointCostController.text) ?? 50,
                      'icon': iconController.text.trim(),
                      'created_by_member_id': memberId,
                    });

                    Navigator.pop(context, true);
                    await _loadData();

                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Reward created! 🎉')),
                      );
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Error creating reward: $e')),
                      );
                    }
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.honeyGold,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Create Reward'),
              ),
            ],
          ),
        ),
      ),
    );

    if (result == true) {
      // Reward created, data already reloaded
    }
  }

  Future<void> _showDefaultRewardsDialog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Default Rewards?'),
        content: const Text(
          'This will add a set of common household rewards '
          '(Screen Time, Stay Up Late, Pick Dinner, etc.) to your household. '
          'You can always edit or delete them later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('No Thanks'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Add Defaults'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final householdId = _household!['id'];
      final memberId = _myMembership!['id'];

      final defaultRewards = [
        {'title': '30 min Screen Time', 'description': 'Extra 30 minutes of screen time', 'point_cost': 25, 'icon': '📱'},
        {'title': '1 Hour Screen Time', 'description': 'Extra 1 hour of screen time', 'point_cost': 50, 'icon': '📺'},
        {'title': 'Stay Up 30 Min Late', 'description': 'Stay up 30 minutes past bedtime', 'point_cost': 40, 'icon': '🌙'},
        {'title': 'Pick Dinner', 'description': 'Choose what the family has for dinner', 'point_cost': 75, 'icon': '🍕'},
        {'title': 'Pick Movie Night', 'description': 'Choose the family movie', 'point_cost': 50, 'icon': '🎬'},
        {'title': 'Dessert Treat', 'description': 'Pick a special dessert', 'point_cost': 30, 'icon': '🍰'},
        {'title': 'No Chores Today', 'description': 'Skip one day of chores', 'point_cost': 100, 'icon': '🏖️'},
        {'title': 'Friend Over', 'description': 'Invite a friend over', 'point_cost': 80, 'icon': '👫'},
        {'title': '\$5 Allowance Bonus', 'description': 'Extra \$5 in allowance', 'point_cost': 150, 'icon': '💵'},
        {'title': 'Trip to Ice Cream', 'description': 'Family trip for ice cream', 'point_cost': 200, 'icon': '🍦'},
      ];

      for (final reward in defaultRewards) {
        await Supabase.instance.client.from('rewards').insert({
          'household_id': householdId,
          'title': reward['title'],
          'description': reward['description'],
          'point_cost': reward['point_cost'],
          'icon': reward['icon'],
          'created_by_member_id': memberId,
        });
      }

      await _loadData();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Default rewards added! 🎁')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error adding defaults: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Rewards 🎁'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Rewards'),
            Tab(text: 'History'),
          ],
        ),
      ),
      body: Column(
        children: [
          // Points balance header
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  AppColors.honeyGold.withOpacity(0.1),
                  AppColors.honeyGold.withOpacity(0.05),
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
            child: Column(
              children: [
                const Text(
                  'Your Points Balance',
                  style: TextStyle(fontSize: 14, color: Colors.grey),
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.stars, color: AppColors.honeyGold, size: 32),
                    const SizedBox(width: 8),
                    Text(
                      '$_myPoints',
                      style: const TextStyle(
                        fontSize: 40,
                        fontWeight: FontWeight.bold,
                        color: AppColors.honeyGold,
                      ),
                    ),
                  ],
                ),
                const Text(
                  'points',
                  style: TextStyle(fontSize: 14, color: Colors.grey),
                ),
              ],
            ),
          ),
          // Tab content
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildRewardsTab(),
                _buildHistoryTab(),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showCreateRewardSheet,
        icon: const Icon(Icons.add),
        label: const Text('Add Reward'),
        backgroundColor: AppColors.honeyGold,
        foregroundColor: Colors.white,
      ),
    );
  }

  Widget _buildRewardsTab() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_rewards.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.card_giftcard, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              'No rewards yet',
              style: TextStyle(fontSize: 18, color: Colors.grey[600]),
            ),
            const SizedBox(height: 8),
            Text(
              'Create your own or add defaults',
              style: TextStyle(color: Colors.grey[500]),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: _showDefaultRewardsDialog,
              icon: const Icon(Icons.auto_awesome),
              label: const Text('Add Default Rewards'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.honeyGold,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        if (_rewards.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _showDefaultRewardsDialog,
                icon: const Icon(Icons.auto_awesome, size: 18),
                label: const Text('Add Defaults'),
              ),
            ),
          ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.85,
            ),
            itemCount: _rewards.length,
            itemBuilder: (context, index) {
              final reward = _rewards[index];
              final canAfford = _myPoints >= (reward['point_cost'] as int);

              return Card(
                elevation: 2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: InkWell(
                  onTap: canAfford ? () => _redeemReward(reward) : null,
                  borderRadius: BorderRadius.circular(16),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          reward['icon'] ?? '🎁',
                          style: const TextStyle(fontSize: 36),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          reward['title'],
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        if (reward['description'] != null)
                          Text(
                            reward['description'],
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey[600],
                            ),
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: canAfford
                                ? AppColors.honeyGold.withOpacity(0.2)
                                : Colors.grey[200],
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.stars,
                                size: 16,
                                color: canAfford
                                    ? AppColors.honeyGold
                                    : Colors.grey,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '${reward['point_cost']}',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: canAfford
                                      ? AppColors.honeyGold
                                      : Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (!canAfford)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              'Not enough points',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.grey[500],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildHistoryTab() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_redemptions.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.history, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              'No redemptions yet',
              style: TextStyle(fontSize: 18, color: Colors.grey[600]),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _redemptions.length,
      itemBuilder: (context, index) {
        final redemption = _redemptions[index];
        final reward = redemption['rewards'] as Map<String, dynamic>?;
        final member = redemption['household_members'] as Map<String, dynamic>?;
        final status = redemption['status'] as String? ?? 'pending';
        final isPending = status == 'pending';
        final isApproved = status == 'approved';

        Color statusColor;
        IconData statusIcon;
        String statusText;

        switch (status) {
          case 'approved':
            statusColor = AppColors.grassGreen;
            statusIcon = Icons.check_circle;
            statusText = 'Approved';
            break;
          case 'denied':
            statusColor = AppColors.coral;
            statusIcon = Icons.cancel;
            statusText = 'Denied';
            break;
          default:
            statusColor = AppColors.honeyGold;
            statusIcon = Icons.schedule;
            statusText = 'Pending';
        }

        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Text(
                  reward?['icon'] ?? '🎁',
                  style: const TextStyle(fontSize: 32),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        reward?['title'] ?? 'Unknown Reward',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Redeemed by ${member?['display_name'] ?? 'Unknown'}',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey[600],
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _formatDate(redemption['redeemed_at']),
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey[500],
                        ),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(statusIcon, size: 16, color: statusColor),
                        const SizedBox(width: 4),
                        Text(
                          statusText,
                          style: TextStyle(
                            fontSize: 12,
                            color: statusColor,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${redemption['point_cost']} pts',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (isPending && Permissions.canManageRewards(_myMembership))
                      TextButton(
                        onPressed: () => _approveRedemption(redemption),
                        child: const Text('Approve'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _formatDate(String? dateStr) {
    if (dateStr == null) return '';
    final date = DateTime.tryParse(dateStr);
    if (date == null) return '';
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${date.month}/${date.day}/${date.year}';
  }
}