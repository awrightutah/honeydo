import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../services/active_member_service.dart';
import '../utils/membership.dart';
import '../utils/permissions.dart';
import '../widgets/chore_photo_viewer.dart';
import '../widgets/reject_reason_dialog.dart';
import 'chore_detail_screen.dart';

/// Unified admin dashboard for pending items needing decision:
/// chore verifications, wishlist items, and (Batch 6) meal requests.
///
/// Replaces the original "Pending Verification" admin section that lived on
/// chore_dashboard. The 5b investigation chose to consolidate into one screen
/// reachable via an AppBar inbox icon (admin-only) so admins land in one
/// place to act on everything; the chore_dashboard simplifies into a pure
/// "my chores" view.
class ApprovalsScreen extends StatefulWidget {
  const ApprovalsScreen({super.key});

  @override
  State<ApprovalsScreen> createState() => _ApprovalsScreenState();
}

class _ApprovalsScreenState extends State<ApprovalsScreen> {
  Map<String, dynamic>? _myMembership;
  Map<String, dynamic>? _household;
  List<Map<String, dynamic>> _pendingVerification = [];
  // Most-recent chore_verification_photos row per chore — used by the
  // _VerificationCard thumbnail. Null entry = kid skipped photo (Batch 4a).
  Map<String, Map<String, dynamic>?> _latestPhotoByChoreId = {};
  List<Map<String, dynamic>> _pendingWishlist = [];
  // Pending meal requests (Batch 6a). Each row carries joined recipe data
  // and the requesting kid's display info. Approve/deny via decide_meal_request
  // RPC (admin-only). When request has both date + meal_type, Approve calls
  // RPC directly. When either is null, Approve opens _ApproveMealRequestDialog
  // to collect the override fields the RPC requires.
  List<Map<String, dynamic>> _pendingMealRequests = [];
  bool _isLoading = true;

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

  /// If admin switches to a kid mid-screen, pop back to home (the screen is
  /// meaningless to non-admins; the kid has nothing to approve).
  void _onActiveMemberChanged() {
    if (!mounted) return;
    _loadData().then((_) {
      if (!mounted) return;
      if (!Permissions.isAdmin(_myMembership)) {
        Navigator.of(context).pop();
      }
    });
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);

    try {
      final membership = await MembershipHelper.loadActiveMembership(
        includeHouseholdJoin: true,
      );

      if (membership == null) {
        if (mounted) setState(() => _isLoading = false);
        return;
      }

      _myMembership = membership;
      _household = membership['households'];
      final householdId = _household!['id'];

      // Defensive: bail out for non-admin (UI gate in home_shell already
      // hides the entry; defense-in-depth here).
      if (!Permissions.isAdmin(_myMembership)) {
        if (mounted) setState(() => _isLoading = false);
        return;
      }

      // Parallel admin queries: pending chore verifications + their
      // most-recent photos + pending wishlist items.
      final pendingVerif = await Supabase.instance.client
          .from('chores')
          .select(
              '*, assignee:household_members!assigned_to_member_id(display_name)')
          .eq('household_id', householdId)
          .eq('status', 'pending_verification')
          .order('completed_at', ascending: true);

      Map<String, Map<String, dynamic>?> photosByChore = {};
      if (pendingVerif.isNotEmpty) {
        final pendingChoreIds = pendingVerif
            .map((c) => c['id'] as String)
            .toList(growable: false);
        final photoRows = await Supabase.instance.client
            .from('chore_verification_photos')
            .select()
            .inFilter('chore_id', pendingChoreIds)
            .order('created_at', ascending: false);

        // Group by chore_id, keep first (most-recent due to DESC).
        for (final row in photoRows) {
          final cid = row['chore_id'] as String;
          photosByChore.putIfAbsent(cid, () => Map<String, dynamic>.from(row));
        }
        // Ensure every pending chore has an entry (null = skipped photo).
        for (final cid in pendingChoreIds) {
          photosByChore.putIfAbsent(cid, () => null);
        }
      }

      final pendingWish = await Supabase.instance.client
          .from('shopping_items')
          .select(
              '*, requester:household_members!added_by_member_id(display_name, kind)')
          .eq('household_id', householdId)
          .eq('is_wishlist', true)
          .order('created_at', ascending: false);

      // Batch 6a — pending meal requests for this household. Joined to
      // household_recipes (for title + image_url) and household_members
      // (for the requesting kid's display name).
      final pendingMealsRaw = await Supabase.instance.client
          .from('meal_requests')
          .select(
              '*, recipe:household_recipes(title, image_url), '
              'requester:household_members!requested_by_member_id(display_name, kind)')
          .eq('household_id', householdId)
          .eq('status', 'pending')
          .order('created_at', ascending: false);

      if (!mounted) return;
      setState(() {
        _pendingVerification = List<Map<String, dynamic>>.from(pendingVerif);
        _latestPhotoByChoreId = photosByChore;
        _pendingWishlist = List<Map<String, dynamic>>.from(pendingWish);
        _pendingMealRequests =
            List<Map<String, dynamic>>.from(pendingMealsRaw);
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('approvals load failed: $e');
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load approvals: $e')),
      );
    }
  }

