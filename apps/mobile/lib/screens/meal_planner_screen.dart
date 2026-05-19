import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../services/realtime_service.dart';
import 'recipe_detail_screen.dart';

/// Full meal planner screen with 7-day week view, meal type selection,
/// recipe linking, and custom meal entry.
class MealPlannerScreen extends StatefulWidget {
  const MealPlannerScreen({super.key});

  @override
  State<MealPlannerScreen> createState() => _MealPlannerScreenState();
}

class _MealPlannerScreenState extends State<MealPlannerScreen> {
  Map<String, dynamic>? _household;
  Map<String, dynamic>? _myMembership;
  List<Map<String, dynamic>> _mealPlans = [];
  List<Map<String, dynamic>> _householdRecipes = [];
  List<Map<String, dynamic>> _members = [];
  bool _isLoading = true;

  DateTime _weekStart = _startOfWeek(DateTime.now());

  static DateTime _startOfWeek(DateTime date) {
    final d = date.subtract(Duration(days: date.weekday - 1));
    return DateTime(d.year, d.month, d.day);
  }

  @override
  void initState() {
    super.initState();
    _loadData();
    RealtimeService.instance.mealPlansVersion.addListener(_onRealtimeUpdate);
  }

  @override
  void dispose() {
    RealtimeService.instance.mealPlansVersion.removeListener(_onRealtimeUpdate);
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

      // Load recipes and members in parallel
      final results = await Future.wait([
        Supabase.instance.client
            .from('household_recipes')
            .select()
            .eq('household_id', householdId)
            .order('title'),
        Supabase.instance.client
            .from('household_members')
            .select()
            .eq('household_id', householdId)
            .eq('is_active', true)
            .order('display_name'),
      ]);

      _householdRecipes = List<Map<String, dynamic>>.from(results[0]);
      _members = List<Map<String, dynamic>>.from(results[1]);

      await _loadMealPlans();
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadMealPlans() async {
    if (_household == null) return;

    try {
      final weekEnd = _weekStart.add(const Duration(days: 7));
      final plans = await Supabase.instance.client
          .from('meal_plans')
          .select('*, recipe:household_recipes(title, image_url), cook:household_members!assigned_cook_member_id(display_name)')
          .eq('household_id', _household!['id'])
          .gte('planned_for', _weekStart.toIso8601String().substring(0, 10))
          .lt('planned_for', weekEnd.toIso8601String().substring(0, 10))
          .order('planned_for');

      setState(() {
        _mealPlans = List<Map<String, dynamic>>.from(plans);
        _isLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _navigateWeek(int direction) {
    setState(() {
      _weekStart = _weekStart.add(Duration(days: 7 * direction));
      _isLoading = true;
    });
    _loadMealPlans();
  }

  List<Map<String, dynamic>> _mealsForDay(DateTime day) {
    final dateStr = day.toIso8601String().substring(0, 10);
    return _mealPlans.where((m) => m['planned_for']?.toString().startsWith(dateStr) == true).toList();
  }

  void _showAddMealSheet(DateTime day, {String? mealType}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => _AddMealPlanSheet(
        householdId: _household!['id'],
        myMemberId: _myMembership!['id'],
        day: day,
        preselectedMealType: mealType,
        recipes: _householdRecipes,
        members: _members,
      ),
    ).then((_) => _loadMealPlans());
  }

  Future<void> _deleteMealPlan(String planId) async {
    try {
      await Supabase.instance.client
          .from('meal_plans')
          .delete()
          .eq('id', planId);
      _loadMealPlans();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not delete meal plan.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final weekEnd = _weekStart.add(const Duration(days: 6));
    final weekLabel = '${_formatMonthDay(_weekStart)} – ${_formatMonthDay(weekEnd)}';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Meal Planner 🍽️'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loadData,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Week navigation
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton.outlined(
                        onPressed: () => _navigateWeek(-1),
                        icon: const Icon(Icons.chevron_left_rounded),
                      ),
                      Column(
                        children: [
                          Text(
                            weekLabel,
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          if (_isCurrentWeek())
                            Container(
                              margin: const EdgeInsets.only(top: 4),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppColors.honeyGold.withOpacity(.2),
                                borderRadius: BorderRadius.circular(100),
                              ),
                              child: const Text('This week', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                            ),
                        ],
                      ),
                      IconButton.outlined(
                        onPressed: () => _navigateWeek(1),
                        icon: const Icon(Icons.chevron_right_rounded),
                      ),
                    ],
                  ),
                ),

                // Days of the week
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _loadMealPlans,
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: 7,
                      itemBuilder: (context, index) {
                        final day = _weekStart.add(Duration(days: index));
                        final dayMeals = _mealsForDay(day);
                        final isToday = _isSameDay(day, DateTime.now());

                        return _DayCard(
                          day: day,
                          isToday: isToday,
                          meals: dayMeals,
                          onAddMeal: (mealType) => _showAddMealSheet(day, mealType: mealType),
                          onDeleteMeal: _deleteMealPlan,
                          onAddCustom: () => _showAddMealSheet(day),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  bool _isCurrentWeek() {
    final now = DateTime.now();
    final currentWeekStart = _startOfWeek(now);
    return currentWeekStart.year == _weekStart.year &&
        currentWeekStart.month == _weekStart.month &&
        currentWeekStart.day == _weekStart.day;
  }

  static bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  String _formatMonthDay(DateTime date) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[date.month - 1]} ${date.day}';
  }
}

class _DayCard extends StatelessWidget {
  const _DayCard({
    required this.day,
    required this.isToday,
    required this.meals,
    required this.onAddMeal,
    required this.onDeleteMeal,
    required this.onAddCustom,
  });

  final DateTime day;
  final bool isToday;
  final List<Map<String, dynamic>> meals;
  final void Function(String mealType) onAddMeal;
  final void Function(String planId) onDeleteMeal;
  final VoidCallback onAddCustom;

  static const _mealTypes = ['breakfast', 'lunch', 'dinner', 'snack'];
  static const _mealEmoji = {
    'breakfast': '🌅',
    'lunch': '☀️',
    'dinner': '🌙',
    'snack': '🍎',
  };
  static const _mealColors = {
    'breakfast': AppColors.honeyGold,
    'lunch': AppColors.grassGreen,
    'dinner': AppColors.skyBlue,
    'snack': AppColors.coral,
  };

  @override
  Widget build(BuildContext context) {
    final dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: isToday ? const BorderSide(color: AppColors.honeyGold, width: 2) : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Day header
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      if (isToday) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.honeyGold.withOpacity(.2),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text('Today', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.honeyGold)),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Text(
                        '${dayNames[day.weekday - 1]}, ${day.month}/${day.day}',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add_rounded, size: 20),
                  onPressed: onAddCustom,
                  tooltip: 'Add meal',
                  style: IconButton.styleFrom(
                    backgroundColor: AppColors.honeyGold.withOpacity(.1),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Meal slots
            ..._mealTypes.map((type) {
              final plannedMeal = meals.where((m) => m['meal_type'] == type).toList();
              final color = _mealColors[type] ?? Colors.grey;
              final emoji = _mealEmoji[type] ?? '🍽️';

              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: plannedMeal.isNotEmpty
                    ? ...plannedMeal.map((meal) => _MealSlot(
                          meal: meal,
                          color: color,
                          emoji: emoji,
                          typeLabel: type,
                          onDelete: () => onDeleteMeal(meal['id']),
                        ))
                    : _EmptyMealSlot(
                        type: type,
                        emoji: emoji,
                        color: color,
                        onTap: () => onAddMeal(type),
                      ),
              );
            }),
          ],
        ),
      ),
    );
  }
}

