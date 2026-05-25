import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../services/active_member_service.dart';
import '../utils/membership.dart';
import '../utils/permissions.dart';

/// Admin-only CRUD for the household's necessity_categories list. When a
/// kid adds a shopping item whose category matches one of these strings
/// (case-insensitive), `add_shopping_item` RPC bypasses the wishlist and
/// inserts directly to the active shopping list.
///
/// Reached from Settings → Household section (Batch 5b-ii). Kid sessions
/// don't see the entry there and would bounce off the build-level admin
/// gate here as defense-in-depth.
///
/// Composite PK on (household_id, category) means edit-in-place isn't
/// possible — we expose delete + add as separate actions. Free-text input
/// with case-insensitive dup check on the client + ON CONFLICT DO NOTHING
/// on the server.
class NecessityCategoriesScreen extends StatefulWidget {
  const NecessityCategoriesScreen({super.key});

  @override
  State<NecessityCategoriesScreen> createState() =>
      _NecessityCategoriesScreenState();
}

class _NecessityCategoriesScreenState extends State<NecessityCategoriesScreen> {
  Map<String, dynamic>? _myMembership;
  Map<String, dynamic>? _household;
  List<String> _categories = [];
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

  /// If admin switches to a kid mid-screen, pop back to home. The screen is
  /// admin-only — even though Settings doesn't show the entry to kids, this
  /// safety net handles the rare case of a profile switch while the screen
  /// is mounted.
  void _onActiveMemberChanged() {
    if (!mounted) return;
    _loadData().then((_) {
      if (!mounted) return;
      if (!Permissions.canManageNecessityCategories(_myMembership)) {
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

      if (!Permissions.canManageNecessityCategories(_myMembership)) {
        if (mounted) setState(() => _isLoading = false);
        return;
      }

      final rows = await Supabase.instance.client
          .from('necessity_categories')
          .select('category')
          .eq('household_id', _household!['id'])
          .order('category');

      if (!mounted) return;
      setState(() {
        _categories =
            (rows as List).map((r) => r['category'] as String).toList();
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('necessity_categories load failed: $e');
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load categories: $e')),
      );
    }
  }

  Future<void> _addCategory() async {
    final controller = TextEditingController();
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => _AddCategoryDialog(controller: controller),
    );
    if (result == null) return; // cancelled

    final name = result.trim();
    if (name.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please enter a category name')),
        );
      }
      return;
    }

    // Case-insensitive duplicate check on the client. The composite PK on
    // necessity_categories catches dupes server-side too via the ON
    // CONFLICT clause, but the client check prevents the confusing
    // "succeeded but nothing changed" UX on conflict.
    final existsCi = _categories
        .any((c) => c.toLowerCase() == name.toLowerCase());
    if (existsCi) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('"$name" already exists')),
        );
      }
      return;
    }

    try {
      await Supabase.instance.client.from('necessity_categories').insert({
        'household_id': _household!['id'],
        'category': name,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Added "$name" to necessity categories')),
        );
      }
      await _loadData();
    } catch (e) {
      debugPrint('necessity_category insert failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not add category: $e')),
        );
      }
    }
  }

  Future<void> _deleteCategory(String category) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete category?'),
        content: Text(
          "Remove \"$category\" from necessity categories? Existing items with this category aren't affected.",
        ),
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
          .from('necessity_categories')
          .delete()
          .eq('household_id', _household!['id'])
          .eq('category', category);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Removed "$category" from necessity categories')),
        );
      }
      await _loadData();
    } catch (e) {
      debugPrint('necessity_category delete failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not delete category: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Defensive build-level admin gate. Settings already hides the entry
    // for kids; this catches edge cases (deep links, post-load membership
    // change before _onActiveMemberChanged pops the screen).
    if (!_isLoading &&
        _myMembership != null &&
        !Permissions.canManageNecessityCategories(_myMembership)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Necessity Categories')),
        body: const Center(child: Text('Admins only')),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Necessity Categories')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadData,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.honeyGold.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'Items added by kids in these categories skip the wishlist and go directly to the shared shopping list.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurface),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_categories.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 32),
                      child: Center(
                        child: Text(
                          'No necessity categories yet. Add one below to let kids add items without admin approval.',
                          textAlign: TextAlign.center,
                          style:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                        ),
                      ),
                    )
                  else
                    ..._categories.map((category) => Card(
                          key: ValueKey(category),
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            leading: const Icon(Icons.check_circle_outline,
                                color: AppColors.grassGreen),
                            title: Text(category,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline,
                                  color: AppColors.coral),
                              tooltip: 'Delete',
                              onPressed: () => _deleteCategory(category),
                            ),
                          ),
                        )),
                ],
              ),
            ),
      floatingActionButton: _isLoading
          ? null
          : FloatingActionButton.extended(
              onPressed: _addCategory,
              icon: const Icon(Icons.add),
              label: const Text('Add'),
            ),
    );
  }
}

/// Separate StatefulWidget for the Add Category dialog so its TextEditing-
/// Controller can be disposed by the State after the dismissal animation
/// completes — same lesson as the showRejectReasonDialog refactor in 5b-i.
class _AddCategoryDialog extends StatefulWidget {
  const _AddCategoryDialog({required this.controller});
  final TextEditingController controller;

  @override
  State<_AddCategoryDialog> createState() => _AddCategoryDialogState();
}

class _AddCategoryDialogState extends State<_AddCategoryDialog> {
  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add necessity category'),
      content: TextField(
        controller: widget.controller,
        autofocus: true,
        maxLength: 50,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(
          hintText: 'Category name',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, widget.controller.text),
          child: const Text('Add'),
        ),
      ],
    );
  }
}
