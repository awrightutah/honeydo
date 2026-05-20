import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:image_picker/image_picker.dart';
import '../theme/app_theme.dart';
import '../services/image_upload_service.dart';

/// Full recipe detail screen with viewing, editing, and sharing capabilities.
class RecipeDetailScreen extends StatefulWidget {
  final String recipeId;
  final bool isHouseholdRecipe;

  const RecipeDetailScreen({
    super.key,
    required this.recipeId,
    this.isHouseholdRecipe = true,
  });

  @override
  State<RecipeDetailScreen> createState() => _RecipeDetailScreenState();
}

class _RecipeDetailScreenState extends State<RecipeDetailScreen> {
  Map<String, dynamic>? _recipe;
  Map<String, dynamic>? _householdMember;
  List<Map<String, dynamic>> _shoppingLists = [];
  bool _isLoading = true;
  bool _isEditing = false;
  int _servingsMultiplier = 1;

  // Edit controllers
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _servingsController = TextEditingController();
  final _prepTimeController = TextEditingController();
  final _cookTimeController = TextEditingController();
  final _caloriesController = TextEditingController();
  String _selectedDifficulty = 'easy';
  String _selectedCuisine = 'American';
  List<dynamic> _editIngredients = [];
  List<dynamic> _editSteps = [];

  final List<String> _cuisines = [
    'American', 'Italian', 'Mexican', 'Asian', 'Indian',
    'Mediterranean', 'French', 'Southern', 'Other',
  ];

