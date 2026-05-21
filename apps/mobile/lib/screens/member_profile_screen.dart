import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';

/// Public profile screen for a household member.
/// Viewable by tapping on a member in the leaderboard or stats.
class MemberProfileScreen extends StatefulWidget {
  final String memberId;

  const MemberProfileScreen({super.key, required this.memberId});

  @override
  State<MemberProfileScreen> createState() => _MemberProfileScreenState();
}

class _MemberProfileScreenState extends State<MemberProfileScreen> {
  Map<String, dynamic>? _member;
  Map<String, dynamic>? _stats;
  List<Map<String, dynamic>> _recentChores = [];
  List<Map<String, dynamic>> _badges = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    try {
      // Load member profile
      final member = await Supabase.instance.client
          .from('household_members')
          .select('*')
          .eq('id', widget.memberId)
          .limit(1);

      if (member.isEmpty) {
        setState(() => _isLoading = false);
        return;
      }

      _member = member[0];
      final householdId = _member!['household_id'];

      // Load stats in parallel
      final results = await Future.wait([
        // Total completed chores
        Supabase.instance.client
            .from('chores')
            .select('id')
            .eq('assigned_to_member_id', widget.memberId)
            .inFilter('status', ['verified', 'completed']),
        // Total points earned
        Supabase.instance.client
            .from('point_transactions')
            .select('amount')
            .eq('member_id', widget.memberId)
            .eq('transaction_type', 'earned'),
        // Current streak (from leaderboard function)
        Supabase.instance.client.rpc('get_leaderboard', params: {'p_household_id': householdId}),
        // Recent chores
        Supabase.instance.client
            .from('chores')
            .select('id, title, status, difficulty, point_value, due_at, completed_at')
            .eq('assigned_to_member_id', widget.memberId)
            .order('created_at', ascending: false)
            .limit(10),
        // Badges
        Supabase.instance.client
            .from('member_badges')
            .select('*, badges(*)')
            .eq('member_id', widget.memberId)
            .order('earned_at', ascending: false)
            .limit(20),
      ]);

      final completedChores = results[0] as List;
      final pointsRows = results[1] as List;
      final leaderboardResults = results[2] as List;
      final recentChores = results[3] as List;
      final badges = results[4] as List;

      // Calculate total points
      int totalPoints = 0;
      for (final row in pointsRows) {
        totalPoints += (row['amount'] as num?)?.toInt() ?? 0;
      }

      // Find streak from leaderboard
      int streak = 0;
      int rank = 0;
      for (final entry in leaderboardResults) {
        if (entry['member_id'] == widget.memberId || entry['id'] == widget.memberId) {
          streak = (entry['current_streak'] as num?)?.toInt() ?? 0;
          rank = (entry['rank'] as num?)?.toInt() ?? 0;
          break;
        }
      }

      setState(() {
        _stats = {
          'completed_chore_count': completedChores.length,
          'total_points_earned': totalPoints,
          'current_streak': streak,
          'rank': rank,
        };
        _recentChores = List<Map<String, dynamic>>.from(recentChores);
        _badges = List<Map<String, dynamic>>.from(badges);
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading profile: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _member == null
              ? const Center(child: Text('Member not found'))
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      // Profile header
                      _buildProfileHeader(),
                      const SizedBox(height: 24),

                      // Stats cards
                      _buildStatsRow(),
                      const SizedBox(height: 24),

                      // Badges section
                      if (_badges.isNotEmpty) ...[
                        _buildSectionHeader('Badges', Icons.military_tech_rounded),
                        const SizedBox(height: 12),
                        _buildBadgesGrid(),
                        const SizedBox(height: 24),
                      ],

                      // Recent chores section
                      _buildSectionHeader('Recent Chores', Icons.task_alt_rounded),
                      const SizedBox(height: 12),
                      _buildRecentChoresList(),
                    ],
                  ),
                ),
    );
  }

  Widget _buildProfileHeader() {
    final displayName = _member!['display_name'] ?? 'Unknown';
    final kind = _member!['kind'] ?? 'adult_auth_user';
    final role = _member!['role'] ?? 'member';
    final avatarUrl = _member!['avatar_url'];
    final pointsBalance = _member!['points_balance'] ?? 0;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.honeyGold, Color(0xFFF5A623)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: AppColors.honeyGold.withOpacity(.3),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          CircleAvatar(
            radius: 40,
            backgroundColor: Colors.white,
            backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl) : null,
            child: avatarUrl == null
                ? Text(
                    kind == 'sub_profile' ? '\ud83d\udc76' : displayName[0].toUpperCase(),
                    style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: AppColors.honeyGold),
                  )
                : null,
          ),
          const SizedBox(height: 12),
          Text(
            displayName,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Colors.white),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(.25),
                  borderRadius: BorderRadius.circular(100),
                ),
                child: Text(
                  kind == 'sub_profile' ? '\ud83d\udc76 Kid Profile' : 'Adult',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(.25),
                  borderRadius: BorderRadius.circular(100),
                ),
                child: Text(
                  role == 'owner' ? '\ud83d\udc51 Owner' : role == 'admin' ? '\u2b50 Admin' : 'Member',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.star_rounded, color: Colors.white, size: 20),
              const SizedBox(width: 4),
              Text(
                '$pointsBalance pts',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.white),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatsRow() {
    final completedCount = _stats?['completed_chore_count'] ?? 0;
    final totalEarned = _stats?['total_points_earned'] ?? 0;
    final streak = _stats?['current_streak'] ?? 0;
    final rank = _stats?['rank'] ?? 0;

    return Row(
      children: [
        _buildStatCard(Icons.check_circle_rounded, 'Completed', '$completedCount', AppColors.grassGreen),
        const SizedBox(width: 8),
        _buildStatCard(Icons.star_rounded, 'Earned', '$totalEarned', AppColors.honeyGold),
        const SizedBox(width: 8),
        _buildStatCard(Icons.local_fire_department_rounded, 'Streak', '${streak}d', AppColors.coral),
        const SizedBox(width: 8),
        _buildStatCard(Icons.emoji_events_rounded, 'Rank', '#$rank', AppColors.skyBlue),
      ],
    );
  }

  Widget _buildStatCard(IconData icon, String label, String value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withOpacity(.1),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withOpacity(.3)),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(height: 4),
            Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: color)),
            Text(label, style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 20, color: Colors.grey.shade700),
        const SizedBox(width: 8),
        Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Colors.grey.shade800)),
      ],
    );
  }

  Widget _buildBadgesGrid() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _badges.map((badge) {
        final badgeData = badge['badges'] as Map<String, dynamic>?;
        final name = badgeData?['name'] ?? 'Badge';
        final emoji = badgeData?['emoji'] ?? '\ud83c\udfc6';
        final earnedAt = badge['earned_at'];

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.honeyGold.withOpacity(.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.honeyGold.withOpacity(.3)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(emoji, style: const TextStyle(fontSize: 18)),
              const SizedBox(width: 6),
              Text(name, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildRecentChoresList() {
    if (_recentChores.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Icon(Icons.task_alt_outlined, size: 40, color: Colors.grey.shade300),
              const SizedBox(height: 8),
              Text('No chores yet', style: TextStyle(color: Colors.grey.shade400, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      );
    }

    return Column(
      children: _recentChores.map((chore) {
        final status = chore['status'] ?? 'assigned';
        final difficulty = chore['difficulty'] ?? 'easy';
        final title = chore['title'] ?? '';
        final points = chore['point_value'] ?? 0;

        final statusColor = switch (status) {
          'verified' => AppColors.grassGreen,
          'completed' => AppColors.skyBlue,
          'in_progress' => AppColors.honeyGold,
          'assigned' => Colors.grey,
          'overdue' => AppColors.coral,
          _ => Colors.grey,
        };

        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Row(
            children: [
              Container(
                width: 4,
                height: 36,
                decoration: BoxDecoration(
                  color: statusColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                    const SizedBox(height: 2),
                    Text(
                      status.replaceAll('_', ' ').toUpperCase(),
                      style: TextStyle(fontSize: 11, color: statusColor, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.honeyGold.withOpacity(.15),
                  borderRadius: BorderRadius.circular(100),
                ),
                child: Text('$points pts', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.honeyGold)),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}
