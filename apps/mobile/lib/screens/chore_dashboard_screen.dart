import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../services/realtime_service.dart';
import 'chore_detail_screen.dart';

class ChoreDashboardScreen extends StatefulWidget {
  const ChoreDashboardScreen({super.key});

  @override
  State<ChoreDashboardScreen> createState() => _ChoreDashboardScreenState();
}

class _ChoreDashboardScreenState extends State<ChoreDashboardScreen> {
  List<Map<String, dynamic>> _myChores = [];
  List<Map<String, dynamic>> _pendingVerification = [];
  Map<String, dynamic>? _household;
  Map<String, dynamic>? _myMembership;
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadData();
    // Listen for realtime updates from other household members
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
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final user = Supabase.instance.client.auth.currentUser!;
      final userId = user.id;

      // Get user's household membership
      final memberships = await Supabase.instance.client
          .from('household_members')
          .select('*, households(*)')
          .eq('auth_user_id', userId)
          .limit(1);

      if (memberships.isEmpty) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'You\'re not in a household yet. Create or join one to get started!';
        });
        return;
      }

      _myMembership = memberships[0];
      _household = memberships[0]['households'];
      final householdId = _household!['id'];
      final myMemberId = _myMembership!['id'];

      // Load chores assigned to me that are assigned/pending
      final myChores = await Supabase.instance.client
          .from('chores')
          .select()
          .eq('household_id', householdId)
          .eq('assigned_to_member_id', myMemberId)
          .inSet('status', ['assigned', 'pending'])
          .order('due_at', ascending: true);

      // Load chores pending verification (if admin)
      List<Map<String, dynamic>> pendingVerif = [];
      if (_myMembership!['role'] == 'admin') {
        pendingVerif = await Supabase.instance.client
            .from('chores')
            .select('*, assignee:household_members!assigned_to_member_id(display_name)')
            .eq('household_id', householdId)
            .eq('status', 'pending_verification')
            .order('completed_at', ascending: true);
      }

      setState(() {
        _myChores = List<Map<String, dynamic>>.from(myChores);
        _pendingVerification = List<Map<String, dynamic>>.from(pendingVerif);
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'Could not load chores. Pull down to retry.';
      });
    }
  }

  Future<void> _completeChore(String choreId) async {
    try {
      await Supabase.instance.client.from('chores').update({
        'status': 'pending_verification',
        'completed_at': DateTime.now().toIso8601String(),
      }).eq('id', choreId);

      _loadData();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not mark chore as complete. Please try again.')),
        );
      }
    }
  }

  Future<void> _verifyChore(String choreId, bool approved) async {
    try {
      final chore = _pendingVerification.firstWhere((c) => c['id'] == choreId);
      final points = chore['point_value'] ?? 5;

      if (approved) {
        // Update chore status
        await Supabase.instance.client.from('chores').update({
          'status': 'completed',
          'verified_at': DateTime.now().toIso8601String(),
          'verified_by_member_id': _myMembership!['id'],
        }).eq('id', choreId);

        // Award points to the user who completed it
        final assignedMemberId = chore['assigned_to_member_id'] as String;
        final assignedMember = await Supabase.instance.client
            .from('household_members')
            .select('user_id')
            .eq('id', assignedMemberId)
            .single();

        await Supabase.instance.client.rpc('award_points', params: {
          'p_user_id': assignedMember['user_id'],
          'p_household_id': chore['household_id'],
          'p_points': points + (chore['bonus_points'] ?? 0),
          'p_reason': 'chore_completion',
          'p_reference_id': choreId,
        });

        // Check for new achievements
        await Supabase.instance.client.rpc('check_and_award_achievements', params: {
          'p_user_id': assignedMember['user_id'],
          'p_household_id': chore['household_id'],
        });
      } else {
        // Reject - put chore back to assigned
        await Supabase.instance.client.from('chores').update({
          'status': 'assigned',
          'completed_at': null,
        }).eq('id', choreId);
      }

      _loadData();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update chore status. Please try again.')),
        );
      }
    }
  }

  void _showAddChoreSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => _AddChoreSheet(
        householdId: _household!['id'],
        myMemberId: _myMembership!['id'],
      ),
    ).then((_) => _loadData());
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = _myMembership?['role'] == 'admin';
    final totalPending = _myChores.length;
    final totalVerification = _pendingVerification.length;

    return Scaffold(
      appBar: AppBar(
        title: Text(_household?['name'] != null ? '${_household!['name']} 🐝' : 'Today\'s Chores 🐝'),
        actions: [
          if (_household != null)
            IconButton(
              icon: const Icon(Icons.add_circle_outline_rounded),
              onPressed: _showAddChoreSheet,
              tooltip: 'Add chore',
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
          : _errorMessage != null
              ? _buildError()
              : RefreshIndicator(
                  onRefresh: _loadData,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      // Stats row
                      Row(
                        children: [
                          Expanded(
                            child: _StatCard(
                              title: 'My Chores',
                              value: '$totalPending',
                              icon: Icons.task_alt_rounded,
                              color: AppColors.honeyGold,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _StatCard(
                              title: 'My Points',
                              value: '${_myMembership?['points_balance'] ?? 0}',
                              icon: Icons.star_rounded,
                              color: AppColors.grassGreen,
                            ),
                          ),
                          if (isAdmin) ...[
                            const SizedBox(width: 12),
                            Expanded(
                              child: _StatCard(
                                title: 'Verify',
                                value: '$totalVerification',
                                icon: Icons.verified_rounded,
                                color: AppColors.skyBlue,
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 24),

                      // Pending Verification section (admin only)
                      if (isAdmin && _pendingVerification.isNotEmpty) ...[
                        _SectionHeader(title: 'Pending Verification', count: totalVerification),
                        const SizedBox(height: 8),
                        ..._pendingVerification.map((chore) => _VerificationCard(
                              chore: chore,
                              onApprove: () => _verifyChore(chore['id'], true),
                              onReject: () => _verifyChore(chore['id'], false),
                            )),
                        const SizedBox(height: 24),
                      ],

                      // My Chores section
                      _SectionHeader(title: 'My Chores', count: totalPending),
                      const SizedBox(height: 8),
                      if (_myChores.isEmpty)
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(32),
                            child: Column(
                              children: [
                                const Text('🎉', style: TextStyle(fontSize: 48)),
                                const SizedBox(height: 12),
                                Text('All caught up!', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                                const SizedBox(height: 4),
                                Text('No pending chores right now.', style: Theme.of(context).textTheme.bodyMedium),
                              ],
                            ),
                          ),
                        )
                      else
                        ..._myChores.map((chore) => _ChoreCard(
                              chore: chore,
                              onComplete: () => _completeChore(chore['id']),
                            )),
                    ],
                  ),
                ),
      floatingActionButton: _household != null
          ? FloatingActionButton.extended(
              onPressed: _showAddChoreSheet,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add Chore'),
            )
          : null,
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('😕', style: TextStyle(fontSize: 48)),
            const SizedBox(height: 16),
            Text(_errorMessage!, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyLarge),
            const SizedBox(height: 24),
            FilledButton(onPressed: _loadData, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.title, required this.value, required this.icon, required this.color});
  final String title;
  final String value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(height: 8),
            Text(value, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900)),
            const SizedBox(height: 2),
            Text(title, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.count});
  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          decoration: BoxDecoration(
            color: AppColors.honeyGold.withOpacity(.2),
            borderRadius: BorderRadius.circular(100),
          ),
          child: Text('$count', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
        ),
      ],
    );
  }
}

