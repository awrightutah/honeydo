import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import 'chore_dashboard_screen.dart';
import 'meal_planner_screen.dart';
import 'shopping_list_screen.dart';
import 'calendar_screen.dart';
import 'recipe_library_screen.dart';
import 'members_screen.dart';

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

  late final List<Widget> _screens;

  @override
  void initState() {
    super.initState();
    _loadHouseholdInfo();
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
      }
    } catch (_) {
      // Silently handle - screens will show their own errors
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
        _buildScreens();
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
    return Scaffold(
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : IndexedStack(
              index: _currentIndex,
              children: _screens,
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
      // App bar with household name and profile access
      appBar: _isLoading
          ? null
          : AppBar(
              title: Text(
                _household?['name'] ?? 'Honeydo',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              actions: [
                IconButton(
                  icon: const Icon(Icons.people_outline_rounded),
                  onPressed: () => _navigateToMembers(),
                  tooltip: 'Household members',
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_horiz_rounded),
                  onSelected: _handleMenuAction,
                  itemBuilder: (context) => [
                    const PopupMenuItem(value: 'members', child: Row(children: [Icon(Icons.people_rounded, size: 20), SizedBox(width: 12), Text('Household Members')])),
                    const PopupMenuItem(value: 'leaderboard', child: Row(children: [Icon(Icons.emoji_events_rounded, size: 20), SizedBox(width: 12), Text('Leaderboard')])),
                    const PopupMenuItem(value: 'rewards', child: Row(children: [Icon(Icons.card_giftcard_rounded, size: 20), SizedBox(width: 12), Text('Rewards')])),
                    const PopupMenuDivider(),
                    const PopupMenuItem(value: 'settings', child: Row(children: [Icon(Icons.settings_rounded, size: 20), SizedBox(width: 12), Text('Settings')])),
                    const PopupMenuItem(value: 'signout', child: Row(children: [Icon(Icons.logout_rounded, size: 20), SizedBox(width: 12), Text('Sign Out')])),
                  ],
                ),
              ],
            ),
    );
  }

  void _navigateToMembers() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const MembersScreen()),
    );
  }

  void _handleMenuAction(String action) {
    switch (action) {
      case 'members':
        _navigateToMembers();
        break;
      case 'leaderboard':
        _showLeaderboard();
        break;
      case 'rewards':
        _showRewards();
        break;
      case 'settings':
        // TODO: Navigate to settings screen
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
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  controller: scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: (results as List).length,
                  itemBuilder: (context, i) {
                    final entry = results[i] as Map<String, dynamic>;
                    final rank = entry['rank'] ?? i + 1;
                    final name = entry['display_name'] ?? 'Unknown';
                    final points = entry['points_balance'] ?? 0;
                    final kind = entry['kind'] ?? 'adult_auth_user';

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
                      subtitle: Text(kind == 'sub_profile' ? 'Kid' : 'Adult'),
                      trailing: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(
                          color: AppColors.honeyGold.withOpacity(.15),
                          borderRadius: BorderRadius.circular(100),
                        ),
                        child: Text('$points pts', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppColors.honeyGold)),
                      ),
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

  void _showRewards() {
    // TODO: Build full rewards screen
    showModalBottomSheet(
      context: context,
      builder: (context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.card_giftcard_rounded, color: AppColors.coral, size: 28),
                const SizedBox(width: 12),
                Text('Rewards', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'Spend your points on rewards set by your household admin!',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppColors.honeyGold.withOpacity(.1),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.star_rounded, color: AppColors.honeyGold, size: 32),
                  const SizedBox(width: 8),
                  Text(
                    '${_myMembership?['points_balance'] ?? 0} points',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            const Text('Coming soon — admins will be able to set up custom rewards.'),
          ],
        ),
      ),
    );
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
      await Supabase.instance.client.auth.signOut();
    }
  }
}
