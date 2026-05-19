import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';

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
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    super.dispose();
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

      // Load membership with household
      final memberships = await Supabase.instance.client
          .from('household_members')
          .select('*, households(*)')
          .eq('auth_user_id', user.id)
          .eq('is_active', true)
          .limit(1);

      if (memberships.isNotEmpty) {
        _membership = memberships[0];
        _household = memberships[0]['households'];
      }

      _profile = profile;
      _displayNameController.text = _membership?['display_name'] ?? profile['display_name'] ?? '';
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading profile: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
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
    // In a full implementation, this would use image_picker to select
    // a photo and upload to Supabase Storage 'avatars' bucket.
    // For now, show a dialog explaining the feature.
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Profile Photo'),
        content: const Text(
          'To upload a profile photo, the app needs the image_picker package and '
          'a configured Supabase Storage bucket. This will be available in a future update.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
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
