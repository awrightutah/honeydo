import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../utils/membership.dart';
import 'chore_detail_screen.dart';
import 'recipe_detail_screen.dart';

/// Global search across chores, recipes, and shopping items.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _searchController = TextEditingController();
  final _focusNode = FocusNode();

  Map<String, dynamic>? _household;
  List<Map<String, dynamic>> _chores = [];
  List<Map<String, dynamic>> _recipes = [];
  List<Map<String, dynamic>> _shoppingItems = [];

  bool _isSearching = false;
  String _query = '';
  SearchTab _activeTab = SearchTab.all;

  @override
  void initState() {
    super.initState();
    _focusNode.requestFocus();
    _loadHousehold();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadHousehold() async {
    try {
      // Batch 7a-iii — Pattern A (LOW-risk): only household_id is consumed
      // downstream, and kid + parent admin share the same household, so this
      // migration is for code-consistency, not bug fix. No ActiveMemberService
      // listener needed.
      final membership = await MembershipHelper.loadActiveMembership();
      if (membership != null) {
        setState(() => _household = {'id': membership['household_id']});
      }
    } catch (e) {
      debugPrint('search_screen load household failed: $e');
    }
  }

  Future<void> _performSearch(String query) async {
    if (_household == null || query.trim().isEmpty) {
      setState(() {
        _chores = [];
        _recipes = [];
        _shoppingItems = [];
        _isSearching = false;
        _query = query.trim();
      });
      return;
    }

    setState(() {
      _isSearching = true;
      _query = query.trim();
    });

    try {
      final householdId = _household!['id'];
      final pattern = '%${query.trim()}%';

      final results = await Future.wait([
        Supabase.instance.client
            .from('chores')
            .select('id, title, description, status, point_value, due_at')
            .eq('household_id', householdId)
            .or('title.ilike.$pattern,description.ilike.$pattern')
            .limit(10),
        Supabase.instance.client
            .from('household_recipes')
            .select('id, title, description, difficulty, cuisine, image_url')
            .eq('household_id', householdId)
            .or('title.ilike.$pattern,description.ilike.$pattern,cuisine.ilike.$pattern')
            .limit(10),
        Supabase.instance.client
            .from('shopping_items')
            .select('id, name, category, purchased, display_quantity')
            .eq('household_id', householdId)
            .ilike('name', pattern)
            .limit(10),
      ]);

      if (mounted) {
        setState(() {
          _chores = List<Map<String, dynamic>>.from(results[0]);
          _recipes = List<Map<String, dynamic>>.from(results[1]);
          _shoppingItems = List<Map<String, dynamic>>.from(results[2]);
          _isSearching = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isSearching = false);
    }
  }

  int get _totalResults => _chores.length + _recipes.length + _shoppingItems.length;

  List<Map<String, dynamic>> get _filteredResults {
    switch (_activeTab) {
      case SearchTab.all:
        return [
          ..._chores.map((c) => {...c, '_type': 'chore'}),
          ..._recipes.map((r) => {...r, '_type': 'recipe'}),
          ..._shoppingItems.map((s) => {...s, '_type': 'shopping'}),
        ];
      case SearchTab.chores:
        return _chores.map((c) => {...c, '_type': 'chore'}).toList();
      case SearchTab.recipes:
        return _recipes.map((r) => {...r, '_type': 'recipe'}).toList();
      case SearchTab.shopping:
        return _shoppingItems.map((s) => {...s, '_type': 'shopping'}).toList();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.pop(context),
        ),
        title: TextField(
          controller: _searchController,
          focusNode: _focusNode,
          decoration: InputDecoration(
            hintText: 'Search chores, recipes, shopping...',
            hintStyle: TextStyle(color: Colors.grey.shade500),
            border: InputBorder.none,
          ),
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          textInputAction: TextInputAction.search,
          onSubmitted: _performSearch,
          onChanged: (value) {
            if (value.trim().isEmpty) {
              setState(() {
                _query = '';
                _chores = [];
                _recipes = [];
                _shoppingItems = [];
              });
            }
          },
        ),
        actions: [
          if (_searchController.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear_rounded),
              onPressed: () {
                _searchController.clear();
                setState(() {
                  _query = '';
                  _chores = [];
                  _recipes = [];
                  _shoppingItems = [];
                });
              },
            ),
        ],
      ),
      body: Column(
        children: [
          // Tab filters
          if (_query.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  _SearchFilterChip(
                    label: 'All',
                    count: _totalResults,
                    selected: _activeTab == SearchTab.all,
                    onTap: () => setState(() => _activeTab = SearchTab.all),
                  ),
                  const SizedBox(width: 8),
                  _SearchFilterChip(
                    label: 'Chores',
                    count: _chores.length,
                    selected: _activeTab == SearchTab.chores,
                    onTap: () => setState(() => _activeTab = SearchTab.chores),
                    color: AppColors.skyBlue,
                  ),
                  const SizedBox(width: 8),
                  _SearchFilterChip(
                    label: 'Recipes',
                    count: _recipes.length,
                    selected: _activeTab == SearchTab.recipes,
                    onTap: () => setState(() => _activeTab = SearchTab.recipes),
                    color: AppColors.coral,
                  ),
                  const SizedBox(width: 8),
                  _SearchFilterChip(
                    label: 'Shopping',
                    count: _shoppingItems.length,
                    selected: _activeTab == SearchTab.shopping,
                    onTap: () => setState(() => _activeTab = SearchTab.shopping),
                    color: AppColors.grassGreen,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
          ],

          // Results
          Expanded(
            child: _isSearching
                ? const Center(child: CircularProgressIndicator())
                : _query.isEmpty
                    ? _buildEmptyState()
                    : _buildResults(),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search_rounded, size: 64, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          Text(
            'Search Clanquility',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: Colors.grey.shade400,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'Find chores, recipes, and shopping items',
            style: TextStyle(color: Colors.grey.shade500),
          ),
          const SizedBox(height: 32),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              _SuggestionChip('🧹 Clean kitchen', onTap: () => _quickSearch('Clean kitchen')),
              _SuggestionChip('🍝 Pasta recipe', onTap: () => _quickSearch('Pasta')),
              _SuggestionChip('🥛 Milk', onTap: () => _quickSearch('Milk')),
              _SuggestionChip('🗑️ Trash', onTap: () => _quickSearch('Trash')),
            ],
          ),
        ],
      ),
    );
  }

  void _quickSearch(String query) {
    _searchController.text = query;
    _performSearch(query);
  }

  Widget _buildResults() {
    final results = _filteredResults;

    if (results.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('🔍', style: TextStyle(fontSize: 48)),
            const SizedBox(height: 12),
            Text(
              'No results for "$_query"',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text(
              'Try different keywords or check spelling',
              style: TextStyle(color: Colors.grey.shade500),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: results.length,
      itemBuilder: (context, index) {
        final item = results[index];
        final type = item['_type'] as String;

        return _SearchResultCard(
          item: item,
          type: type,
          onTap: () => _navigateToDetail(item, type),
        );
      },
    );
  }

  void _navigateToDetail(Map<String, dynamic> item, String type) {
    switch (type) {
      case 'chore':
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ChoreDetailScreen(choreId: item['id']),
          ),
        );
        break;
      case 'recipe':
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => RecipeDetailScreen(
              recipeId: item['id'],
            ),
          ),
        );
        break;
      case 'shopping':
        // Shopping items don't have a detail screen, just show a snackbar
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${item['name']} - ${item['display_quantity'] ?? 'No quantity'}')),
        );
        break;
    }
  }
}

