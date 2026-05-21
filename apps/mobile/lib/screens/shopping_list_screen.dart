import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../services/realtime_service.dart';
import 'shopping_category_screen.dart';

/// Full shopping list screen with multi-store support, manual entry,
/// recipe ingredient import, purchased tracking, and category grouping.
class ShoppingListScreen extends StatefulWidget {
  const ShoppingListScreen({super.key});

  @override
  State<ShoppingListScreen> createState() => _ShoppingListScreenState();
}

class _ShoppingListScreenState extends State<ShoppingListScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  Map<String, dynamic>? _household;
  Map<String, dynamic>? _myMembership;
  List<Map<String, dynamic>> _shoppingLists = [];
  List<Map<String, dynamic>> _shoppingItems = [];
  List<Map<String, dynamic>> _stores = [];
  List<Map<String, dynamic>> _householdRecipes = [];
  bool _isLoading = true;
  bool _groupByCategory = true;

  String? _activeListId;

  static const _categoryOrder = [
    'Produce', 'Dairy', 'Meat & Seafood', 'Pantry', 'Frozen',
    'Bakery', 'Beverages', 'Snacks', 'Household', 'Personal Care',
    'Pet Supplies', 'Other',
  ];

  static const _categoryIcons = {
    'Produce': Icons.eco_rounded,
    'Dairy': Icons.water_drop_rounded,
    'Meat & Seafood': Icons.set_meal_rounded,
    'Pantry': Icons.inventory_2_rounded,
    'Frozen': Icons.ac_unit_rounded,
    'Bakery': Icons.bakery_dining_rounded,
    'Beverages': Icons.local_cafe_rounded,
    'Snacks': Icons.cookie_rounded,
    'Household': Icons.cleaning_services_rounded,
    'Personal Care': Icons.spa_rounded,
    'Pet Supplies': Icons.pets_rounded,
    'Other': Icons.more_horiz_rounded,
  };

  static const _categoryColors = {
    'Produce': Color(0xFF4CAF50),
    'Dairy': Color(0xFF42A5F5),
    'Meat & Seafood': Color(0xFFEF5350),
    'Pantry': Color(0xFFFF9800),
    'Frozen': Color(0xFF29B6F6),
    'Bakery': Color(0xFFD4A373),
    'Beverages': Color(0xFF7E57C2),
    'Snacks': Color(0xFFFFCA28),
    'Household': Color(0xFF78909C),
    'Personal Care': Color(0xFFEC407A),
    'Pet Supplies': Color(0xFF8D6E63),
    'Other': Color(0xFF9E9E9E),
  };

  @override
  void initState() {
    super.initState();
    _loadData();
    RealtimeService.instance.shoppingVersion.addListener(_onRealtimeUpdate);
  }

  @override
  void dispose() {
    RealtimeService.instance.shoppingVersion.removeListener(_onRealtimeUpdate);
    super.dispose();
  }

  void _onRealtimeUpdate() {
    if (mounted) _loadData();
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
      final householdId = _household!['id'];

      final results = await Future.wait([
        Supabase.instance.client
            .from('shopping_lists')
            .select()
            .eq('household_id', householdId)
            .order('created_at', ascending: false),
        Supabase.instance.client
            .from('stores')
            .select()
            .eq('household_id', householdId)
            .order('is_default', ascending: false),
        Supabase.instance.client
            .from('household_recipes')
            .select('id, title, ingredients')
            .eq('household_id', householdId)
            .order('title'),
      ]);

      _shoppingLists = List<Map<String, dynamic>>.from(results[0]);
      _stores = List<Map<String, dynamic>>.from(results[1]);
      _householdRecipes = List<Map<String, dynamic>>.from(results[2]);

      if (_shoppingLists.isNotEmpty) {
        _activeListId = _shoppingLists.first['id'];
      } else {
        await _createDefaultList();
      }

      await _loadShoppingItems();
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _createDefaultList() async {
    if (_household == null) return;

    try {
      final newList = await Supabase.instance.client
          .from('shopping_lists')
          .insert({
            'household_id': _household!['id'],
            'name': 'Current Shopping List',
            'is_active': true,
            'created_by_member_id': _myMembership!['id'],
          })
          .select()
          .single();

      setState(() {
        _shoppingLists = [newList];
        _activeListId = newList['id'];
      });
    } catch (_) {}
  }

  Future<void> _loadShoppingItems() async {
    if (_activeListId == null) return;

    try {
      final items = await Supabase.instance.client
          .from('shopping_items')
          .select('*, store:stores(name)')
          .eq('shopping_list_id', _activeListId!)
          .order('purchased', ascending: true)
          .order('sort_order');

      setState(() {
        _shoppingItems = List<Map<String, dynamic>>.from(items);
        _isLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showAddItemSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => _AddShoppingItemSheet(
        householdId: _household!['id'],
        shoppingListId: _activeListId!,
        myMemberId: _myMembership!['id'],
        stores: _stores,
      ),
    ).then((_) => _loadShoppingItems());
  }

  void _showAddFromRecipeSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => _AddFromRecipeSheet(
        householdId: _household!['id'],
        shoppingListId: _activeListId!,
        myMemberId: _myMembership!['id'],
        recipes: _householdRecipes,
      ),
    ).then((_) => _loadShoppingItems());
  }

  Future<void> _togglePurchased(String itemId, bool purchased) async {
    try {
      await Supabase.instance.client
          .from('shopping_items')
          .update({
            'purchased': purchased,
            'purchased_by_member_id': purchased ? _myMembership!['id'] : null,
            'purchased_at': purchased ? DateTime.now().toIso8601String() : null,
          })
          .eq('id', itemId);
      _loadShoppingItems();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update item.')),
        );
      }
    }
  }

  Future<void> _deleteItem(String itemId) async {
    try {
      await Supabase.instance.client
          .from('shopping_items')
          .delete()
          .eq('id', itemId);
      _loadShoppingItems();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not delete item.')),
        );
      }
    }
  }

  void _showEditItemSheet(Map<String, dynamic> item) {
    final nameController = TextEditingController(text: item['name'] ?? '');
    final quantityController = TextEditingController(text: item['quantity']?.toString() ?? '');
    final unitController = TextEditingController(text: item['unit'] ?? '');
    String? selectedCategory = item['category'];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Edit Item', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
              const SizedBox(height: 20),
              TextFormField(
                controller: nameController,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Item name',
                  prefixIcon: Icon(Icons.edit_note_rounded),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: TextFormField(
                      controller: quantityController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Quantity',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 3,
                    child: TextFormField(
                      controller: unitController,
                      decoration: const InputDecoration(
                        labelText: 'Unit (e.g., lbs, oz)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                value: selectedCategory,
                decoration: const InputDecoration(
                  labelText: 'Category',
                  prefixIcon: Icon(Icons.category_rounded),
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem<String>(value: null, child: Text('No category')),
                  ..._ShoppingListContent._categories.map((c) => DropdownMenuItem<String>(value: c, child: Text(c))),
                ],
                onChanged: (v) => selectedCategory = v,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () async {
                  final name = nameController.text.trim();
                  if (name.isEmpty) return;

                  final quantity = quantityController.text.trim();
                  final unit = unitController.text.trim();
                  final displayQuantity = quantity.isEmpty ? null : (unit.isEmpty ? quantity : '$quantity $unit');

                  try {
                    await Supabase.instance.client
                        .from('shopping_items')
                        .update({
                          'name': name,
                          'quantity': double.tryParse(quantity),
                          'unit': unit.isEmpty ? null : unit,
                          'display_quantity': displayQuantity,
                          'category': selectedCategory,
                        })
                        .eq('id', item['id']);

                    if (mounted) {
                      Navigator.pop(context);
                      _loadShoppingItems();
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Error updating item: $e')),
                      );
                    }
                  }
                },
                child: const Text('Save Changes'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _clearPurchasedItems() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear purchased items?'),
        content: const Text('This will remove all checked-off items from the list.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.coral),
            child: const Text('Clear'),
          ),
        ],
      ),
    );

    if (confirmed != true || _activeListId == null) return;

    try {
      await Supabase.instance.client
          .from('shopping_items')
          .delete()
          .eq('shopping_list_id', _activeListId!)
          .eq('purchased', true);
      _loadShoppingItems();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not clear items.')),
        );
      }
    }
  }

  /// Group items by category for display
  Map<String, List<Map<String, dynamic>>> _groupItemsByCategory(List<Map<String, dynamic>> items) {
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final item in items) {
      final category = (item['category'] as String?) ?? 'Other';
      groups.putIfAbsent(category, () => []).add(item);
    }
    return groups;
  }

  /// Get sorted category names
  List<String> _sortedCategories(Map<String, List<Map<String, dynamic>>> groups) {
    final cats = groups.keys.toList();
    cats.sort((a, b) {
      final ai = _categoryOrder.indexOf(a);
      final bi = _categoryOrder.indexOf(b);
      // Default categories first, in defined order; custom categories last, alphabetically
      if (ai >= 0 && bi >= 0) return ai.compareTo(bi);
      if (ai >= 0) return -1;
      if (bi >= 0) return 1;
      return a.compareTo(b);
    });
    return cats;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final unpurchasedItems = _shoppingItems.where((i) => !(i['purchased'] ?? false)).toList();
    final purchasedItems = _shoppingItems.where((i) => i['purchased'] ?? false).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Shopping List 🛒'),
        actions: [
          IconButton(
            icon: Icon(_groupByCategory ? Icons.list_rounded : Icons.category_rounded),
            onPressed: () => setState(() => _groupByCategory = !_groupByCategory),
            tooltip: _groupByCategory ? 'Show as list' : 'Group by category',
          ),
          PopupMenuButton<String>(
            onSelected: (action) {
              switch (action) {
                case 'categories':
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const ShoppingCategoryScreen()));
                  break;
                case 'clear':
                  _clearPurchasedItems();
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'categories',
                child: Row(children: [
                  Icon(Icons.category_rounded, size: 20),
                  SizedBox(width: 12),
                  Text('Manage Categories'),
                ]),
              ),
              if (purchasedItems.isNotEmpty)
                const PopupMenuItem(
                  value: 'clear',
                  child: Row(children: [
                    Icon(Icons.cleaning_services_rounded, size: 20),
                    SizedBox(width: 12),
                    Text('Clear Purchased'),
                  ]),
                ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loadData,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadData,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // Quick actions
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _showAddItemSheet,
                          icon: const Icon(Icons.add_rounded, size: 18),
                          label: const Text('Add item'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _showAddFromRecipeSheet,
                          icon: const Icon(Icons.restaurant_menu_rounded, size: 18),
                          label: const Text('From recipe'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // Unpurchased items
                  if (unpurchasedItems.isNotEmpty) ...[
                    Row(
                      children: [
                        Text(
                          'To buy',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.honeyGold.withOpacity(.2),
                            borderRadius: BorderRadius.circular(100),
                          ),
                          child: Text('${unpurchasedItems.length}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (_groupByCategory)
                      ..._buildCategorizedItems(unpurchasedItems)
                    else
                      ...unpurchasedItems.map((item) => _ShoppingItemCard(
                            item: item,
                            onToggle: (v) => _togglePurchased(item['id'], v),
                            onDelete: () => _deleteItem(item['id']),
                            onEdit: () => _showEditItemSheet(item),
                          )),
                    const SizedBox(height: 24),
                  ],

                  // Purchased items
                  if (purchasedItems.isNotEmpty) ...[
                    Row(
                      children: [
                        Text(
                          'Purchased',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.grassGreen.withOpacity(.2),
                            borderRadius: BorderRadius.circular(100),
                          ),
                          child: Text('${purchasedItems.length}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    ...purchasedItems.map((item) => _ShoppingItemCard(
                          item: item,
                          onToggle: (v) => _togglePurchased(item['id'], v),
                          onDelete: () => _deleteItem(item['id']),
                          onEdit: () => _showEditItemSheet(item),
                        )),
                  ],

                  // Empty state
                  if (_shoppingItems.isEmpty)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          children: [
                            const Text('🛒', style: TextStyle(fontSize: 48)),
                            const SizedBox(height: 12),
                            Text('Your list is empty', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                            const SizedBox(height: 4),
                            Text('Add items manually or import from a recipe.', style: Theme.of(context).textTheme.bodyMedium),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  /// Build category-grouped item sections
  List<Widget> _buildCategorizedItems(List<Map<String, dynamic>> items) {
    final groups = _groupItemsByCategory(items);
    final sortedCats = _sortedCategories(groups);
    final widgets = <Widget>[];

    for (final cat in sortedCats) {
      final catItems = groups[cat]!;
      final color = _categoryColors[cat] ?? Colors.grey;
      final icon = _categoryIcons[cat] ?? Icons.label_rounded;

      widgets.add(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Category header
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 8, top: 8),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: color.withOpacity(.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(icon, size: 16, color: color),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    cat,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: color,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: color.withOpacity(.1),
                      borderRadius: BorderRadius.circular(100),
                    ),
                    child: Text(
                      '${catItems.length}',
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: color),
                    ),
                  ),
                ],
              ),
            ),
            // Items in category
            ...catItems.map((item) => _ShoppingItemCard(
                  item: item,
                  onToggle: (v) => _togglePurchased(item['id'], v),
                  onDelete: () => _deleteItem(item['id']),
                  onEdit: () => _showEditItemSheet(item),
                )),
            const SizedBox(height: 4),
          ],
        ),
      );
    }

    return widgets;
  }
}

class _ShoppingItemCard extends StatelessWidget {
  const _ShoppingItemCard({
    required this.item,
    required this.onToggle,
    required this.onDelete,
    required this.onEdit,
  });

  final Map<String, dynamic> item;
  final void Function(bool) onToggle;
  final VoidCallback onDelete;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final name = item['name'] ?? 'Unknown';
    final quantity = item['display_quantity'] ?? item['quantity'];
    final purchased = item['purchased'] ?? false;
    final store = item['store']?['name'];
    final category = item['category'];

    return Dismissible(
      key: ValueKey(item['id']),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDelete(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        decoration: BoxDecoration(
          color: AppColors.coral.withOpacity(.1),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.delete_outline_rounded, color: AppColors.coral),
      ),
      child: Card(
        margin: const EdgeInsets.only(bottom: 6),
        child: InkWell(
          onTap: onEdit,
          borderRadius: BorderRadius.circular(12),
          child: CheckboxListTile(
          value: purchased,
          onChanged: (v) => onToggle(v ?? false),
          title: Text(
            name,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              decoration: purchased ? TextDecoration.lineThrough : null,
              color: purchased ? Colors.grey : null,
            ),
          ),
          subtitle: Row(
            children: [
              if (quantity != null) ...[
                Text(quantity, style: const TextStyle(fontSize: 13)),
                const SizedBox(width: 8),
              ],
              if (store != null) ...[
                Icon(Icons.storefront_rounded, size: 14, color: AppColors.skyBlue),
                const SizedBox(width: 2),
                Text(store, style: const TextStyle(fontSize: 13)),
                const SizedBox(width: 8),
              ],
              if (category != null) ...[
                Icon(Icons.label_outline_rounded, size: 14, color: Colors.grey.shade500),
                const SizedBox(width: 2),
                Text(category, style: const TextStyle(fontSize: 13)),
              ],
            ],
          ),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        ),
        ),
      ),
    );
  }
}