  Future<void> _verifyChore(String choreId, bool approved) async {
    try {
      final chore =
          _pendingVerification.firstWhere((c) => c['id'] == choreId);

      String? reasonForReject;
      if (!approved) {
        final reason =
            await showRejectReasonDialog(context, chore['title'] ?? 'this chore');
        if (reason == null) return; // cancelled
        reasonForReject = reason.isEmpty ? null : reason;
      }

      // approve_chore (migration 0017) handles status update, points
      // award (kid/adult branching), achievements, and photo delete_after
      // scheduling server-side. Reject sets status='rejected' — kid Re-do
      // is in Batch 4b (chore_dashboard / chore_detail surface it).
      await Supabase.instance.client.rpc('approve_chore', params: {
        'p_chore_id': choreId,
        'p_approved': approved,
        'p_reason': reasonForReject,
      });

      // Recurring chores still need next-occurrence creation app-side.
      if (approved) {
        await _createNextRecurringChoreIfNeeded(chore);
      }

      await _loadData();
    } catch (e) {
      debugPrint('approve_chore failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update chore status: $e')),
        );
      }
    }
  }

  /// Approve a kid-added wishlist item → admin-only RPC flips is_wishlist
  /// to false and writes approved_by_member_id + approved_at.
  Future<void> _approveWishlistItem(String itemId) async {
    try {
      await Supabase.instance.client.rpc('approve_wishlist_item', params: {
        'p_item_id': itemId,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Item added to shopping list')),
        );
      }
      await _loadData();
    } catch (e) {
      debugPrint('approve_wishlist_item failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not approve item: $e')),
        );
      }
    }
  }

  /// Deny a wishlist item → confirmation modal → direct DELETE. RLS allows
  /// admin DELETE on shopping_items.
  Future<void> _denyWishlistItem(String itemId, String itemName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this wishlist item?'),
        content: Text("This can't be undone. \"$itemName\" will be removed."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.coral),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await Supabase.instance.client
          .from('shopping_items')
          .delete()
          .eq('id', itemId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Wishlist item removed')),
        );
      }
      await _loadData();
    } catch (e) {
      debugPrint('deny wishlist item failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not delete item: $e')),
        );
      }
    }
  }

  /// Approve a kid-submitted meal request → calls decide_meal_request
  /// with p_approved=true. The RPC atomically inserts the matching
  /// meal_plans row.
  ///
  /// **Case A** (request has both `requested_for_date` AND `meal_type`):
  /// call RPC directly.
  ///
  /// **Case B** (either field is null): RPC would raise. Open
  /// `_ApproveMealRequestDialog` to collect overrides + optional admin
  /// note, then call RPC with `p_planned_for_override` /
  /// `p_meal_type_override` / `p_note`.
  Future<void> _approveMealRequest(Map<String, dynamic> request) async {
    final requestId = request['id'] as String;
    final requestDate = request['requested_for_date'] as String?;
    final requestMealType = request['meal_type'] as String?;
    final recipeTitle =
        (request['recipe']?['title'] as String?) ?? 'this meal';

    try {
      if (requestDate != null && requestMealType != null) {
        // Case A — RPC fires directly.
        await Supabase.instance.client.rpc('decide_meal_request', params: {
          'p_request_id': requestId,
          'p_approved': true,
        });
      } else {
        // Case B — collect overrides.
        final result = await showDialog<_ApproveMealResult?>(
          context: context,
          builder: (ctx) => _ApproveMealRequestDialog(
            recipeTitle: recipeTitle,
            initialDate: requestDate == null
                ? null
                : DateTime.tryParse(requestDate),
            initialMealType: requestMealType,
          ),
        );
        if (result == null) return; // cancelled

        await Supabase.instance.client.rpc('decide_meal_request', params: {
          'p_request_id': requestId,
          'p_approved': true,
          'p_note': result.note,
          'p_planned_for_override':
              result.date.toIso8601String().split('T').first,
          'p_meal_type_override': result.mealType,
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Added to meal plan')),
        );
      }
      await _loadData();
    } catch (e) {
      debugPrint('decide_meal_request approve failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not approve meal request: $e')),
        );
      }
    }
  }

  /// Deny a meal request via `decide_meal_request` with p_approved=false.
  /// Reuses `showRejectReasonDialog` with verb='Deny' (Batch 6a's verb
  /// param addition). Empty string from the dialog becomes null on the
  /// RPC's `p_note` so the column stays NULL when no reason was typed.
  Future<void> _denyMealRequest(String requestId, String recipeTitle) async {
    final reason =
        await showRejectReasonDialog(context, recipeTitle, verb: 'Deny');
    if (reason == null) return; // cancelled

    try {
      await Supabase.instance.client.rpc('decide_meal_request', params: {
        'p_request_id': requestId,
        'p_approved': false,
        'p_note': reason.isEmpty ? null : reason,
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Request denied')),
        );
      }
      await _loadData();
    } catch (e) {
      debugPrint('decide_meal_request deny failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not deny meal request: $e')),
        );
      }
    }
  }

  /// Migrated from chore_dashboard alongside _verifyChore. When a recurring
  /// chore is approved, schedule its next occurrence.
  Future<void> _createNextRecurringChoreIfNeeded(
      Map<String, dynamic> chore) async {
    final recurrence = chore['recurrence_rule'] as String?;
    if (recurrence == null || recurrence == 'once') return;

    DateTime baseDate;
    if (chore['due_at'] != null) {
      baseDate = DateTime.parse(chore['due_at']).toLocal();
    } else {
      baseDate = DateTime.now();
    }

    final nextDue = switch (recurrence) {
      'daily' => baseDate.add(const Duration(days: 1)),
      'weekly' => baseDate.add(const Duration(days: 7)),
      'biweekly' => baseDate.add(const Duration(days: 14)),
      'monthly' => DateTime(baseDate.year, baseDate.month + 1, baseDate.day,
          baseDate.hour, baseDate.minute),
      _ => null,
    };
    if (nextDue == null) return;

    final nextExists = await Supabase.instance.client
        .from('chores')
        .select('id')
        .eq('household_id', chore['household_id'])
        .eq('title', chore['title'])
        .eq('assigned_to_member_id', chore['assigned_to_member_id'])
        .eq('recurrence_rule', recurrence)
        .eq('due_at', nextDue.toUtc().toIso8601String())
        .limit(1);
    if (nextExists.isNotEmpty) return;

    final insert = Map<String, dynamic>.from(chore)
      ..remove('id')
      ..remove('created_at')
      ..remove('updated_at')
      ..remove('completed_at')
      ..remove('verified_at')
      ..remove('verified_by_member_id')
      ..remove('assignee')
      ..['status'] = 'assigned'
      ..['due_at'] = nextDue.toUtc().toIso8601String();

    await Supabase.instance.client.from('chores').insert(insert);
  }

  @override
  Widget build(BuildContext context) {
    final hasAny = _pendingVerification.isNotEmpty ||
        _pendingWishlist.isNotEmpty ||
        _pendingMealRequests.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Approvals'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : !hasAny
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('🎉', style: TextStyle(fontSize: 64)),
                        const SizedBox(height: 16),
                        Text('All caught up!',
                            style: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.copyWith(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 4),
                        Text('Nothing waiting for approval right now.',
                            style: Theme.of(context).textTheme.bodyMedium),
                      ],
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _loadData,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (_pendingVerification.isNotEmpty) ...[
                        _SectionHeader(
                            title: 'Pending Chore Verifications',
                            count: _pendingVerification.length),
                        const SizedBox(height: 8),
                        ..._pendingVerification.map((chore) {
                          final photo = _latestPhotoByChoreId[chore['id']];
                          return _VerificationCard(
                            key: ValueKey(chore['id']),
                            chore: chore,
                            latestPhoto: photo,
                            onApprove: () => _verifyChore(chore['id'], true),
                            onReject: () => _verifyChore(chore['id'], false),
                            onPhotoDeleted: _loadData,
                          );
                        }),
                        const SizedBox(height: 24),
                      ],
                      if (_pendingWishlist.isNotEmpty) ...[
                        _SectionHeader(
                            title: 'Pending Wishlist',
                            count: _pendingWishlist.length),
                        const SizedBox(height: 8),
                        ..._pendingWishlist.map((item) => _WishlistCard(
                              key: ValueKey(item['id']),
                              item: item,
                              onApprove: () =>
                                  _approveWishlistItem(item['id']),
                              onDeny: () => _denyWishlistItem(
                                  item['id'], item['name'] ?? 'Item'),
                            )),
                        const SizedBox(height: 24),
                      ],
                      if (_pendingMealRequests.isNotEmpty) ...[
                        _SectionHeader(
                            title: 'Meal Requests',
                            count: _pendingMealRequests.length),
                        const SizedBox(height: 8),
                        ..._pendingMealRequests.map((req) {
                          final recipeTitle =
                              req['recipe']?['title'] ?? 'this meal';
                          return _MealRequestCard(
                            key: ValueKey(req['id']),
                            request: req,
                            onApprove: () => _approveMealRequest(req),
                            onDeny: () =>
                                _denyMealRequest(req['id'], recipeTitle),
                          );
                        }),
                        const SizedBox(height: 24),
                      ],
                    ],
                  ),
                ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.count});
  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(title,
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          decoration: BoxDecoration(
            color: AppColors.honeyGold.withOpacity(.2),
            borderRadius: BorderRadius.circular(100),
          ),
          child: Text('$count',
              style: const TextStyle(
                  fontWeight: FontWeight.w700, fontSize: 13)),
        ),
      ],
    );
  }
}

