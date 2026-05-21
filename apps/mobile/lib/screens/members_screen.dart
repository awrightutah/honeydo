import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../theme/app_theme.dart';
import 'member_profile_screen.dart';

/// Screen for managing household members: adding sub-profiles (kids),
/// inviting adults, and managing existing members.
class MembersScreen extends StatefulWidget {
  const MembersScreen({super.key});

  @override
  State<MembersScreen> createState() => _MembersScreenState();
}

class _MembersScreenState extends State<MembersScreen> {
  List<Map<String, dynamic>> _members = [];
  Map<String, dynamic>? _household;
  Map<String, dynamic>? _myMembership;
  bool _isLoading = true;
  String? _inviteCode;

  @override
  void initState() {
    super.initState();
    _loadData();
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

      if (memberships.isEmpty) return;

      _myMembership = memberships[0];
      _household = memberships[0]['households'];

      final members = await Supabase.instance.client
          .from('household_members')
          .select()
          .eq('household_id', _household!['id'])
          .eq('is_active', true)
          .order('created_at');

      setState(() {
        _members = List<Map<String, dynamic>>.from(members);
        _isLoading = false;
      });
    } catch (_) {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _generateInviteCode() async {
    setState(() => _isLoading = true);

    try {
      final response = await Supabase.instance.client.functions.invoke(
        'generate-invite',
        body: {'household_id': _household!['id']},
      );

      // Fallback: create invite directly
      final user = Supabase.instance.client.auth.currentUser!;
      final existingInvites = await Supabase.instance.client
          .from('household_invites')
          .select()
          .eq('household_id', _household!['id'])
          .isFilter('revoked_at', null)
          .gt('expires_at', DateTime.now().toIso8601String())
          .limit(1);

      if (existingInvites.isNotEmpty) {
        setState(() {
          _inviteCode = existingInvites[0]['code'];
          _isLoading = false;
        });
        return;
      }

      // Generate a new code
      final code = _generateCode();
      await Supabase.instance.client.from('household_invites').insert({
        'household_id': _household!['id'],
        'code': code,
        'max_uses': 5,
        'use_count': 0,
        'created_by': user.id,
        'expires_at': DateTime.now().add(const Duration(days: 7)).toIso8601String(),
      });

      setState(() {
        _inviteCode = code;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not generate invite code.')),
        );
      }
    }
  }

  String _generateCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // No ambiguous chars
    final buffer = StringBuffer();
    for (int i = 0; i < 6; i++) {
      buffer.write(chars[DateTime.now().microsecond % chars.length]);
    }
    return buffer.toString();
  }

  void _showAddSubProfileSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => _AddSubProfileSheet(
        householdId: _household!['id'],
        adminMemberId: _myMembership!['id'],
      ),
    ).then((_) => _loadData());
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = _myMembership?['role'] == 'admin';
    final adultCount = _members.where((m) => m['kind'] == 'adult_auth_user').length;
    final childCount = _members.where((m) => m['kind'] == 'sub_profile').length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Household Members 👥'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadData,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // Stats
                  Row(
                    children: [
                      Expanded(
                        child: _StatCard(
                          title: 'Adults',
                          value: '$adultCount',
                          icon: Icons.person_rounded,
                          color: AppColors.skyBlue,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _StatCard(
                          title: 'Kids',
                          value: '$childCount',
                          icon: Icons.child_care_rounded,
                          color: AppColors.honeyGold,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _StatCard(
                          title: 'Total',
                          value: '${_members.length}/6',
                          icon: Icons.groups_rounded,
                          color: AppColors.grassGreen,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // Members list
                  Text('Members', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 12),
                  ..._members.map((member) => _MemberCard(
                        member: member,
                        isCurrentUser: member['auth_user_id'] == Supabase.instance.client.auth.currentUser?.id,
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => MemberProfileScreen(memberId: member['id'])),
                        ),
                      )),

                  const SizedBox(height: 24),

                  // Invite code section (admin only)
                  if (isAdmin) ...[
                    Text('Invite Others', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 12),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.mail_outline_rounded, color: AppColors.skyBlue),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text('Invite Code', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                                      Text('Share this code so others can join your household.', style: Theme.of(context).textTheme.bodySmall),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            if (_inviteCode != null)
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: AppColors.skyBlue.withOpacity(.1),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: AppColors.skyBlue.withOpacity(.3)),
                                ),
                                child: Column(
                                  children: [
                                    Text(
                                      _inviteCode!,
                                      style: const TextStyle(
                                        fontSize: 28,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: 6,
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text('Expires in 7 days', style: Theme.of(context).textTheme.bodySmall),
                                  ],
                                ),
                              )
                            else
                              Text(
                                'Generate an invite code to let others join your household.',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            const SizedBox(height: 16),
                            FilledButton.icon(
                              onPressed: _generateInviteCode,
                              icon: const Icon(Icons.vpn_key_rounded, size: 18),
                              label: Text(_inviteCode != null ? 'Get new code' : 'Generate invite code'),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Add kid profile
                    Text('Kid Profiles', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    Text(
                      'Kid profiles are COPPA-safe — no email or personal data is collected. '
                      'Kids access the app using a simple PIN under the adult\'s account.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _members.length < 6 ? _showAddSubProfileSheet : null,
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Add kid profile'),
                    ),
                  ],
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
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 6),
            Text(value, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900)),
            Text(title, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

class _MemberCard extends StatelessWidget {
  const _MemberCard({required this.member, required this.isCurrentUser, required this.onTap});
  final Map<String, dynamic> member;
  final bool isCurrentUser;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final name = member['display_name'] ?? 'Unknown';
    final role = member['role'] ?? 'member';
    final kind = member['kind'] ?? 'adult_auth_user';
    final points = member['points_balance'] ?? 0;
    final isKid = kind == 'sub_profile';

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: isKid ? AppColors.honeyGold.withOpacity(.2) : AppColors.skyBlue.withOpacity(.2),
          child: Text(
            isKid ? '👶' : '👤',
            style: const TextStyle(fontSize: 22),
          ),
        ),
        title: Row(
          children: [
            Flexible(child: Text(name, style: const TextStyle(fontWeight: FontWeight.w700))),
            if (isCurrentUser) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.grassGreen.withOpacity(.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text('You', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.grassGreen)),
              ),
            ],
          ],
        ),
        subtitle: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: role == 'admin' ? AppColors.coral.withOpacity(.15) : Colors.grey.withOpacity(.1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                isKid ? 'Kid' : role == 'admin' ? 'Admin' : 'Member',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: role == 'admin' ? AppColors.coral : Colors.grey.shade700,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.star_rounded, size: 14, color: AppColors.honeyGold),
            const SizedBox(width: 2),
            Text('$points pts', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        trailing: isKid
            ? Icon(Icons.lock_outline_rounded, size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant)
            : null,
      ),
    );
  }
}

