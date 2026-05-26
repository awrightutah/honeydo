import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../services/notification_service.dart';

/// Detailed notification preferences screen with per-category settings.
class NotificationPreferencesScreen extends StatefulWidget {
  const NotificationPreferencesScreen({super.key});

  @override
  State<NotificationPreferencesScreen> createState() => _NotificationPreferencesScreenState();
}

class _NotificationPreferencesScreenState extends State<NotificationPreferencesScreen> {
  Map<String, dynamic>? _preferences;
  Map<String, dynamic>? _membership;
  bool _isLoading = true;
  bool _isUpdating = false;

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

      _membership = memberships[0];
      _preferences = await NotificationService().loadPreferences();
      setState(() => _isLoading = false);
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading preferences: $e')),
        );
      }
    }
  }

  Future<void> _updatePref(String key, bool value) async {
    setState(() => _isUpdating = true);
    try {
      await NotificationService().updatePreferences({key: value});
      setState(() {
        _preferences?[key] = value;
        _isUpdating = false;
      });
    } catch (e) {
      setState(() => _isUpdating = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error updating preference: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notification Preferences', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                // Master toggle
                Container(
                  margin: const EdgeInsets.all(16),
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        AppColors.honeyGold.withValues(alpha:0.1),
                        AppColors.honeyGold.withValues(alpha:0.05),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppColors.honeyGold.withValues(alpha:0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.notifications_active_rounded, color: AppColors.honeyGold, size: 32),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Push Notifications',
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _preferences?['push_enabled'] == true
                                  ? 'Notifications are enabled'
                                  : 'All notifications are disabled',
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.grey.shade600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Switch(
                        value: _preferences?['push_enabled'] ?? true,
                        onChanged: (v) => _updatePref('push_enabled', v),
                        activeColor: AppColors.honeyGold,
                      ),
                    ],
                  ),
                ),

                // Chore notifications
                _buildSectionHeader('Chores', Icons.task_alt_rounded, AppColors.grassGreen),
                SwitchListTile(
                  secondary: const Icon(Icons.alarm),
                  title: const Text('Chore Reminders'),
                  subtitle: const Text('Get reminded about upcoming chores'),
                  value: _preferences?['chore_reminders'] ?? true,
                  onChanged: (_preferences?['push_enabled'] ?? true) ? (v) => _updatePref('chore_reminders', v) : null,
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.assignment_turned_in),
                  title: const Text('Chore Assignments'),
                  subtitle: const Text('When a chore is assigned to you'),
                  value: _preferences?['chore_assignments'] ?? true,
                  onChanged: (_preferences?['push_enabled'] ?? true) ? (v) => _updatePref('chore_assignments', v) : null,
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.verified),
                  title: const Text('Chore Verification'),
                  subtitle: const Text('When your completed chore is verified'),
                  value: _preferences?['chore_verification'] ?? true,
                  onChanged: (_preferences?['push_enabled'] ?? true) ? (v) => _updatePref('chore_verification', v) : null,
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.warning_amber),
                  title: const Text('Overdue Alerts'),
                  subtitle: const Text('When a chore is past its due date'),
                  value: _preferences?['overdue_alerts'] ?? true,
                  onChanged: (_preferences?['push_enabled'] ?? true) ? (v) => _updatePref('overdue_alerts', v) : null,
                ),

                // Meal notifications
                _buildSectionHeader('Meals', Icons.restaurant_menu_rounded, AppColors.honeyGold),
                SwitchListTile(
                  secondary: const Icon(Icons.restaurant),
                  title: const Text('Meal Reminders'),
                  subtitle: const Text('Get reminded about meal plans'),
                  value: _preferences?['meal_reminders'] ?? true,
                  onChanged: (_preferences?['push_enabled'] ?? true) ? (v) => _updatePref('meal_reminders', v) : null,
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.add_shopping_cart),
                  title: const Text('Shopping List Updates'),
                  subtitle: const Text('When items are added to shopping lists'),
                  value: _preferences?['shopping_updates'] ?? true,
                  onChanged: (_preferences?['push_enabled'] ?? true) ? (v) => _updatePref('shopping_updates', v) : null,
                ),

                // Achievement notifications
                _buildSectionHeader('Gamification', Icons.emoji_events_rounded, AppColors.coral),
                SwitchListTile(
                  secondary: const Icon(Icons.emoji_events),
                  title: const Text('Achievement Alerts'),
                  subtitle: const Text('Get notified when you earn badges'),
                  value: _preferences?['achievement_notifications'] ?? true,
                  onChanged: (_preferences?['push_enabled'] ?? true) ? (v) => _updatePref('achievement_notifications', v) : null,
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.star),
                  title: const Text('Points Updates'),
                  subtitle: const Text('When you earn or spend points'),
                  value: _preferences?['points_updates'] ?? true,
                  onChanged: (_preferences?['push_enabled'] ?? true) ? (v) => _updatePref('points_updates', v) : null,
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.local_fire_department),
                  title: const Text('Streak Reminders'),
                  subtitle: const Text('Keep your streak going'),
                  value: _preferences?['streak_reminders'] ?? true,
                  onChanged: (_preferences?['push_enabled'] ?? true) ? (v) => _updatePref('streak_reminders', v) : null,
                ),

                // Household notifications
                _buildSectionHeader('Household', Icons.people_rounded, AppColors.skyBlue),
                SwitchListTile(
                  secondary: const Icon(Icons.person_add),
                  title: const Text('Member Joined'),
                  subtitle: const Text('When someone joins your household'),
                  value: _preferences?['member_joined'] ?? true,
                  onChanged: (_preferences?['push_enabled'] ?? true) ? (v) => _updatePref('member_joined', v) : null,
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.announcement),
                  title: const Text('Household Announcements'),
                  subtitle: const Text('Important updates from admins'),
                  value: _preferences?['household_announcements'] ?? true,
                  onChanged: (_preferences?['push_enabled'] ?? true) ? (v) => _updatePref('household_announcements', v) : null,
                ),

                // Quiet hours
                _buildSectionHeader('Quiet Hours', Icons.bedtime_rounded, Colors.purple),
                SwitchListTile(
                  secondary: const Icon(Icons.do_not_disturb_on),
                  title: const Text('Enable Quiet Hours'),
                  subtitle: const Text('Pause notifications during set hours'),
                  value: _preferences?['quiet_hours_enabled'] ?? false,
                  onChanged: (v) => _updatePref('quiet_hours_enabled', v),
                ),
                if (_preferences?['quiet_hours_enabled'] == true) ...[
                  ListTile(
                    leading: const Icon(Icons.bedtime),
                    title: const Text('Start Time'),
                    subtitle: Text(_preferences?['quiet_hours_start'] ?? '10:00 PM'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _pickQuietTime('quiet_hours_start'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.wb_sunny),
                    title: const Text('End Time'),
                    subtitle: Text(_preferences?['quiet_hours_end'] ?? '7:00 AM'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _pickQuietTime('quiet_hours_end'),
                  ),
                ],

                const SizedBox(height: 32),

                // Reset to defaults
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: OutlinedButton.icon(
                    onPressed: _resetToDefaults,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Reset to Defaults'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.coral,
                      minimumSize: const Size(double.infinity, 48),
                    ),
                  ),
                ),
                const SizedBox(height: 40),
              ],
            ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon, Color color) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: color,
              letterSpacing: 1.0,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickQuietTime(String key) async {
    final currentStr = _preferences?[key] as String? ?? (key.contains('start') ? '10:00 PM' : '7:00 AM');
    TimeOfDay initialTime;

    try {
      final parts = currentStr.replaceAll(' ', '').toUpperCase();
      if (parts.contains('PM') || parts.contains('AM')) {
        final timePart = parts.replaceAll(RegExp(r'[AP]M'), '');
        final h_m = timePart.split(':');
        int h = int.parse(h_m[0]);
        final m = int.parse(h_m[1]);
        if (parts.contains('PM') && h != 12) h += 12;
        if (parts.contains('AM') && h == 12) h = 0;
        initialTime = TimeOfDay(hour: h, minute: m);
      } else {
        initialTime = key.contains('start') ? const TimeOfDay(hour: 22, minute: 0) : const TimeOfDay(hour: 7, minute: 0);
      }
    } catch (_) {
      initialTime = key.contains('start') ? const TimeOfDay(hour: 22, minute: 0) : const TimeOfDay(hour: 7, minute: 0);
    }

    final picked = await showTimePicker(
      context: context,
      initialTime: initialTime,
    );

    if (picked != null) {
      final period = picked.hour >= 12 ? 'PM' : 'AM';
      final displayHour = picked.hour > 12 ? picked.hour - 12 : (picked.hour == 0 ? 12 : picked.hour);
      final timeStr = '$displayHour:${picked.minute.toString().padLeft(2, '0')} $period';
      await _updatePref(key, timeStr as dynamic);
    }
  }

  Future<void> _resetToDefaults() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset Notifications?'),
        content: const Text('This will reset all notification preferences to their default settings.'),
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
            child: const Text('Reset'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final defaults = {
          'push_enabled': true,
          'chore_reminders': true,
          'chore_assignments': true,
          'chore_verification': true,
          'overdue_alerts': true,
          'meal_reminders': true,
          'shopping_updates': true,
          'achievement_notifications': true,
          'points_updates': true,
          'streak_reminders': true,
          'member_joined': true,
          'household_announcements': true,
          'quiet_hours_enabled': false,
          'quiet_hours_start': '10:00 PM',
          'quiet_hours_end': '7:00 AM',
        };

        await NotificationService().updatePreferences(defaults);

        await _loadData();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Preferences reset to defaults')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error resetting preferences: $e')),
          );
        }
      }
    }
  }
}
