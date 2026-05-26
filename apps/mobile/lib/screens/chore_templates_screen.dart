import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/active_member_service.dart';
import '../theme/app_theme.dart';
import '../utils/membership.dart';

class ChoreTemplatesScreen extends StatefulWidget {
  const ChoreTemplatesScreen({super.key});

  @override
  State<ChoreTemplatesScreen> createState() => _ChoreTemplatesScreenState();
}

class _ChoreTemplatesScreenState extends State<ChoreTemplatesScreen> {
  List<Map<String, dynamic>> _templates = [];
  Map<String, dynamic>? _household;
  Map<String, dynamic>? _myMembership;
  bool _isLoading = true;
  String? _selectedCategory;
  String _searchQuery = '';
  final _searchController = TextEditingController();

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
    _searchController.dispose();
    super.dispose();
  }

  void _onActiveMemberChanged() {
    if (mounted) _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);

    try {
      // Batch 7a-i — MembershipHelper so template `created_by_member_id` on
      // writes attributes to the active member, not the parent admin.
      // (Templates are admin-only in practice today; the menu-entry gating
      // is an orthogonal followup tracked from the 7a investigation.)
      final membership = await MembershipHelper.loadActiveMembership(
        includeHouseholdJoin: true,
      );
      if (membership != null) {
        _myMembership = membership;
        _household = membership['households'];
      }

      final householdId = _household?['id'];
      final templates = await Supabase.instance.client
          .from('chore_templates')
          .select()
          .or('household_id.is.null,household_id.eq.$householdId')
          .order('is_system', ascending: true)
          .order('room_or_category')
          .order('title');

      setState(() => _templates = List<Map<String, dynamic>>.from(templates));
    } catch (e) {
      debugPrint('chore_templates load failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not load templates: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  List<String> get _categories {
    final cats = <String>{};
    for (final t in _templates) {
      final cat = t['room_or_category'] as String?;
      if (cat != null && cat.isNotEmpty) cats.add(cat);
    }
    return cats.toList()..sort();
  }

  List<Map<String, dynamic>> get _filteredTemplates {
    var results = _templates;

    if (_selectedCategory != null) {
      results = results.where((t) => t['room_or_category'] == _selectedCategory).toList();
    }

    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      results = results.where((t) {
        final title = (t['title'] ?? '').toLowerCase();
        final desc = (t['description'] ?? '').toLowerCase();
        final cat = (t['room_or_category'] ?? '').toLowerCase();
        return title.contains(q) || desc.contains(q) || cat.contains(q);
      }).toList();
    }

    return results;
  }

  Map<String, List<Map<String, dynamic>>> get _groupedTemplates {
    final filtered = _filteredTemplates;
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final t in filtered) {
      final cat = t['room_or_category'] ?? 'Other';
      grouped.putIfAbsent(cat, () => []).add(t);
    }
    return grouped;
  }

  Future<void> _quickAddFromTemplate(Map<String, dynamic> template) async {
    if (_household == null || _myMembership == null) return;

    final members = await Supabase.instance.client
        .from('household_members')
        .select()
        .eq('household_id', _household!['id']);

    if (!mounted) return;

    final selectedMemberId = await showDialog<String>(
      context: context,
      builder: (context) => _QuickAssignDialog(
        template: template,
        members: List<Map<String, dynamic>>.from(members),
      ),
    );

    if (selectedMemberId == null || !mounted) return;

    try {
      await Supabase.instance.client.from('chores').insert({
        'household_id': _household!['id'],
        'title': template['title'],
        'description': template['description'],
        'assigned_to_member_id': selectedMemberId == 'unassigned' ? null : selectedMemberId,
        'created_by_member_id': _myMembership!['id'],
        'difficulty': template['difficulty'] ?? 'easy',
        'point_value': template['suggested_points'] ?? 5,
        'status': 'assigned',
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ ${template['title']} added!'),
            backgroundColor: AppColors.grassGreen,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not create chore.')),
        );
      }
    }
  }

  Future<void> _addCustomTemplate() async {
    final titleController = TextEditingController();
    final descController = TextEditingController();
    final pointsController = TextEditingController(text: '5');
    String category = 'Household';
    String difficulty = 'easy';
    String frequency = 'weekly';
    String icon = '📋';

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Create Template', style: TextStyle(fontWeight: FontWeight.w800)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Icon picker
                Wrap(
                  spacing: 8,
                  children: ['📋', '🧹', '🍽️', '🧽', '🗑️', '🧺', '🪟', '🌿', '🚗', '👕', '🛏️', '🧑‍🍳'].map((e) => 
                    ChoiceChip(
                      label: Text(e, style: const TextStyle(fontSize: 20)),
                      selected: icon == e,
                      onSelected: (_) => setDialogState(() => icon = e),
                    ),
                  ).toList(),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: titleController,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Title *',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: descController,
                  textCapitalization: TextCapitalization.sentences,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Description',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: category,
                  decoration: const InputDecoration(
                    labelText: 'Room / Category',
                    border: OutlineInputBorder(),
                  ),
                  items: ['Kitchen', 'Living Room', 'Bedroom', 'Bathroom', 'Laundry', 'Yard', 'Garage', 'Entryway', 'Pets', 'Household', 'Other']
                      .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                      .toList(),
                  onChanged: (v) => setDialogState(() => category = v ?? 'Household'),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: difficulty,
                        decoration: const InputDecoration(
                          labelText: 'Difficulty',
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(value: 'easy', child: Text('🟢 Easy')),
                          DropdownMenuItem(value: 'medium', child: Text('🟡 Medium')),
                          DropdownMenuItem(value: 'hard', child: Text('🔴 Hard')),
                        ],
                        onChanged: (v) => setDialogState(() => difficulty = v ?? 'easy'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: pointsController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Points',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (v) {},
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: frequency,
                  decoration: const InputDecoration(
                    labelText: 'Frequency',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'daily', child: Text('Daily')),
                    DropdownMenuItem(value: 'weekly', child: Text('Weekly')),
                    DropdownMenuItem(value: 'biweekly', child: Text('Bi-weekly')),
                    DropdownMenuItem(value: 'monthly', child: Text('Monthly')),
                    DropdownMenuItem(value: 'as_needed', child: Text('As needed')),
                  ],
                  onChanged: (v) => setDialogState(() => frequency = v ?? 'weekly'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (titleController.text.trim().isEmpty) return;
                Navigator.pop(context, true);
              },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );

    if (result != true || !mounted) return;

    try {
      await Supabase.instance.client.from('chore_templates').insert({
        'title': titleController.text.trim(),
        'description': descController.text.trim().isNotEmpty ? descController.text.trim() : null,
        'room_or_category': category,
        'difficulty': difficulty,
        'suggested_points': int.tryParse(pointsController.text) ?? 5,
        'suggested_frequency': frequency,
        'icon': icon,
        'is_system': false,
        'household_id': _household!['id'],
      });

      _loadData();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not create template.')),
        );
      }
    }
  }

  Future<void> _deleteCustomTemplate(Map<String, dynamic> template) async {
    if (template['is_system'] == true) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Template?'),
        content: Text('Remove "${template['title']}" from your household templates?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.coral),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await Supabase.instance.client
          .from('chore_templates')
          .delete()
          .eq('id', template['id']);

      _loadData();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not delete template.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final grouped = _groupedTemplates;
    final categories = grouped.keys.toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Chore Templates', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_circle_outline_rounded),
            onPressed: _addCustomTemplate,
            tooltip: 'Create template',
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(110),
          child: Column(
            children: [
              // Search bar
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: TextField(
                  controller: _searchController,
                  onChanged: (v) => setState(() => _searchQuery = v),
                  decoration: InputDecoration(
                    hintText: 'Search templates...',
                    prefixIcon: const Icon(Icons.search_rounded, size: 20),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear_rounded, size: 20),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                          )
                        : null,
                    filled: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    isDense: true,
                  ),
                ),
              ),
              // Category filter chips
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        label: const Text('All'),
                        selected: _selectedCategory == null,
                        onSelected: (_) => setState(() => _selectedCategory = null),
                        backgroundColor: Colors.grey.shade100,
                        selectedColor: AppColors.honeyGold.withOpacity(.2),
                        checkmarkColor: AppColors.honeyGold,
                      ),
                    ),
                    ..._categories.map((cat) => Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        label: Text(cat),
                        selected: _selectedCategory == cat,
                        onSelected: (_) => setState(() => _selectedCategory = _selectedCategory == cat ? null : cat),
                        backgroundColor: Colors.grey.shade100,
                        selectedColor: AppColors.honeyGold.withOpacity(.2),
                        checkmarkColor: AppColors.honeyGold,
                      ),
                    )),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _filteredTemplates.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.assignment_outlined, size: 64, color: Colors.grey.shade300),
                      const SizedBox(height: 16),
                      Text(
                        _searchQuery.isNotEmpty ? 'No templates match your search' : 'No templates yet',
                        style: TextStyle(fontSize: 16, color: Colors.grey.shade500, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Create custom templates for your household!',
                        style: TextStyle(fontSize: 13, color: Colors.grey.shade400),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: categories.length,
                  itemBuilder: (context, index) {
                    final category = categories[index];
                    final templates = grouped[category]!;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: EdgeInsets.only(bottom: 8, top: index > 0 ? 20 : 0),
                          child: Row(
                            children: [
                              _categoryIcon(category),
                              const SizedBox(width: 8),
                              Text(
                                category,
                                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade200,
                                  borderRadius: BorderRadius.circular(100),
                                ),
                                child: Text(
                                  '${templates.length}',
                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.grey.shade600),
                                ),
                              ),
                            ],
                          ),
                        ),
                        ...templates.map((t) => _TemplateCard(
                              template: t,
                              onQuickAdd: () => _quickAddFromTemplate(t),
                              onDelete: t['is_system'] != true ? () => _deleteCustomTemplate(t) : null,
                            )),
                      ],
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addCustomTemplate,
        icon: const Icon(Icons.add_rounded),
        label: const Text('New Template'),
        backgroundColor: AppColors.honeyGold,
        foregroundColor: Colors.white,
      ),
    );
  }

  Widget _categoryIcon(String category) {
    final iconMap = {
      'Kitchen': Icons.kitchen_rounded,
      'Living Room': Icons.weekend_rounded,
      'Bedroom': Icons.bed_rounded,
      'Bathroom': Icons.bathtub_rounded,
      'Laundry': Icons.local_laundry_service_rounded,
      'Yard': Icons.yard_rounded,
      'Garage': Icons.garage_rounded,
      'Entryway': Icons.door_front_door_rounded,
      'Pets': Icons.pets_rounded,
      'Household': Icons.home_rounded,
    };
    return Icon(iconMap[category] ?? Icons.category_rounded, size: 20, color: AppColors.honeyGold);
  }
}