/// Migrated from chore_dashboard. Same layout (title + points + photo
/// thumbnail + Reject/Approve buttons). Tap card → ChoreDetailScreen.
class _VerificationCard extends StatelessWidget {
  const _VerificationCard({
    super.key,
    required this.chore,
    required this.latestPhoto,
    required this.onApprove,
    required this.onReject,
    required this.onPhotoDeleted,
  });
  final Map<String, dynamic> chore;
  final Map<String, dynamic>? latestPhoto;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback onPhotoDeleted;

  @override
  Widget build(BuildContext context) {
    final name = chore['title'] ?? 'Untitled Chore';
    final points = chore['point_value'] ?? 5;
    final assignee = chore['assignee'] as Map<String, dynamic>?;
    final completedBy = assignee?['display_name'] ?? 'Someone';
    final storagePath = latestPhoto?['storage_path'] as String?;
    final photoId = latestPhoto?['id'] as String?;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ChoreDetailScreen(choreId: chore['id']),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(name,
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium
                                      ?.copyWith(fontWeight: FontWeight.w800)),
                            ),
                            Text('+$points pts',
                                style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13,
                                    color: AppColors.honeyGold)),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Completed by $completedBy',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  ChorePhotoThumbnail(
                    storagePath: storagePath,
                    photoId: photoId,
                    canDelete: true,
                    onDeleted: onPhotoDeleted,
                    size: 64,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onReject,
                      icon: const Icon(Icons.close_rounded, size: 18),
                      label: const Text('Reject'),
                      style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.coral),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: onApprove,
                      icon: const Icon(Icons.check_rounded, size: 18),
                      label: const Text('Approve'),
                      style: FilledButton.styleFrom(
                          backgroundColor: AppColors.grassGreen),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// New for Batch 5b-i. Renders a kid-added wishlist item with Approve / Deny.
