import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../services/realtime_service.dart';
import 'chore_dashboard_screen.dart';
import 'meal_planner_screen.dart';
import 'shopping_list_screen.dart';
import 'calendar_screen.dart';
import 'recipe_library_screen.dart';
import 'members_screen.dart';
import 'rewards_screen.dart';
import 'achievements_screen.dart';
import 'point_history_screen.dart';
import 'settings_screen.dart';
import 'profile_screen.dart';
import 'subscription_screen.dart';
import 'feedback_screen.dart';
import 'activity_feed_screen.dart';
import 'search_screen.dart';
import 'household_stats_screen.dart';
import 'chore_templates_screen.dart';
import 'invite_management_screen.dart';
import 'announcements_screen.dart';
import 'member_profile_screen.dart';
import 'data_export_screen.dart';
import '../services/feature_tour_service.dart';
import '../widgets/offline_banner.dart';

class HomeShellScreen extends StatefulWidget {
  const HomeShellScreen({super.key});

  @override
  State<HomeShellScreen> createState() => _HomeShellScreenState();
}

class _HomeShellScreenState extends State<HomeShellScreen> {
  int _currentIndex = 0;
  Map<String, dynamic>? _household;
  Map<String, dynamic>? _myMembership;
  bool _isLoading = true;
  Map<String, dynamic>? _pinnedAnnouncement;
  bool _showTour = false;

  late final List<Widget> _screens;

  @override
  void initState() {
    super.initState();
    _loadHouseholdInfo();
    // Listen for points changes to refresh the badge
    RealtimeService.instance.pointsVersion.addListener(_onPointsChanged);
    // Listen for announcement changes to refresh the banner
    RealtimeService.instance.announcementsVersion.addListener(_onAnnouncementChanged);
  }

  @override
  void dispose() {
    RealtimeService.instance.pointsVersion.removeListener(_onPointsChanged);
    RealtimeService.instance.announcementsVersion.removeListener(_onAnnouncementChanged);
    super.dispose();
  }

  void _onPointsChanged() {
    if (mounted) {
      // Reload membership to get updated points balance
      _loadHouseholdInfo();
    }
  }

  void _onAnnouncementChanged() {
    if (mounted) _loadHouseholdInfo();
  }