  final List<String> _difficulties = ['easy', 'medium', 'hard'];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _servingsController.dispose();
    _prepTimeController.dispose();
    _cookTimeController.dispose();
    _caloriesController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);

    try {
      final user = Supabase.instance.client.auth.currentUser!;

      // Load membership
      final memberships = await Supabase.instance.client
          .from('household_members')
          .select('*, households(*)')
          .eq('auth_user_id', user.id)
          .limit(1);

      if (memberships.isEmpty) {
        setState(() => _isLoading = false);
        return;
      }

      _householdMember = memberships[0];
      final householdId = _householdMember!['household_id'];

      // Load recipe
      final tableName = widget.isHouseholdRecipe ? 'household_recipes' : 'master_recipes';
      final recipes = await Supabase.instance.client
          .from(tableName)
          .select()
          .eq('id', widget.recipeId)
          .limit(1);

      if (recipes.isEmpty) {
        setState(() => _isLoading = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Recipe not found')),
          );
          Navigator.pop(context);
        }
        return;
      }

      _recipe = recipes[0];

      // Populate edit fields
      _titleController.text = _recipe?['title'] ?? '';
      _descriptionController.text = _recipe?['description'] ?? '';
      _servingsController.text = (_recipe?['servings'] ?? 4).toString();
      _prepTimeController.text = (_recipe?['prep_time_minutes'] ?? 0).toString();
      _cookTimeController.text = (_recipe?['cook_time_minutes'] ?? 0).toString();
      _caloriesController.text = (_recipe?['calories_per_serving'] ?? 0).toString();
      _selectedDifficulty = _recipe?['difficulty'] ?? 'easy';
      _selectedCuisine = _recipe?['cuisine'] ?? 'American';
      _editIngredients = List<dynamic>.from(_recipe?['ingredients'] ?? []);
      _editSteps = List<dynamic>.from(_recipe?['steps'] ?? []);

      // Load shopping lists for the "add to list" feature
      try {
        _shoppingLists = await Supabase.instance.client
            .from('shopping_lists')
            .select()
            .eq('household_id', householdId)
            .order('created_at', ascending: false);
      } catch (_) {
        _shoppingLists = [];
      }

      setState(() => _isLoading = false);
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading recipe: $e')),
        );
      }
    }
  }

  Future<void> _saveRecipe() async {
    if (_titleController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Title is required')),
      );
      return;
    }

    try {
      final updates = <String, dynamic>{
        'title': _titleController.text.trim(),
        'description': _descriptionController.text.trim(),
        'servings': int.tryParse(_servingsController.text) ?? 4,
        'prep_time_minutes': int.tryParse(_prepTimeController.text) ?? 0,
        'cook_time_minutes': int.tryParse(_cookTimeController.text) ?? 0,
        'calories_per_serving': int.tryParse(_caloriesController.text) ?? 0,
        'difficulty': _selectedDifficulty,
        'cuisine': _selectedCuisine,
        'ingredients': _editIngredients,
        'steps': _editSteps,
      };

      await Supabase.instance.client
          .from('household_recipes')
          .update(updates)
          .eq('id', widget.recipeId);

      setState(() => _isEditing = false);
      await _loadData();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Recipe updated!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving recipe: $e')),
        );
      }
    }
  }

  Future<void> _toggleFavorite() async {
    try {
      await Supabase.instance.client
          .from('household_recipes')
          .update({'is_favorite': !(_recipe?['is_favorite'] ?? false)})
          .eq('id', widget.recipeId);

      await _loadData();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error updating favorite: $e')),
        );
      }
    }
  }

  Future<void> _addToShoppingList() async {
    if (_shoppingLists.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No shopping lists found. Create one first!')),
      );
      return;
    }

    String? selectedListId = _shoppingLists.first['id'];

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Add to Shopping List'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Select a shopping list:'),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: selectedListId,
                items: _shoppingLists.map((list) => DropdownMenuItem(
                  value: list['id'],
                  child: Text(list['name'] ?? 'Unnamed List'),
                )).toList(),
                onChanged: (v) => setDialogState(() => selectedListId = v),
              ),
              const SizedBox(height: 16),
              Text(
                'This will add ${_recipe?['ingredients']?.length ?? 0} ingredients to the list.',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.grassGreen,
                foregroundColor: Colors.white,
              ),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true && selectedListId != null) {
      try {
        final ingredients = _recipe?['ingredients'] as List<dynamic>? ?? [];
        for (final ing in ingredients) {
          final ingMap = ing is Map ? ing : {'raw': ing.toString()};
          await Supabase.instance.client.from('shopping_items').insert({
            'shopping_list_id': selectedListId,
            'name': ingMap['raw'] ?? ingMap['name'] ?? ing.toString(),
            'quantity': ingMap['quantity']?.toString() ?? '',
            'is_purchased': false,
          });
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Added ${ingredients.length} ingredients to shopping list!')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error adding to shopping list: $e')),
          );
        }
      }
    }
  }

  Future<void> _addToMealPlan() async {
    DateTime selectedDate = DateTime.now().add(const Duration(days: 1));
    String selectedMealType = 'dinner';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Add to Meal Plan'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('${selectedDate.month}/${selectedDate.day}/${selectedDate.year}'),
                trailing: const Icon(Icons.calendar_today),
                onTap: () async {
                  final date = await showDatePicker(
                    context: context,
                    initialDate: selectedDate,
                    firstDate: DateTime.now(),
                    lastDate: DateTime.now().add(const Duration(days: 90)),
                  );
                  if (date != null) setDialogState(() => selectedDate = date);
                },
              ),
              DropdownButtonFormField<String>(
                value: selectedMealType,
                items: const [
                  DropdownMenuItem(value: 'breakfast', child: Text('Breakfast')),
                  DropdownMenuItem(value: 'lunch', child: Text('Lunch')),
                  DropdownMenuItem(value: 'dinner', child: Text('Dinner')),
                  DropdownMenuItem(value: 'snack', child: Text('Snack')),
                ],
                onChanged: (v) => setDialogState(() => selectedMealType = v!),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.honeyGold,
                foregroundColor: Colors.white,
              ),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true) {
      try {
        await Supabase.instance.client.from('meal_plan_entries').insert({
          'household_id': _householdMember!['household_id'],
          'recipe_id': widget.recipeId,
          'meal_date': selectedDate.toIso8601String().split('T')[0],
          'meal_type': selectedMealType,
          'added_by_member_id': _householdMember!['id'],
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Added to meal plan!')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error adding to meal plan: $e')),
          );
        }
      }
    }
  }

  Future<void> _deleteRecipe() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Recipe?'),
        content: const Text('This action cannot be undone. The recipe will be permanently removed from your household.'),
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
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await Supabase.instance.client
            .from('household_recipes')
            .delete()
            .eq('id', widget.recipeId);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Recipe deleted')),
          );
          Navigator.pop(context);
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error deleting recipe: $e')),
          );
        }
      }
    }
  }

  String _formatTotalTime() {
    final prep = _recipe?['prep_time_minutes'] ?? 0;
    final cook = _recipe?['cook_time_minutes'] ?? 0;
    final total = prep + cook;
    if (total == 0) return 'No time specified';
    if (total < 60) return '$total min';
    final hours = total ~/ 60;
    final mins = total % 60;
    return '${hours}h ${mins > 0 ? '${mins}m' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final isFavorite = _recipe?['is_favorite'] ?? false;
    final canEdit = widget.isHouseholdRecipe;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // Image header
          SliverAppBar(
            expandedHeight: 280,
            pinned: true,
            actions: [
              if (canEdit && !_isEditing) ...[
                IconButton(
                  icon: Icon(isFavorite ? Icons.favorite : Icons.favorite_border, color: isFavorite ? Colors.red : null),
                  onPressed: _toggleFavorite,
                ),
                IconButton(
                  icon: const Icon(Icons.edit_rounded),
                  onPressed: () => setState(() => _isEditing = true),
                ),
                PopupMenuButton<String>(
                  onSelected: (action) {
                    switch (action) {
                      case 'shopping':
                        _addToShoppingList();
                        break;
                      case 'mealplan':
                        _addToMealPlan();
                        break;
                      case 'delete':
                        _deleteRecipe();
                        break;
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(value: 'shopping', child: Row(children: [Icon(Icons.shopping_cart, size: 20), SizedBox(width: 12), Text('Add to Shopping List')])),
                    const PopupMenuItem(value: 'mealplan', child: Row(children: [Icon(Icons.calendar_month, size: 20), SizedBox(width: 12), Text('Add to Meal Plan')])),
                    const PopupMenuDivider(),
                    const PopupMenuItem(value: 'delete', child: Row(children: [Icon(Icons.delete, size: 20, color: AppColors.coral), SizedBox(width: 12), Text('Delete Recipe', style: TextStyle(color: AppColors.coral))])),
                  ],
                ),
              ],
              if (_isEditing) ...[
                TextButton(
                  onPressed: () => setState(() => _isEditing = false),
                  child: const Text('Cancel'),
                ),
              ],
            ],
            flexibleSpace: FlexibleSpaceBar(
              background: _recipe?['image_url'] != null
                  ? Image.network(
                      _recipe!['image_url'],
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => _buildImagePlaceholder(),
                    )
                  : _buildImagePlaceholder(),
            ),
          ),

          // Content
          SliverToBoxAdapter(
            child: _isEditing ? _buildEditMode() : _buildViewMode(),
          ),
        ],
      ),
      // Floating action buttons for quick actions
      floatingActionButton: !_isEditing && canEdit
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingActionButton.small(
                  heroTag: 'cart',
                  onPressed: _addToShoppingList,
                  backgroundColor: AppColors.grassGreen,
                  child: const Icon(Icons.shopping_cart, color: Colors.white),
                ),
                const SizedBox(width: 8),
                FloatingActionButton.small(
                  heroTag: 'meal',
                  onPressed: _addToMealPlan,
                  backgroundColor: AppColors.skyBlue,
                  child: const Icon(Icons.calendar_month, color: Colors.white),
                ),
              ],
            )
          : null,
    );
  }

  Widget _buildImagePlaceholder() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.honeyGold.withOpacity(0.3),
            AppColors.coral.withOpacity(0.2),
          ],
        ),
      ),
      child: const Center(
        child: Icon(Icons.restaurant_menu, size: 80, color: Colors.white54),
      ),
    );
  }

  Widget _buildViewMode() {
    final ingredients = _recipe?['ingredients'] as List<dynamic>? ?? [];
    final steps = _recipe?['steps'] as List<dynamic>? ?? [];
    final difficulty = _recipe?['difficulty'] ?? 'easy';

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title
          Text(
            _recipe?['title'] ?? 'Untitled Recipe',
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 8),

          // Description
          if (_recipe?['description'] != null && (_recipe!['description'] as String).isNotEmpty) ...[
            Text(
              _recipe!['description'],
              style: TextStyle(fontSize: 16, color: Colors.grey.shade600, height: 1.5),
            ),
            const SizedBox(height: 16),
          ],

          // Info chips
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildInfoChip(Icons.schedule, _formatTotalTime()),
              _buildInfoChip(Icons.people, '${(_recipe?['servings'] ?? 4) * _servingsMultiplier} servings'),
              _buildInfoChip(
                Icons.local_fire_department,
                difficulty == 'hard' ? 'Hard' : difficulty == 'medium' ? 'Medium' : 'Easy',
                color: difficulty == 'hard' ? AppColors.coral : difficulty == 'medium' ? AppColors.honeyGold : AppColors.grassGreen,
              ),
              if (_recipe?['cuisine'] != null)
                _buildInfoChip(Icons.public, _recipe!['cuisine']),
              if (_recipe?['calories_per_serving'] != null && _recipe!['calories_per_serving'] > 0)
                _buildInfoChip(Icons.local_fire_department, '${_recipe!['calories_per_serving'] * _servingsMultiplier} cal/serving'),
            ],
          ),
          const SizedBox(height: 8),

          // Servings adjuster
          Row(
            children: [
              const Text('Servings:', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(width: 12),
              IconButton(
                onPressed: _servingsMultiplier > 1 ? () => setState(() => _servingsMultiplier--) : null,
                icon: const Icon(Icons.remove_circle_outline),
              ),
              Text(
                '${(_recipe?['servings'] ?? 4) * _servingsMultiplier}',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
              IconButton(
                onPressed: () => setState(() => _servingsMultiplier++),
                icon: const Icon(Icons.add_circle_outline),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Ingredients section
          _buildSectionHeader('Ingredients', AppColors.honeyGold),
          const SizedBox(height: 12),
          if (ingredients.isEmpty)
            const Text('No ingredients listed', style: TextStyle(color: Colors.grey))
          else
            ...ingredients.map((ing) {
              final ingMap = ing is Map ? ing : {'raw': ing.toString()};
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.only(top: 7),
                      decoration: BoxDecoration(
                        color: AppColors.honeyGold,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: RichText(
                        text: TextSpan(
                          style: DefaultTextStyle.of(context).style.copyWith(fontSize: 15),
                          children: [
                            if (ingMap['quantity'] != null)
                              TextSpan(
                                text: '${ingMap['quantity']} ',
                                style: const TextStyle(fontWeight: FontWeight.w700),
                              ),
                            if (ingMap['unit'] != null)
                              TextSpan(
                                text: '${ingMap['unit']} ',
                                style: const TextStyle(fontWeight: FontWeight.w600),
                              ),
                            TextSpan(text: ingMap['name'] ?? ingMap['raw'] ?? ing.toString()),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
          const SizedBox(height: 24),

          // Steps section
          _buildSectionHeader('Instructions', AppColors.skyBlue),
          const SizedBox(height: 12),
          if (steps.isEmpty)
            const Text('No instructions listed', style: TextStyle(color: Colors.grey))
          else
            ...steps.asMap().entries.map((entry) {
              final index = entry.key;
              final step = entry.value;
              return Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: AppColors.skyBlue,
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: Text(
                          '${index + 1}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        step.toString(),
                        style: const TextStyle(fontSize: 15, height: 1.5),
                      ),
                    ),
                  ],
                ),
              );
            }),

          // Source info
          if (_recipe?['source_url'] != null) ...[
            const SizedBox(height: 16),
            _buildSectionHeader('Source', AppColors.grassGreen),
            const SizedBox(height: 8),
            Text(
              _recipe!['source_url'],
              style: TextStyle(fontSize: 14, color: AppColors.skyBlue, decoration: TextDecoration.underline),
            ),
          ],

          // Nutrition info
          if (_recipe?['calories_per_serving'] != null && _recipe!['calories_per_serving'] > 0) ...[
            const SizedBox(height: 24),
            _buildSectionHeader('Nutrition per Serving', AppColors.coral),
            const SizedBox(height: 8),
            Row(
              children: [
                _buildNutritionCard('Calories', '${_recipe!['calories_per_serving']}', AppColors.coral),
                const SizedBox(width: 8),
                _buildNutritionCard('Protein', '${_recipe?['protein_g'] ?? '-'}g', AppColors.skyBlue),
                const SizedBox(width: 8),
                _buildNutritionCard('Carbs', '${_recipe?['carbs_g'] ?? '-'}g', AppColors.honeyGold),
                const SizedBox(width: 8),
                _buildNutritionCard('Fat', '${_recipe?['fat_g'] ?? '-'}g', AppColors.grassGreen),
              ],
            ),
          ],

          const SizedBox(height: 80), // Space for FABs
        ],
      ),
    );
  }

  Widget _buildInfoChip(IconData icon, String label, {Color? color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: (color ?? AppColors.honeyGold).withOpacity(0.1),
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: (color ?? AppColors.honeyGold).withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color ?? AppColors.honeyGold),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: color ?? AppColors.honeyGold)),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, Color color) {
    return Row(
      children: [
        Container(width: 4, height: 20, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 8),
        Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
      ],
    );
  }

  Widget _buildNutritionCard(String label, String value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Text(value, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: color)),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(fontSize: 11, color: Colors.grey.shade600, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  Widget _buildEditMode() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: _titleController,
            decoration: const InputDecoration(
              labelText: 'Title',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.title),
            ),
          ),
          const SizedBox(height: 16),

          TextFormField(
            controller: _descriptionController,
            decoration: const InputDecoration(
              labelText: 'Description',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.description),
              alignLabelWithHint: true,
            ),
            maxLines: 3,
          ),
          const SizedBox(height: 16),

          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _servingsController,
                  decoration: const InputDecoration(
                    labelText: 'Servings',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.people),
                  ),
                  keyboardType: TextInputType.number,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _selectedDifficulty,
                  decoration: const InputDecoration(
                    labelText: 'Difficulty',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.signal_cellular_alt),
                  ),
                  items: _difficulties.map((d) => DropdownMenuItem(
                    value: d,
                    child: Text(d[0].toUpperCase() + d.substring(1)),
                  )).toList(),
                  onChanged: (v) => setState(() => _selectedDifficulty = v!),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _prepTimeController,
                  decoration: const InputDecoration(
                    labelText: 'Prep (min)',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.timer),
                  ),
                  keyboardType: TextInputType.number,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  controller: _cookTimeController,
                  decoration: const InputDecoration(
                    labelText: 'Cook (min)',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.outdoor_grill),
                  ),
                  keyboardType: TextInputType.number,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          DropdownButtonFormField<String>(
            value: _selectedCuisine,
            decoration: const InputDecoration(
              labelText: 'Cuisine',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.public),
            ),
            items: _cuisines.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
            onChanged: (v) => setState(() => _selectedCuisine = v!),
          ),
          const SizedBox(height: 16),

          TextFormField(
            controller: _caloriesController,
            decoration: const InputDecoration(
              labelText: 'Calories per serving',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.local_fire_department),
            ),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 24),

          // Ingredients editing
          Row(
            children: [
              const Text('Ingredients', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.add_circle, color: AppColors.honeyGold),
                onPressed: () => _addIngredient(),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ..._editIngredients.asMap().entries.map((entry) {
            final index = entry.key;
            final ing = entry.value;
            final ingMap = ing is Map ? ing : {'raw': ing.toString()};
            return ListTile(
              dense: true,
              title: Text(ingMap['raw'] ?? ingMap['name'] ?? ing.toString()),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline, size: 18),
                onPressed: () => setState(() => _editIngredients.removeAt(index)),
              ),
            );
          }),
          const SizedBox(height: 16),

          // Steps editing
          Row(
            children: [
              const Text('Steps', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.add_circle, color: AppColors.skyBlue),
                onPressed: () => _addStep(),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ..._editSteps.asMap().entries.map((entry) {
            final index = entry.key;
            return ListTile(
              dense: true,
              leading: CircleAvatar(
                radius: 14,
                backgroundColor: AppColors.skyBlue,
                child: Text('${index + 1}', style: const TextStyle(color: Colors.white, fontSize: 12)),
              ),
              title: Text(entry.value.toString(), maxLines: 2, overflow: TextOverflow.ellipsis),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline, size: 18),
                onPressed: () => setState(() => _editSteps.removeAt(index)),
              ),
            );
          }),
          const SizedBox(height: 32),

          ElevatedButton.icon(
            onPressed: _saveRecipe,
            icon: const Icon(Icons.save),
            label: const Text('Save Changes'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.honeyGold,
              foregroundColor: Colors.white,
              minimumSize: const Size(double.infinity, 52),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _uploadRecipeImage,
            icon: const Icon(Icons.camera_alt),
            label: const Text('Change Recipe Photo'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.skyBlue,
              minimumSize: const Size(double.infinity, 48),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _addIngredient() async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Ingredient'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'e.g., 2 cups flour',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Add'),
          ),
        ],
      ),
    );

    if (confirmed == true && controller.text.isNotEmpty) {
      setState(() {
        _editIngredients.add({'raw': controller.text.trim()});
      });
    }
    controller.dispose();
  }

  Future<void> _addStep() async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Step'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'Describe the step...',
            border: OutlineInputBorder(),
          ),
          maxLines: 3,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Add'),
          ),
        ],
      ),
    );

    if (confirmed == true && controller.text.isNotEmpty) {
      setState(() {
        _editSteps.add(controller.text.trim());
      });
    }
    controller.dispose();
  }

  Future<void> _uploadRecipeImage() async {
    try {
      final source = await ImageUploadService.showImageSourceDialog(context);
      if (source == null) return;

      final imageUrl = await ImageUploadService.uploadRecipeImage(
        recipeId: widget.recipeId,
        source: source == 'camera' ? ImageSource.camera : ImageSource.gallery,
      );

      if (imageUrl != null) {
        await Supabase.instance.client
            .from('household_recipes')
            .update({'image_url': imageUrl})
            .eq('id', widget.recipeId);

        await _loadData();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Recipe image updated!')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error uploading image: $e')),
        );
      }
    }
  }
}