/// Approve flips is_wishlist=false via the approve_wishlist_item RPC; Deny
/// hard-deletes the row (RLS allows admin DELETE).
class _WishlistCard extends StatelessWidget {
  const _WishlistCard({
    super.key,
    required this.item,
    required this.onApprove,
    required this.onDeny,
  });
  final Map<String, dynamic> item;
  final VoidCallback onApprove;
  final VoidCallback onDeny;

  @override
  Widget build(BuildContext context) {
    final name = item['name'] ?? 'Unnamed item';
    final category = item['category'] as String?;
    final displayQty = item['display_quantity'] as String?;
    final requester = item['requester'] as Map<String, dynamic>?;
    final requestedBy = requester?['display_name'] ?? 'Someone';
    final createdAt = item['created_at'] as String?;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(name,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800)),
                ),
                if (displayQty != null && displayQty.isNotEmpty)
                  Text(displayQty,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      )),
              ],
            ),
            if (category != null && category.isNotEmpty) ...[
              const SizedBox(height: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.honeyGold.withOpacity(.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(category,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.honeyGold,
                    )),
              ),
            ],
            const SizedBox(height: 6),
            Text(
              'Requested by $requestedBy · ${_formatRelative(createdAt)}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onDeny,
                    icon: const Icon(Icons.close_rounded, size: 18),
                    label: const Text('Deny'),
                    style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.coral),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: onApprove,
                    icon: const Icon(Icons.check_rounded, size: 18),
                    label: const Text('Approve'),
                    style: FilledButton.styleFrom(
                        backgroundColor: AppColors.grassGreen),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Small inline relative-time formatter. No `time_ago` util exists in the
