import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/app_theme.dart';
import '../main.dart';
import 'profile_screen.dart';
import 'subscription_screen.dart';
import 'feedback_screen.dart';
import 'notification_preferences_screen.dart';
import 'data_export_screen.dart';

/// Settings screen for profile, household, and app configuration.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Map<String, dynamic>? _household;
  Map<String, dynamic>? _myMembership;
  Map<String, dynamic>? _profile;
  bool _isLoading = true;
  bool _notificationsEnabled = true;
  bool _choreReminders = true;
  bool _mealReminders = true;
  bool _achievementNotifications = true;
  bool _darkMode = false;

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

      // Load profile
      final profiles = await Supabase.instance.client
          .from('profiles')
          .select('*')
          .eq('id', user.id)
          .limit(1);

      if (profiles.isNotEmpty) {
        _profile = profiles[0];
      }

      // Load notification preferences
      final prefs = await Supabase.instance.client
          .from('notification_preferences')
          .select('*')
          .eq('member_id', _myMembership!['id'])
          .limit(1);

      if (prefs.isNotEmpty) {
        _notificationsEnabled = prefs[0]['push_enabled'] ?? true;
        _choreReminders = prefs[0]['chore_reminders'] ?? true;
        _mealReminders = prefs[0]['meal_reminders'] ?? true;
        _achievementNotifications = prefs[0]['achievement_notifications'] ?? true;
      }

      // Load dark mode preference
      final sharedPrefs = await SharedPreferences.getInstance();
      _darkMode = sharedPrefs.getBool('dark_mode') ?? false;

      setState(() => _isLoading = false);
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading settings: $e')),
        );
      }
    }
  }

  Future<void> _updateNotificationPref(String key, bool value) async {
    try {
      final memberId = _myMembership!['id'];
      final householdId = _household!['id'];

      await Supabase.instance.client
          .from('notification_preferences')
          .upsert({
            'member_id': memberId,
            'household_id': householdId,
            key: value,
          });

      setState(() {});

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Preference updated')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error updating preference: $e')),
        );
      }
    }
  }

  Future<void> _showEditProfileSheet() async {
    final nameController = TextEditingController(
      text: _myMembership?['display_name'] ?? '',
    );

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
                'Edit Profile',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Display Name',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.person),
                ),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () async {
                  try {
                    await Supabase.instance.client
                        .from('household_members')
                        .update({
                          'display_name': nameController.text.trim(),
                        })
                        .eq('id', _myMembership!['id']);

                    Navigator.pop(context, true);
                    await _loadData();

                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Profile updated!')),
                      );
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Error updating profile: $e')),
                      );
                    }
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.honeyGold,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    );

    if (result == true) {
      // Profile updated
    }
  }

  Future<void> _showEditHouseholdSheet() async {
    final nameController = TextEditingController(
      text: _household?['name'] ?? '',
    );
    final emojiController = TextEditingController(
      text: _household?['emoji'] ?? '🏠',
    );

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
                'Edit Household',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  SizedBox(
                    width: 60,
                    child: TextField(
                      controller: emojiController,
                      decoration: const InputDecoration(
                        labelText: 'Emoji',
                        border: OutlineInputBorder(),
                      ),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 24),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: nameController,
                      decoration: const InputDecoration(
                        labelText: 'Household Name',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () async {
                  try {
                    await Supabase.instance.client
                        .from('households')
                        .update({
                          'name': nameController.text.trim(),
                          'emoji': emojiController.text.trim(),
                        })
                        .eq('id', _household!['id']);

                    Navigator.pop(context, true);
                    await _loadData();

                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Household updated!')),
                      );
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Error updating household: $e')),
                      );
                    }
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.honeyGold,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    );

    if (result == true) {
      // Household updated
    }
  }

  Future<void> _showChangePasswordSheet() async {
    final currentPasswordController = TextEditingController();
    final newPasswordController = TextEditingController();
    final confirmPasswordController = TextEditingController();

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
                'Change Password',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: currentPasswordController,
                decoration: const InputDecoration(
                  labelText: 'Current Password',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.lock),
                ),
                obscureText: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: newPasswordController,
                decoration: const InputDecoration(
                  labelText: 'New Password',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.lock_outline),
                ),
                obscureText: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: confirmPasswordController,
                decoration: const InputDecoration(
                  labelText: 'Confirm New Password',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.lock_outline),
                ),
                obscureText: true,
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () async {
                  if (newPasswordController.text !=
                      confirmPasswordController.text) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Passwords do not match')),
                    );
                    return;
                  }

                  if (newPasswordController.text.length < 6) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('Password must be at least 6 characters')),
                    );
                    return;
                  }

                  try {
                    await Supabase.instance.client.auth.updateUser(
                      UserAttributes(password: newPasswordController.text),
                    );

                    Navigator.pop(context, true);

                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Password updated!')),
                      );
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Error: $e')),
                      );
                    }
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.honeyGold,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Update Password'),
              ),
            ],
          ),
        ),
      ),
    );

    if (result == true) {
      // Password updated
    }
  }

  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign Out'),
        content: const Text('Are you sure you want to sign out?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.coral,
              foregroundColor: Colors.white,
            ),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await Supabase.instance.client.auth.signOut();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final isAdmin = _myMembership?['role'] == 'admin';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings ⚙️'),
      ),
      body: ListView(
        children: [
          // Profile section
          _buildSectionHeader('Profile'),
          ListTile(
            leading: CircleAvatar(
              backgroundColor: AppColors.honeyGold.withOpacity(0.2),
              child: Text(
                (_myMembership?['display_name'] as String? ?? '?')[0].toUpperCase(),
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  color: AppColors.honeyGold,
                ),
              ),
            ),
            title: Text(
              _myMembership?['display_name'] ?? 'Unknown',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text(
              _myMembership?['kind'] == 'adult_auth_user'
                  ? 'Adult · ${isAdmin ? 'Admin' : 'Member'}'
                  : 'Kid Profile',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ProfileScreen()),
            ),
          ),

          // Household section
          _buildSectionHeader('Household'),
          ListTile(
            leading: Text(
              _household?['emoji'] ?? '🏠',
              style: const TextStyle(fontSize: 28),
            ),
            title: Text(
              _household?['name'] ?? 'Unknown Household',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text('Household ID: ${_household?['id']?.toString().substring(0, 8) ?? ''}...'),
            trailing: isAdmin ? const Icon(Icons.edit) : null,
            onTap: isAdmin ? _showEditHouseholdSheet : null,
          ),

          // Notification preferences
          _buildSectionHeader('Notifications'),
          SwitchListTile(
            secondary: const Icon(Icons.notifications),
            title: const Text('Push Notifications'),
            subtitle: const Text('Enable all notifications'),
            value: _notificationsEnabled,
            onChanged: (value) {
              setState(() => _notificationsEnabled = value);
              _updateNotificationPref('push_enabled', value);
            },
          ),
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('Notification Preferences'),
            subtitle: const Text('Customize which notifications you receive'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const NotificationPreferencesScreen()),
            ),
          ),

          // Account section
          _buildSectionHeader('Account'),
          SwitchListTile(
            secondary: const Icon(Icons.dark_mode),
            title: const Text('Dark Mode'),
            subtitle: const Text('Switch between light and dark themes'),
            value: _darkMode,
            onChanged: (value) async {
              setState(() => _darkMode = value);
              final sharedPrefs = await SharedPreferences.getInstance();
              await sharedPrefs.setBool('dark_mode', value);
              // Update the app theme
              HoneydoApp.themeNotifier.value = value ? ThemeMode.dark : ThemeMode.light;
            },
          ),
          ListTile(
            leading: const Icon(Icons.workspace_premium_rounded),
            title: const Text('Subscription'),
            subtitle: Text(
              _household?['tier'] == 'premium' ? 'Premium Plan' : 'Free Plan',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SubscriptionScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.lock),
            title: const Text('Change Password'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _showChangePasswordSheet,
          ),
          ListTile(
            leading: const Icon(Icons.download_rounded),
            title: const Text('Export Data'),
            subtitle: const Text('Download your household data as JSON or CSV'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const DataExportScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.email),
            title: const Text('Email'),
            subtitle: Text(
              Supabase.instance.client.auth.currentUser?.email ?? 'Unknown',
            ),
          ),

          // About section
          _buildSectionHeader('About'),
          const ListTile(
            leading: Icon(Icons.info),
            title: Text('Honeydo'),
            subtitle: Text('Version 1.0.0'),
          ),
          ListTile(
            leading: const Icon(Icons.feedback),
            title: const Text('Send Feedback'),
            subtitle: const Text('Report bugs or request features'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const FeedbackScreen()),
            ),
          ),
          const ListTile(
            leading: Icon(Icons.description),
            title: Text('Terms of Service'),
            trailing: Icon(Icons.chevron_right),
          ),
          const ListTile(
            leading: Icon(Icons.privacy_tip),
            title: Text('Privacy Policy'),
            trailing: Icon(Icons.chevron_right),
          ),
          const ListTile(
            leading: Icon(Icons.help),
            title: Text('Help & Support'),
            trailing: Icon(Icons.chevron_right),
          ),

          // Sign out
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ElevatedButton.icon(
              onPressed: _signOut,
              icon: const Icon(Icons.logout),
              label: const Text('Sign Out'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.coral,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 48),
              ),
            ),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          color: AppColors.honeyGold,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}