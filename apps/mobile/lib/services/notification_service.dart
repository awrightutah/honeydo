import 'package:supabase_flutter/supabase_flutter.dart';

/// Service for managing device tokens and notification preferences.
/// In a full production app, this integrates with Firebase Cloud Messaging.
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final _client = Supabase.instance.client;

  /// Register a device token for push notifications.
  /// Called when the app starts or when a new token is generated.
  Future<void> registerDeviceToken({
    required String token,
    required String platform,
  }) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return;

      // Get the member id for this user
      final membership = await _client
          .from('household_members')
          .select('id')
          .eq('auth_user_id', user.id)
          .eq('is_active', true)
          .limit(1);

      if (membership.isEmpty) return;
      final memberId = membership[0]['id'];

      // Upsert the device token
      await _client.from('device_tokens').upsert({
        'member_id': memberId,
        'platform': platform,
        'token': token,
        'last_seen_at': DateTime.now().toIso8601String(),
      }, onConflict: 'token');
    } catch (e) {
      // Silent fail — notifications are non-critical
    }
  }

  /// Unregister a device token (e.g., on sign out).
  Future<void> unregisterDeviceToken(String token) async {
    try {
      await _client
          .from('device_tokens')
          .delete()
          .eq('token', token);
    } catch (_) {}
  }

  /// Load notification preferences for the current user.
  Future<Map<String, dynamic>?> loadPreferences() async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return null;

      final membership = await _client
          .from('household_members')
          .select('id, household_id')
          .eq('auth_user_id', user.id)
          .eq('is_active', true)
          .limit(1);

      if (membership.isEmpty) return null;
      final memberId = membership[0]['id'];

      final prefs = await _client
          .from('notification_preferences')
          .select()
          .eq('member_id', memberId)
          .maybeSingle();

      // If no preferences exist yet, create defaults
      if (prefs == null) {
        final newPrefs = {
          'member_id': memberId,
          'morning_digest': true,
          'evening_recap': true,
          'chore_reminders': true,
          'verification_alerts': true,
          'gamification_alerts': true,
          'calendar_reminders': true,
          'quiet_hours_start': '21:00',
          'quiet_hours_end': '07:00',
        };
        await _client.from('notification_preferences').insert(newPrefs);
        return newPrefs;
      }

      return prefs;
    } catch (e) {
      return null;
    }
  }

  /// Update notification preferences.
  Future<bool> updatePreferences(Map<String, dynamic> updates) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return false;

      final membership = await _client
          .from('household_members')
          .select('id')
          .eq('auth_user_id', user.id)
          .eq('is_active', true)
          .limit(1);

      if (membership.isEmpty) return false;
      final memberId = membership[0]['id'];

      await _client
          .from('notification_preferences')
          .update(updates)
          .eq('member_id', memberId);

      return true;
    } catch (e) {
      return false;
    }
  }
}
