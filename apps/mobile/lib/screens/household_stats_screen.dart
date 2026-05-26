import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../utils/membership.dart';
import 'member_profile_screen.dart';

/// Household statistics dashboard with visual breakdowns of activity,
/// chore completion rates, top contributors, and meal planning stats.
class HouseholdStatsScreen extends StatefulWidget {
  const HouseholdStatsScreen({super.key});

  @override
  State<HouseholdStatsScreen> createState() => _HouseholdStatsScreenState();
}

class _HouseholdStatsScreenState extends State<HouseholdStatsScreen> {
  Map<String, dynamic>? _household;
  Map<String, dynamic>? _myMembership;
  bool _isLoading = true;

  // Stats data
  int _totalChores = 0;
  int _completedChores = 0;
  int _verifiedChores = 0;
  int _overdueChores = 0;
  int _totalPointsEarned = 0;
  int _totalPointsSpent = 0;
  int _totalRecipes = 0;
  int _totalMealPlans = 0;
  int _totalShoppingItems = 0;
  int _completedShoppingItems = 0;
  int _totalMembers = 0;
  int _totalRewardsRedeemed = 0;
  List<Map<String, dynamic>> _topMembers = [];
  List<Map<String, dynamic>> _weeklyActivity = [];
  int _currentStreak = 0;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);

    try {
      // Batch 7a-iii — Pattern A (LOW-risk): household-wide stats, no
      // permission gating on _myMembership. Numbers are the same for kid and
      // admin within the same household. No listener needed.
      final membership = await MembershipHelper.loadActiveMembership(
        includeHouseholdJoin: true,
      );
      if (membership == null) {
        setState(() => _isLoading = false);
        return;
      }

      _myMembership = membership;
      _household = membership['households'];
      final householdId = _household!['id'];

      // Load all stats in parallel
      final results = await Future.wait([
        // Chores stats
        Supabase.instance.client
            .from('chores')
            .select('status, point_value')
            .eq('household_id', householdId),
        // Points earned
        Supabase.instance.client
            .from('point_transactions')
            .select('type, amount')
            .eq('household_id', householdId),
        // Recipes count
        Supabase.instance.client
            .from('household_recipes')
            .select('id')
            .eq('household_id', householdId),
        // Meal plans count
        Supabase.instance.client
            .from('meal_plans')
            .select('id')
            .eq('household_id', householdId),
        // Shopping items
        Supabase.instance.client
            .from('shopping_items')
            .select('purchased')
            .eq('household_id', householdId),
        // Members with points
        Supabase.instance.client
            .from('household_members')
            .select('id, display_name, points_balance, avatar_url')
            .eq('household_id', householdId)
            .eq('is_active', true)
            .order('points_balance', ascending: false),
        // Reward redemptions
        Supabase.instance.client
            .from('reward_redemptions')
            .select('id')
            .eq('household_id', householdId),
        // Recent chore completions for streak calc
        Supabase.instance.client
            .from('chores')
            .select('completed_at')
            .eq('household_id', householdId)
            .not('completed_at', 'is', null)
            .order('completed_at', ascending: false)
            .limit(30),
      ]);

      // Process chores
      final chores = List<Map<String, dynamic>>.from(results[0]);
      _totalChores = chores.length;
      _completedChores = chores.where((c) => c['status'] == 'verified' || c['status'] == 'pending_verification').length;
      _verifiedChores = chores.where((c) => c['status'] == 'verified').length;
      _overdueChores = chores.where((c) => c['status'] == 'overdue').length;

      // Process points
      final transactions = List<Map<String, dynamic>>.from(results[1]);
      _totalPointsEarned = transactions
          .where((t) => t['type'] == 'earned' || t['type'] == 'bonus')
          .fold<int>(0, (sum, t) => sum + ((t['amount'] as int?) ?? 0));
      _totalPointsSpent = transactions
          .where((t) => t['type'] == 'spent')
          .fold<int>(0, (sum, t) => sum + ((t['amount'] as int?) ?? 0).abs());

      // Other counts
      _totalRecipes = (results[2] as List).length;
      _totalMealPlans = (results[3] as List).length;

      final shoppingItems = List<Map<String, dynamic>>.from(results[4]);
      _totalShoppingItems = shoppingItems.length;
      _completedShoppingItems = shoppingItems.where((i) => i['purchased'] == true).length;

      _topMembers = List<Map<String, dynamic>>.from(results[5]);
      _totalMembers = _topMembers.length;

      _totalRewardsRedeemed = (results[6] as List).length;

      // Calculate streak
      final completions = List<Map<String, dynamic>>.from(results[7]);
      _currentStreak = _calculateStreak(completions);

      // Build weekly activity data
      _weeklyActivity = _buildWeeklyActivity(completions);

      setState(() => _isLoading = false);
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  int _calculateStreak(List<Map<String, dynamic>> completions) {
    if (completions.isEmpty) return 0;

    final dates = <DateTime>{};
    for (final c in completions) {
      try {
        final date = DateTime.parse(c['completed_at'].toString());
        dates.add(DateTime(date.year, date.month, date.day));
      } catch (_) {}
    }

    if (dates.isEmpty) return 0;

    final sortedDates = dates.toList()..sort((a, b) => b.compareTo(a));
    int streak = 0;
    DateTime? lastDate;

    for (final date in sortedDates) {
      if (lastDate == null) {
        final today = DateTime.now();
        final yesterday = DateTime(today.year, today.month, today.day - 1);
        if (date == DateTime(today.year, today.month, today.day) || date == yesterday) {
          streak = 1;
          lastDate = date;
        } else {
          break;
        }
      } else {
        final expectedPrev = DateTime(lastDate.year, lastDate.month, lastDate.day - 1);
        if (date == expectedPrev) {
          streak++;
          lastDate = date;
        } else {
          break;
        }
      }
    }

    return streak;
  }

  List<Map<String, dynamic>> _buildWeeklyActivity(List<Map<String, dynamic>> completions) {
    final now = DateTime.now();
    final weekAgo = now.subtract(const Duration(days: 7));
    final activity = <Map<String, dynamic>>[];

    for (int i = 6; i >= 0; i--) {
      final day = now.subtract(Duration(days: i));
      final dayStart = DateTime(day.year, day.month, day.day);
      final dayEnd = dayStart.add(const Duration(days: 1));

      final count = completions.where((c) {
        try {
          final date = DateTime.parse(c['completed_at'].toString());
          return date.isAfter(dayStart) && date.isBefore(dayEnd);
        } catch (_) {
          return false;
        }
      }).length;

      activity.add({
        'day': dayStart,
        'count': count,
      });
    }

    return activity;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Household Stats 📊'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loadData,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadData,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // Household name
                  if (_household != null)
                    Card(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Row(
                          children: [
                            Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(colors: [AppColors.honeyGold, Color(0xFFFF8F00)]),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: const Center(child: Text('🏠', style: TextStyle(fontSize: 24))),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _household!['name'] ?? 'My Household',
                                    style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
                                  ),
                                  Text(
                                    '$_totalMembers member${_totalMembers == 1 ? '' : 's'} · ${_currentStreak} day streak 🔥',
                                    style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),

                  // Completion rate card
                  _StatCard(
                    title: 'Chore Completion Rate',
                    value: _totalChores > 0 ? '${((_verifiedChores / _totalChores) * 100).round()}%' : '0%',
                    subtitle: '$_verifiedChores of $_totalChores chores verified',
                    progress: _totalChores > 0 ? _verifiedChores / _totalChores : 0,
                    color: AppColors.grassGreen,
                    icon: Icons.task_alt_rounded,
                  ),
                  const SizedBox(height: 12),

                  // Weekly activity chart
                  Card(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.bar_chart_rounded, color: AppColors.skyBlue, size: 20),
                              const SizedBox(width: 8),
                              Text('Weekly Activity', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                            ],
                          ),
                          const SizedBox(height: 20),
                          SizedBox(
                            height: 120,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: _weeklyActivity.map((day) {
                                final count = day['count'] as int;
                                final maxCount = _weeklyActivity.map((d) => d['count'] as int).reduce((a, b) => a > b ? a : b);
                                final height = maxCount > 0 ? count / maxCount : 0.0;
                                final date = day['day'] as DateTime;
                                final isToday = date.day == DateTime.now().day && date.month == DateTime.now().month;

                                return Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 4),
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        if (count > 0)
                                          Text('$count', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
                                        const SizedBox(height: 4),
                                        Container(
                                          height: (height * 80).clamp(4, 80).toDouble(),
                                          decoration: BoxDecoration(
                                            gradient: LinearGradient(
                                              begin: Alignment.topCenter,
                                              end: Alignment.bottomCenter,
                                              colors: isToday
                                                  ? [AppColors.honeyGold, const Color(0xFFFF8F00)]
                                                  : [AppColors.skyBlue.withValues(alpha:.7), AppColors.skyBlue],
                                            ),
                                            borderRadius: BorderRadius.circular(6),
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          ['M', 'T', 'W', 'T', 'F', 'S', 'S'][date.weekday - 1],
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: isToday ? FontWeight.w800 : FontWeight.w500,
                                            color: isToday ? AppColors.honeyGold : Colors.grey,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Quick stats grid
                  Row(
                    children: [
                      Expanded(
                        child: _QuickStatCard(
                          label: 'Points Earned',
                          value: '$_totalPointsEarned',
                          icon: Icons.stars_rounded,
                          color: AppColors.honeyGold,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _QuickStatCard(
                          label: 'Points Spent',
                          value: '$_totalPointsSpent',
                          icon: Icons.shopping_cart_rounded,
                          color: AppColors.coral,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _QuickStatCard(
                          label: 'Recipes',
                          value: '$_totalRecipes',
                          icon: Icons.menu_book_rounded,
                          color: AppColors.coral,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _QuickStatCard(
                          label: 'Meal Plans',
                          value: '$_totalMealPlans',
                          icon: Icons.calendar_month_rounded,
                          color: AppColors.grassGreen,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _QuickStatCard(
                          label: 'Shopping',
                          value: '$_completedShoppingItems/$_totalShoppingItems',
                          icon: Icons.shopping_basket_rounded,
                          color: AppColors.skyBlue,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _QuickStatCard(
                          label: 'Rewards',
                          value: '$_totalRewardsRedeemed',
                          icon: Icons.card_giftcard_rounded,
                          color: const Color(0xFFAB47BC),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Top members leaderboard
                  if (_topMembers.isNotEmpty) ...[
                    Card(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.emoji_events_rounded, color: AppColors.honeyGold, size: 20),
                                const SizedBox(width: 8),
                                Text('Leaderboard', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                              ],
                            ),
                            const SizedBox(height: 16),
                            ..._topMembers.take(5).toList().asMap().entries.map((entry) {
                              final index = entry.key;
                              final member = entry.value;
                              final points = member['points_balance'] as int? ?? 0;
                              final name = member['display_name'] ?? 'Unknown';
                              final medals = ['🥇', '🥈', '🥉'];

                              return InkWell(
                                borderRadius: BorderRadius.circular(12),
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(builder: (_) => MemberProfileScreen(memberId: member['id'])),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: 28,
                                        child: index < 3
                                            ? Text(medals[index], style: const TextStyle(fontSize: 18))
                                            : Text('${index + 1}', style: TextStyle(fontWeight: FontWeight.w700, color: Colors.grey.shade400)),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Text(name, style: const TextStyle(fontWeight: FontWeight.w700)),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: AppColors.honeyGold.withValues(alpha:.1),
                                          borderRadius: BorderRadius.circular(100),
                                        ),
                                        child: Text(
                                          '$points pts',
                                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.honeyGold),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            }),
                          ],
                        ),
                      ),
                    ),
                  ],

                  // Overdue chores warning
                  if (_overdueChores > 0) ...[
                    const SizedBox(height: 12),
                    Card(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: const BorderSide(color: AppColors.coral, width: 2),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Row(
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: AppColors.coral.withValues(alpha:.12),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(Icons.warning_amber_rounded, color: AppColors.coral),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '$_overdueChores Overdue Chore${_overdueChores == 1 ? '' : 's'}',
                                    style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.coral),
                                  ),
                                  const Text('These chores need attention!', style: TextStyle(fontSize: 13)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],

                  const SizedBox(height: 32),
                ],
              ),
            ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.title,
    required this.value,
    required this.subtitle,
    required this.progress,
    required this.color,
    required this.icon,
  });

  final String title;
  final String value;
  final String subtitle;
  final double progress;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 20),
                const SizedBox(width: 8),
                Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
              ],
            ),
            const SizedBox(height: 16),
            Text(value, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900, color: color)),
            const SizedBox(height: 4),
            Text(subtitle, style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(100),
              child: LinearProgressIndicator(
                value: progress.clamp(0.0, 1.0),
                minHeight: 8,
                backgroundColor: color.withValues(alpha:.15),
                valueColor: AlwaysStoppedAnimation(color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickStatCard extends StatelessWidget {
  const _QuickStatCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 18),
                const Spacer(),
              ],
            ),
            const SizedBox(height: 12),
            Text(value, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(fontSize: 12, color: Colors.grey.shade600, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}
