import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../utils/membership.dart';

/// Manage shopping item categories: reorder, add custom, delete.
/// Also used to assign categories to items.
class ShoppingCategoryScreen extends StatefulWidget {
  const ShoppingCategoryScreen({super.key});

  @override
  State<ShoppingCategoryScreen> createState() => _ShoppingCategoryScreenState();
}

class _ShoppingCategoryScreenState extends State<ShoppingCategoryScreen> {
  Map<String, dynamic>? _household;
  List<Map<String, dynamic>> _categories = [];
  bool _isLoading = true;

  static const _defaultCategories = [
    _CategoryDef('Produce', Icons.eco_rounded, Color(0xFF4CAF50), '🥬'),
    _CategoryDef('Dairy', Icons.water_drop_rounded, Color(0xFF42A5F5), '🥛'),
    _CategoryDef('Meat & Seafood', Icons.set_meal_rounded, Color(0xFFEF5350), '🥩'),
    _CategoryDef('Pantry', Icons.inventory_2_rounded, Color(0xFFFF9800), '🫘'),
    _CategoryDef('Frozen', Icons.ac_unit_rounded, Color(0xFF29B6F6), '🧊'),
    _CategoryDef('Bakery', Icons.bakery_dining_rounded, Color(0xFFD4A373), '🍞'),
    _CategoryDef('Beverages', Icons.local_cafe_rounded, Color(0xFF7E57C2), '☕'),
    _CategoryDef('Snacks', Icons.cookie_rounded, Color(0xFFFFCA28), '🍪'),
    _CategoryDef('Household', Icons.cleaning_services_rounded, Color(0xFF78909C), '🧹'),
    _CategoryDef('Personal Care', Icons.spa_rounded, Color(0xFFEC407A), '🧴'),
    _CategoryDef('Pet Supplies', Icons.pets_rounded, Color(0xFF8D6E63), '🐾'),
    _CategoryDef('Other', Icons.more_horiz_rounded, Color(0xFF9E9E9E), '📦'),
  ];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      // Batch 7a-iii — Pattern A (LOW-risk): household-scoped category list,
      // no permission gating on _myMembership downstream. No listener needed.
      // The latent TextEditingController dispose bug elsewhere in this file
      // is tracked for Batch 7b — not addressed here.
      final membership = await MembershipHelper.loadActiveMembership(
        includeHouseholdJoin: true,
      );
      if (membership == null) {
        setState(() => _isLoading = false);
        return;
      }

      _household = membership['households'];
      final householdId = _household!['id'];

      // Load custom categories from shopping_items distinct categories
      final items = await Supabase.instance.client
          .from('shopping_items')
          .select('category')
          .eq('household_id', householdId)
          .not('category', 'is', null);

      final usedCategories = <String>{};
      for (final item in items) {
        final cat = item['category'] as String?;
        if (cat != null && cat.isNotEmpty) usedCategories.add(cat);
      }

      // Build category list: defaults first, then any custom categories from items
      final customCats = usedCategories.where((c) => !_defaultCategories.any((d) => d.name == c)).toList()..sort();

      setState(() {
        _categories = [
          ..._defaultCategories.map((d) => {
            'name': d.name,
            'icon': d.icon,
            'color': d.color,
            'emoji': d.emoji,
            'is_default': true,
          }),
          ...customCats.map((c) => {
            'name': c,
            'icon': Icons.label_rounded,
            'color': Colors.grey,
            'emoji': '🏷️',
            'is_default': false,
          }),
        ];
        _isLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _addCustomCategory() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Category'),
        content: TextFormField(
          controller: controller,
          textCapitalization: TextCapitalization.words,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Category name',
            hintText: 'e.g., Baby Supplies, Garden',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );

    controller.dispose();

    if (result != null && result.isNotEmpty) {
      // Check if it already exists
      if (_categories.any((c) => (c['name'] as String).toLowerCase() == result.toLowerCase())) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Category "$result" already exists.')),
          );
        }
        return;
      }

      setState(() {
        _categories.add({
          'name': result,
          'icon': Icons.label_rounded,
          'color': Colors.grey,
          'emoji': '🏷️',
          'is_default': false,
        });
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Category "$result" added. It will appear when items use it.')),
        );
      }
    }
  }

  Future<void> _deleteCustomCategory(int index) async {
    final cat = _categories[index];
    if (cat['is_default'] == true) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Category?'),
        content: Text('This will remove "${cat['name']}" from the category list. Items using this category will be moved to "Other".'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.coral),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      // Update items with this category to "Other"
      try {
        final householdId = _household!['id'];
        await Supabase.instance.client
            .from('shopping_items')
            .update({'category': 'Other'})
            .eq('household_id', householdId)
            .eq('category', cat['name']);

        setState(() => _categories.removeAt(index));
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not delete category.')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Shopping Categories'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_rounded),
            onPressed: _addCustomCategory,
            tooltip: 'Add category',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _categories.length,
              itemBuilder: (context, index) {
                final cat = _categories[index];
                final name = cat['name'] as String;
                final icon = cat['icon'] as IconData;
                final color = cat['color'] as Color;
                final emoji = cat['emoji'] as String;
                final isDefault = cat['is_default'] as bool;

                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: ListTile(
                    leading: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: color.withOpacity(.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Center(
                        child: Icon(icon, color: color, size: 22),
                      ),
                    ),
                    title: Text(
                      name,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      isDefault ? 'Default category' : 'Custom category',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(emoji, style: const TextStyle(fontSize: 20)),
                        if (!isDefault) ...[
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(Icons.delete_outline_rounded, size: 20, color: AppColors.coral),
                            onPressed: () => _deleteCustomCategory(index),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class _CategoryDef {
  const _CategoryDef(this.name, this.icon, this.color, this.emoji);
  final String name;
  final IconData icon;
  final Color color;
  final String emoji;
}
