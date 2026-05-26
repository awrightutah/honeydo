import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/active_member_service.dart';
import '../theme/app_theme.dart';
import '../utils/membership.dart';

/// Feedback screen for submitting feature requests and bug reports.
class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen({super.key});

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  List<Map<String, dynamic>> _feedbackList = [];
  bool _isLoading = true;
  String _selectedType = 'feature_request';

  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _loadFeedback();
    ActiveMemberService.instance.activeMemberId
        .addListener(_onActiveMemberChanged);
  }

  @override
  void dispose() {
    ActiveMemberService.instance.activeMemberId
        .removeListener(_onActiveMemberChanged);
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  void _onActiveMemberChanged() {
    if (mounted) _loadFeedback();
  }

  Future<void> _loadFeedback() async {
    try {
      // Batch 7a-ii — MembershipHelper. The list itself is household-scoped
      // so the legacy pattern would have returned correct rows, but using the
      // helper here keeps the migration consistent with `_submitFeedback`
      // (which needs the active member's id for write attribution).
      final membership = await MembershipHelper.loadActiveMembership();
      if (membership == null) {
        setState(() => _isLoading = false);
        return;
      }

      final householdId = membership['household_id'];

      final data = await Supabase.instance.client
          .from('feedback_requests')
          .select()
          .eq('household_id', householdId)
          .order('created_at', ascending: false);

      _feedbackList = List<Map<String, dynamic>>.from(data);
    } catch (e) {
      debugPrint('feedback load failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading feedback: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _submitFeedback() async {
    if (!_formKey.currentState!.validate()) return;

    try {
      // Batch 7a-ii — write attribution fix. Pre-migration, kid feedback was
      // attributed to the parent admin's `submitted_by_member_id`.
      final membership = await MembershipHelper.loadActiveMembership();
      if (membership == null) return;

      final memberId = membership['id'];
      final householdId = membership['household_id'];

      await Supabase.instance.client.from('feedback_requests').insert({
        'household_id': householdId,
        'submitted_by_member_id': memberId,
        'type': _selectedType,
        'title': _titleController.text.trim(),
        'description': _descriptionController.text.trim().isNotEmpty
            ? _descriptionController.text.trim()
            : null,
        'status': 'new',
      });

      _titleController.clear();
      _descriptionController.clear();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Thank you for your feedback!'),
            backgroundColor: AppColors.grassGreen,
          ),
        );
      }

      await _loadFeedback();
    } catch (e) {
      debugPrint('feedback submit failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error submitting feedback: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Feedback', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadFeedback,
              child: CustomScrollView(
                slivers: [
                  // Submit feedback section
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Share Your Thoughts',
                              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Help us improve Honeydo! Submit feature requests or report bugs.',
                              style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
                            ),
                            const SizedBox(height: 20),

                            // Type selector
                            Row(
                              children: [
                                _typeChip('feature_request', '💡 Feature', Icons.lightbulb_rounded),
                                const SizedBox(width: 8),
                                _typeChip('bug_report', '🐛 Bug', Icons.bug_report_rounded),
                                const SizedBox(width: 8),
                                _typeChip('other', '📝 Other', Icons.more_horiz_rounded),
                              ],
                            ),
                            const SizedBox(height: 16),

                            // Title
                            TextFormField(
                              controller: _titleController,
                              decoration: InputDecoration(
                                labelText: 'Title',
                                hintText: 'Brief summary of your feedback',
                                prefixIcon: const Icon(Icons.title_rounded),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
                              ),
                              validator: (v) => (v == null || v.trim().isEmpty) ? 'Please enter a title' : null,
                            ),
                            const SizedBox(height: 12),

                            // Description
                            TextFormField(
                              controller: _descriptionController,
                              decoration: InputDecoration(
                                labelText: 'Description (optional)',
                                hintText: 'Provide more details...',
                                prefixIcon: const Icon(Icons.description_rounded),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
                              ),
                              maxLines: 3,
                            ),
                            const SizedBox(height: 16),

                            FilledButton(
                              onPressed: _submitFeedback,
                              style: FilledButton.styleFrom(
                                minimumSize: const Size.fromHeight(48),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                              ),
                              child: const Text('Submit Feedback'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // Previous feedback
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                      child: Text(
                        'YOUR SUBMISSIONS',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                  ),

                  _feedbackList.isEmpty
                      ? SliverFillRemaining(
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.feedback_outlined, size: 64, color: Colors.grey.shade300),
                                const SizedBox(height: 16),
                                Text('No feedback submitted yet', style: TextStyle(fontSize: 16, color: Colors.grey.shade500, fontWeight: FontWeight.w600)),
                              ],
                            ),
                          ),
                        )
                      : SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (context, index) {
                              final fb = _feedbackList[index];
                              return _feedbackCard(fb);
                            },
                            childCount: _feedbackList.length,
                          ),
                        ),

                  const SliverPadding(padding: EdgeInsets.only(bottom: 40)),
                ],
              ),
            ),
    );
  }

  Widget _typeChip(String type, String label, IconData icon) {
    final isSelected = _selectedType == type;
    return ChoiceChip(
      avatar: Icon(icon, size: 16, color: isSelected ? Colors.white : AppColors.honeyGold),
      label: Text(label),
      selected: isSelected,
      onSelected: (_) => setState(() => _selectedType = type),
      selectedColor: AppColors.honeyGold,
      labelStyle: TextStyle(
        color: isSelected ? Colors.white : AppColors.charcoal,
        fontWeight: FontWeight.w700,
        fontSize: 12,
      ),
    );
  }

  Widget _feedbackCard(Map<String, dynamic> fb) {
    final statusColors = {
      'new': AppColors.skyBlue,
      'reviewing': AppColors.honeyGold,
      'planned': AppColors.grassGreen,
      'completed': AppColors.grassGreen,
      'declined': AppColors.coral,
    };

    final statusIcons = {
      'new': Icons.fiber_new_rounded,
      'reviewing': Icons.visibility_rounded,
      'planned': Icons.calendar_month_rounded,
      'completed': Icons.check_circle_rounded,
      'declined': Icons.cancel_rounded,
    };

    final color = statusColors[fb['status']] ?? Colors.grey;
    final icon = statusIcons[fb['status']] ?? Icons.help_rounded;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: color),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: color.withOpacity(.1),
                    borderRadius: BorderRadius.circular(100),
                  ),
                  child: Text(
                    (fb['status'] as String).replaceAll('_', ' ').toUpperCase(),
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: color),
                  ),
                ),
                const Spacer(),
                Text(
                  _formatDate(fb['created_at']),
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              fb['title'] ?? '',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
            ),
            if (fb['description'] != null && (fb['description'] as String).isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                fb['description'],
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600, height: 1.4),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (fb['admin_notes'] != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.honeyGold.withOpacity(.05),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.honeyGold.withOpacity(.2)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.admin_panel_settings_rounded, size: 14, color: AppColors.honeyGold),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        fb['admin_notes'],
                        style: const TextStyle(fontSize: 12, color: AppColors.honeyGold, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatDate(String? isoDate) {
    if (isoDate == null) return '';
    try {
      final dt = DateTime.parse(isoDate);
      final now = DateTime.now();
      final diff = now.difference(dt);

      if (diff.inMinutes < 1) return 'Just now';
      if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
      if (diff.inHours < 24) return '${diff.inHours}h ago';
      if (diff.inDays < 7) return '${diff.inDays}d ago';
      return '${dt.month}/${dt.day}/${dt.year}';
    } catch (_) {
      return '';
    }
  }
}