enum SearchTab { all, chores, recipes, shopping }

class _SearchFilterChip extends StatelessWidget {
  const _SearchFilterChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
    this.color,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final chipColor = color ?? AppColors.honeyGold;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? chipColor.withValues(alpha:.15) : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(100),
          border: Border.all(
            color: selected ? chipColor.withValues(alpha:.4) : Colors.grey.shade200,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                fontSize: 13,
                color: selected ? chipColor : Colors.grey.shade600,
              ),
            ),
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: selected ? chipColor.withValues(alpha:.2) : Colors.grey.shade200,
                borderRadius: BorderRadius.circular(100),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: selected ? chipColor : Colors.grey.shade600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SuggestionChip extends StatelessWidget {
  const _SuggestionChip(this.label, {required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      label: Text(label),
      onPressed: onTap,
      labelStyle: TextStyle(fontSize: 13, color: Colors.grey.shade700),
    );
  }
}

class _SearchResultCard extends StatelessWidget {
  const _SearchResultCard({
    required this.item,
    required this.type,
    required this.onTap,
  });

  final Map<String, dynamic> item;
  final String type;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    switch (type) {
      case 'chore':
        return _ChoreResultCard(item: item, onTap: onTap);
      case 'recipe':
        return _RecipeResultCard(item: item, onTap: onTap);
      case 'shopping':
        return _ShoppingResultCard(item: item, onTap: onTap);
      default:
        return const SizedBox.shrink();
    }
  }
}

