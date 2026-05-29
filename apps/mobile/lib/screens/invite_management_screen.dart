import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/active_member_service.dart';
import '../shared/utils/invite_code.dart';
import '../theme/app_theme.dart';
import '../utils/membership.dart';
import '../utils/permissions.dart';

class InviteManagementScreen extends StatefulWidget {
  const InviteManagementScreen({super.key});

  @override
  State<InviteManagementScreen> createState() => _InviteManagementScreenState();
}

class _InviteManagementScreenState extends State<InviteManagementScreen> {
  List<Map<String, dynamic>> _invites = [];
  Map<String, dynamic>? _household;
  Map<String, dynamic>? _myMembership;
  bool _isLoading = true;

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
    super.dispose();
  }

  void _onActiveMemberChanged() {
    if (mounted) _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);

    try {
      // Batch 7a-ii — MembershipHelper so `_isAdmin` reflects the active
      // member's role. Pre-fix, a kid session saw `_isAdmin = true` because
      // `_myMembership` coerced to the parent admin's row; the kid-facing UI
      // would then show the "Generate Invite" FAB. RLS catches actual write
      // attempts, but the misleading UI is what this migration corrects.
      final membership = await MembershipHelper.loadActiveMembership(
        includeHouseholdJoin: true,
      );
      if (membership != null) {
        _myMembership = membership;
        _household = membership['households'];
      }

      if (_household != null) {
        final invites = await Supabase.instance.client
            .from('household_invites')
            .select()
            .eq('household_id', _household!['id'])
            .order('created_at', ascending: false);

        setState(() => _invites = List<Map<String, dynamic>>.from(invites));
      }
    } catch (e) {
      debugPrint('invite_management load failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not load invites: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  bool get _isAdmin => Permissions.canInviteMembers(_myMembership);

  Future<void> _createInvite() async {
    if (_household == null) return;

    int maxUses = 1;
    int expiryDays = 7;

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => _CreateInviteDialog(),
    );

    if (result == null || !mounted) return;

    maxUses = result['max_uses'] ?? 1;
    expiryDays = result['expiry_days'] ?? 7;

    try {
      // Generate a random 6-character code
      final code = generateInviteCode();
      final expiresAt = DateTime.now().add(Duration(days: expiryDays));

      // Get the profile id for created_by
      final user = Supabase.instance.client.auth.currentUser!;
      final profile = await Supabase.instance.client
          .from('profiles')
          .select('id')
          .eq('id', user.id)
          .single();

      await Supabase.instance.client.from('household_invites').insert({
        'household_id': _household!['id'],
        'code': code,
        'expires_at': expiresAt.toIso8601String(),
        'max_uses': maxUses,
        'use_count': 0,
        'created_by': profile['id'],
      });

      _loadData();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not create invite code.')),
        );
      }
    }
  }

  Future<void> _revokeInvite(Map<String, dynamic> invite) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Revoke Invite?'),
        content: Text('This will deactivate invite code "${invite['code']}". Anyone with this code will no longer be able to join.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.coral),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await Supabase.instance.client
          .from('household_invites')
          .update({'revoked_at': DateTime.now().toIso8601String()})
          .eq('id', invite['id']);

      _loadData();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not revoke invite.')),
        );
      }
    }
  }

  void _copyInviteCode(String code) {
    Clipboard.setData(ClipboardData(text: code));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Invite code copied!'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _shareInviteCode(String code) {
    final householdName = _household?['name'] ?? 'Clanquility';
    final text = 'Join my household "$householdName" on Clanquility! 🐝\n\nInvite code: $code\n\nDownload Clanquility and enter this code to join.';

    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Invite message copied to clipboard!'),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.grassGreen,
        duration: const Duration(seconds: 3),
        action: SnackBarAction(
          label: 'Got it',
          textColor: Colors.white,
          onPressed: () {},
        ),
      ),
    );
  }

  bool _isExpired(Map<String, dynamic> invite) {
    final expiresAt = invite['expires_at'];
    if (expiresAt == null) return false;
    return DateTime.tryParse(expiresAt)?.isBefore(DateTime.now()) ?? false;
  }

  bool _isRevoked(Map<String, dynamic> invite) {
    return invite['revoked_at'] != null;
  }

  bool _isExhausted(Map<String, dynamic> invite) {
    final maxUses = invite['max_uses'] ?? 1;
    final useCount = invite['use_count'] ?? 0;
    return useCount >= maxUses;
  }

  bool _isActive(Map<String, dynamic> invite) {
    return !_isExpired(invite) && !_isRevoked(invite) && !_isExhausted(invite);
  }

  @override
  Widget build(BuildContext context) {
    final activeInvites = _invites.where(_isActive).toList();
    final inactiveInvites = _invites.where((i) => !_isActive(i)).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Invite Codes', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadData,
              child: CustomScrollView(
                slivers: [
                  // Header card
                  SliverToBoxAdapter(
                    child: Container(
                      margin: const EdgeInsets.all(16),
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [AppColors.honeyGold, Color(0xFFE8941A)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.honeyGold.withValues(alpha:.3),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.card_giftcard_rounded, color: Colors.white, size: 28),
                              SizedBox(width: 12),
                              Text(
                                'Invite Family Members',
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 18,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'Share an invite code with family members so they can join your household. Each code can be used a limited number of times.',
                            style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
                          ),
                          if (activeInvites.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            ...activeInvites.map((invite) => _ActiveInviteCard(
                              invite: invite,
                              onCopy: () => _copyInviteCode(invite['code']),
                              onShare: () => _shareInviteCode(invite['code']),
                              onRevoke: () => _revokeInvite(invite),
                            )),
                          ],
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: _createInvite,
                            icon: const Icon(Icons.add_rounded),
                            label: const Text('Create New Invite Code'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: const BorderSide(color: Colors.white54),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Active invites count
                  if (activeInvites.isNotEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            const Icon(Icons.check_circle_rounded, color: AppColors.grassGreen, size: 18),
                            const SizedBox(width: 8),
                            Text(
                              '${activeInvites.length} active invite${activeInvites.length != 1 ? 's' : ''}',
                              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                            ),
                          ],
                        ),
                      ),
                    ),

                  // Active invite list
                  if (activeInvites.isNotEmpty)
                    SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) => _InviteListCard(
                          invite: activeInvites[index],
                          isActive: true,
                          onRevoke: () => _revokeInvite(activeInvites[index]),
                          onCopy: () => _copyInviteCode(activeInvites[index]['code']),
                        ),
                        childCount: activeInvites.length,
                      ),
                    ),

                  // Inactive section
                  if (inactiveInvites.isNotEmpty) ...[
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 16, right: 16, top: 24, bottom: 8),
                        child: Row(
                          children: [
                            Icon(Icons.history_rounded, color: Colors.grey.shade500, size: 18),
                            const SizedBox(width: 8),
                            Text(
                              'Expired & Revoked',
                              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: Colors.grey.shade600),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) => _InviteListCard(
                          invite: inactiveInvites[index],
                          isActive: false,
                          onRevoke: null,
                          onCopy: null,
                        ),
                        childCount: inactiveInvites.length,
                      ),
                    ),
                  ],

                  // Empty state
                  if (_invites.isEmpty)
                    SliverToBoxAdapter(
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 60),
                          child: Column(
                            children: [
                              Icon(Icons.mail_outline_rounded, size: 64, color: Colors.grey.shade300),
                              const SizedBox(height: 16),
                              Text(
                                'No invite codes yet',
                                style: TextStyle(fontSize: 16, color: Colors.grey.shade500, fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Create an invite code to let family\nmembers join your household.',
                                style: TextStyle(fontSize: 13, color: Colors.grey.shade400),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 24),
                              FilledButton.icon(
                                onPressed: _createInvite,
                                icon: const Icon(Icons.add_rounded),
                                label: const Text('Create Invite Code'),
                                style: FilledButton.styleFrom(
                                  backgroundColor: AppColors.honeyGold,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                  const SliverPadding(padding: EdgeInsets.only(bottom: 80)),
                ],
              ),
            ),
      floatingActionButton: _isAdmin
          ? FloatingActionButton.extended(
              onPressed: _createInvite,
              icon: const Icon(Icons.add_rounded),
              label: const Text('New Invite'),
              backgroundColor: AppColors.honeyGold,
              foregroundColor: Colors.white,
            )
          : null,
    );
  }
}

