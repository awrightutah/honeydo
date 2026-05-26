import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:image_picker/image_picker.dart';
import '../theme/app_theme.dart';
import '../services/image_upload_service.dart';
import '../services/active_member_service.dart';
import '../utils/membership.dart';
import '../utils/music_apps.dart';
import '../utils/music_launcher.dart';
import '../utils/permissions.dart';

/// Profile screen for managing display name, avatar, and viewing member details.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  Map<String, dynamic>? _profile;
  Map<String, dynamic>? _membership;
  Map<String, dynamic>? _household;
  bool _isLoading = true;
  bool _isEditing = false;

  final _displayNameController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _loadData();
    // Batch 8 — when the active member switches (admin -> kid or vice versa)
    // the profile contents need to reload so the Music section appears or
    // disappears against the new perspective.
    ActiveMemberService.instance.activeMemberId
        .addListener(_onActiveMemberChanged);
  }

  @override
  void dispose() {
    ActiveMemberService.instance.activeMemberId
        .removeListener(_onActiveMemberChanged);
    _displayNameController.dispose();
    super.dispose();
  }

  void _onActiveMemberChanged() {
    if (mounted) _loadData();
  }

  Future<void> _loadData() async {
    try {
      final user = Supabase.instance.client.auth.currentUser!;

      // Load profile
      final profile = await Supabase.instance.client
          .from('profiles')
          .select()
          .eq('id', user.id)
          .single();

      // Batch 8 — MembershipHelper resolves to the active kid sub_profile when
      // one is selected. Without this, a kid session falls back to the parent
      // admin's row and the kid Music section never renders.
      final membership = await MembershipHelper.loadActiveMembership(
        includeHouseholdJoin: true,
      );
      if (membership != null) {
        _membership = membership;
        _household = membership['households'];
      }

      _profile = profile;
      _displayNameController.text = _membership?['display_name'] ?? profile['display_name'] ?? '';
    } catch (e) {
      debugPrint('profile load failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading profile: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ─── Batch 8: kid music app deep link ───────────────────────────────────
  //
  // The launch + picker helpers were extracted to `utils/music_launcher.dart`
  // and `widgets/music_picker_sheet.dart` during Batch 8.1 so the same logic
  // could power the chore_dashboard floating shortcut. This screen still owns
  // the local "playMusic" orchestration (null-preference → prompt + auto-open
  // picker) and the row UI; the heavy lifting is shared.

  Future<void> _playMusic() async {
    final info = MusicAppInfo.fromDbValue(
      _membership?['music_app_preference'] as String?,
    );
    if (info == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose your music app first')),
      );
      await _pickMusicApp();
      return;
    }
    await launchMusicApp(context, info);
  }

  Future<void> _pickMusicApp() async {
    final memberId = _membership?['id'] as String?;
    if (memberId == null) return;
    final picked = await pickAndSaveMusicApp(context, memberId: memberId);
    if (picked == null || !mounted) return;
    setState(() {
      _membership = {
        ..._membership!,
        'music_app_preference': picked.dbValue,
      };
    });
  }

  Future<void> _saveDisplayName() async {
    if (!_formKey.currentState!.validate()) return;

    try {
      final newName = _displayNameController.text.trim();
      
      // Update household_members display name
      if (_membership != null) {
        await Supabase.instance.client
            .from('household_members')
            .update({'display_name': newName})
            .eq('id', _membership!['id']);
      }

      // Also update the profiles table
      final user = Supabase.instance.client.auth.currentUser!;
      await Supabase.instance.client
          .from('profiles')
          .update({'display_name': newName})
          .eq('id', user.id);

      if (mounted) {
        setState(() {
          _isEditing = false;
          if (_membership != null) _membership!['display_name'] = newName;
          if (_profile != null) _profile!['display_name'] = newName;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Display name updated!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error updating name: $e')),
        );
      }
    }
  }

  Future<void> _updateAvatar() async {
    try {
      final source = await ImageUploadService.showImageSourceDialog(context);
      if (source == null) return; // User cancelled

      final imageUrl = await ImageUploadService.uploadAvatar(
        source: source == 'camera' ? ImageSource.camera : ImageSource.gallery,
      );

      if (imageUrl != null) {
        // Update the avatar_url on the membership record
        await Supabase.instance.client
            .from('household_members')
            .update({'avatar_url': imageUrl})
            .eq('id', _membership!['id']);

        // Also update on profiles table
        await Supabase.instance.client
            .from('profiles')
            .update({'avatar_url': imageUrl})
            .eq('id', Supabase.instance.client.auth.currentUser!.id);

        await _loadData();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Profile photo updated!')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error uploading photo: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Profile', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          if (!_isEditing)
            IconButton(
              icon: const Icon(Icons.edit_rounded),
              onPressed: () => setState(() => _isEditing = true),
              tooltip: 'Edit profile',
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadData,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(20),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Avatar section
                      Center(
                        child: GestureDetector(
                          onTap: _updateAvatar,
                          child: Stack(
                            children: [
                              CircleAvatar(
                                radius: 56,
                                backgroundColor: AppColors.honeyGold.withOpacity(.15),
                                backgroundImage: _membership?['avatar_url'] != null
                                    ? NetworkImage(_membership!['avatar_url'])
                                    : null,
                                child: _membership?['avatar_url'] == null
                                    ? Text(
                                        (_membership?['display_name'] as String?)?.isNotEmpty == true
                                            ? (_membership!['display_name'] as String).substring(0, 1).toUpperCase()
                                            : '?',
                                        style: const TextStyle(
                                          fontSize: 36,
                                          fontWeight: FontWeight.w900,
                                          color: AppColors.honeyGold,
                                        ),
                                      )
                                    : null,
                              ),
                              Positioned(
                                bottom: 0,
                                right: 0,
                                child: Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: AppColors.honeyGold,
                                    shape: BoxShape.circle,
                                    border: Border.all(color: Colors.white, width: 2),
                                  ),
                                  child: const Icon(Icons.camera_alt_rounded, size: 16, color: Colors.white),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Display name
                      if (_isEditing) ...[
                        TextFormField(
                          controller: _displayNameController,
                          decoration: InputDecoration(
                            labelText: 'Display Name',
                            prefixIcon: const Icon(Icons.badge_rounded),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
                          ),
                          validator: (v) => (v == null || v.trim().isEmpty) ? 'Name required' : null,
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () {
                                  _displayNameController.text = _membership?['display_name'] ?? '';
                                  setState(() => _isEditing = false);
                                },
                                style: OutlinedButton.styleFrom(
                                  minimumSize: const Size.fromHeight(48),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                ),
                                child: const Text('Cancel'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: FilledButton(
                                onPressed: _saveDisplayName,
                                style: FilledButton.styleFrom(
                                  minimumSize: const Size.fromHeight(48),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                ),
                                child: const Text('Save'),
                              ),
                            ),
                          ],
                        ),
                      ] else ...[
                        _sectionCard(
                          icon: Icons.badge_rounded,
                          title: 'Display Name',
                          value: _membership?['display_name'] ?? 'Not set',
                        ),
                      ],
                      const SizedBox(height: 16),

                      // Account info
                      Text('ACCOUNT', style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.2,
                      )),
                      const SizedBox(height: 8),
                      _sectionCard(
                        icon: Icons.email_rounded,
                        title: 'Email',
                        value: _profile?['email'] ?? Supabase.instance.client.auth.currentUser?.email ?? 'Not set',
                      ),
                      const SizedBox(height: 8),
                      _sectionCard(
                        icon: Icons.calendar_today_rounded,
                        title: 'Member Since',
                        value: _formatDate(_membership?['created_at']),
                      ),
                      const SizedBox(height: 24),

                      // Household info
                      Text('HOUSEHOLD', style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.2,
                      )),
                      const SizedBox(height: 8),
                      if (_household != null) ...[
                        _sectionCard(
                          icon: Icons.home_rounded,
                          title: 'Household',
                          value: '${_household!['emoji'] ?? ''} ${_household!['name'] ?? 'Unnamed'}'.trim(),
                        ),
                        const SizedBox(height: 8),
                        _sectionCard(
                          icon: Icons.shield_rounded,
                          title: 'Role',
                          value: _formatRole(_membership?['role']),
                        ),
                        const SizedBox(height: 8),
                        _sectionCard(
                          icon: Icons.category_rounded,
                          title: 'Account Type',
                          value: _membership?['kind'] == 'sub_profile' ? 'Kid Profile' : 'Adult Account',
                        ),
                      ] else
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              'Not part of a household yet.',
                              style: TextStyle(color: Colors.grey.shade600),
                            ),
                          ),
                        ),
                      const SizedBox(height: 24),

                      // Batch 8 — Music section. Only shown when the active
                      // member is a kid sub_profile; adults don't get the
                      // launcher UI on their own profile.
                      if (Permissions.isKid(_membership)) ...[
                        Text('MUSIC', style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.2,
                        )),
                        const SizedBox(height: 8),
                        _musicAppRow(),
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          onPressed: _playMusic,
                          icon: const Text('🎵', style: TextStyle(fontSize: 18)),
                          label: const Text('Play Music'),
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.honeyGold,
                            minimumSize: const Size.fromHeight(48),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                      ],

                      // Gamification stats
                      Text('STATS', style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.2,
                      )),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: _statCard(
                              icon: Icons.star_rounded,
                              label: 'Points',
                              value: '${_membership?['points_balance'] ?? 0}',
                              color: AppColors.honeyGold,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _statCard(
                              icon: Icons.local_fire_department_rounded,
                              label: 'Streak',
                              value: '${_membership?['current_streak'] ?? 0}',
                              color: AppColors.coral,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  /// Batch 8 — tappable row showing the kid's current music app pick (or
  /// "Not set yet"). Tap opens the picker bottom sheet.
  Widget _musicAppRow() {
    final info = MusicAppInfo.fromDbValue(
      _membership?['music_app_preference'] as String?,
    );
    return Card(
      child: InkWell(
        onTap: _pickMusicApp,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Text(
                info?.emoji ?? '🎵',
                style: const TextStyle(fontSize: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Music app',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      info?.label ?? 'Not set yet — tap to choose',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded,
                  color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionCard({required IconData icon, required String title, required String value}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, size: 22, color: AppColors.skyBlue),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(fontSize: 12, color: Colors.grey.shade600, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statCard({required IconData icon, required String label, required String value, required Color color}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Icon(icon, size: 28, color: color),
            const SizedBox(height: 8),
            Text(value, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: color)),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(fontSize: 12, color: Colors.grey.shade600, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  String _formatDate(String? isoDate) {
    if (isoDate == null) return 'Unknown';
    try {
      final dt = DateTime.parse(isoDate);
      return '${dt.month}/${dt.day}/${dt.year}';
    } catch (_) {
      return 'Unknown';
    }
  }

  String _formatRole(String? role) {
    switch (role) {
      case 'owner':
        return '👑 Owner';
      case 'admin':
        return '🛡️ Admin';
      case 'member':
        return '👤 Member';
      default:
        return role ?? 'Unknown';
    }
  }
}
