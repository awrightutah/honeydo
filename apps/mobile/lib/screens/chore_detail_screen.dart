import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';

/// Chore detail screen for viewing, editing, and managing individual chores.
class ChoreDetailScreen extends StatefulWidget {
  final String choreId;

  const ChoreDetailScreen({super.key, required this.choreId});

  @override
  State<ChoreDetailScreen> createState() => _ChoreDetailScreenState();
}

class _ChoreDetailScreenState extends State<ChoreDetailScreen> {
  Map<String, dynamic>? _chore;
  Map<String, dynamic>? _householdMember;
  List<Map<String, dynamic>> _assignees = [];
  List<Map<String, dynamic>> _activityLog = [];
  bool _isLoading = true;
  bool _isEditing = false;

  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _pointsController = TextEditingController();
  String _selectedFrequency = 'once';
  String _selectedStatus = 'assigned';
  String? _selectedAssigneeId;
  DateTime? _dueDate;
  TimeOfDay? _dueTime;

  final List<Map<String, String>> _frequencies = [
    {'value': 'once', 'label': 'One Time'},
    {'value': 'daily', 'label': 'Daily'},
    {'value': 'weekly', 'label': 'Weekly'},
    {'value': 'biweekly', 'label': 'Every 2 Weeks'},
    {'value': 'monthly', 'label': 'Monthly'},
  ];