class _ActiveInviteCard extends StatelessWidget {
  final Map<String, dynamic> invite;
  final VoidCallback onCopy;
  final VoidCallback onShare;
  final VoidCallback onRevoke;

  const _ActiveInviteCard({
    required this.invite,
    required this.onCopy,
    required this.onShare,
    required this.onRevoke,
  });

  @override
  Widget build(BuildContext context) {
    final code = invite['code'] ?? '';
    final maxUses = invite['max_uses'] ?? 1;
    final useCount = invite['use_count'] ?? 0;
    final remaining = maxUses - useCount;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha:.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Code display
          Row(
            children: [
              Expanded(
                child: Text(
                  code,
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                    letterSpacing: 4,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy_rounded, color: Colors.white70, size: 20),
                onPressed: onCopy,
                tooltip: 'Copy code',
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Usage info
          Row(
            children: [
              Icon(Icons.people_outline_rounded, size: 14, color: Colors.white70),
              const SizedBox(width: 4),
              Text(
                '$useCount of $maxUses used',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(width: 12),
              if (remaining > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.green.shade700,
                    borderRadius: BorderRadius.circular(100),
                  ),
                  child: Text(
                    '$remaining remaining',
                    style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700),
                  ),
                ),
              const Spacer(),
              TextButton.icon(
                onPressed: onShare,
                icon: const Icon(Icons.share_rounded, size: 16),
                label: const Text('Share'),
                style: TextButton.styleFrom(foregroundColor: Colors.white, padding: EdgeInsets.zero),
              ),
            ],
          ),
          // Expiry
          if (invite['expires_at'] != null) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.schedule_rounded, size: 14, color: Colors.white60),
                const SizedBox(width: 4),
                Text(
                  _formatExpiry(invite['expires_at']),
                  style: const TextStyle(color: Colors.white60, fontSize: 11),
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          // Revoke button
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: onRevoke,
              style: TextButton.styleFrom(foregroundColor: Colors.red.shade200, padding: EdgeInsets.zero),
              child: const Text('Revoke', style: TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }

  String _formatExpiry(String? expiresAt) {
    if (expiresAt == null) return '';
    final dt = DateTime.tryParse(expiresAt);
    if (dt == null) return '';
    final diff = dt.difference(DateTime.now());
    if (diff.isNegative) return 'Expired';
    if (diff.inDays == 0) return 'Expires today';
    if (diff.inDays == 1) return 'Expires tomorrow';
    return 'Expires in ${diff.inDays} days';
  }
}

class _InviteListCard extends StatelessWidget {
  final Map<String, dynamic> invite;
  final bool isActive;
  final VoidCallback? onRevoke;
  final VoidCallback? onCopy;

  const _InviteListCard({
    required this.invite,
    required this.isActive,
    this.onRevoke,
    this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    final code = invite['code'] ?? '';
    final maxUses = invite['max_uses'] ?? 1;
    final useCount = invite['use_count'] ?? 0;
    final isRevoked = invite['revoked_at'] != null;

    final expiresAt = invite['expires_at'];
    final isExpired = expiresAt != null && DateTime.tryParse(expiresAt)?.isBefore(DateTime.now()) == true;
    final isExhausted = useCount >= maxUses;

    String statusLabel;
    Color statusColor;
    IconData statusIcon;

    if (isRevoked) {
      statusLabel = 'Revoked';
      statusColor = AppColors.coral;
      statusIcon = Icons.block_rounded;
    } else if (isExpired) {
      statusLabel = 'Expired';
      statusColor = Colors.grey;
      statusIcon = Icons.schedule_rounded;
    } else if (isExhausted) {
      statusLabel = 'Used up';
      statusColor = Colors.orange;
      statusIcon = Icons.check_circle_outline_rounded;
    } else {
      statusLabel = 'Active';
      statusColor = AppColors.grassGreen;
      statusIcon = Icons.check_circle_rounded;
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: ListTile(
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: statusColor.withValues(alpha:.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(statusIcon, color: statusColor, size: 22),
        ),
        title: Row(
          children: [
            Text(
              code,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                letterSpacing: 2,
                color: isActive ? AppColors.honeyGold : Colors.grey.shade500,
              ),
            ),
            if (onCopy != null)
              IconButton(
                icon: Icon(Icons.copy_rounded, size: 16, color: Colors.grey.shade400),
                onPressed: onCopy,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              ),
          ],
        ),
        subtitle: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha:.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(statusLabel, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: statusColor)),
            ),
            const SizedBox(width: 8),
            Text('$useCount/$maxUses used', style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
          ],
        ),
        trailing: onRevoke != null
            ? IconButton(
                icon: Icon(Icons.delete_outline_rounded, size: 18, color: Colors.grey.shade400),
                onPressed: onRevoke,
              )
            : null,
      ),
    );
  }
}