class _MealSlot extends StatelessWidget {
  const _MealSlot({
    required this.meal,
    required this.color,
    required this.emoji,
    required this.typeLabel,
    required this.onDelete,
  });

  final Map<String, dynamic> meal;
  final Color color;
  final String emoji;
  final String typeLabel;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final title = meal['custom_title'] ?? meal['recipe']?['title'] ?? 'Untitled';
    final cook = meal['cook']?['display_name'];
    final servings = meal['servings'];
    final notes = meal['notes'];
    final recipeId = meal['recipe_id'] as String?;
    final hasRecipe = recipeId != null;

    return Dismissible(
      key: ValueKey(meal['id']),
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
      child: InkWell(
        onTap: hasRecipe
            ? () {
                // Navigate to recipe detail using the recipe_id
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => RecipeDetailScreen(
                      recipeId: recipeId,
                      isHousehold: true,
                    ),
                  ),
                );
              }
            : null,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: color.withOpacity(.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withOpacity(.2)),
          ),
          child: Row(
            children: [
              Text(emoji, style: const TextStyle(fontSize: 18)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                        ),
                        if (hasRecipe) ...[
                          Icon(Icons.menu_book_rounded, size: 14, color: color),
                          const SizedBox(width: 2),
                          Icon(Icons.open_in_new_rounded, size: 12, color: Colors.grey.shade400),
                        ],
                      ],
                    ),
                    if (cook != null || servings != null)
                      Text(
                        [
                          if (cook != null) 'Cook: $cook',
                          if (servings != null) '$servings servings',
                        ].join(' · '),
                        style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    if (notes != null && notes.toString().isNotEmpty)
                      Text(notes, style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant, fontStyle: FontStyle.italic), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 16),
                onPressed: onDelete,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyMealSlot extends StatelessWidget {
  const _EmptyMealSlot({
    required this.type,
    required this.emoji,
    required this.color,
    required this.onTap,
  });

  final String type;
  final String emoji;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.withOpacity(.15), style: BorderStyle.solid),
        ),
        child: Row(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 16)),
            const SizedBox(width: 8),
            Text(
              'Add $type',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade500, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddMealPlanSheet extends StatefulWidget {
  const _AddMealPlanSheet({
    required this.householdId,
    required this.myMemberId,
    required this.day,
    this.preselectedMealType,
    required this.recipes,
    required this.members,
  });

  final String householdId;
  final String myMemberId;
  final DateTime day;
  final String? preselectedMealType;
  final List<Map<String, dynamic>> recipes;
  final List<Map<String, dynamic>> members;

  @override
  State<_AddMealPlanSheet> createState() => _AddMealPlanSheetState();
}

class _AddMealPlanSheetState extends State<_AddMealPlanSheet> {
  String _mealType = 'dinner';
  String? _selectedRecipeId;
  final _customTitleController = TextEditingController();
  final _servingsController = TextEditingController();
  final _notesController = TextEditingController();
  String? _assignedCookId;
  bool _isLoading = false;
  bool _addIngredientsToList = true;

  static const _mealTypes = ['breakfast', 'lunch', 'dinner', 'snack', 'other'];
  static const _mealEmoji = {'breakfast': '🌅', 'lunch': '☀️', 'dinner': '🌙', 'snack': '🍎', 'other': '🍽️'};

  @override
  void initState() {
    super.initState();
    if (widget.preselectedMealType != null) {
      _mealType = widget.preselectedMealType!;
    }
  }

  @override
  void dispose() {
    _customTitleController.dispose();
    _servingsController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _createMealPlan() async {
    final customTitle = _customTitleController.text.trim();
    if (_selectedRecipeId == null && customTitle.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a recipe or enter a custom meal name.')),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final mealPlanResult = await Supabase.instance.client.from('meal_plans').insert({
        'household_id': widget.householdId,
        'planned_for': widget.day.toIso8601String().substring(0, 10),
        'meal_type': _mealType,
        'recipe_id': _selectedRecipeId,
        'custom_title': customTitle.isEmpty ? null : customTitle,
        'assigned_cook_member_id': _assignedCookId,
        'servings': int.tryParse(_servingsController.text.trim()),
        'notes': _notesController.text.trim().isEmpty ? null : _notesController.text.trim(),
        'created_by_member_id': widget.myMemberId,
      }).select().single();

      // Auto-add recipe ingredients to shopping list
      if (_addIngredientsToList && _selectedRecipeId != null) {
        try {
          final recipe = await Supabase.instance.client
              .from('household_recipes')
              .select('ingredients')
              .eq('id', _selectedRecipeId!)
              .single();

          final ingredients = recipe['ingredients'] as List<dynamic>? ?? [];
          if (ingredients.isNotEmpty) {
            // Find or create active shopping list
            final lists = await Supabase.instance.client
                .from('shopping_lists')
                .select('id')
                .eq('household_id', widget.householdId)
                .eq('is_active', true)
                .limit(1);

            String shoppingListId;
            if (lists.isNotEmpty) {
              shoppingListId = lists[0]['id'];
            } else {
              final newList = await Supabase.instance.client
                  .from('shopping_lists')
                  .insert({
                    'household_id': widget.householdId,
                    'name': 'Current Shopping List',
                    'is_active': true,
                    'created_by_member_id': widget.myMemberId,
                  })
                  .select()
                  .single();
              shoppingListId = newList['id'];
            }

            final mealPlanId = mealPlanResult['id'];
            final inserts = ingredients.map((ing) {
              final text = ing is String ? ing : (ing['raw']?.toString() ?? ing.toString());
              return {
                'household_id': widget.householdId,
                'shopping_list_id': shoppingListId,
                'name': text,
                'purchased': false,
                'source_recipe_id': _selectedRecipeId,
                'source_meal_plan_id': mealPlanId,
                'added_by_member_id': widget.myMemberId,
              };
            }).toList();

            await Supabase.instance.client.from('shopping_items').insert(inserts);
          }
        } catch (_) {
          // Non-critical: ingredients failed to add, but meal plan was created
        }
      }

      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not add meal plan. Please try again.')),
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
            Text('Plan a Meal', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
            const SizedBox(height: 4),
            Text(
              '${_dayName(widget.day)}, ${widget.day.month}/${widget.day.day}',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),

            // Meal type selector
            Text('Meal type', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            SizedBox(
              height: 40,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _mealTypes.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final type = _mealTypes[i];
                  final selected = _mealType == type;
                  return ChoiceChip(
                    label: Text('${_mealEmoji[type]} ${type[0].toUpperCase()}${type.substring(1)}'),
                    selected: selected,
                    onSelected: (_) => setState(() => _mealType = type),
                  );
                },
              ),
            ),
            const SizedBox(height: 20),

            // Recipe selection
            Text('Recipe (optional)', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: _selectedRecipeId,
              decoration: const InputDecoration(
                labelText: 'Choose a recipe',
                prefixIcon: Icon(Icons.menu_book_rounded),
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem(value: null, child: Text('Custom meal (enter name below)')),
                ...widget.recipes.map((r) => DropdownMenuItem(
                  value: r['id'],
                  child: Text(r['title'] ?? 'Untitled', overflow: TextOverflow.ellipsis),
                )),
              ],
              onChanged: (v) => setState(() => _selectedRecipeId = v),
            ),
            const SizedBox(height: 16),

            // Custom title
            TextFormField(
              controller: _customTitleController,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Custom meal name',
                prefixIcon: Icon(Icons.edit_note_rounded),
                border: OutlineInputBorder(),
                hintText: 'e.g., Leftover night, Pizza delivery',
              ),
            ),
            const SizedBox(height: 16),

            // Assigned cook
            DropdownButtonFormField<String>(
              value: _assignedCookId,
              decoration: const InputDecoration(
                labelText: 'Assigned cook',
                prefixIcon: Icon(Icons.person_outline_rounded),
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem(value: null, child: Text('Unassigned')),
                ...widget.members.map((m) => DropdownMenuItem(
                  value: m['id'],
                  child: Text(m['display_name'] ?? 'Unknown'),
                )),
              ],
              onChanged: (v) => setState(() => _assignedCookId = v),
            ),
            const SizedBox(height: 16),

            // Servings
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _servingsController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Servings',
                      prefixIcon: Icon(Icons.people_outline_rounded),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Notes
            TextFormField(
              controller: _notesController,
              textCapitalization: TextCapitalization.sentences,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Notes',
                prefixIcon: Icon(Icons.note_rounded),
                border: OutlineInputBorder(),
                hintText: 'Any special instructions or preferences',
              ),
            ),
            const SizedBox(height: 16),

            // Auto-add ingredients to shopping list
            if (_selectedRecipeId != null)
              SwitchListTile(
                value: _addIngredientsToList,
                onChanged: (v) => setState(() => _addIngredientsToList = v),
                title: const Text('Add ingredients to shopping list', style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: const Text('Recipe ingredients will be added to your active shopping list.'),
                secondary: const Icon(Icons.add_shopping_cart_rounded),
                contentPadding: EdgeInsets.zero,
              ),
            const SizedBox(height: 24),

            FilledButton(
              onPressed: _isLoading ? null : _createMealPlan,
              child: _isLoading
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Add meal plan'),
            ),
          ],
        ),
      ),
    );
  }

  String _dayName(DateTime date) {
    const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    return days[date.weekday - 1];
  }
}