class _AddShoppingItemSheet extends StatefulWidget {
  const _AddShoppingItemSheet({
    required this.householdId,
    required this.shoppingListId,
    required this.myMemberId,
    required this.stores,
  });

  final String householdId;
  final String shoppingListId;
  final String myMemberId;
  final List<Map<String, dynamic>> stores;

  @override
  State<_AddShoppingItemSheet> createState() => _AddShoppingItemSheetState();
}

class _AddShoppingItemSheetState extends State<_AddShoppingItemSheet> {
  final _nameController = TextEditingController();
  final _quantityController = TextEditingController();
  final _unitController = TextEditingController();
  String? _selectedCategory;
  String? _selectedStoreId;
  bool _isLoading = false;

  static const _categories = ['Produce', 'Dairy', 'Meat & Seafood', 'Pantry', 'Frozen', 'Bakery', 'Beverages', 'Snacks', 'Household', 'Personal Care', 'Pet Supplies', 'Other'];

  static const _categoryEmojis = {
    'Produce': '🥬', 'Dairy': '🥛', 'Meat & Seafood': '🥩', 'Pantry': '🫘',
    'Frozen': '🧊', 'Bakery': '🍞', 'Beverages': '☕', 'Snacks': '🍪',
    'Household': '🧹', 'Personal Care': '🧴', 'Pet Supplies': '🐾', 'Other': '📦',
  };