class _TemplateCard extends StatelessWidget {
  final Map<String, dynamic> template;
  final VoidCallback onQuickAdd;
  final VoidCallback? onDelete;

  const _TemplateCard({
    required this.template,
    required this.onQuickAdd,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final isSystem = template['is_system'] == true;
    final difficulty = template['difficulty'] ?? 'easy';
    final points = template['suggested_points'] ?? 5;
    final icon = template['icon'] ?? '📋';
    final frequency = template['suggested_frequency'] ?? '';

    final difficultyColor = switch (difficulty) {
      'hard' => AppColors.coral,
      'medium' => AppColors.honeyGold,
      _ => AppColors.grassGreen,
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onQuickAdd,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // Icon circle
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: difficultyColor.withOpacity(.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(icon, style: const TextStyle(fontSize: 22)),
                ),
              ),
              const SizedBox(width: 12),
              // Content
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            template['title'] ?? '',
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (!isSystem)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: AppColors.skyBlue.withOpacity(.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text('Custom', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: AppColors.skyBlue)),
                          ),
                      ],
                    ),
                    if (template['description'] != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        template['description'],
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: difficultyColor.withOpacity(.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '${difficulty[0].toUpperCase()}${difficulty.substring(1)}',
                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: difficultyColor),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(Icons.star_rounded, size: 14, color: AppColors.honeyGold),
                        Text('$points', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.honeyGold)),
                        if (frequency.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Icon(Icons.repeat_rounded, size: 12, color: Colors.grey.shade400),
                          const SizedBox(width: 2),
                          Text(_frequencyLabel(frequency), style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              // Action buttons
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.add_circle_rounded, color: AppColors.grassGreen),
                    onPressed: onQuickAdd,
                    tooltip: 'Quick add chore',
                    iconSize: 28,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  ),
                  if (onDelete != null)
                    IconButton(
                      icon: Icon(Icons.delete_outline_rounded, size: 18, color: Colors.grey.shade400),
                      onPressed: onDelete,
                      tooltip: 'Delete template',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 36, minHeight: 28),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _frequencyLabel(String freq) {
    return switch (freq) {
      'daily' => 'Daily',
      'weekly' => 'Weekly',
      'biweekly' => 'Bi-weekly',
      'monthly' => 'Monthly',
      'as_needed' => 'As needed',
      _ => freq,
    };
  }
}

