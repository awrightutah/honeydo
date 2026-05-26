import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../services/active_member_service.dart';
import '../utils/membership.dart';

/// Activity feed screen showing recent household activity.
class ActivityFeedScreen extends StatefulWidget {
  const ActivityFeedScreen({super.key});

  @override
  State<ActivityFeedScreen> createState() => _ActivityFeedScreenState();
}

class _ActivityFeedScreenState extends State<ActivityFeedScreen> {
  List<Map<String, dynamic>> _activities = [];
  Map<String, dynamic>? _householdMember;
  bool _isLoading = true;
  String _filter = 'all'; // all, chores, meals, achievements, members

  @override
  void initState() {
    super.initState();
    _loadData();
    // Batch 6b — reload when the user switches to a kid/admin profile so the
    // feed reflects the active perspective (kid sub_profile vs adult auth row).
    ActiveMemberService.instance.activeMemberId
        .addListener(_onActiveMemberChanged);
  }

  @override
  void dispose() {
    ActiveMemberService.instance.activeMemberId
        .removeListener(_onActiveMemberChanged);
    super.dispose();
  }

  void _onActiveMemberChanged() {
    if (mounted) _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);

    try {
      // Batch 6b — use MembershipHelper so kid sessions resolve to the kid
      // sub_profile row instead of silently coercing to the parent admin.
      final membership = await MembershipHelper.loadActiveMembership(
        includeHouseholdJoin: true,
      );

      if (membership == null) {
        setState(() => _isLoading = false);
        return;
      }

      _householdMember = membership;
      final householdId = _householdMember!['household_id'];

      // Build activity feed from multiple sources
      final List<Map<String, dynamic>> allActivities = [];

      // 1. Chore completions
      try {
        final chores = await Supabase.instance.client
            .from('chores')
            .select('id, title, status, completed_at, point_value, assigned_to_member_id, household_members!chores_assigned_to_member_id_fkey(display_name, kind)')
            .eq('household_id', householdId)
            .inFilter('status', ['verified', 'pending_verification'])
            .order('completed_at', ascending: false)
            .limit(20);

        for (final chore in chores) {
          if (chore['completed_at'] != null) {
            allActivities.add({
              'type': 'chore_completed',
              'timestamp': chore['completed_at'],
              'member_name': chore['household_members']?['display_name'] ?? 'Someone',
              'member_kind': chore['household_members']?['kind'] ?? 'adult_auth_user',
              'title': chore['title'],
              'points': chore['point_value'] ?? 0,
              'status': chore['status'],
              'id': chore['id'],
            });
          }
        }
      } catch (_) {}

      // 2. Achievements earned
      try {
        final achievements = await Supabase.instance.client
            .from('achievements')
            .select('earned_at, badge_name, icon, household_members!achievements_member_id_fkey(display_name, kind)')
            .eq('household_id', householdId)
            .order('earned_at', ascending: false)
            .limit(20);

        for (final achievement in achievements) {
          allActivities.add({
            'type': 'achievement_earned',
            'timestamp': achievement['earned_at'],
            'member_name': achievement['household_members']?['display_name'] ?? 'Someone',
            'member_kind': achievement['household_members']?['kind'] ?? 'adult_auth_user',
            'badge_name': achievement['badge_name'] ?? 'Badge',
            'badge_icon': achievement['icon'] ?? '🏆',
          });
        }
      } catch (_) {}

      // 3. Points transactions
      try {
        final transactions = await Supabase.instance.client
            .from('point_transactions')
            .select('created_at, amount, type, note, household_members!point_transactions_member_id_fkey(display_name, kind)')
            .eq('household_id', householdId)
            .order('created_at', ascending: false)
            .limit(20);

        for (final tx in transactions) {
          allActivities.add({
            'type': 'points',
            'timestamp': tx['created_at'],
            'member_name': tx['household_members']?['display_name'] ?? 'Someone',
            'member_kind': tx['household_members']?['kind'] ?? 'adult_auth_user',
            'amount': tx['amount'] ?? 0,
            'transaction_type': tx['type'] ?? 'earned',
            'reason': tx['note'] ?? '',
          });
        }
      } catch (_) {}

      // 4. Reward redemptions
      try {
        final redemptions = await Supabase.instance.client
            .from('reward_redemptions')
            .select('redeemed_at, point_cost, rewards(title, icon), household_members!reward_redemptions_member_id_fkey(display_name, kind)')
            .eq('household_id', householdId)
            .order('redeemed_at', ascending: false)
            .limit(20);

        for (final redemption in redemptions) {
          allActivities.add({
            'type': 'reward_redeemed',
            'timestamp': redemption['redeemed_at'],
            'member_name': redemption['household_members']?['display_name'] ?? 'Someone',
            'member_kind': redemption['household_members']?['kind'] ?? 'adult_auth_user',
            'reward_name': redemption['rewards']?['title'] ?? 'Reward',
            'points_cost': redemption['point_cost'] ?? 0,
          });
        }
      } catch (_) {}

      // 5. New members joined
      try {
        final newMembers = await Supabase.instance.client
            .from('household_members')
            .select('created_at, display_name, kind')
            .eq('household_id', householdId)
            .order('created_at', ascending: false)
            .limit(10);

        for (final member in newMembers) {
          allActivities.add({
            'type': 'member_joined',
            'timestamp': member['created_at'],
            'member_name': member['display_name'] ?? 'New Member',
            'member_kind': member['kind'] ?? 'adult_auth_user',
          });
        }
      } catch (_) {}

      // 6. Meal request decisions (Batch 6b). Only decided rows surface; a
      // pending request is not yet an "activity." Joins recipe (title) and
      // the requesting member (kid name + kind) so the entry can render as
      // "Randi's request for Pad Thai was approved/denied".
      try {
        final mealReqs = await Supabase.instance.client
            .from('meal_requests')
            .select(
                'id, decided_at, status, decided_note, '
                'household_recipes!meal_requests_recipe_id_fkey(title), '
                'household_members!meal_requests_requested_by_member_id_fkey(display_name, kind)')
            .eq('household_id', householdId)
            .neq('status', 'pending')
            .order('decided_at', ascending: false)
            .limit(20);

        for (final m in mealReqs) {
          allActivities.add({
            'type': 'meal_request_decided',
            'timestamp': m['decided_at'],
            'member_name':
                m['household_members']?['display_name'] ?? 'Someone',
            'member_kind':
                m['household_members']?['kind'] ?? 'adult_auth_user',
            'recipe_title': m['household_recipes']?['title'] ?? 'a meal',
            'status': m['status'],
            'decided_note': m['decided_note'],
            'id': m['id'],
          });
        }
      } catch (_) {}

      // Sort by timestamp
      allActivities.sort((a, b) {
        final aTime = DateTime.tryParse(a['timestamp'] ?? '') ?? DateTime.now();
        final bTime = DateTime.tryParse(b['timestamp'] ?? '') ?? DateTime.now();
        return bTime.compareTo(aTime);
      });

      setState(() {
        _activities = allActivities;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading activity: $e')),
        );
      }
    }
  }

  List<Map<String, dynamic>> get _filteredActivities {
    if (_filter == 'all') return _activities;
    return _activities.where((a) => a['type'] == _filter).toList();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredActivities;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Household Activity', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadData,
              child: Column(
                children: [
                  // Filter chips
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _buildFilterChip('all', 'All', Icons.list),
                          const SizedBox(width: 8),
                          _buildFilterChip('chore_completed', 'Chores', Icons.task_alt),
                          const SizedBox(width: 8),
                          _buildFilterChip('achievement_earned', 'Achievements', Icons.emoji_events),
                          const SizedBox(width: 8),
                          _buildFilterChip('points', 'Points', Icons.star),
                          const SizedBox(width: 8),
                          _buildFilterChip('reward_redeemed', 'Rewards', Icons.card_giftcard),
                          const SizedBox(width: 8),
                          _buildFilterChip('meal_request_decided', 'Meals', Icons.restaurant_menu),
                          const SizedBox(width: 8),
                          _buildFilterChip('member_joined', 'Members', Icons.person_add),
                        ],
                      ),
                    ),
                  ),

                  // Activity list
                  Expanded(
                    child: filtered.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.history, size: 64, color: Colors.grey.shade300),
                                const SizedBox(height: 16),
                                Text(
                                  'No activity yet',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.grey.shade500,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Start completing chores to see activity here!',
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Colors.grey.shade400,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            itemCount: filtered.length,
                            itemBuilder: (context, index) {
                              final activity = filtered[index];
                              return _buildActivityItem(activity);
                            },
                          ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildFilterChip(String value, String label, IconData icon) {
    final isSelected = _filter == value;
    return FilterChip(
      selected: isSelected,
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: isSelected ? Colors.white : AppColors.honeyGold),
          const SizedBox(width: 4),
          Text(label),
        ],
      ),
      selectedColor: AppColors.honeyGold,
      labelStyle: TextStyle(
        color: isSelected ? Colors.white : AppColors.honeyGold,
        fontWeight: FontWeight.w600,
        fontSize: 12,
      ),
      onSelected: (_) => setState(() => _filter = value),
    );
  }

  Widget _buildActivityItem(Map<String, dynamic> activity) {
    final type = activity['type'] ?? '';
    final memberName = activity['member_name'] ?? 'Someone';
    final timestamp = _formatTimestamp(activity['timestamp']);
    final isKid = activity['member_kind'] == 'sub_profile';

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Activity icon
          _buildActivityIcon(type, activity),
          const SizedBox(width: 12),

          // Activity content
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.grey.shade100),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Main activity text
                  RichText(
                    text: TextSpan(
                      style: DefaultTextStyle.of(context).style.copyWith(fontSize: 14),
                      children: [
                        TextSpan(
                          text: memberName,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        if (isKid) const TextSpan(text: ' 👦', style: TextStyle(fontSize: 14)),
                        TextSpan(text: _getActivityDescription(type, activity)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  // Timestamp
                  Text(
                    timestamp,
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActivityIcon(String type, Map<String, dynamic> activity) {
    return switch (type) {
      'chore_completed' => Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: AppColors.grassGreen.withOpacity(0.15),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.check_circle, color: AppColors.grassGreen, size: 20),
        ),
      'achievement_earned' => Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: AppColors.honeyGold.withOpacity(0.15),
            shape: BoxShape.circle,
          ),
          child: Text(activity['badge_icon'] ?? '🏆', style: const TextStyle(fontSize: 20)),
        ),
      'points' => Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: (activity['transaction_type'] == 'earned' ? AppColors.honeyGold : AppColors.coral).withOpacity(0.15),
            shape: BoxShape.circle,
          ),
          child: Icon(
            activity['transaction_type'] == 'earned' ? Icons.add_circle : Icons.remove_circle,
            color: activity['transaction_type'] == 'earned' ? AppColors.honeyGold : AppColors.coral,
            size: 20,
          ),
        ),
      'reward_redeemed' => Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: AppColors.skyBlue.withOpacity(0.15),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.card_giftcard, color: AppColors.skyBlue, size: 20),
        ),
      'member_joined' => Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Colors.purple.withOpacity(0.15),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.person_add, color: Colors.purple, size: 20),
        ),
      'meal_request_decided' => () {
          final approved = activity['status'] == 'approved';
          final color = approved ? AppColors.grassGreen : AppColors.coral;
          return Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withOpacity(0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.restaurant_menu, color: color, size: 20),
          );
        }(),
      _ => Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Colors.grey.withOpacity(0.15),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.info, color: Colors.grey, size: 20),
        ),
    };
  }

  String _getActivityDescription(String type, Map<String, dynamic> activity) {
    return switch (type) {
      'chore_completed' => ' completed "${activity['title']}" (+${activity['points']} pts)',
      'achievement_earned' => ' earned the "${activity['badge_name']}" badge',
      'points' => activity['transaction_type'] == 'earned'
          ? ' earned ${activity['amount']} points'
          : activity['transaction_type'] == 'spent'
              ? ' spent ${activity['amount']} points'
              : ' had ${activity['amount']} points adjusted',
      'reward_redeemed' => ' redeemed "${activity['reward_name']}" (-${activity['points_cost']} pts)',
      'member_joined' => ' joined the household',
      'meal_request_decided' => () {
          final approved = activity['status'] == 'approved';
          final title = activity['recipe_title'] ?? 'a meal';
          final note = (activity['decided_note'] as String?)?.trim();
          if (approved) {
            return ' had "$title" approved for the meal plan';
          }
          if (note != null && note.isNotEmpty) {
            return ' had "$title" denied — "$note"';
          }
          return ' had "$title" denied';
        }(),
      _ => ' did something',
    };
  }

  String _formatTimestamp(String? ts) {
    if (ts == null) return '';
    try {
      final dt = DateTime.parse(ts).toLocal();
      final now = DateTime.now();
      final diff = now.difference(dt);

      if (diff.inMinutes < 1) return 'Just now';
      if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
      if (diff.inHours < 24) return '${diff.inHours}h ago';
      if (diff.inDays == 1) return 'Yesterday';
      if (diff.inDays < 7) return '${diff.inDays}d ago';
      return '${dt.month}/${dt.day}/${dt.year}';
    } catch (_) {
      return ts;
    }
  }
}
