import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../theme/app_theme.dart';
import '../services/realtime_service.dart';
import '../services/active_member_service.dart';
import '../utils/membership.dart';
import '../utils/permissions.dart';
import 'recipe_detail_screen.dart';

/// Full recipe library screen with household recipe management,
/// master recipe browsing, URL import, and shopping list integration.
class RecipeLibraryScreen extends StatefulWidget {
  const RecipeLibraryScreen({super.key});

  @override
  State<RecipeLibraryScreen> createState() => _RecipeLibraryScreenState();
}

class _RecipeLibraryScreenState extends State<RecipeLibraryScreen>
    with TickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  late TabController _tabController;
  int _tabCount = 2;
  Map<String, dynamic>? _household;
  Map<String, dynamic>? _myMembership;
  List<Map<String, dynamic>> _householdRecipes = [];
  List<Map<String, dynamic>> _masterRecipes = [];
  List<Map<String, dynamic>> _shoppingLists = [];
  // Batch 6b — kid-only "My Requests" tab. Populated only when the active
  // membership is a kid; otherwise the tab itself is hidden and this stays
  // empty.
  List<Map<String, dynamic>> _myMealRequests = [];
  bool _isLoading = true;
  String _searchQuery = '';
  String? _selectedCuisine;
  String? _selectedDifficulty;

  String get _apiUrl => dotenv.env['API_URL'] ?? 'https://honeydo-production-743d.up.railway.app';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabCount, vsync: this);
    _loadData();
    RealtimeService.instance.recipesVersion.addListener(_onRealtimeUpdate);
    // Batch 6b — meal_requests realtime ticks refresh the kid's "My Requests"
    // tab when the admin decides on the kid's pending row from another device.
    RealtimeService.instance.mealRequestsVersion.addListener(_onRealtimeUpdate);
    // Reload when the user switches between profiles so the kid-only tab
    // appears / disappears appropriately.
    ActiveMemberService.instance.activeMemberId
        .addListener(_onActiveMemberChanged);
  }

  @override
  void dispose() {
    RealtimeService.instance.recipesVersion.removeListener(_onRealtimeUpdate);
    RealtimeService.instance.mealRequestsVersion.removeListener(_onRealtimeUpdate);
    ActiveMemberService.instance.activeMemberId
        .removeListener(_onActiveMemberChanged);
    _tabController.dispose();
    super.dispose();
  }

  void _onRealtimeUpdate() {
    if (mounted) _loadData();
  }

  void _onActiveMemberChanged() {
    if (mounted) _loadData();
  }

  /// Recreates _tabController if the desired tab count changed. Called from
  /// _loadData after the active membership is known. Length must be set at
  /// creation time — TabController doesn't support live resize.
  void _syncTabCount(int desired) {
    if (desired == _tabCount) return;
    final oldIndex = _tabController.index;
    _tabController.dispose();
    _tabCount = desired;
    _tabController = TabController(
      length: _tabCount,
      vsync: this,
      initialIndex: oldIndex.clamp(0, _tabCount - 1),
    );
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);

    try {
      // Batch 6b — MembershipHelper resolves to the active kid sub_profile if
      // one is selected; otherwise to the JWT holder's adult row. Critical for
      // the kid-only "My Requests" tab to gate on a real kid membership and
      // for the meal_requests query to filter on the correct member id.
      final membership = await MembershipHelper.loadActiveMembership(
        includeHouseholdJoin: true,
      );

      if (membership == null) {
        setState(() => _isLoading = false);
        return;
      }

      _myMembership = membership;
      _household = membership['households'];
      final householdId = _household!['id'];
      final isKid = Permissions.isKid(membership);

      // Load household recipes
      final recipes = await Supabase.instance.client
          .from('household_recipes')
          .select('*')
          .eq('household_id', householdId)
          .order('created_at', ascending: false);

      // Load approved master recipes
      final master = await Supabase.instance.client
          .from('master_recipes')
          .select('*')
          .eq('status', 'approved')
          .order('average_rating', ascending: false);

      // Load shopping lists
      final lists = await Supabase.instance.client
          .from('shopping_lists')
          .select('*')
          .eq('household_id', householdId)
          .eq('is_active', true);

      // Batch 6b — load this kid's meal requests (all statuses) for the
      // "My Requests" tab. Only run for kid sessions to keep the network
      // chatter off the adult path.
      List<Map<String, dynamic>> myRequests = [];
      if (isKid) {
        try {
          final reqs = await Supabase.instance.client
              .from('meal_requests')
              .select(
                  'id, status, decided_at, decided_note, requested_for_date, '
                  'meal_type, created_at, '
                  'household_recipes!meal_requests_recipe_id_fkey(id, title, image_url)')
              .eq('requested_by_member_id', membership['id'])
              .order('created_at', ascending: false);
          myRequests = List<Map<String, dynamic>>.from(reqs);
        } catch (e) {
          debugPrint('load my meal requests failed: $e');
          // Soft failure — leave the tab empty rather than blocking the whole
          // screen on a meal_requests query problem.
        }
      }

      if (!mounted) return;
      _syncTabCount(isKid ? 3 : 2);
      setState(() {
        _householdRecipes = List<Map<String, dynamic>>.from(recipes);
        _masterRecipes = List<Map<String, dynamic>>.from(master);
        _shoppingLists = List<Map<String, dynamic>>.from(lists);
        _myMealRequests = myRequests;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('recipe_library load failed: $e');
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error loading recipes: $e')),
      );
    }
  }

  List<Map<String, dynamic>> get _filteredHouseholdRecipes {
    var filtered = _householdRecipes;

    if (_searchQuery.isNotEmpty) {
      filtered = filtered
          .where((r) =>
              (r['title'] as String? ?? '')
                  .toLowerCase()
                  .contains(_searchQuery.toLowerCase()) ||
              (r['description'] as String? ?? '')
                  .toLowerCase()
                  .contains(_searchQuery.toLowerCase()))
          .toList();
    }

    if (_selectedCuisine != null) {
      filtered = filtered
          .where((r) => r['cuisine'] == _selectedCuisine)
          .toList();
    }

    if (_selectedDifficulty != null) {
      filtered = filtered
          .where((r) => r['difficulty'] == _selectedDifficulty)
          .toList();
    }

    return filtered;
  }

  List<Map<String, dynamic>> get _filteredMasterRecipes {
    var filtered = _masterRecipes;

    if (_searchQuery.isNotEmpty) {
      filtered = filtered
          .where((r) =>
              (r['title'] as String? ?? '')
                  .toLowerCase()
                  .contains(_searchQuery.toLowerCase()) ||
              (r['description'] as String? ?? '')
                  .toLowerCase()
                  .contains(_searchQuery.toLowerCase()))
          .toList();
    }

    if (_selectedCuisine != null) {
      filtered = filtered
          .where((r) => r['cuisine'] == _selectedCuisine)
          .toList();
    }

    if (_selectedDifficulty != null) {
      filtered = filtered
          .where((r) => r['difficulty'] == _selectedDifficulty)
          .toList();
    }

    return filtered;
  }

  Future<void> _toggleFavorite(Map<String, dynamic> recipe) async {
    try {
      await Supabase.instance.client
          .from('household_recipes')
          .update({'is_favorite': !(recipe['is_favorite'] ?? false)})
          .eq('id', recipe['id']);

      await _loadData();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error updating favorite: $e')),
        );
      }
    }
  }

  Future<void> _addToHousehold(Map<String, dynamic> masterRecipe) async {
    try {
      final householdId = _household!['id'];
      final memberId = _myMembership!['id'];

      await Supabase.instance.client.from('household_recipes').insert({
        'household_id': householdId,
        'master_recipe_id': masterRecipe['id'],
        'title': masterRecipe['title'],
        'description': masterRecipe['description'],
        'ingredients': masterRecipe['ingredients'],
        'steps': masterRecipe['steps'],
        'prep_time_minutes': masterRecipe['prep_time_minutes'],
        'cook_time_minutes': masterRecipe['cook_time_minutes'],
        'servings': masterRecipe['servings'],
        'difficulty': masterRecipe['difficulty'],
        'cuisine': masterRecipe['cuisine'],
        'tags': masterRecipe['tags'],
        'image_url': masterRecipe['image_url'],
        'source': 'master_library',
        'source_url': masterRecipe['source_url'],
        'created_by_member_id': memberId,
      });

      // Increment added_count on master recipe
      await Supabase.instance.client.rpc('increment_master_recipe_added_count',
          params: {'p_recipe_id': masterRecipe['id']});

      await _loadData();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Recipe added to your library!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error adding recipe: $e')),
        );
      }
    }
  }

  Future<void> _addIngredientsToShoppingList(
      Map<String, dynamic> recipe) async {
    if (_shoppingLists.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No active shopping list found')),
        );
      }
      return;
    }

    final shoppingListId = _shoppingLists.first['id'];
    final householdId = _household!['id'];
    final memberId = _myMembership!['id'];
    final ingredients = recipe['ingredients'] as List<dynamic>? ?? [];

    if (ingredients.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No ingredients to add')),
        );
      }
      return;
    }

    try {
      final items = ingredients.map((ing) {
        final ingMap = ing as Map<String, dynamic>?;
        final raw = ingMap?['raw'] as String? ?? ing.toString();
        return {
          'household_id': householdId,
          'shopping_list_id': shoppingListId,
          'name': raw,
          'display_quantity': raw,
          'category': 'Other',
          'source_recipe_id': recipe['id'],
          'added_by_member_id': memberId,
        };
      }).toList();

      await Supabase.instance.client
          .from('shopping_items')
          .insert(items);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Added ${items.length} ingredients to shopping list'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error adding ingredients: $e')),
        );
      }
    }
  }

  Future<void> _showImportUrlSheet() async {
    final urlController = TextEditingController();

    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Container(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Import Recipe from URL',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: urlController,
                decoration: const InputDecoration(
                  labelText: 'Recipe URL',
                  hintText: 'https://example.com/recipe/...',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () async {
                  final url = urlController.text.trim();
                  if (url.isNotEmpty) {
                    Navigator.pop(context, url);
                  }
                },
                child: const Text('Import'),
              ),
            ],
          ),
        ),
      ),
    );

    if (result != null) {
      await _importRecipe(result);
    }
  }

  Future<void> _importRecipe(String url) async {
    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final response = await http.post(
        Uri.parse('$_apiUrl/recipes/import'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'url': url}),
      );

      Navigator.pop(context); // Close loading dialog

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['ok'] == true && data['recipe'] != null) {
          await _showImportedRecipeSheet(data['recipe']);
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(data['error'] ?? 'Import failed')),
            );
          }
        }
      } else {
        final error = jsonDecode(response.body);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(error['error'] ?? 'Import failed')),
          );
        }
      }
    } catch (e) {
      Navigator.pop(context); // Close loading dialog
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error importing recipe: $e')),
        );
      }
    }
  }

  Future<void> _showImportedRecipeSheet(Map<String, dynamic> imported) async {
    final titleController = TextEditingController(text: imported['title']);
    final descriptionController =
        TextEditingController(text: imported['description']);
    final servingsController =
        TextEditingController(text: imported['servings']?.toString() ?? '4');
    final prepTimeController =
        TextEditingController(text: imported['prep_time']?.toString() ?? '');
    final cookTimeController =
        TextEditingController(text: imported['cook_time']?.toString() ?? '');
    final cuisineController =
        TextEditingController(text: imported['cuisine'] ?? '');
    final difficultyController =
        TextEditingController(text: imported['difficulty'] ?? 'Easy');

    final ingredients = List<Map<String, dynamic>>.from(
        imported['ingredients'] ?? []);
    final steps = List<String>.from(imported['steps'] ?? []);

    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => DraggableScrollableSheet(
          initialChildSize: 0.9,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          expand: false,
          builder: (context, scrollController) => Container(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom,
            ),
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.all(20),
              children: [
                const Text(
                  'Review Imported Recipe',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: titleController,
                  decoration: const InputDecoration(
                    labelText: 'Recipe Title',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: descriptionController,
                  decoration: const InputDecoration(
                    labelText: 'Description',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 3,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: servingsController,
                        decoration: const InputDecoration(
                          labelText: 'Servings',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.number,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: prepTimeController,
                        decoration: const InputDecoration(
                          labelText: 'Prep Time (min)',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.number,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: cookTimeController,
                        decoration: const InputDecoration(
                          labelText: 'Cook Time (min)',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.number,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: cuisineController,
                        decoration: const InputDecoration(
                          labelText: 'Cuisine',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: difficultyController,
                  decoration: const InputDecoration(
                    labelText: 'Difficulty',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Ingredients',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                ...ingredients.asMap().entries.map((entry) {
                  final index = entry.key;
                  final ing = entry.value;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                            ),
                            controller: TextEditingController(
                              text: ing['raw'] ?? '',
                            ),
                            onChanged: (value) {
                              ingredients[index]['raw'] = value;
                            },
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete),
                          onPressed: () {
                            setSheetState(() {
                              ingredients.removeAt(index);
                            });
                          },
                        ),
                      ],
                    ),
                  );
                }),
                TextButton.icon(
                  onPressed: () {
                    setSheetState(() {
                      ingredients.add({'raw': ''});
                    });
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('Add Ingredient'),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Steps',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                ...steps.asMap().entries.map((entry) {
                  final index = entry.key;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: AppColors.honeyGold,
                            shape: BoxShape.circle,
                          ),
                          child: Center(
                            child: Text(
                              '${index + 1}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                            ),
                            controller: TextEditingController(text: steps[index]),
                            onChanged: (value) {
                              steps[index] = value;
                            },
                            maxLines: null,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete),
                          onPressed: () {
                            setSheetState(() {
                              steps.removeAt(index);
                            });
                          },
                        ),
                      ],
                    ),
                  );
                }),
                TextButton.icon(
                  onPressed: () {
                    setSheetState(() {
                      steps.add('');
                    });
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('Add Step'),
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () async {
                    try {
                      final householdId = _household!['id'];
                      final memberId = _myMembership!['id'];

                      await Supabase.instance.client
                          .from('household_recipes')
                          .insert({
                        'household_id': householdId,
                        'title': titleController.text.trim(),
                        'description': descriptionController.text.trim(),
                        'ingredients': ingredients,
                        'steps': steps,
                        'servings':
                            int.tryParse(servingsController.text) ?? 4,
                        'prep_time_minutes':
                            int.tryParse(prepTimeController.text),
                        'cook_time_minutes':
                            int.tryParse(cookTimeController.text),
                        'cuisine': cuisineController.text.trim(),
                        'difficulty': difficultyController.text.trim(),
                        'image_url': imported['image_url'],
                        'source': 'imported_url',
                        'source_url': imported['source_url'],
                        'created_by_member_id': memberId,
                      });

                      Navigator.pop(context, true);
                      await _loadData();

                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Recipe saved!')),
                        );
                      }
                    } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Error saving recipe: $e')),
                        );
                      }
                    }
                  },
                  child: const Text('Save Recipe'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (result == true) {
      // Recipe saved, data already reloaded
    }
  }

  Future<void> _showManualRecipeSheet() async {
    final titleController = TextEditingController();
    final descriptionController = TextEditingController();
    final servingsController = TextEditingController(text: '4');
    final prepTimeController = TextEditingController();
    final cookTimeController = TextEditingController();
    final cuisineController = TextEditingController();
    final difficultyController = TextEditingController(text: 'Easy');

    final ingredients = <Map<String, dynamic>>[];
    final steps = <String>[];

    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => DraggableScrollableSheet(
          initialChildSize: 0.9,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          expand: false,
          builder: (context, scrollController) => Container(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom,
            ),
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.all(20),
              children: [
                const Text(
                  'Add New Recipe',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: titleController,
                  decoration: const InputDecoration(
                    labelText: 'Recipe Title *',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: descriptionController,
                  decoration: const InputDecoration(
                    labelText: 'Description',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 3,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: servingsController,
                        decoration: const InputDecoration(
                          labelText: 'Servings',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.number,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: prepTimeController,
                        decoration: const InputDecoration(
                          labelText: 'Prep Time (min)',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.number,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: cookTimeController,
                        decoration: const InputDecoration(
                          labelText: 'Cook Time (min)',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.number,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: cuisineController,
                        decoration: const InputDecoration(
                          labelText: 'Cuisine',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: difficultyController,
                  decoration: const InputDecoration(
                    labelText: 'Difficulty',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Ingredients',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                ...ingredients.asMap().entries.map((entry) {
                  final index = entry.key;
                  final ing = entry.value;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                            ),
                            controller: TextEditingController(
                              text: ing['raw'] ?? '',
                            ),
                            onChanged: (value) {
                              ingredients[index]['raw'] = value;
                            },
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete),
                          onPressed: () {
                            setSheetState(() {
                              ingredients.removeAt(index);
                            });
                          },
                        ),
                      ],
                    ),
                  );
                }),
                TextButton.icon(
                  onPressed: () {
                    setSheetState(() {
                      ingredients.add({'raw': ''});
                    });
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('Add Ingredient'),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Steps',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                ...steps.asMap().entries.map((entry) {
                  final index = entry.key;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: AppColors.honeyGold,
                            shape: BoxShape.circle,
                          ),
                          child: Center(
                            child: Text(
                              '${index + 1}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                            ),
                            controller: TextEditingController(text: steps[index]),
                            onChanged: (value) {
                              steps[index] = value;
                            },
                            maxLines: null,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete),
                          onPressed: () {
                            setSheetState(() {
                              steps.removeAt(index);
                            });
                          },
                        ),
                      ],
                    ),
                  );
                }),
                TextButton.icon(
                  onPressed: () {
                    setSheetState(() {
                      steps.add('');
                    });
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('Add Step'),
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () async {
                    if (titleController.text.trim().isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Please enter a title')),
                      );
                      return;
                    }

                    try {
                      final householdId = _household!['id'];
                      final memberId = _myMembership!['id'];

                      await Supabase.instance.client
                          .from('household_recipes')
                          .insert({
                        'household_id': householdId,
                        'title': titleController.text.trim(),
                        'description': descriptionController.text.trim(),
                        'ingredients': ingredients,
                        'steps': steps,
                        'servings':
                            int.tryParse(servingsController.text) ?? 4,
                        'prep_time_minutes':
                            int.tryParse(prepTimeController.text),
                        'cook_time_minutes':
                            int.tryParse(cookTimeController.text),
                        'cuisine': cuisineController.text.trim(),
                        'difficulty': difficultyController.text.trim(),
                        'source': 'manual',
                        'created_by_member_id': memberId,
                      });

                      Navigator.pop(context, true);
                      await _loadData();

                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Recipe saved!')),
                        );
                      }
                    } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Error saving recipe: $e')),
                        );
                      }
                    }
                  },
                  child: const Text('Save Recipe'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (result == true) {
      // Recipe saved, data already reloaded
    }
  }

  Future<void> _showRecipeDetail(Map<String, dynamic> recipe) async {
    final isHousehold = recipe.containsKey('household_id') && recipe['household_id'] != null;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RecipeDetailScreen(
          recipeId: recipe['id'],
          isHouseholdRecipe: isHousehold,
        ),
      ),
    ).then((_) => _loadData());
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // Batch 6b — kid sessions get an extra "My Requests" tab as the 3rd tab.
    // _tabCount is synced inside _loadData via _syncTabCount() so the tab
    // bar's child count always matches the controller's length.
    final showRequestsTab = _tabCount == 3;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recipe Library 📚'),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: showRequestsTab,
          tabs: [
            const Tab(text: 'My Recipes'),
            const Tab(text: 'Browse Library'),
            if (showRequestsTab) const Tab(text: 'My Requests'),
          ],
        ),
      ),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search recipes...',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
                fillColor: Colors.grey[100],
              ),
              onChanged: (value) {
                setState(() => _searchQuery = value);
              },
            ),
          ),
          // Filter chips
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilterChip(
                  label: const Text('All Cuisines'),
                  selected: _selectedCuisine == null,
                  onSelected: (selected) {
                    setState(() => _selectedCuisine = selected ? null : _selectedCuisine);
                  },
                ),
                ...['Italian', 'Mexican', 'Asian', 'American', 'Mediterranean'].map((cuisine) =>
                  FilterChip(
                    label: Text(cuisine),
                    selected: _selectedCuisine == cuisine,
                    onSelected: (selected) {
                      setState(() => _selectedCuisine = selected ? cuisine : null);
                    },
                  ),
                ),
                FilterChip(
                  label: const Text('Easy'),
                  selected: _selectedDifficulty == 'Easy',
                  onSelected: (selected) {
                    setState(() => _selectedDifficulty = selected ? 'Easy' : null);
                  },
                ),
                FilterChip(
                  label: const Text('Medium'),
                  selected: _selectedDifficulty == 'Medium',
                  onSelected: (selected) {
                    setState(() => _selectedDifficulty = selected ? 'Medium' : null);
                  },
                ),
                FilterChip(
                  label: const Text('Hard'),
                  selected: _selectedDifficulty == 'Hard',
                  onSelected: (selected) {
                    setState(() => _selectedDifficulty = selected ? 'Hard' : null);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // Tab content
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildMyRecipesTab(),
                _buildBrowseLibraryTab(),
                if (showRequestsTab) _buildMyRequestsTab(),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'recipes-fab',
        onPressed: () {
          showModalBottomSheet(
            context: context,
            builder: (context) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: const Icon(Icons.link),
                    title: const Text('Import from URL'),
                    onTap: () {
                      Navigator.pop(context);
                      _showImportUrlSheet();
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.edit),
                    title: const Text('Create Manually'),
                    onTap: () {
                      Navigator.pop(context);
                      _showManualRecipeSheet();
                    },
                  ),
                ],
              ),
            ),
          );
        },
        icon: const Icon(Icons.add),
        label: const Text('Add Recipe'),
      ),
    );
  }

  Widget _buildMyRecipesTab() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final recipes = _filteredHouseholdRecipes;

    if (recipes.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.restaurant_menu, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              'No recipes yet',
              style: TextStyle(fontSize: 18, color: Colors.grey[600]),
            ),
            const SizedBox(height: 8),
            Text(
              'Import from a URL or create your own',
              style: TextStyle(color: Colors.grey[500]),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: recipes.length,
      itemBuilder: (context, index) {
        final recipe = recipes[index];
        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: InkWell(
            onTap: () => _showRecipeDetail(recipe),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  if (recipe['image_url'] != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(
                        recipe['image_url'],
                        width: 80,
                        height: 80,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) => Container(
                          width: 80,
                          height: 80,
                          color: Colors.grey[300],
                          child: const Icon(Icons.restaurant, size: 32),
                        ),
                      ),
                    )
                  else
                    Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        color: AppColors.honeyGold.withValues(alpha:0.2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.restaurant, size: 32),
                    ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                recipe['title'] ?? 'Untitled',
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            IconButton(
                              icon: Icon(
                                recipe['is_favorite'] == true
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                                color: recipe['is_favorite'] == true
                                    ? Colors.red
                                    : null,
                              ),
                              onPressed: () => _toggleFavorite(recipe),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        if (recipe['description'] != null)
                          Text(
                            recipe['description'],
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.grey[600],
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          children: [
                            if (recipe['difficulty'] != null)
                              Chip(
                                label: Text(recipe['difficulty']),
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                            if (recipe['cuisine'] != null)
                              Chip(
                                label: Text(recipe['cuisine']),
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBrowseLibraryTab() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final recipes = _filteredMasterRecipes;

    if (recipes.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.public, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              'No recipes in library',
              style: TextStyle(fontSize: 18, color: Colors.grey[600]),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: recipes.length,
      itemBuilder: (context, index) {
        final recipe = recipes[index];
        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: InkWell(
            onTap: () => _showRecipeDetail(recipe),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  if (recipe['image_url'] != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(
                        recipe['image_url'],
                        width: 80,
                        height: 80,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) => Container(
                          width: 80,
                          height: 80,
                          color: Colors.grey[300],
                          child: const Icon(Icons.restaurant, size: 32),
                        ),
                      ),
                    )
                  else
                    Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        color: AppColors.skyBlue.withValues(alpha:0.2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.public, size: 32),
                    ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          recipe['title'] ?? 'Untitled',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        if (recipe['description'] != null)
                          Text(
                            recipe['description'],
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.grey[600],
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            if (recipe['average_rating'] != null)
                              Row(
                                children: [
                                  const Icon(Icons.star, size: 16, color: Colors.amber),
                                  const SizedBox(width: 4),
                                  Text(
                                    recipe['average_rating'].toString(),
                                    style: const TextStyle(fontSize: 14),
                                  ),
                                  const SizedBox(width: 8),
                                ],
                              ),
                            if (recipe['rating_count'] != null && recipe['rating_count'] > 0)
                              Text(
                                '(${recipe['rating_count']} ratings)',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey[600],
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          children: [
                            if (recipe['difficulty'] != null)
                              Chip(
                                label: Text(recipe['difficulty']),
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                            if (recipe['cuisine'] != null)
                              Chip(
                                label: Text(recipe['cuisine']),
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    onPressed: () => _addToHousehold(recipe),
                    tooltip: 'Add to my recipes',
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ─── Batch 6b: kid's "My Requests" tab ─────────────────────────────────

  Widget _buildMyRequestsTab() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_myMealRequests.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.restaurant_menu, size: 64, color: Colors.grey[400]),
              const SizedBox(height: 16),
              Text(
                'No meal requests yet',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Colors.grey[600],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                "Tap 'Request this meal' on any recipe to start.",
                style: TextStyle(color: Colors.grey[500]),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _myMealRequests.length,
        itemBuilder: (context, index) {
          final req = _myMealRequests[index];
          return _MyRequestCard(
            key: ValueKey(req['id']),
            request: req,
          );
        },
      ),
    );
  }
}

/// Single row in the kid's "My Requests" tab. Stateless — admin decision is
/// the only thing that flips status; the kid sees decisions land via the
/// mealRequestsVersion realtime listener triggering _loadData on the parent.
class _MyRequestCard extends StatelessWidget {
  const _MyRequestCard({super.key, required this.request});
  final Map<String, dynamic> request;

  static const _mealTypeEmojis = {
    'breakfast': '🌅',
    'lunch': '☀️',
    'dinner': '🌙',
    'snack': '🍎',
    'other': '🍽️',
  };

  String _formatRelative(String? iso) {
    if (iso == null) return '';
    try {
      final dt = DateTime.parse(iso).toLocal();
      final diff = DateTime.now().difference(dt);
      if (diff.inMinutes < 1) return 'just now';
      if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
      if (diff.inHours < 24) return '${diff.inHours}h ago';
      if (diff.inDays == 1) return 'yesterday';
      if (diff.inDays < 7) return '${diff.inDays}d ago';
      return '${dt.month}/${dt.day}/${dt.year}';
    } catch (_) {
      return iso;
    }
  }

  String _formatScheduled(String? iso) {
    if (iso == null) return '';
    try {
      final dt = DateTime.parse(iso);
      const months = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
      ];
      return '${months[dt.month - 1]} ${dt.day}';
    } catch (_) {
      return iso;
    }
  }

  @override
  Widget build(BuildContext context) {
    final recipe = request['household_recipes'] as Map<String, dynamic>?;
    final title = recipe?['title'] as String? ?? 'Recipe';
    final imageUrl = recipe?['image_url'] as String?;
    final status = request['status'] as String? ?? 'pending';
    final note = (request['decided_note'] as String?)?.trim();

    final pillColor = switch (status) {
      'approved' => AppColors.grassGreen,
      'denied' => AppColors.coral,
      _ => AppColors.honeyGold,
    };
    final pillText = switch (status) {
      'approved' => 'Approved',
      'denied' => 'Denied',
      _ => 'Pending',
    };

    String secondLine;
    if (status == 'approved') {
      final scheduled = _formatScheduled(
        request['requested_for_date'] as String?,
      );
      final mealType = request['meal_type'] as String?;
      final emoji = _mealTypeEmojis[mealType] ?? '🍽️';
      final mealLabel = mealType == null
          ? ''
          : '${mealType[0].toUpperCase()}${mealType.substring(1)}';
      secondLine = scheduled.isEmpty && mealLabel.isEmpty
          ? 'On the meal plan'
          : 'Scheduled for ${[scheduled, '$emoji $mealLabel']
              .where((s) => s.trim().isNotEmpty)
              .join(' · ')}';
    } else if (status == 'denied') {
      secondLine = (note != null && note.isNotEmpty)
          ? '"$note"'
          : 'No reason given';
    } else {
      secondLine = 'Submitted ${_formatRelative(request['created_at'] as String?)}';
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: imageUrl != null
                  ? Image.network(
                      imageUrl,
                      width: 64,
                      height: 64,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _thumbFallback(),
                    )
                  : _thumbFallback(),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: pillColor.withValues(alpha:0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          pillText,
                          style: TextStyle(
                            color: pillColor,
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    secondLine,
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.grey.shade700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _thumbFallback() => Container(
        width: 64,
        height: 64,
        color: Colors.grey.shade200,
        alignment: Alignment.center,
        child: const Text('🍯', style: TextStyle(fontSize: 28)),
      );
}