/// codebase today (verified by grep); if more places need this, extract to
/// `utils/relative_time.dart`.
String _formatRelative(String? iso) {
  if (iso == null) return '';
  final dt = DateTime.tryParse(iso);
  if (dt == null) return '';
  final diff = DateTime.now().difference(dt.toLocal());
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  return '${(diff.inDays / 7).floor()}w ago';
}

const _mealTypeEmojis = {
  'breakfast': '🌅',
  'lunch': '☀️',
  'dinner': '🌙',
  'snack': '🍎',
  'other': '🍽️',
};

String _formatMealDate(String? iso) {
  if (iso == null) return 'Any day';
  final d = DateTime.tryParse(iso);
  if (d == null) return 'Any day';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final monthStr = months[d.month - 1];
  final now = DateTime.now();
  if (d.year == now.year) return '$monthStr ${d.day}';
  return '$monthStr ${d.day}, ${d.year}';
}

/// Batch 6a — admin-facing card for a single pending meal_request row in
/// the unified Approvals dashboard. Mirrors `_WishlistCard`'s shape with
/// a recipe image thumbnail (Q8). Approve/Deny callbacks are wired from
/// `_ApprovalsScreenState`.
class _MealRequestCard extends StatelessWidget {
  const _MealRequestCard({
    super.key,
    required this.request,
    required this.onApprove,
    required this.onDeny,
  });
  final Map<String, dynamic> request;
  final VoidCallback onApprove;
  final VoidCallback onDeny;

  @override
  Widget build(BuildContext context) {
    final recipe = request['recipe'] as Map<String, dynamic>?;
    final recipeTitle = recipe?['title'] as String? ?? 'Unnamed meal';
    final recipeImageUrl = recipe?['image_url'] as String?;
    final requester = request['requester'] as Map<String, dynamic>?;
    final requestedBy = requester?['display_name'] as String? ?? 'Someone';
    final createdAt = request['created_at'] as String?;
    final mealType = request['meal_type'] as String?;
    final dateStr = _formatMealDate(request['requested_for_date'] as String?);
    final mealStr = mealType == null
        ? 'Any meal'
        : '${_mealTypeEmojis[mealType] ?? ''} '
            '${mealType[0].toUpperCase()}${mealType.substring(1)}';

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (recipeImageUrl != null && recipeImageUrl.isNotEmpty)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      width: 64,
                      height: 64,
                      child: Image.network(
                        recipeImageUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          color: Colors.grey.shade100,
                          child: Icon(Icons.restaurant_menu_rounded,
                              color: Colors.grey.shade500),
                        ),
                      ),
                    ),
                  )
                else
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(Icons.restaurant_menu_rounded,
                        color: Colors.grey.shade500),
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(recipeTitle,
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 6),
                      Text(
                        '$mealStr · $dateStr',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Requested by $requestedBy · ${_formatRelative(createdAt)}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onDeny,
                    icon: const Icon(Icons.close_rounded, size: 18),
                    label: const Text('Deny'),
                    style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.coral),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: onApprove,
                    icon: const Icon(Icons.check_rounded, size: 18),
                    label: const Text('Approve'),
                    style: FilledButton.styleFrom(
                        backgroundColor: AppColors.grassGreen),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Returned by `_ApproveMealRequestDialog` on success — bundles the admin's