class _CreateInviteDialog extends StatefulWidget {
  @override
  State<_CreateInviteDialog> createState() => _CreateInviteDialogState();
}

class _CreateInviteDialogState extends State<_CreateInviteDialog> {
  int _maxUses = 5;
  int _expiryDays = 7;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create Invite Code', style: TextStyle(fontWeight: FontWeight.w800)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Generate a shareable invite code for your household.',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 20),

          // Max uses
          Text('Maximum uses: $_maxUses', style: const TextStyle(fontWeight: FontWeight.w700)),
          Slider(
            value: _maxUses.toDouble(),
            min: 1,
            max: 20,
            divisions: 19,
            label: '$_maxUses',
            onChanged: (v) => setState(() => _maxUses = v.round()),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('1', style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
              Text('20', style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
            ],
          ),
          const SizedBox(height: 16),

          // Expiry
          Text('Expires after: $_expiryDays days', style: const TextStyle(fontWeight: FontWeight.w700)),
          Slider(
            value: _expiryDays.toDouble(),
            min: 1,
            max: 30,
            divisions: 29,
            label: '$_expiryDays',
            onChanged: (v) => setState(() => _expiryDays = v.round()),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('1 day', style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
              Text('30 days', style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, {
            'max_uses': _maxUses,
            'expiry_days': _expiryDays,
          }),
          style: FilledButton.styleFrom(backgroundColor: AppColors.honeyGold),
          child: const Text('Create Code'),
        ),
      ],
    );
  }
}
