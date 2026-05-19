import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';

/// Point transaction history screen showing all point activity.
class PointHistoryScreen extends StatefulWidget {
  const PointHistoryScreen({super.key});

  @override
  State<PointHistoryScreen> createState() => _PointHistoryScreenState();
}

class _PointHistoryScreenState extends State<PointHistoryScreen> {
  Map<String, dynamic>? _household;
  Map<String, dynamic>? _myMembership;
  List<Map<String, dynamic>> _transactions = [];
  bool _isLoading = true;
  String? _filterType;

  @override
  void initState() {
    super.initState();
    _loadData();
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
      final memberId = _myMembership!['id'];

      var query = Supabase.instance.client
          .from('point_transactions')
          .select('*')
          .eq('household_id', householdId)
          .eq('member_id', memberId);

      if (_filterType != null) {
        query = query.eq('type', _filterType!);
      }

      final transactions = await query.order('created_at', ascending: false).limit(100);

      setState(() {
        _transactions = List<Map<String, dynamic>>.from(transactions);
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading history: $e')),
        );
      }
    }
  }

  int get _myPoints => _myMembership?['points_balance'] ?? 0;

  int get _totalEarned => _transactions
      .where((t) => (t['amount'] as int?) ?? 0 > 0)
      .fold(0, (sum, t) => sum + ((t['amount'] as int?) ?? 0));

  int get _totalSpent => _transactions
      .where((t) => (t['amount'] as int?) ?? 0 < 0)
      .fold(0, (sum, t) => sum + ((t['amount'] as int?) ?? 0).abs());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Point History 📊'),
      ),
      body: Column(
        children: [
          // Summary cards
          Container(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Card(
                    color: AppColors.honeyGold.withOpacity(0.1),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          const Icon(Icons.stars, color: AppColors.honeyGold, size: 24),
                          const SizedBox(height: 4),
                          Text(
                            '$_myPoints',
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Text('Balance', style: TextStyle(fontSize: 12)),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Card(
                    color: AppColors.grassGreen.withOpacity(0.1),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          const Icon(Icons.add_circle, color: AppColors.grassGreen, size: 24),
                          const SizedBox(height: 4),
                          Text(
                            '$_totalEarned',
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: AppColors.grassGreen,
                            ),
                          ),
                          const Text('Earned', style: TextStyle(fontSize: 12)),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Card(
                    color: AppColors.coral.withOpacity(0.1),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          const Icon(Icons.remove_circle, color: AppColors.coral, size: 24),
                          const SizedBox(height: 4),
                          Text(
                            '$_totalSpent',
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: AppColors.coral,
                            ),
                          ),
                          const Text('Spent', style: TextStyle(fontSize: 12)),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Filter chips
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              children: [
                FilterChip(
                  label: const Text('All'),
                  selected: _filterType == null,
                  onSelected: (selected) {
                    setState(() => _filterType = null);
                    _loadData();
                  },
                ),
                FilterChip(
                  label: const Text('Earned'),
                  selected: _filterType == 'earned',
                  onSelected: (selected) {
                    setState(() => _filterType = selected ? 'earned' : null);
                    _loadData();
                  },
                ),
                FilterChip(
                  label: const Text('Spent'),
                  selected: _filterType == 'spent',
                  onSelected: (selected) {
                    setState(() => _filterType = selected ? 'spent' : null);
                    _loadData();
                  },
                ),
                FilterChip(
                  label: const Text('Bonus'),
                  selected: _filterType == 'bonus',
                  onSelected: (selected) {
                    setState(() => _filterType = selected ? 'bonus' : null);
                    _loadData();
                  },
                ),
                FilterChip(
                  label: const Text('Adjusted'),
                  selected: _filterType == 'adjusted',
                  onSelected: (selected) {
                    setState(() => _filterType = selected ? 'adjusted' : null);
                    _loadData();
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),

          // Transaction list
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _transactions.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.receipt_long, size: 64, color: Colors.grey[400]),
                            const SizedBox(height: 16),
                            Text(
                              'No transactions yet',
                              style: TextStyle(fontSize: 18, color: Colors.grey[600]),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Complete chores to earn points!',
                              style: TextStyle(color: Colors.grey[500]),
                            ),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _loadData,
                        child: ListView.builder(
                          padding: const EdgeInsets.all(16),
                          itemCount: _transactions.length,
                          itemBuilder: (context, index) {
                            final tx = _transactions[index];
                            final amount = tx['amount'] as int? ?? 0;
                            final isPositive = amount > 0;
                            final type = tx['type'] as String? ?? 'earned';

                            Color typeColor;
                            IconData typeIcon;
                            String typeLabel;

                            switch (type) {
                              case 'earned':
                                typeColor = AppColors.grassGreen;
                                typeIcon = Icons.add_circle;
                                typeLabel = 'Earned';
                                break;
                              case 'spent':
                                typeColor = AppColors.coral;
                                typeIcon = Icons.remove_circle;
                                typeLabel = 'Spent';
                                break;
                              case 'bonus':
                                typeColor = AppColors.honeyGold;
                                typeIcon = Icons.auto_awesome;
                                typeLabel = 'Bonus';
                                break;
                              case 'adjusted':
                                typeColor = AppColors.skyBlue;
                                typeIcon = Icons.tune;
                                typeLabel = 'Adjusted';
                                break;
                              case 'reversed':
                                typeColor = Colors.grey;
                                typeIcon = Icons.undo;
                                typeLabel = 'Reversed';
                                break;
                              default:
                                typeColor = Colors.grey;
                                typeIcon = Icons.circle;
                                typeLabel = type;
                            }

                            return Card(
                              margin: const EdgeInsets.only(bottom: 8),
                              child: ListTile(
                                leading: Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: typeColor.withOpacity(0.1),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(typeIcon, color: typeColor, size: 20),
                                ),
                                title: Text(
                                  tx['note'] ?? typeLabel,
                                  style: const TextStyle(fontSize: 14),
                                ),
                                subtitle: Text(
                                  _formatDate(tx['created_at']),
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey[500],
                                  ),
                                ),
                                trailing: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      isPositive ? '+$amount' : '$amount',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        color: isPositive
                                            ? AppColors.grassGreen
                                            : AppColors.coral,
                                      ),
                                    ),
                                    Text(
                                      'Balance: ${tx['balance_after'] ?? '?'}',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.grey[500],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
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
    return '${date.month}/${date.day}/${date.year} at ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
  }
}