/// chosen date + meal_type override + optional note. The admin's note flows
/// into `decide_meal_request`'s `p_note` (writes to `meal_requests.decided_note`).
class _ApproveMealResult {
  const _ApproveMealResult({
    required this.date,
    required this.mealType,
    this.note,
  });
  final DateTime date;
  final String mealType;
  final String? note;
}

/// Case B approve dialog — shown only when the request lacks date OR
/// meal_type. Admin completes the missing fields (RPC raises if either
/// is still null after the COALESCE with override params). Note field
/// is optional; persists to `meal_requests.decided_note`.
///
/// StatefulWidget so the TextEditingController is owned by State and
/// disposed post-animation (carry-forward lesson from 5b-i's reject
/// dialog refactor).
class _ApproveMealRequestDialog extends StatefulWidget {
  const _ApproveMealRequestDialog({
    required this.recipeTitle,
    this.initialDate,
    this.initialMealType,
  });
  final String recipeTitle;
  final DateTime? initialDate;
  final String? initialMealType;

  @override
  State<_ApproveMealRequestDialog> createState() =>
      _ApproveMealRequestDialogState();
}

class _ApproveMealRequestDialogState
    extends State<_ApproveMealRequestDialog> {
  DateTime? _date;
  late String _mealType;
  final _noteController = TextEditingController();

  static const _mealTypes = [
    'breakfast',
    'lunch',
    'dinner',
    'snack',
    'other',
  ];

  @override
  void initState() {
    super.initState();
    _date = widget.initialDate;
    _mealType = widget.initialMealType ?? 'dinner';
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date ?? now.add(const Duration(days: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 90)),
    );
    if (picked != null) {
      setState(() => _date = picked);
    }
  }

  String _formatDate(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[d.month - 1]} ${d.day}';
  }

  void _submit() {
    if (_date == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please pick a date')),
      );
      return;
    }
    Navigator.pop(
      context,
      _ApproveMealResult(
        date: _date!,
        mealType: _mealType,
        note: _noteController.text.trim().isEmpty
            ? null
            : _noteController.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Approve "${widget.recipeTitle}"?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Date',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
            const SizedBox(height: 6),
            InkWell(
              onTap: _pickDate,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 12),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade400),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.calendar_today_rounded, size: 16),
                    const SizedBox(width: 8),
                    Text(_date == null ? 'Pick a date' : _formatDate(_date!)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text('Meal type',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              value: _mealType,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              ),
              items: _mealTypes
                  .map((m) => DropdownMenuItem<String>(
                        value: m,
                        child: Text(
                          '${_mealTypeEmojis[m] ?? ''} '
                          '${m[0].toUpperCase()}${m.substring(1)}',
                        ),
                      ))
                  .toList(),
              onChanged: (v) {
                if (v != null) setState(() => _mealType = v);
              },
            ),
            const SizedBox(height: 16),
            const Text('Note (optional)',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
            const SizedBox(height: 6),
            TextField(
              controller: _noteController,
              maxLines: 2,
              maxLength: 500,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                hintText: 'e.g. Let\'s do this for Friday dinner!',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          style:
              FilledButton.styleFrom(backgroundColor: AppColors.grassGreen),
          child: const Text('Approve'),
        ),
      ],
    );
  }
}