class _QuickAssignDialog extends StatefulWidget {
  final Map<String, dynamic> template;
  final List<Map<String, dynamic>> members;

  const _QuickAssignDialog({
    required this.template,
    required this.members,
  });

  @override
  State<_QuickAssignDialog> createState() => _QuickAssignDialogState();
}

class _QuickAssignDialogState extends State<_QuickAssignDialog> {
  String? _selectedMemberId;
  DateTime? _dueDate;

  @override
  Widget build(BuildContext context) {
    final icon = widget.template['icon'] ?? '📋';
    final points = widget.template['suggested_points'] ?? 5;

    return AlertDialog(
      title: Row(
        children: [
          Text(icon, style: const TextStyle(fontSize: 24)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Quick Add: ${widget.template['title']}',
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Points badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.honeyGold.withOpacity(.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.star_rounded, color: AppColors.honeyGold, size: 18),
                const SizedBox(width: 4),
                Text('$points points', style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.honeyGold)),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Assign to
          Text('Assign to:', style: TextStyle(fontWeight: FontWeight.w600, color: Colors.grey.shade700, fontSize: 13)),
          const SizedBox(height: 8),
          ...[
            {'id': 'unassigned', 'display_name': 'Unassigned', 'kind': 'none'},
            ...widget.members,
          ].map((m) => RadioListTile<String>(
            value: m['id'],
            groupValue: _selectedMemberId ?? 'unassigned',
            onChanged: (v) => setState(() => _selectedMemberId = v),
            title: Row(
              children: [
                if (m['kind'] == 'sub_profile') const Text('👶 ', style: TextStyle(fontSize: 14)),
                Text(m['display_name'] ?? 'Unknown', style: const TextStyle(fontSize: 14)),
              ],
            ),
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.trailing,
          )),

          const SizedBox(height: 12),

          // Due date
          OutlinedButton.icon(
            onPressed: () async {
              final date = await showDatePicker(
                context: context,
                initialDate: _dueDate ?? DateTime.now().add(const Duration(days: 1)),
                firstDate: DateTime.now(),
                lastDate: DateTime.now().add(const Duration(days: 90)),
              );
              if (date != null) setState(() => _dueDate = date);
            },
            icon: Icon(Icons.calendar_today_rounded, size: 16),
            label: Text(_dueDate != null ? 'Due: ${_dueDate!.month}/${_dueDate!.day}' : 'Set due date (optional)'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _selectedMemberId ?? 'unassigned'),
          child: const Text('Add Chore'),
        ),
      ],
    );
  }
}
