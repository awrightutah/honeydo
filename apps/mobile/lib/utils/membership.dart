import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/active_member_service.dart';

/// Resolves "which household member is the user operating as right now."
///
/// The authoritative answer is overlaid in two steps:
///   1. The JWT holder's row (the parent/admin) is loaded via auth.uid().
///      This always exists for an authenticated user and provides the
///      household context.
///   2. If [ActiveMemberService] has a non-null active member id that
///      differs from the JWT holder's id, that row is loaded separately
///      and returned in place of the JWT holder's row. This is how the
///      profile switcher's kid-mode resolves to a sub_profile member —
///      kids have `auth_user_id IS NULL` (no JWT of their own), so a plain
///      `.eq('auth_user_id', auth.uid())` lookup can never return a kid.
///
/// Without this overlay, every screen that loads "my membership" by JWT
/// alone silently coerces to the adult — `Permissions.isKid(...)` returns
/// false, kid-attributed write paths fall through to adult INSERT, and
/// `added_by_member_id` records the wrong person. The bug was surfaced
/// during Batch 5a iPhone smoke-test; see
/// `/audits/2026-05-shopping-screen-active-member-bug-investigation.md`.
///
/// Pair this loader with a [ActiveMemberService.instance.activeMemberId]
/// listener in the screen's `initState` so the screen reloads when the
/// user switches profiles mid-session.
class MembershipHelper {
  MembershipHelper._();

  /// Load the currently-active household membership record.
  ///
  /// Returns the kid's row if a kid profile is active (per
  /// [ActiveMemberService]), otherwise the JWT holder's (parent/admin) row.
  /// Returns `null` if no household membership exists for the signed-in
  /// user (the "not in a household yet" case).
  ///
  /// Pass `includeHouseholdJoin: true` to also eager-load `households(*)`
  /// in the same query — useful when the caller needs the household record
  /// alongside the membership.
  ///
  /// Throws if the user isn't authenticated.
  static Future<Map<String, dynamic>?> loadActiveMembership({
    bool includeHouseholdJoin = false,
  }) async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return null;

    final selectClause = includeHouseholdJoin ? '*, households(*)' : '*';

    // Step 1: JWT holder's membership (adult).
    final adultRows = await Supabase.instance.client
        .from('household_members')
        .select(selectClause)
        .eq('auth_user_id', user.id)
        .eq('is_active', true)
        .limit(1);

    if (adultRows.isEmpty) return null;
    final adultMembership = Map<String, dynamic>.from(adultRows[0]);

    // Step 2: Overlay. If a different active member is set, load that row.
    final activeId = ActiveMemberService.instance.activeMemberId.value;
    if (activeId == null || activeId == adultMembership['id']) {
      return adultMembership;
    }

    final activeRows = await Supabase.instance.client
        .from('household_members')
        .select(selectClause)
        .eq('id', activeId)
        .eq('is_active', true)
        .limit(1);

    if (activeRows.isEmpty) {
      // Stale active-member id (member deleted or deactivated). Fall back
      // to the adult so the screen still loads; callers can decide whether
      // to ask ActiveMemberService to clear() or switchTo(adult).
      return adultMembership;
    }

    final active = Map<String, dynamic>.from(activeRows[0]);
    // The overlaid query won't have re-joined the household. Carry it over
    // from the adult row so callers that asked for `includeHouseholdJoin`
    // don't have to special-case the result.
    if (includeHouseholdJoin && active['households'] == null) {
      active['households'] = adultMembership['households'];
    }
    return active;
  }
}
