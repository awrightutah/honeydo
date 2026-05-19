import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../services/realtime_service.dart';

/// Full calendar screen with month view, custom tags/colors,
/// event creation, tag filtering, and shared reminders.
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  Map<String, dynamic>? _household;
  Map<String, dynamic>? _myMembership;
  List<Map<String, dynamic>> _events = [];
  List<Map<String, dynamic>> _tags = [];
  List<Map<String, dynamic>> _members = [];
  bool _isLoading = true;

  DateTime _focusedMonth = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime? _selectedDay;
  String? _filterTagId;

  @override
  void initState() {
    super.initState();
    _selectedDay = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
    _loadData();
    RealtimeService.instance.choresVersion.addListener(_onRealtimeUpdate);
  }

  @override
  void dispose() {
    RealtimeService.instance.choresVersion.removeListener(_onRealtimeUpdate);
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
            .from('calendar_tags')
            .select()
            .eq('household_id', householdId)
            .order('name'),
        Supabase.instance.client
            .from('household_members')
            .select()
            .eq('household_id', householdId)
            .eq('is_active', true)
            .order('display_name'),
      ]);

      _tags = List<Map<String, dynamic>>.from(results[0]);
      _members = List<Map<String, dynamic>>.from(results[1]);

      await _loadEvents();
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadEvents() async {
    if (_household == null) return;

    try {
      final monthStart = DateTime(_focusedMonth.year, _focusedMonth.month, 1);
      final monthEnd = DateTime(_focusedMonth.year, _focusedMonth.month + 1, 0, 23, 59, 59);

      var query = Supabase.instance.client
          .from('calendar_events')
          .select('*, tag:calendar_tags(name, color, emoji), creator:household_members!created_by_member_id(display_name)')
          .eq('household_id', _household!['id'])
          .gte('starts_at', monthStart.toIso8601String())
          .lte('starts_at', monthEnd.toIso8601String())
          .order('starts_at');

      if (_filterTagId != null) {
        query = query.eq('tag_id', _filterTagId!);
      }

      final events = await query;

      setState(() {
        _events = List<Map<String, dynamic>>.from(events);
        _isLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  List<Map<String, dynamic>> _eventsForDay(DateTime day) {
    return _events.where((e) {
      final startsAt = DateTime.tryParse(e['starts_at'] ?? '');
      if (startsAt == null) return false;
      return startsAt.year == day.year && startsAt.month == day.month && startsAt.day == day.day;
    }).toList();
  }

  void _showAddEventSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => _AddEventSheet(
        householdId: _household!['id'],
        myMemberId: _myMembership!['id'],
        selectedDay: _selectedDay ?? DateTime.now(),
        tags: _tags,
        members: _members,
      ),
    ).then((_) => _loadEvents());
  }

  Future<void> _deleteEvent(String eventId) async {
    try {
      await Supabase.instance.client
          .from('calendar_events')
          .delete()
          .eq('id', eventId);
      _loadEvents();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not delete event.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Family Calendar 📅'),
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
                // Tag filter
                if (_tags.isNotEmpty)
                  SizedBox(
                    height: 44,
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      scrollDirection: Axis.horizontal,
                      itemCount: _tags.length + 1,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (context, i) {
                        if (i == 0) {
                          return ChoiceChip(
                            label: const Text('All'),
                            selected: _filterTagId == null,
                            onSelected: (_) {
                              setState(() => _filterTagId = null);
                              _loadEvents();
                            },
                          );
                        }
                        final tag = _tags[i - 1];
                        final tagId = tag['id'];
                        return ChoiceChip(
                          avatar: Text(tag['emoji'] ?? '📌', style: const TextStyle(fontSize: 14)),
                          label: Text(tag['name'] ?? '', style: const TextStyle(fontSize: 12)),
                          selected: _filterTagId == tagId,
                          onSelected: (_) {
                            setState(() => _filterTagId = _filterTagId == tagId ? null : tagId);
                            _loadEvents();
                          },
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 8),

                // Month navigation
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton.outlined(
                        onPressed: () {
                          setState(() {
                            _focusedMonth = DateTime(_focusedMonth.year, _focusedMonth.month - 1, 1);
                          });
                          _loadEvents();
                        },
                        icon: const Icon(Icons.chevron_left_rounded),
                      ),
                      Text(
                        _monthYear(_focusedMonth),
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      IconButton.outlined(
                        onPressed: () {
                          setState(() {
                            _focusedMonth = DateTime(_focusedMonth.year, _focusedMonth.month + 1, 1);
                          });
                          _loadEvents();
                        },
                        icon: const Icon(Icons.chevron_right_rounded),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),

                // Calendar grid
                _buildCalendarGrid(),

                const SizedBox(height: 8),

                // Selected day events
                if (_selectedDay != null) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _formatSelectedDay(),
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.add_rounded, size: 20),
                          onPressed: _showAddEventSheet,
                          style: IconButton.styleFrom(backgroundColor: AppColors.honeyGold.withOpacity(.1)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: _buildDayEvents(),
                  ),
                ],
              ],
            ),
    );
  }

  Widget _buildCalendarGrid() {
    final firstDay = DateTime(_focusedMonth.year, _focusedMonth.month, 1);
    final lastDay = DateTime(_focusedMonth.year, _focusedMonth.month + 1, 0);
    final startWeekday = firstDay.weekday; // 1=Mon, 7=Sun
    final daysInMonth = lastDay.day;

    // Build day cells
    final cells = <Widget>[];

    // Day headers
    const dayHeaders = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    for (final h in dayHeaders) {
      cells.add(Center(
        child: Text(h, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.grey.shade500)),
      ));
    }

    // Empty cells before month starts
    for (var i = 1; i < startWeekday; i++) {
      cells.add(const SizedBox());
    }

    // Day cells
    for (var d = 1; d <= daysInMonth; d++) {
      final day = DateTime(_focusedMonth.year, _focusedMonth.month, d);
      final isToday = _isSameDay(day, DateTime.now());
      final isSelected = _selectedDay != null && _isSameDay(day, _selectedDay!);
      final dayEvents = _eventsForDay(day);

      cells.add(
        GestureDetector(
          onTap: () => setState(() => _selectedDay = day),
          child: Container(
            decoration: BoxDecoration(
              color: isSelected ? AppColors.honeyGold : (isToday ? AppColors.honeyGold.withOpacity(.15) : null),
              shape: BoxShape.circle,
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Text(
                  '$d',
                  style: TextStyle(
                    fontWeight: isToday || isSelected ? FontWeight.w800 : FontWeight.w500,
                    color: isSelected ? Colors.white : null,
                    fontSize: 14,
                  ),
                ),
                if (dayEvents.isNotEmpty)
                  Positioned(
                    bottom: 2,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: dayEvents.take(3).map((e) {
                        final color = _parseColor(e['tag']?['color'] ?? e['color_override']);
                        return Container(
                          width: 5,
                          height: 5,
                          margin: const EdgeInsets.symmetric(horizontal: 1),
                          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                        );
                      }).toList(),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: GridView.count(
        crossAxisCount: 7,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
        children: cells,
      ),
    );
  }

  Widget _buildDayEvents() {
    if (_selectedDay == null) return const SizedBox();

    final dayEvents = _eventsForDay(_selectedDay!);

    if (dayEvents.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('📋', style: TextStyle(fontSize: 48)),
            const SizedBox(height: 12),
            Text('No events', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text('Tap + to add an event for this day.', style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: dayEvents.length,
      itemBuilder: (context, i) {
        final event = dayEvents[i];
        return _EventCard(
          event: event,
          onDelete: () => _deleteEvent(event['id']),
        );
      },
    );
  }

  static bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  String _monthYear(DateTime date) {
    const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
    return '${months[date.month - 1]} ${date.year}';
  }

  String _formatSelectedDay() {
    if (_selectedDay == null) return '';
    const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${days[_selectedDay!.weekday - 1]}, ${months[_selectedDay!.month - 1]} ${_selectedDay!.day}';
  }

  Color _parseColor(String? hex) {
    if (hex == null) return AppColors.skyBlue;
    try {
      final code = hex.replaceFirst('#', '');
      return Color(int.parse('FF$code', radix: 16));
    } catch (_) {
      return AppColors.skyBlue;
    }
  }
}

class _EventCard extends StatelessWidget {
  const _EventCard({required this.event, required this.onDelete});

  final Map<String, dynamic> event;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final title = event['title'] ?? 'Untitled';
    final description = event['description'];
    final startsAt = DateTime.tryParse(event['starts_at'] ?? '');
    final endsAt = DateTime.tryParse(event['ends_at'] ?? '');
    final allDay = event['all_day'] ?? false;
    final tag = event['tag'] as Map<String, dynamic>?;
    final creator = event['creator']?['display_name'];
    final reminder = event['reminder_minutes_before'];

    final tagColor = _parseColor(tag?['color']);
    final tagName = tag?['name'];
    final tagEmoji = tag?['emoji'];

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Dismissible(
        key: ValueKey(event['id']),
        direction: DismissDirection.endToStart,
        onDismissed: (_) => onDelete(),
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 16),
          decoration: BoxDecoration(
            color: AppColors.coral.withOpacity(.1),
            borderRadius: BorderRadius.circular(24),
          ),
          child: const Icon(Icons.delete_outline_rounded, color: AppColors.coral),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // Color indicator
                  Container(
                    width: 4,
                    height: 40,
                    decoration: BoxDecoration(
                      color: tagColor,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                        if (description != null && description.toString().isNotEmpty)
                          Text(description, style: Theme.of(context).textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                  if (allDay)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.skyBlue.withOpacity(.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text('All day', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.skyBlue)),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  if (startsAt != null && !allDay) ...[
                    Icon(Icons.schedule_rounded, size: 14, color: Theme.of(context).colorScheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Text(
                      _formatTime(startsAt, endsAt),
                      style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(width: 12),
                  ],
                  if (tagName != null) ...[
                    if (tagEmoji != null) Text(tagEmoji, style: const TextStyle(fontSize: 12)),
                    const SizedBox(width: 4),
                    Text(tagName, style: TextStyle(fontSize: 12, color: tagColor, fontWeight: FontWeight.w600)),
                    const SizedBox(width: 12),
                  ],
                  if (reminder != null) ...[
                    Icon(Icons.notifications_active_rounded, size: 14, color: AppColors.honeyGold),
                    const SizedBox(width: 4),
                    Text('${reminder}m before', style: const TextStyle(fontSize: 12, color: AppColors.honeyGold)),
                  ],
                ],
              ),
              if (creator != null) ...[
                const SizedBox(height: 4),
                Text('Added by $creator', style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant, fontStyle: FontStyle.italic)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Color _parseColor(String? hex) {
    if (hex == null) return AppColors.skyBlue;
    try {
      final code = hex.replaceFirst('#', '');
      return Color(int.parse('FF$code', radix: 16));
    } catch (_) {
      return AppColors.skyBlue;
    }
  }

  String _formatTime(DateTime starts, DateTime? ends) {
    final startStr = '${starts.hour.toString().padLeft(2, '0')}:${starts.minute.toString().padLeft(2, '0')}';
    if (ends != null) {
      final endStr = '${ends.hour.toString().padLeft(2, '0')}:${ends.minute.toString().padLeft(2, '0')}';
      return '$startStr – $endStr';
    }
    return startStr;
  }
}

class _AddEventSheet extends StatefulWidget {
  const _AddEventSheet({
    required this.householdId,
    required this.myMemberId,
    required this.selectedDay,
    required this.tags,
    required this.members,
  });

  final String householdId;
  final String myMemberId;
  final DateTime selectedDay;
  final List<Map<String, dynamic>> tags;
  final List<Map<String, dynamic>> members;

  @override
  State<_AddEventSheet> createState() => _AddEventSheetState();
}

class _AddEventSheetState extends State<_AddEventSheet> {
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  DateTime _startsAt = DateTime.now();
  DateTime? _endsAt;
  bool _allDay = false;
  String? _selectedTagId;
  int _reminderMinutes = 0;
  List<String> _selectedMemberIds = [];
  bool _isLoading = false;

  static const _reminderOptions = [0, 5, 10, 15, 30, 60, 1440];
  static const _reminderLabels = ['None', '5 min', '10 min', '15 min', '30 min', '1 hour', '1 day'];

  @override
  void initState() {
    super.initState();
    _startsAt = DateTime(widget.selectedDay.year, widget.selectedDay.month, widget.selectedDay.day, 9, 0);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _createEvent() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter an event title.')),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final eventId = await Supabase.instance.client
          .from('calendar_events')
          .insert({
            'household_id': widget.householdId,
            'title': title,
            'description': _descriptionController.text.trim().isEmpty ? null : _descriptionController.text.trim(),
            'starts_at': _startsAt.toIso8601String(),
            'ends_at': _endsAt?.toIso8601String(),
            'all_day': _allDay,
            'tag_id': _selectedTagId,
            'reminder_minutes_before': _reminderMinutes > 0 ? _reminderMinutes : null,
            'created_by_member_id': widget.myMemberId,
          })
          .select('id')
          .single();

      // Add member associations
      if (_selectedMemberIds.isNotEmpty && eventId != null) {
        final memberInserts = _selectedMemberIds.map((memberId) => {
          'event_id': eventId['id'],
          'member_id': memberId,
        }).toList();

        await Supabase.instance.client.from('calendar_event_members').insert(memberInserts);
      }

      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not create event. Please try again.')),
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
            Text('New Event', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
            const SizedBox(height: 20),

            // Title
            TextFormField(
              controller: _titleController,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Event title',
                prefixIcon: Icon(Icons.edit_note_rounded),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),

            // Description
            TextFormField(
              controller: _descriptionController,
              textCapitalization: TextCapitalization.sentences,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
                prefixIcon: Icon(Icons.note_rounded),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),

            // All day toggle
            SwitchListTile(
              value: _allDay,
              onChanged: (v) => setState(() => _allDay = v),
              title: const Text('All day', style: TextStyle(fontWeight: FontWeight.w600)),
              secondary: const Icon(Icons.today_rounded),
              contentPadding: EdgeInsets.zero,
            ),
            const SizedBox(height: 16),

            // Start time
            if (!_allDay)
              OutlinedButton.icon(
                onPressed: () async {
                  final time = await showTimePicker(
                    context: context,
                    initialTime: TimeOfDay.fromDateTime(_startsAt),
                  );
                  if (time != null) {
                    setState(() {
                      _startsAt = DateTime(
                        _startsAt.year, _startsAt.month, _startsAt.day,
                        time.hour, time.minute,
                      );
                    });
                  }
                },
                icon: const Icon(Icons.schedule_rounded, size: 18),
                label: Text('Start: ${_startsAt.hour.toString().padLeft(2, '0')}:${_startsAt.minute.toString().padLeft(2, '0')}'),
              ),
            const SizedBox(height: 16),

            // Tag selection
            DropdownButtonFormField<String>(
              value: _selectedTagId,
              decoration: const InputDecoration(
                labelText: 'Tag',
                prefixIcon: Icon(Icons.label_outline_rounded),
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem(value: null, child: Text('No tag')),
                ...widget.tags.map((t) => DropdownMenuItem(
                  value: t['id'],
                  child: Row(
                    children: [
                      if (t['emoji'] != null) Text(t['emoji'], style: const TextStyle(fontSize: 14)),
                      const SizedBox(width: 6),
                      Text(t['name'] ?? '', style: const TextStyle(fontSize: 14)),
                    ],
                  ),
                )),
              ],
              onChanged: (v) => setState(() => _selectedTagId = v),
            ),
            const SizedBox(height: 16),

            // Reminder
            DropdownButtonFormField<int>(
              value: _reminderMinutes,
              decoration: const InputDecoration(
                labelText: 'Reminder',
                prefixIcon: Icon(Icons.notifications_none_rounded),
                border: OutlineInputBorder(),
              ),
              items: List.generate(_reminderOptions.length, (i) => DropdownMenuItem(
                value: _reminderOptions[i],
                child: Text(_reminderLabels[i]),
              )),
              onChanged: (v) => setState(() => _reminderMinutes = v ?? 0),
            ),
            const SizedBox(height: 24),

            FilledButton(
              onPressed: _isLoading ? null : _createEvent,
              child: _isLoading
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Create event'),
            ),
          ],
        ),
      ),
    );
  }
}
