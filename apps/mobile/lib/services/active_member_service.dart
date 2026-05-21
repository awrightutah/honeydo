import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tracks which household member is currently active on this device.
///
/// Adult accounts authenticate with Supabase. Kid profiles are COPPA-safe
/// sub-profiles under the adult account; after PIN verification, this service
/// stores the selected household_member id so screens can use that member
/// context for chores, points, and profile display.
class ActiveMemberService {
  ActiveMemberService._();
  static final ActiveMemberService instance = ActiveMemberService._();

  static const _activeMemberIdKey = 'active_member_id';

  final ValueNotifier<String?> activeMemberId = ValueNotifier<String?>(null);

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    activeMemberId.value = prefs.getString(_activeMemberIdKey);
  }

  Future<void> switchTo(String memberId) async {
    activeMemberId.value = memberId;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeMemberIdKey, memberId);
  }

  Future<void> clear() async {
    activeMemberId.value = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_activeMemberIdKey);
  }
}