  final List<Map<String, String>> _statuses = [
    {'value': 'assigned', 'label': 'Assigned'},
    {'value': 'in_progress', 'label': 'In Progress'},
    {'value': 'completed', 'label': 'Completed'},
    {'value': 'verified', 'label': 'Verified'},
    {'value': 'skipped', 'label': 'Skipped'},
  ];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _pointsController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);

    try {
      final user = Supabase.instance.client.auth.currentUser!;

      // Load current membership
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

      // Load chore details
      final chores = await Supabase.instance.client
          .from('chores')
          .select('*, household_members!chores_assigned_to_member_id_fkey(display_name, kind, avatar_url)')
          .eq('id', widget.choreId)
          .limit(1);

      if (chores.isEmpty) {
        setState(() => _isLoading = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Chore not found')),
          );
          Navigator.pop(context);
        }
        return;
      }

      _chore = chores[0];

      // Load all household members for assignee dropdown
      _assignees = await Supabase.instance.client
          .from('household_members')
          .select('id, display_name, kind, avatar_url')
          .eq('household_id', householdId)
          .order('display_name');

      // Populate edit fields
      _titleController.text = _chore?['title'] ?? '';
      _descriptionController.text = _chore?['description'] ?? '';
      _pointsController.text = (_chore?['point_value'] ?? 10).toString();
      _selectedFrequency = _chore?['frequency'] ?? 'once';
      _selectedStatus = _chore?['status'] ?? 'assigned';
      _selectedAssigneeId = _chore?['assigned_to_member_id'];

      if (_chore?['due_at'] != null) {
        _dueDate = DateTime.parse(_chore!['due_at']);
        _dueTime = TimeOfDay.fromDateTime(_dueDate!);
      }

      // Load activity/verification log
      try {
        _activityLog = await Supabase.instance.client
            .from('chore_verifications')
            .select('*, household_members!chore_verifications_verifier_member_id_fkey(display_name)')
            .eq('chore_id', widget.choreId)
            .order('created_at', ascending: false)
            .limit(20);
      } catch (_) {
        // Verification table may not have data
        _activityLog = [];
      }

      setState(() => _isLoading = false);
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading chore: $e')),
        );
      }
    }
  }

  Future<void> _saveChore() async {
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
        'point_value': int.tryParse(_pointsController.text) ?? 10,
        'frequency': _selectedFrequency,
        'status': _selectedStatus,
        'assigned_to_member_id': _selectedAssigneeId,
      };

      if (_dueDate != null) {
        DateTime dueAt = _dueDate!;
        if (_dueTime != null) {
          dueAt = DateTime(dueAt.year, dueAt.month, dueAt.day, _dueTime!.hour, _dueTime!.minute);
        } else {
          dueAt = DateTime(dueAt.year, dueAt.month, dueAt.day, 23, 59);
        }
        updates['due_at'] = dueAt.toUtc().toIso8601String();
      } else {
        updates['due_at'] = null;
      }

      await Supabase.instance.client
          .from('chores')
          .update(updates)
          .eq('id', widget.choreId);

      setState(() => _isEditing = false);
      await _loadData();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Chore updated!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving chore: $e')),
        );
      }
    }
  }

  Future<void> _deleteChore() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Chore?'),
        content: const Text('This action cannot be undone. All data for this chore will be permanently removed.'),
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
            .from('chores')
            .delete()
            .eq('id', widget.choreId);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Chore deleted')),
          );
          Navigator.pop(context);
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error deleting chore: $e')),
          );
        }
      }
    }
  }

  Future<void> _pickDueDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueDate ?? now.add(const Duration(days: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );

    if (picked != null) {
      setState(() => _dueDate = picked);
    }
  }

  Future<void> _pickDueTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _dueTime ?? TimeOfDay.now(),
    );

    if (picked != null) {
      setState(() => _dueTime = picked);
    }
  }

  String _formatDate(String? dateStr) {
    if (dateStr == null) return 'No due date';
    try {
      final dt = DateTime.parse(dateStr).toLocal();
      final now = DateTime.now();
      final diff = dt.difference(now);

      if (diff.isNegative) return 'Overdue';
      if (diff.inHours < 1) return 'Due in ${diff.inMinutes}m';
      if (diff.inHours < 24) return 'Due in ${diff.inHours}h';
      if (diff.inDays == 1) return 'Due tomorrow';
      return 'Due ${dt.month}/${dt.day}';
    } catch (_) {
      return dateStr;
    }
  }

  Color _statusColor(String status) {
    return switch (status) {
      'assigned' => AppColors.skyBlue,
      'in_progress' => AppColors.honeyGold,
      'completed' => AppColors.grassGreen,
      'verified' => const Color(0xFF4CAF50),
      'skipped' => Colors.grey,
      _ => Colors.grey,
    };
  }

  IconData _statusIcon(String status) {
    return switch (status) {
      'assigned' => Icons.assignment,
      'in_progress' => Icons.pending,
      'completed' => Icons.check_circle,
      'verified' => Icons.verified,
      'skipped' => Icons.skip_next,
      _ => Icons.help,
    };
  }

  IconData _frequencyIcon(String freq) {
    return switch (freq) {
      'once' => Icons.looks_one,
      'daily' => Icons.today,
      'weekly' => Icons.date_range,
      'biweekly' => Icons.event_repeat,
      'monthly' => Icons.calendar_month,
      _ => Icons.repeat,
    };
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final isAdmin = _householdMember?['role'] == 'admin';
    final isAssignedToMe = _chore?['assigned_to_member_id'] == _householdMember?['id'];
    final canEdit = isAdmin || isAssignedToMe;
    final assignee = _chore?['household_members'];

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit Chore' : 'Chore Details'),
        actions: [
          if (!_isEditing && canEdit) ...[
            IconButton(
              icon: const Icon(Icons.edit_rounded),
              onPressed: () => setState(() => _isEditing = true),
              tooltip: 'Edit',
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: _deleteChore,
              tooltip: 'Delete',
            ),
          ],
          if (_isEditing) ...[
            TextButton(
              onPressed: () => setState(() => _isEditing = false),
              child: const Text('Cancel'),
            ),
          ],
        ],
      ),
      body: _isEditing ? _buildEditMode() : _buildViewMode(assignee, canEdit),
    );
  }

  Widget _buildViewMode(Map<String, dynamic>? assignee, bool canEdit) {
    final status = _chore?['status'] ?? 'assigned';
    final frequency = _chore?['frequency'] ?? 'once';
    final pointValue = _chore?['point_value'] ?? 10;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Status card
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [_statusColor(status).withOpacity(0.1), _statusColor(status).withOpacity(0.05)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: _statusColor(status).withOpacity(0.3)),
            ),
            child: Row(
              children: [
                Icon(_statusIcon(status), color: _statusColor(status), size: 32),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _statuses.firstWhere((s) => s['value'] == status, orElse: () => {'label': status})['label']!,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: _statusColor(status),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _formatDate(_chore?['due_at']),
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
                // Points badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.honeyGold.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(100),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.star_rounded, color: AppColors.honeyGold, size: 18),
                      const SizedBox(width: 4),
                      Text(
                        '$pointValue pts',
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          color: AppColors.honeyGold,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Title
          Text(
            _chore?['title'] ?? 'Untitled Chore',
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 12),

          // Description
          if (_chore?['description'] != null && (_chore!['description'] as String).isNotEmpty) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: Text(
                _chore!['description'],
                style: TextStyle(fontSize: 15, color: Colors.grey.shade700, height: 1.5),
              ),
            ),
            const SizedBox(height: 24),
          ],

          // Details grid
          Row(
            children: [
              Expanded(child: _buildDetailCard(Icons.person_rounded, 'Assigned To', assignee?['display_name'] ?? 'Unassigned')),
              const SizedBox(width: 12),
              Expanded(child: _buildDetailCard(_frequencyIcon(frequency), 'Frequency', _frequencies.firstWhere((f) => f['value'] == frequency, orElse: () => {'label': frequency})['label']!)),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _buildDetailCard(Icons.calendar_today_rounded, 'Due Date', _dueDate != null ? '${_dueDate!.month}/${_dueDate!.day}/${_dueDate!.year}' : 'None')),
              const SizedBox(width: 12),
              Expanded(child: _buildDetailCard(Icons.access_time_rounded, 'Due Time', _dueTime != null ? _dueTime!.format(context) : 'None')),
            ],
          ),
          const SizedBox(height: 24),

          // Quick actions
          if (canEdit && status != 'verified') ...[
            const Text(
              'Quick Actions',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (status == 'assigned')
                  _buildActionChip('Start', Icons.play_arrow_rounded, AppColors.skyBlue, () => _quickUpdateStatus('in_progress')),
                if (status == 'in_progress' || status == 'assigned')
                  _buildActionChip('Complete', Icons.check_circle_rounded, AppColors.grassGreen, () => _quickUpdateStatus('completed')),
                if (status == 'completed' && isAdmin)
                  _buildActionChip('Verify', Icons.verified_rounded, const Color(0xFF4CAF50), () => _quickUpdateStatus('verified')),
                if (status != 'skipped')
                  _buildActionChip('Skip', Icons.skip_next_rounded, Colors.grey, () => _quickUpdateStatus('skipped')),
                if (status != 'assigned')
                  _buildActionChip('Reassign', Icons.refresh_rounded, AppColors.honeyGold, () => _quickUpdateStatus('assigned')),
              ],
            ),
            const SizedBox(height: 24),
          ],

          // Activity log
          if (_activityLog.isNotEmpty) ...[
            const Text(
              'Activity Log',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            ..._activityLog.map((log) => _buildActivityItem(log)),
          ],

          // Created/Updated timestamps
          const SizedBox(height: 24),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_chore?['created_at'] != null)
                  Text(
                    'Created: ${_formatTimestamp(_chore!['created_at'])}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                  ),
                if (_chore?['updated_at'] != null)
                  Text(
                    'Updated: ${_formatTimestamp(_chore!['updated_at'])}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailCard(IconData icon, String label, String value) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: AppColors.honeyGold),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(fontSize: 11, color: Colors.grey.shade500, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 8),
          Text(value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  Widget _buildActionChip(String label, IconData icon, Color color, VoidCallback onTap) {
    return ActionChip(
      avatar: Icon(icon, size: 18, color: color),
      label: Text(label),
      labelStyle: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 13),
      backgroundColor: color.withOpacity(0.1),
      side: BorderSide(color: color.withOpacity(0.3)),
      onPressed: onTap,
    );
  }

  Widget _buildActivityItem(Map<String, dynamic> log) {
    final verifier = log['household_members']?['display_name'] ?? 'Unknown';
    final status = log['status'] ?? 'unknown';
    final createdAt = log['created_at'] ?? '';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(_statusIcon(status), size: 20, color: _statusColor(status)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$verifier ${status == 'verified' ? 'verified' : status == 'completed' ? 'completed' : 'updated'} this chore',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                Text(
                  _formatTimestamp(createdAt),
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEditMode() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Title
            TextFormField(
              controller: _titleController,
              decoration: const InputDecoration(
                labelText: 'Title',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.title),
              ),
              validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
            ),
            const SizedBox(height: 16),

            // Description
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

            // Points and Frequency row
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextFormField(
                    controller: _pointsController,
                    decoration: const InputDecoration(
                      labelText: 'Points',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.star_rounded),
                    ),
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 3,
                  child: DropdownButtonFormField<String>(
                    value: _selectedFrequency,
                    decoration: const InputDecoration(
                      labelText: 'Frequency',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.repeat),
                    ),
                    items: _frequencies.map((f) => DropdownMenuItem(
                      value: f['value'],
                      child: Text(f['label']!),
                    )).toList(),
                    onChanged: (v) => setState(() => _selectedFrequency = v!),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Status
            DropdownButtonFormField<String>(
              value: _selectedStatus,
              decoration: const InputDecoration(
                labelText: 'Status',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.assignment),
              ),
              items: _statuses.map((s) => DropdownMenuItem(
                value: s['value'],
                child: Text(s['label']!),
              )).toList(),
              onChanged: (v) => setState(() => _selectedStatus = v!),
            ),
            const SizedBox(height: 16),

            // Assignee
            DropdownButtonFormField<String?>(
              value: _selectedAssigneeId,
              decoration: const InputDecoration(
                labelText: 'Assign To',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.person),
              ),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('Unassigned')),
                ..._assignees.map((a) => DropdownMenuItem(
                  value: a['id'],
                  child: Text('${a['display_name']}${a['kind'] == 'sub_profile' ? ' 👦' : ''}'),
                )),
              ],
              onChanged: (v) => setState(() => _selectedAssigneeId = v),
            ),
            const SizedBox(height: 16),

            // Due date and time
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: _pickDueDate,
                    child: InputDecorator(
                      decoration: InputDecoration(
                        labelText: 'Due Date',
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.calendar_today),
                        suffixIcon: _dueDate != null
                            ? IconButton(
                                icon: const Icon(Icons.clear, size: 18),
                                onPressed: () => setState(() => _dueDate = null),
                              )
                            : null,
                      ),
                      child: Text(
                        _dueDate != null ? '${_dueDate!.month}/${_dueDate!.day}/${_dueDate!.year}' : 'No date',
                        style: TextStyle(
                          color: _dueDate != null ? null : Colors.grey.shade500,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: InkWell(
                    onTap: _dueDate != null ? _pickDueTime : null,
                    child: InputDecorator(
                      decoration: InputDecoration(
                        labelText: 'Due Time',
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.access_time),
                        suffixIcon: _dueTime != null
                            ? IconButton(
                                icon: const Icon(Icons.clear, size: 18),
                                onPressed: () => setState(() => _dueTime = null),
                              )
                            : null,
                      ),
                      child: Text(
                        _dueTime != null ? _dueTime!.format(context) : 'No time',
                        style: TextStyle(
                          color: _dueTime != null ? null : Colors.grey.shade500,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 32),

            // Save button
            ElevatedButton.icon(
              onPressed: _saveChore,
              icon: const Icon(Icons.save),
              label: const Text('Save Changes'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.honeyGold,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 52),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _quickUpdateStatus(String newStatus) async {
    try {
      await Supabase.instance.client
          .from('chores')
          .update({'status': newStatus})
          .eq('id', widget.choreId);

      await _loadData();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Status updated to ${_statuses.firstWhere((s) => s['value'] == newStatus, orElse: () => {'label': newStatus})['label']}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error updating status: $e')),
        );
      }
    }
  }

  String _formatTimestamp(String? ts) {
    if (ts == null) return '';
    try {
      final dt = DateTime.parse(ts).toLocal();
      return '${dt.month}/${dt.day}/${dt.year} at ${dt.hour > 12 ? dt.hour - 12 : dt.hour}:${dt.minute.toString().padLeft(2, '0')} ${dt.hour >= 12 ? 'PM' : 'AM'}';
    } catch (_) {
      return ts;
    }
  }
}