  @override
  void dispose() {
    _nameController.dispose();
    _quantityController.dispose();
    _unitController.dispose();
    super.dispose();
  }

  Future<void> _addItem() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter an item name.')),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final quantity = _quantityController.text.trim();
      final unit = _unitController.text.trim();
      final displayQuantity = quantity.isEmpty ? null : (unit.isEmpty ? quantity : '$quantity $unit');

      await Supabase.instance.client.from('shopping_items').insert({
        'household_id': widget.householdId,
        'shopping_list_id': widget.shoppingListId,
        'name': name,
        'quantity': double.tryParse(quantity),
        'unit': unit.isEmpty ? null : unit,
        'display_quantity': displayQuantity,
        'store_id': _selectedStoreId,
        'category': _selectedCategory,
        'purchased': false,
        'added_by_member_id': widget.myMemberId,
      });

      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not add item. Please try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Add Shopping Item', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
            const SizedBox(height: 20),

            // Item name
            TextFormField(
              controller: _nameController,
              textCapitalization: TextCapitalization.words,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Item name',
                prefixIcon: Icon(Icons.shopping_basket_rounded),
                border: OutlineInputBorder(),
                hintText: 'e.g., Milk, Eggs, Bread',
              ),
            ),
            const SizedBox(height: 16),

            // Quantity and unit
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _quantityController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Quantity',
                      prefixIcon: Icon(Icons.format_list_numbered_rounded),
                      border: OutlineInputBorder(),
                      hintText: 'e.g., 2, 1.5',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _unitController,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Unit',
                      border: OutlineInputBorder(),
                      hintText: 'e.g., gal, lbs, dozen',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Category selector with emoji chips
            Text('Category', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            SizedBox(
              height: 42,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _categories.length,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (context, i) {
                  final cat = _categories[i];
                  final selected = _selectedCategory == cat;
                  return ChoiceChip(
                    label: Text('${_categoryEmojis[cat]} ${cat}'),
                    selected: selected,
                    onSelected: (_) => setState(() => _selectedCategory = selected ? null : cat),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),

            // Store
            DropdownButtonFormField<String>(
              value: _selectedStoreId,
              decoration: const InputDecoration(
                labelText: 'Store (optional)',
                prefixIcon: Icon(Icons.storefront_rounded),
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem(value: null, child: Text('No specific store')),
                ...widget.stores.map((s) => DropdownMenuItem(
                  value: s['id'],
                  child: Text(s['name'] ?? 'Unknown'),
                )),
              ],
              onChanged: (v) => setState(() => _selectedStoreId = v),
            ),
            const SizedBox(height: 24),

            FilledButton(
              onPressed: _isLoading ? null : _addItem,
              child: _isLoading
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Add item'),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddFromRecipeSheet extends StatefulWidget {
  const _AddFromRecipeSheet({
    required this.householdId,
    required this.shoppingListId,
    required this.myMemberId,
    required this.recipes,
  });

  final String householdId;
  final String shoppingListId;
  final String myMemberId;
  final List<Map<String, dynamic>> recipes;

  @override
  State<_AddFromRecipeSheet> createState() => _AddFromRecipeSheetState();
}

class _AddFromRecipeSheetState extends State<_AddFromRecipeSheet> {
  String? _selectedRecipeId;
  bool _isLoading = false;
  List<String> _selectedIngredients = [];

  @override
  Widget build(BuildContext context) {
    final selectedRecipe = widget.recipes.where((r) => r['id'] == _selectedRecipeId).firstOrNull;
    final ingredients = selectedRecipe?['ingredients'] as List<dynamic>? ?? [];

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Add from Recipe', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
            const SizedBox(height: 20),

            // Recipe selection
            DropdownButtonFormField<String>(
              value: _selectedRecipeId,
              decoration: const InputDecoration(
                labelText: 'Choose a recipe',
                prefixIcon: Icon(Icons.menu_book_rounded),
                border: OutlineInputBorder(),
              ),
              items: widget.recipes.map((r) => DropdownMenuItem<String>(
                value: r['id'],
                child: Text(r['title'] ?? 'Untitled', overflow: TextOverflow.ellipsis),
              )).toList(),
              onChanged: (v) {
                setState(() {
                  _selectedRecipeId = v;
                  _selectedIngredients = [];
                });
              },
            ),
            const SizedBox(height: 16),

            // Ingredients list
            if (ingredients.isNotEmpty) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Select ingredients:', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                  TextButton(
                    onPressed: () {
                      setState(() {
                        if (_selectedIngredients.length == ingredients.length) {
                          _selectedIngredients = [];
                        } else {
                          _selectedIngredients = ingredients.map((ing) {
                            return ing is String ? ing : (ing['raw']?.toString() ?? ing.toString());
                          }).toList().cast<String>();
                        }
                      });
                    },
                    child: Text(_selectedIngredients.length == ingredients.length ? 'Deselect all' : 'Select all'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                constraints: const BoxConstraints(maxHeight: 200),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: ingredients.length,
                  itemBuilder: (context, i) {
                    final ing = ingredients[i];
                    final text = ing is String ? ing : (ing['raw']?.toString() ?? ing.toString());
                    final isSelected = _selectedIngredients.contains(text);

                    return CheckboxListTile(
                      value: isSelected,
                      onChanged: (v) {
                        setState(() {
                          if (v == true) {
                            _selectedIngredients.add(text);
                          } else {
                            _selectedIngredients.remove(text);
                          }
                        });
                      },
                      title: Text(text, style: const TextStyle(fontSize: 14)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                      dense: true,
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
            ],

            FilledButton(
              onPressed: _isLoading || _selectedIngredients.isEmpty ? null : _addIngredients,
              child: _isLoading
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Text('Add ${_selectedIngredients.length} ingredient${_selectedIngredients.length == 1 ? '' : 's'}'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addIngredients() async {
    setState(() => _isLoading = true);

    try {
      final inserts = _selectedIngredients.map((ing) => {
        'household_id': widget.householdId,
        'shopping_list_id': widget.shoppingListId,
        'name': ing,
        'display_quantity': null,
        'purchased': false,
        'source_recipe_id': _selectedRecipeId,
        'added_by_member_id': widget.myMemberId,
      }).toList();

      await Supabase.instance.client.from('shopping_items').insert(inserts);

      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not add ingredients. Please try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }
}