class _AddSubProfileSheet extends StatefulWidget {
  const _AddSubProfileSheet({required this.householdId, required this.adminMemberId});
  final String householdId;
  final String adminMemberId;

  @override
  State<_AddSubProfileSheet> createState() => _AddSubProfileSheetState();
}

class _AddSubProfileSheetState extends State<_AddSubProfileSheet> {
  final _nameController = TextEditingController();
  final _pinController = TextEditingController();
  final _confirmPinController = TextEditingController();
  bool _obscurePin = true;
  bool _isLoading = false;

  @override
  void dispose() {
    _nameController.dispose();
    _pinController.dispose();
    _confirmPinController.dispose();
    super.dispose();
  }

  Future<void> _createSubProfile() async {
    final name = _nameController.text.trim();
    final pin = _pinController.text.trim();
    final confirmPin = _confirmPinController.text.trim();

    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter a display name.')));
      return;
    }
    if (pin.length < 4) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PIN must be at least 4 digits.')));
      return;
    }
    if (pin != confirmPin) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PINs do not match.')));
      return;
    }

    setState(() => _isLoading = true);

    try {
      // SECURITY DEBT (CQ2 in audits/2026-05-pass-1a-flutter-v3.md):
      // SHA-256 with no salt over a 4-6 digit PIN is recoverable in under
      // one second via a complete rainbow table (key space <= 10^6). Anyone
      // with SELECT access to `pin_hash` can recover every kid PIN.
      // Proper fix: move verification to a server-side Postgres function
      // using pgcrypto (`crypt(pin, gen_salt('bf'))` or scrypt) with a
      // per-row salt, and revoke client SELECT on the `pin_hash` column.
      final bytes = utf8.encode(pin);
      final pinHash = sha256.convert(bytes).toString();
      await Supabase.instance.client.from('household_members').insert({
        'household_id': widget.householdId,
        'kind': 'sub_profile',
        'role': 'member',
        'display_name': name,
        'pin_hash': pinHash,
        'points_balance': 0,
        'is_active': true,
        'created_by': Supabase.instance.client.auth.currentUser!.id,
      });

      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not create kid profile. Please try again.')),
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
            Text('Add Kid Profile 👶', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.grassGreen.withOpacity(.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.shield_rounded, color: AppColors.grassGreen, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'COPPA-safe: No email or personal data is collected for kid profiles. '
                      'They sign in with a simple PIN under your account.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.grassGreen),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            TextFormField(
              controller: _nameController,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Display name',
                prefixIcon: Icon(Icons.face_rounded),
                border: OutlineInputBorder(),
                hintText: 'e.g., Emma',
              ),
            ),
            const SizedBox(height: 16),

            TextFormField(
              controller: _pinController,
              obscureText: _obscurePin,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: InputDecoration(
                labelText: 'Create a PIN',
                prefixIcon: const Icon(Icons.lock_outline_rounded),
                border: const OutlineInputBorder(),
                counterText: '',
                suffixIcon: IconButton(
                  icon: Icon(_obscurePin ? Icons.visibility_off_rounded : Icons.visibility_rounded),
                  onPressed: () => setState(() => _obscurePin = !_obscurePin),
                ),
                hintText: '4-6 digits',
              ),
            ),
            const SizedBox(height: 16),

            TextFormField(
              controller: _confirmPinController,
              obscureText: _obscurePin,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: const InputDecoration(
                labelText: 'Confirm PIN',
                prefixIcon: Icon(Icons.lock_outline_rounded),
                border: OutlineInputBorder(),
                counterText: '',
              ),
            ),
            const SizedBox(height: 24),

            FilledButton(
              onPressed: _isLoading ? null : _createSubProfile,
              child: _isLoading
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Create kid profile'),
            ),
          ],
        ),
      ),
    );
  }
}