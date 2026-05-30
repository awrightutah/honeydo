import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';

const _tagColorPalette = <String>[
  '#E74C3C', // red
  '#F39C12', // orange
  '#F1C40F', // yellow
  '#27AE60', // green
  '#16A085', // teal
  '#3498DB', // cyan
  '#2980B9', // blue
  '#8E44AD', // purple
  '#E91E63', // pink
  '#795548', // brown
  '#607D8B', // gray
  '#34495E', // slate
];

Color _parseTagColor(String? hex) {
  if (hex == null) return AppColors.skyBlue;
  try {
    final code = hex.replaceFirst('#', '');
    return Color(int.parse('FF$code', radix: 16));
  } catch (_) {
    return AppColors.skyBlue;
  }
}

class TagManagementScreen extends StatefulWidget {
  final String householdId;
  const TagManagementScreen({required this.householdId, super.key});

  @override
  State<TagManagementScreen> createState() => _TagManagementScreenState();
}

class _TagManagementScreenState extends State<TagManagementScreen> {
  List<Map<String, dynamic>> _tags = [];
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadTags();
  }

  Future<void> _loadTags() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final result = await Supabase.instance.client
          .from('calendar_tags')
          .select()
          .eq('household_id', widget.householdId)
          .order('created_at', ascending: false);

      if (!mounted) return;
      setState(() {
        _tags = List<Map<String, dynamic>>.from(result);
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMessage = "Couldn't load tags. Check your connection.";
        _isLoading = false;
      });
    }
  }

  Set<String> _existingNamesExcluding(String? excludeTagId) {
    return _tags
        .where((t) => t['id'] != excludeTagId)
        .map((t) => (t['name'] as String? ?? '').toLowerCase())
        .toSet();
  }

  Future<void> _openCreateSheet() async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _TagFormSheet(
        householdId: widget.householdId,
        existingTagNames: _existingNamesExcluding(null),
      ),
    );
    if (result == true && mounted) {
      await _loadTags();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Tag created')),
      );
    }
  }

  Future<void> _openEditSheet(Map<String, dynamic> tag) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _TagFormSheet(
        householdId: widget.householdId,
        existingTag: tag,
        existingTagNames: _existingNamesExcluding(tag['id'] as String?),
      ),
    );
    if (result == true && mounted) {
      await _loadTags();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Tag updated')),
      );
    }
  }

  Future<void> _confirmAndDelete(Map<String, dynamic> tag) async {
    final tagId = tag['id'] as String;
    final tagName = tag['name'] as String? ?? 'tag';
    final supabase = Supabase.instance.client;

    int eventsCount = 0;
    int mealsCount = 0;
    int choresCount = 0;
    try {
      final results = await Future.wait([
        supabase
            .from('calendar_events')
            .select('id')
            .eq('tag_id', tagId)
            .count(CountOption.exact),
        supabase
            .from('meal_plans')
            .select('id')
            .eq('tag_id', tagId)
            .count(CountOption.exact),
        supabase
            .from('chores')
            .select('id')
            .eq('tag_id', tagId)
            .count(CountOption.exact),
      ]);
      eventsCount = results[0].count;
      mealsCount = results[1].count;
      choresCount = results[2].count;
    } catch (_) {
      // Counts default to 0 if any of the three lookups fail; the confirmation
      // still surfaces, just with less information.
    }

    final totalUses = eventsCount + mealsCount + choresCount;
    final message = totalUses == 0
        ? 'Delete "$tagName"? This action cannot be undone.'
        : 'Deleting "$tagName" will remove the tag from '
            '$eventsCount events, $mealsCount meals, and $choresCount chores. '
            "They'll still exist, just untagged. Delete this tag?";

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete tag?'),
        content: Text(message),
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
      await supabase.from('calendar_tags').delete().eq('id', tagId);
      if (!mounted) return;
      await _loadTags();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Tag deleted')),
      );
    } on PostgrestException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _isRlsError(e)
                ? 'Only household admins can manage tags.'
                : 'Could not delete tag.',
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not delete tag.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Manage Tags')),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openCreateSheet,
        icon: const Icon(Icons.add),
        label: const Text('New tag'),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.grey),
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                style: Theme.of(context).textTheme.bodyLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _loadTags, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    if (_tags.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.label_outline, size: 64, color: Colors.grey),
              const SizedBox(height: 12),
              Text(
                'No tags yet',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Text(
                'Tap + to create your first one.',
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _tags.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final tag = _tags[i];
        final color = _parseTagColor(tag['color'] as String?);
        final emoji = tag['emoji'] as String?;
        final name = tag['name'] as String? ?? '';
        return ListTile(
          leading: SizedBox(
            width: 36,
            height: 36,
            child: Center(
              child: emoji != null && emoji.isNotEmpty
                  ? Text(emoji, style: const TextStyle(fontSize: 24))
                  : Icon(Icons.label, color: color),
            ),
          ),
          title: Text(
            name,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _confirmAndDelete(tag),
                tooltip: 'Delete',
              ),
            ],
          ),
          onTap: () => _openEditSheet(tag),
        );
      },
    );
  }
}