class _ChoreResultCard extends StatelessWidget {
  const _ChoreResultCard({required this.item, required this.onTap});

  final Map<String, dynamic> item;
  final VoidCallback onTap;

  static const _statusColors = {
    'assigned': AppColors.skyBlue,
    'in_progress': AppColors.honeyGold,
    'pending_verification': AppColors.coral,
    'verified': AppColors.grassGreen,
    'overdue': AppColors.coral,
    'cancelled': Colors.grey,
    'rejected': AppColors.coral,
  };

  @override
  Widget build(BuildContext context) {
    final title = item['title'] ?? 'Untitled';
    final status = item['status'] ?? 'assigned';
    final points = item['point_value'] ?? 0;
    final statusColor = _statusColors[status] ?? Colors.grey;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha:.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    '${points}pt',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 11, color: statusColor),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha:.1),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            status.replaceAll('_', ' ').toUpperCase(),
                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: statusColor),
                          ),
                        ),
                        if (item['due_at'] != null) ...[
                          const SizedBox(width: 8),
                          Icon(Icons.schedule_rounded, size: 12, color: Colors.grey.shade500),
                          const SizedBox(width: 2),
                          Text(
                            _formatDate(item['due_at']),
                            style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDate(dynamic dateStr) {
    try {
      final date = DateTime.parse(dateStr.toString());
      return '${date.month}/${date.day}';
    } catch (_) {
      return '';
    }
  }
}

class _RecipeResultCard extends StatelessWidget {
  const _RecipeResultCard({required this.item, required this.onTap});

  final Map<String, dynamic> item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final title = item['title'] ?? 'Untitled';
    final difficulty = item['difficulty'];
    final cuisine = item['cuisine'];
    final imageUrl = item['image_url'];

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    color: AppColors.coral.withValues(alpha:.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: imageUrl != null
                      ? Image.network(imageUrl, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.restaurant_rounded, color: AppColors.coral)))
                      : const Center(child: Icon(Icons.restaurant_rounded, color: AppColors.coral)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        if (cuisine != null) ...[
                          Icon(Icons.public_rounded, size: 12, color: Colors.grey.shade500),
                          const SizedBox(width: 2),
                          Text(cuisine, style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                          const SizedBox(width: 8),
                        ],
                        if (difficulty != null) ...[
                          Icon(Icons.signal_cellular_alt_rounded, size: 12, color: Colors.grey.shade500),
                          const SizedBox(width: 2),
                          Text(difficulty, style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShoppingResultCard extends StatelessWidget {
  const _ShoppingResultCard({required this.item, required this.onTap});

  final Map<String, dynamic> item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final name = item['name'] ?? 'Unknown';
    final category = item['category'];
    final purchased = item['purchased'] ?? false;
    final quantity = item['display_quantity'];

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: purchased ? AppColors.grassGreen.withValues(alpha:.12) : AppColors.honeyGold.withValues(alpha:.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Icon(
                    purchased ? Icons.check_rounded : Icons.shopping_basket_rounded,
                    color: purchased ? AppColors.grassGreen : AppColors.honeyGold,
                    size: 22,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        decoration: purchased ? TextDecoration.lineThrough : null,
                        color: purchased ? Colors.grey : null,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        if (quantity != null) ...[
                          Text(quantity, style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                          const SizedBox(width: 8),
                        ],
                        if (category != null)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(category, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.grey.shade600)),
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
  }
}