class _ChoreCard extends StatelessWidget {
  const _ChoreCard({required this.chore, required this.onComplete});
  final Map<String, dynamic> chore;
  final VoidCallback onComplete;

  @override
  Widget build(BuildContext context) {
    final name = chore['title'] ?? 'Untitled Chore';
    final room = chore['room_or_category'] ?? '';
    final points = chore['point_value'] ?? 5;
    final bonus = chore['bonus_points'] ?? 0;
    final difficulty = chore['difficulty'] ?? 'easy';
    final dueAt = chore['due_at'] != null ? DateTime.tryParse(chore['due_at']) : null;
    final isChoreOfDay = chore['chore_of_day_date'] != null;

    final difficultyColor = switch (difficulty) {
      'hard' => AppColors.coral,
      'medium' => AppColors.honeyGold,
      _ => AppColors.grassGreen,
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ChoreDetailScreen(choreId: chore['id']),
            ),
          ).then((_) => onComplete);
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        if (isChoreOfDay) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.honeyGold.withOpacity(.2),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text('⭐', style: TextStyle(fontSize: 12)),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Flexible(
                          child: Text(name, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: difficultyColor.withOpacity(.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '+$points pts${bonus > 0 ? ' +$bonus bonus' : ''}',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: difficultyColor),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  if (room.isNotEmpty) ...[
                    Icon(Icons.room_rounded, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Text(room, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                    const SizedBox(width: 12),
                  ],
                  if (dueAt != null) ...[
                    Icon(Icons.schedule_rounded, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Text(
                      _formatDate(dueAt),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: dueAt.isBefore(DateTime.now()) ? AppColors.coral : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: onComplete,
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: const Text('Mark complete'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(40),
                    backgroundColor: AppColors.grassGreen,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final diff = DateTime(date.year, date.month, date.day).difference(DateTime(now.year, now.month, now.day)).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Tomorrow';
    if (diff < 0) return 'Overdue!';
    return '$diff day${diff > 1 ? "s" : ""} left';
  }
}

class _VerificationCard extends StatelessWidget {
  const _VerificationCard({required this.chore, required this.onApprove, required this.onReject});
  final Map<String, dynamic> chore;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final name = chore['title'] ?? 'Untitled Chore';
    final points = chore['point_value'] ?? 5;
    final assignee = chore['assignee'] as Map<String, dynamic>?;
    final completedBy = assignee?['display_name'] ?? 'Someone';

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ChoreDetailScreen(choreId: chore['id']),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(name, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                  ),
                  Text('+$points pts', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppColors.honeyGold)),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Completed by $completedBy',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onReject,
                      icon: const Icon(Icons.close_rounded, size: 18),
                      label: const Text('Reject'),
                      style: OutlinedButton.styleFrom(foregroundColor: AppColors.coral),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: onApprove,
                      icon: const Icon(Icons.check_rounded, size: 18),
                      label: const Text('Approve'),
                      style: FilledButton.styleFrom(backgroundColor: AppColors.grassGreen),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddChoreSheet extends StatefulWidget {
  const _AddChoreSheet({required this.householdId, required this.myMemberId});
  final String householdId;
  final String myMemberId;

  @override
  State<_AddChoreSheet> createState() => _AddChoreSheetState();
}

class _AddChoreSheetState extends State<_AddChoreSheet> {
  final _titleController = TextEditingController();
  String? _selectedAssigneeId;
  String _selectedDifficulty = 'easy';
  int _pointValue = 5;
  DateTime? _dueDate;
  bool _isLoading = false;

  List<Map<String, dynamic>> _templates = [];
  List<Map<String, dynamic>> _members = [];

  @override
  void initState() {
    super.initState();
    _loadOptions();
  }

  Future<void> _loadOptions() async {
    try {
      // Load system templates + household-specific templates
      final templates = await Supabase.instance.client
          .from('chore_templates')
          .select()
          .or('household_id.is.null,household_id.eq.${widget.householdId}')
          .order('room_or_category');

      final members = await Supabase.instance.client
          .from('household_members')
          .select()
          .eq('household_id', widget.householdId);

      setState(() {
        _templates = List<Map<String, dynamic>>.from(templates);
        _members = List<Map<String, dynamic>>.from(members);
      });
    } catch (_) {}
  }

  Future<void> _createChore() async {
    if (_titleController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a chore title.')),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      await Supabase.instance.client.from('chores').insert({
        'household_id': widget.householdId,
        'title': _titleController.text.trim(),
        'assigned_to_member_id': _selectedAssigneeId,
        'created_by_member_id': widget.myMemberId,
        'difficulty': _selectedDifficulty,
        'point_value': _pointValue,
        'due_at': _dueDate?.toIso8601String(),
        'status': 'assigned',
      });

      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not create chore. Please try again.')),
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
            Text('Add a Chore', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
            const SizedBox(height: 20),

            // Quick template selection
            if (_templates.isNotEmpty) ...[
              Text('Quick template', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              SizedBox(
                height: 44,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _templates.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, i) {
                    final t = _templates[i];
                    return ChoiceChip(
                      label: Text(t['title'] ?? '', style: const TextStyle(fontSize: 12)),
                      selected: _titleController.text == t['title'],
                      onSelected: (_) {
                        setState(() {
                          _titleController.text = t['title'] ?? '';
                          _pointValue = t['suggested_points'] ?? 5;
                          _selectedDifficulty = t['difficulty'] ?? 'easy';
                        });
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Custom title
            TextFormField(
              controller: _titleController,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Chore title',
                prefixIcon: Icon(Icons.edit_note_rounded),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),

            // Assign to
            DropdownButtonFormField<String>(
              value: _selectedAssigneeId,
              decoration: const InputDecoration(
                labelText: 'Assign to',
                prefixIcon: Icon(Icons.person_outline_rounded),
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem(value: null, child: Text('Unassigned')),
                ..._members.map((m) => DropdownMenuItem(
                  value: m['id'],
                  child: Row(
                    children: [
                      if (m['kind'] == 'child') const Text('👶 ', style: TextStyle(fontSize: 14)),
                      Text(m['display_name'] ?? 'Unknown'),
                    ],
                  ),
                )),
              ],
              onChanged: (v) => setState(() => _selectedAssigneeId = v),
            ),
            const SizedBox(height: 16),

            // Difficulty & Points
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _selectedDifficulty,
                    decoration: const InputDecoration(
                      labelText: 'Difficulty',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'easy', child: Text('🟢 Easy')),
                      DropdownMenuItem(value: 'medium', child: Text('🟡 Medium')),
                      DropdownMenuItem(value: 'hard', child: Text('🔴 Hard')),
                    ],
                    onChanged: (v) {
                      setState(() {
                        _selectedDifficulty = v ?? 'easy';
                        _pointValue = switch (_selectedDifficulty) {
                          'hard' => 15,
                          'medium' => 10,
                          _ => 5,
                        };
                      });
                    },
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextFormField(
                    initialValue: '$_pointValue',
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Points',
                      prefixIcon: Icon(Icons.star_outline_rounded),
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) => _pointValue = int.tryParse(v) ?? 5,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

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
              icon: Icon(Icons.calendar_today_rounded, size: 18),
              label: Text(_dueDate != null ? 'Due: ${_dueDate!.month}/${_dueDate!.day}' : 'Set due date (optional)'),
            ),
            const SizedBox(height: 24),

            FilledButton(
              onPressed: _isLoading ? null : _createChore,
              child: _isLoading
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Create chore'),
            ),
          ],
        ),
      ),
    );
  }
}