bool _isRlsError(PostgrestException e) {
  if (e.code == '42501') return true;
  final lower = e.message.toLowerCase();
  return lower.contains('permission') ||
      lower.contains('row-level') ||
      lower.contains('policy');
}

class _TagFormSheet extends StatefulWidget {
  final String householdId;
  final Map<String, dynamic>? existingTag;
  final Set<String> existingTagNames;

  const _TagFormSheet({
    required this.householdId,
    required this.existingTagNames,
    this.existingTag,
  });

  @override
  State<_TagFormSheet> createState() => _TagFormSheetState();
}

class _TagFormSheetState extends State<_TagFormSheet> {
  late final TextEditingController _nameController;
  late final TextEditingController _emojiController;
  late String _selectedColorHex;
  bool _isSaving = false;
  String? _errorMessage;

  bool get _isEditing => widget.existingTag != null;

  @override
  void initState() {
    super.initState();
    final tag = widget.existingTag;
    _nameController = TextEditingController(text: tag?['name'] as String? ?? '');
    _emojiController =
        TextEditingController(text: tag?['emoji'] as String? ?? '');
    final initialHex = tag?['color'] as String?;
    _selectedColorHex = _tagColorPalette.contains(initialHex)
        ? initialHex!
        : _tagColorPalette.first;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emojiController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final emoji = _emojiController.text.trim();

    if (name.isEmpty) {
      setState(() => _errorMessage = 'Name is required.');
      return;
    }
    if (name.length > 20) {
      setState(() => _errorMessage = 'Name must be 20 characters or fewer.');
      return;
    }
    if (widget.existingTagNames.contains(name.toLowerCase())) {
      setState(() => _errorMessage = 'A tag named "$name" already exists.');
      return;
    }

    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });

    try {
      final payload = {
        'name': name,
        'emoji': emoji.isEmpty ? null : emoji,
        'color': _selectedColorHex,
      };
      if (_isEditing) {
        await Supabase.instance.client
            .from('calendar_tags')
            .update(payload)
            .eq('id', widget.existingTag!['id']);
      } else {
        await Supabase.instance.client
            .from('calendar_tags')
            .insert({...payload, 'household_id': widget.householdId});
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on PostgrestException catch (e) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _errorMessage = _isRlsError(e)
            ? 'Only household admins can manage tags.'
            : 'Could not save tag.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _errorMessage = 'Could not save tag.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final emojiPreview = _emojiController.text.trim();
    final previewColor = _parseTagColor(_selectedColorHex);
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _isEditing ? 'Edit tag' : 'New tag',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),

            // Preview chip — updates live as user types / picks color
            Center(
              child: Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: previewColor.withValues(alpha: .15),
                  shape: BoxShape.circle,
                  border: Border.all(color: previewColor, width: 2),
                ),
                child: Center(
                  child: emojiPreview.isNotEmpty
                      ? Text(emojiPreview, style: const TextStyle(fontSize: 36))
                      : Icon(Icons.label, size: 36, color: previewColor),
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Name field
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Name',
                border: OutlineInputBorder(),
                hintText: 'e.g. Soccer',
              ),
              maxLength: 20,
              textInputAction: TextInputAction.next,
              onChanged: (_) {
                if (_errorMessage != null) {
                  setState(() => _errorMessage = null);
                }
              },
            ),
            const SizedBox(height: 4),

            // Emoji field
            TextField(
              controller: _emojiController,
              decoration: const InputDecoration(
                labelText: 'Emoji (optional)',
                border: OutlineInputBorder(),
                hintText: '🏷️',
                helperText: 'Switch keyboard to emoji on iOS to pick one',
              ),
              maxLength: 4,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),

            // Color picker
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Color',
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: _tagColorPalette.map((hex) {
                final isSelected = hex == _selectedColorHex;
                final color = _parseTagColor(hex);
                return GestureDetector(
                  onTap: () => setState(() => _selectedColorHex = hex),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isSelected ? Colors.black87 : Colors.transparent,
                        width: 3,
                      ),
                    ),
                    child: isSelected
                        ? const Icon(Icons.check, color: Colors.white, size: 20)
                        : null,
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),

            if (_errorMessage != null) ...[
              Text(
                _errorMessage!,
                style: const TextStyle(color: AppColors.coral),
              ),
              const SizedBox(height: 12),
            ],

            // Action buttons
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _isSaving
                        ? null
                        : () => Navigator.pop(context, false),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _isSaving ? null : _save,
                    child: _isSaving
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text(_isEditing ? 'Save' : 'Create'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