  Future<void> _loadHouseholdInfo() async {
    try {
      final user = Supabase.instance.client.auth.currentUser!;
      final memberships = await Supabase.instance.client
          .from('household_members')
          .select('*, households(*)')
          .eq('auth_user_id', user.id)
          .limit(1);

      if (memberships.isNotEmpty) {
        _myMembership = memberships[0];
        _household = memberships[0]['households'];
        // Subscribe to realtime updates for this household
        RealtimeService.instance.subscribe(_household!['id']);

        // Load pinned announcement
        try {
          final pinned = await Supabase.instance.client
              .from('announcements')
              .select('title, message')
              .eq('household_id', _household!['id'])
              .eq('is_pinned', true)
              .order('created_at', ascending: false)
              .limit(1);
          _pinnedAnnouncement = pinned.isNotEmpty ? pinned[0] : null;
        } catch (_) {
          _pinnedAnnouncement = null;
        }
      }
    } catch (_) {
      // Silently handle - screens will show their own errors
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
        _buildScreens();
        // Show feature tour for first-time users
        if (!FeatureTourService.instance.tourCompleted) {
          Future.delayed(const Duration(milliseconds: 800), () {
            if (mounted) setState(() => _showTour = true);
          });
        }
      }
    }
  }

  void _buildScreens() {
    _screens = [
      const ChoreDashboardScreen(),
      const MealPlannerScreen(),
      const ShoppingListScreen(),
      const CalendarScreen(),
      const RecipeLibraryScreen(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final scaffold = Scaffold(
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                const OfflineBanner(),
                if (_pinnedAnnouncement != null)
                  Semantics(
                    label: 'Pinned announcement: ${_pinnedAnnouncement!['title']}. Tap to view.',
                    button: true,
                    child: Material(
                    color: AppColors.honeyGold.withOpacity(.15),
                    child: InkWell(
                      onTap: () {
                        Navigator.push(context, MaterialPageRoute(builder: (_) => const AnnouncementsScreen()));
                      },
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        child: Row(
                          children: [
                            const Icon(Icons.push_pin_rounded, size: 16, color: AppColors.honeyGold),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _pinnedAnnouncement!['title'] ?? '',
                                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppColors.honeyGold),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const Icon(Icons.chevron_right_rounded, size: 16, color: AppColors.honeyGold),
                          ],
                        ),
                      ),
                    ),
                  ),
                  ),
                Expanded(
                  child: IndexedStack(
                    index: _currentIndex,
                    children: _screens,
                  ),
                ),
              ],
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (value) => setState(() => _currentIndex = value),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.task_alt_rounded), label: 'Chores'),
          NavigationDestination(icon: Icon(Icons.restaurant_menu_rounded), label: 'Meals'),
          NavigationDestination(icon: Icon(Icons.shopping_cart_rounded), label: 'Shop'),
          NavigationDestination(icon: Icon(Icons.calendar_month_rounded), label: 'Calendar'),
          NavigationDestination(icon: Icon(Icons.menu_book_rounded), label: 'Recipes'),
        ],
      ),
      appBar: _isLoading
          ? null
          : AppBar(
              title: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_household?['emoji'] != null && (_household!['emoji'] as String).isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(
                        _household!['emoji'],
                        style: const TextStyle(fontSize: 22),
                      ),
                    ),
                  Flexible(
                    child: Text(
                      _household?['name'] ?? 'Honeydo',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              actions: [
                // Points badge
                if (_myMembership != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Semantics(
                      label: 'Points balance: ${_myMembership!['points_balance'] ?? 0}. Tap to view history.',
                      button: true,
                      child: TextButton.icon(
                      onPressed: () => _navigateToPointHistory(),
                      icon: const Icon(Icons.star_rounded, size: 18, color: AppColors.honeyGold),
                      label: Text(
                        '${_myMembership!['points_balance'] ?? 0}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          color: AppColors.honeyGold,
                          fontSize: 14,
                        ),
                      ),
                      style: TextButton.styleFrom(
                        backgroundColor: AppColors.honeyGold.withOpacity(.1),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(100)),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ),
                  ),
                IconButton(
                  icon: const Icon(Icons.search_rounded),
                  onPressed: () => _navigateToSearch(),
                  tooltip: 'Search',
                ),
                IconButton(
                  icon: const Icon(Icons.people_outline_rounded),
                  onPressed: () => _navigateToMembers(),
                  tooltip: 'Household members',
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_horiz_rounded),
                  onSelected: _handleMenuAction,
                  itemBuilder: (context) => [
                    const PopupMenuItem(value: 'profile', child: Row(children: [Icon(Icons.person_rounded, size: 20), SizedBox(width: 12), Text('My Profile')])),
                    const PopupMenuItem(value: 'members', child: Row(children: [Icon(Icons.people_rounded, size: 20), SizedBox(width: 12), Text('Household Members')])),
                    const PopupMenuItem(value: 'activity', child: Row(children: [Icon(Icons.timeline_rounded, size: 20), SizedBox(width: 12), Text('Activity Feed')])),
                    const PopupMenuItem(value: 'stats', child: Row(children: [Icon(Icons.bar_chart_rounded, size: 20), SizedBox(width: 12), Text('Household Stats')])),
                    const PopupMenuItem(value: 'templates', child: Row(children: [Icon(Icons.assignment_rounded, size: 20), SizedBox(width: 12), Text('Chore Templates')])),
                    const PopupMenuItem(value: 'invites', child: Row(children: [Icon(Icons.mail_rounded, size: 20), SizedBox(width: 12), Text('Invite Codes')])),
                    const PopupMenuItem(value: 'announcements', child: Row(children: [Icon(Icons.campaign_rounded, size: 20), SizedBox(width: 12), Text('Announcements')])),
                    const PopupMenuItem(value: 'export', child: Row(children: [Icon(Icons.download_rounded, size: 20), SizedBox(width: 12), Text('Export Data')])),
                    const PopupMenuItem(value: 'leaderboard', child: Row(children: [Icon(Icons.emoji_events_rounded, size: 20), SizedBox(width: 12), Text('Leaderboard')])),
                    const PopupMenuItem(value: 'rewards', child: Row(children: [Icon(Icons.card_giftcard_rounded, size: 20), SizedBox(width: 12), Text('Rewards')])),
                    const PopupMenuItem(value: 'achievements', child: Row(children: [Icon(Icons.military_tech_rounded, size: 20), SizedBox(width: 12), Text('Achievements')])),
                    const PopupMenuItem(value: 'point_history', child: Row(children: [Icon(Icons.history_rounded, size: 20), SizedBox(width: 12), Text('Point History')])),
                    const PopupMenuDivider(),
                    const PopupMenuItem(value: 'subscription', child: Row(children: [Icon(Icons.workspace_premium_rounded, size: 20), SizedBox(width: 12), Text('Subscription')])),
                    const PopupMenuItem(value: 'feedback', child: Row(children: [Icon(Icons.feedback_rounded, size: 20), SizedBox(width: 12), Text('Send Feedback')])),
                    const PopupMenuItem(value: 'settings', child: Row(children: [Icon(Icons.settings_rounded, size: 20), SizedBox(width: 12), Text('Settings')])),
                    const PopupMenuItem(value: 'signout', child: Row(children: [Icon(Icons.logout_rounded, size: 20), SizedBox(width: 12), Text('Sign Out')])),
                  ],
                ),
              ],
            ),
    );

    if (_showTour) {
      return Stack(
        children: [
          scaffold,
          FeatureTourOverlay(
            onCompleted: () {
              if (mounted) setState(() => _showTour = false);
            },
          ),
        ],
      );
    }

    return scaffold;
  }

  void _navigateToMembers() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const MembersScreen()),
    );
  }

  void _navigateToSearch() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SearchScreen()),
    );
  }

  void _navigateToStats() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const HouseholdStatsScreen()),
    );
  }

  void _navigateToProfile() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ProfileScreen()),
    );
  }

  void _navigateToRewards() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const RewardsScreen()),
    );
  }

  void _navigateToAchievements() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AchievementsScreen()),
    );
  }

  void _navigateToPointHistory() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PointHistoryScreen()),
    );
  }

  void _navigateToSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  void _navigateToSubscription() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SubscriptionScreen()),
    );
  }

  void _navigateToFeedback() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const FeedbackScreen()),
    );
  }

  void _handleMenuAction(String action) {
    switch (action) {
      case 'profile':
        _navigateToProfile();
        break;
      case 'members':
        _navigateToMembers();
        break;
      case 'leaderboard':
        _showLeaderboard();
        break;
      case 'rewards':
        _navigateToRewards();
        break;
      case 'achievements':
        _navigateToAchievements();
        break;
      case 'point_history':
        _navigateToPointHistory();
        break;
      case 'subscription':
        _navigateToSubscription();
        break;
      case 'activity':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const ActivityFeedScreen()));
        break;
      case 'stats':
        _navigateToStats();
        break;
      case 'templates':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const ChoreTemplatesScreen()));
        break;
      case 'invites':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const InviteManagementScreen()));
        break;
      case 'announcements':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const AnnouncementsScreen()));
        break;
      case 'export':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const DataExportScreen()));
        break;
      case 'feedback':
        _navigateToFeedback();
        break;
      case 'settings':
        _navigateToSettings();
        break;
      case 'signout':
        _signOut();
        break;
    }
  }

  Future<void> _showLeaderboard() async {
    if (_household == null) return;

    try {
      final results = await Supabase.instance.client
          .rpc('get_leaderboard', params: {'p_household_id': _household!['id']});

      if (!mounted) return;

      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (context) => DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.8,
          expand: false,
          builder: (context, scrollController) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    const Icon(Icons.emoji_events_rounded, color: AppColors.honeyGold, size: 28),
                    const SizedBox(width: 12),
                    Text('Leaderboard', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        _navigateToPointHistory();
                      },
                      icon: const Icon(Icons.history_rounded, size: 18),
                      label: const Text('My History'),
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.honeyGold,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: (results as List).isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.emoji_events_outlined, size: 64, color: Colors.grey.shade300),
                            const SizedBox(height: 16),
                            Text('No points yet!', style: TextStyle(fontSize: 16, color: Colors.grey.shade500, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 8),
                            Text('Complete chores to earn points and climb the leaderboard.', style: TextStyle(fontSize: 13, color: Colors.grey.shade400), textAlign: TextAlign.center),
                          ],
                        ),
                      )
                    : ListView.builder(
                        controller: scrollController,
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        itemCount: results.length,
                        itemBuilder: (context, i) {
                          final entry = results[i] as Map<String, dynamic>;
                          final rank = entry['rank'] ?? i + 1;
                          final name = entry['display_name'] ?? 'Unknown';
                          final points = entry['points_balance'] ?? 0;
                          final kind = entry['kind'] ?? 'adult_auth_user';
                          final streak = entry['current_streak'] ?? 0;

                          final rankEmoji = switch (rank) {
                            1 => '🥇',
                            2 => '🥈',
                            3 => '🥉',
                            _ => '',
                          };

                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: rank <= 3 ? AppColors.honeyGold.withOpacity(.2) : Colors.grey.withOpacity(.1),
                              child: Text(
                                rankEmoji.isNotEmpty ? rankEmoji : '$rank',
                                style: TextStyle(fontSize: rankEmoji.isNotEmpty ? 22 : 14, fontWeight: FontWeight.w800),
                              ),
                            ),
                            title: Text(name, style: const TextStyle(fontWeight: FontWeight.w700)),
                            subtitle: Row(
                              children: [
                                Text(kind == 'sub_profile' ? 'Kid' : 'Adult'),
                                if (streak > 0) ...[
                                  const SizedBox(width: 8),
                                  const Icon(Icons.local_fire_department_rounded, size: 14, color: AppColors.coral),
                                  Text('$streak streak', style: const TextStyle(fontSize: 12, color: AppColors.coral, fontWeight: FontWeight.w600)),
                                ],
                              ],
                            ),
                            trailing: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                              decoration: BoxDecoration(
                                color: AppColors.honeyGold.withOpacity(.15),
                                borderRadius: BorderRadius.circular(100),
                              ),
                              child: Text('$points pts', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppColors.honeyGold)),
                            ),
                            onTap: () {
                              final memberId = entry['id'] ?? entry['member_id'];
                              if (memberId != null) {
                                Navigator.pop(context);
                                Navigator.push(context, MaterialPageRoute(builder: (_) => MemberProfileScreen(memberId: memberId)));
                              }
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not load leaderboard.')),
        );
      }
    }
  }

  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text('You\'ll need to sign in again to access your household.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Sign out')),
        ],
      ),
    );

    if (confirmed == true) {
      RealtimeService.instance.reset();
      await Supabase.instance.client.auth.signOut();
    }
  }
}
