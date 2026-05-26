import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/active_member_service.dart';
import '../theme/app_theme.dart';
import '../utils/membership.dart';

/// Achievements screen showing earned and locked badges.
class AchievementsScreen extends StatefulWidget {
  const AchievementsScreen({super.key});

  @override
  State<AchievementsScreen> createState() => _AchievementsScreenState();
}

class _AchievementsScreenState extends State<AchievementsScreen> {
  Map<String, dynamic>? _household;
  Map<String, dynamic>? _myMembership;
  List<Map<String, dynamic>> _earnedAchievements = [];
  bool _isLoading = true;

  // All possible achievements (mirrors the check_and_award_achievements function)
  static const List<Map<String, dynamic>> _allBadges = [
    {'badge_key': 'first_chore', 'badge_name': 'First Chore', 'icon': '🎉', 'description': 'Completed your very first chore!', 'threshold': 1, 'category': 'chores'},
    {'badge_key': 'getting_started', 'badge_name': 'Getting Started', 'icon': '⭐', 'description': 'Completed 5 chores!', 'threshold': 5, 'category': 'chores'},
    {'badge_key': 'chore_champion', 'badge_name': 'Chore Champion', 'icon': '🏆', 'description': 'Completed 25 chores!', 'threshold': 25, 'category': 'chores'},
    {'badge_key': 'honeydo_hero', 'badge_name': 'Honeydo Hero', 'icon': '🤸', 'description': 'Completed 100 chores!', 'threshold': 100, 'category': 'chores'},
    {'badge_key': 'on_a_roll', 'badge_name': 'On a Roll', 'icon': '🔥', 'description': '3-day chore streak!', 'threshold': 3, 'category': 'streak'},
    {'badge_key': 'streak_master', 'badge_name': 'Streak Master', 'icon': '⚡', 'description': '7-day chore streak!', 'threshold': 7, 'category': 'streak'},
    {'badge_key': 'century_club', 'badge_name': 'Century Club', 'icon': '💯', 'description': 'Earned 100 points!', 'threshold': 100, 'category': 'points'},
    {'badge_key': 'point_tycoon', 'badge_name': 'Point Tycoon', 'icon': '💰', 'description': 'Earned 500 points!', 'threshold': 500, 'category': 'points'},
  ];

  @override
  void initState() {
    super.initState();
    _loadData();
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
      // Batch 7a-ii — MembershipHelper so kid sees their own earned badges,
      // not the parent admin's. The earned filter joins on `member_id`.
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
      final memberId = _myMembership!['id'];

      final achievements = await Supabase.instance.client
          .from('achievements')
          .select('*')
          .eq('household_id', householdId)
          .eq('member_id', memberId)
          .order('earned_at', ascending: false);

      setState(() {
        _earnedAchievements = List<Map<String, dynamic>>.from(achievements);
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('achievements load failed: $e');
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading achievements: $e')),
        );
      }
    }
  }

  Set<String> get _earnedBadgeKeys =>
      _earnedAchievements.map((a) => a['badge_key'] as String).toSet();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Achievements 🏆'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : CustomScrollView(
              slivers: [
                // Summary header
                SliverToBoxAdapter(
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          AppColors.honeyGold.withValues(alpha:0.1),
                          AppColors.skyBlue.withValues(alpha:0.05),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            ...List.generate(5, (index) {
                              final filled = index < (_earnedBadgeKeys.length / _allBadges.length * 5).ceil();
                              return Icon(
                                Icons.star,
                                color: filled ? AppColors.honeyGold : Colors.grey[300],
                                size: 32,
                              );
                            }),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '${_earnedBadgeKeys.length} of ${_allBadges.length}',
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Badges Earned',
                          style: TextStyle(fontSize: 14, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                ),

                // Chores category
                _buildCategoryHeader('Chore Milestones'),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: SliverGrid(
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: 1.1,
                    ),
                    delegate: SliverChildListDelegate(
                      _allBadges
                          .where((b) => b['category'] == 'chores')
                          .map((badge) => _buildBadgeCard(badge))
                          .toList(),
                    ),
                  ),
                ),

                // Streak category
                _buildCategoryHeader('Streak Badges'),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: SliverGrid(
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: 1.1,
                    ),
                    delegate: SliverChildListDelegate(
                      _allBadges
                          .where((b) => b['category'] == 'streak')
                          .map((badge) => _buildBadgeCard(badge))
                          .toList(),
                    ),
                  ),
                ),

                // Points category
                _buildCategoryHeader('Point Milestones'),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: SliverGrid(
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: 1.1,
                    ),
                    delegate: SliverChildListDelegate(
                      _allBadges
                          .where((b) => b['category'] == 'points')
                          .map((badge) => _buildBadgeCard(badge))
                          .toList(),
                    ),
                  ),
                ),

                // Recently earned
                if (_earnedAchievements.isNotEmpty) ...[
                  _buildCategoryHeader('Recently Earned'),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: SliverList(
                      delegate: SliverChildListDelegate(
                        _earnedAchievements.take(5).map((achievement) {
                          return Card(
                            margin: const EdgeInsets.only(bottom: 8),
                            child: ListTile(
                              leading: Text(
                                achievement['icon'] ?? '🏅',
                                style: const TextStyle(fontSize: 28),
                              ),
                              title: Text(
                                achievement['badge_name'] ?? 'Unknown',
                                style: const TextStyle(fontWeight: FontWeight.bold),
                              ),
                              subtitle: Text(
                                achievement['description'] ?? '',
                                style: TextStyle(color: Colors.grey[600]),
                              ),
                              trailing: Text(
                                _formatDate(achievement['earned_at']),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey[500],
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                ],

                const SliverPadding(padding: EdgeInsets.only(bottom: 80)),
              ],
            ),
    );
  }

  Widget _buildCategoryHeader(String title) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
        child: Text(
          title,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _buildBadgeCard(Map<String, dynamic> badge) {
    final isEarned = _earnedBadgeKeys.contains(badge['badge_key']);
    final earnedData = isEarned
        ? _earnedAchievements.firstWhere(
            (a) => a['badge_key'] == badge['badge_key'])
        : null;

    return Card(
      elevation: isEarned ? 3 : 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: isEarned
            ? BorderSide(color: AppColors.honeyGold.withValues(alpha:0.5), width: 2)
            : BorderSide.none,
      ),
      child: Container(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              children: [
                Text(
                  badge['icon'],
                  style: TextStyle(
                    fontSize: 40,
                    color: isEarned ? null : Colors.grey.withValues(alpha:0.3),
                  ),
                ),
                if (!isEarned)
                  Positioned.fill(
                    child: Center(
                      child: Icon(
                        Icons.lock,
                        size: 20,
                        color: Colors.grey[400],
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              badge['badge_name'],
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: isEarned ? null : Colors.grey,
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Text(
              badge['description'],
              style: TextStyle(
                fontSize: 11,
                color: isEarned ? Colors.grey[600] : Colors.grey[400],
              ),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            if (isEarned && earnedData != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _formatDate(earnedData['earned_at']),
                  style: TextStyle(
                    fontSize: 10,
                    color: AppColors.grassGreen,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _formatDate(String? dateStr) {
    if (dateStr == null) return '';
    final date = DateTime.tryParse(dateStr);
    if (date == null) return '';
    return '${date.month}/${date.day}/${date.year}';
  }
}