import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../utils/permissions.dart';

/// Screen for managing household announcements/pinned messages.
/// Admins can create, edit, and delete announcements.
/// All members can view announcements.
class AnnouncementsScreen extends StatefulWidget {
  const AnnouncementsScreen({super.key});

  @override
  State<AnnouncementsScreen> createState() => _AnnouncementsScreenState();
}

class _AnnouncementsScreenState extends State<AnnouncementsScreen> {
  Map<String, dynamic>? _household;
  Map<String, dynamic>? _myMembership;
  List<Map<String, dynamic>> _announcements = [];
  bool _isLoading = true;
  bool _isAdmin = false;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    try {
      final user = Supabase.instance.client.auth.currentUser!;

      // Get household info
      final memberships = await Supabase.instance.client
          .from('household_members')
          .select('*, households(*)')
          .eq('auth_user_id', user.id)
          .limit(1);

      if (memberships.isNotEmpty) {
        _myMembership = memberships[0];
        _household = memberships[0]['households'];
        _isAdmin = Permissions.canManageAnnouncements(_myMembership);

        // Load announcements
        final announcements = await Supabase.instance.client
            .from('announcements')
            .select('*, household_members!announcements_created_by_member_id_fkey(display_name, kind, avatar_url)')
            .eq('household_id', _household!['id'])
            .order('created_at', ascending: false)
            .limit(50);

        setState(() {
          _announcements = List<Map<String, dynamic>>.from(announcements);
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading announcements: $e')),
        );
      }
    }
  }

  Future<void> _showCreateEditDialog([Map<String, dynamic>? announcement]) async {
    final titleController = TextEditingController(text: announcement?['title'] ?? '');
    final messageController = TextEditingController(text: announcement?['message'] ?? '');
    bool isPinned = announcement?['is_pinned'] ?? false;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(announcement == null ? 'New Announcement' : 'Edit Announcement'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleController,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Title',
                    hintText: 'e.g., "Family Meeting Tonight"',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: messageController,
                  textCapitalization: TextCapitalization.sentences,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Message',
                    hintText: 'Enter your announcement...',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  title: const Text('Pin to top'),
                  subtitle: const Text('Pinned announcements stay at the top'),
                  value: isPinned,
                  onChanged: (v) => setDialogState(() => isPinned = v),
                  contentPadding: EdgeInsets.zero,
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
                if (titleController.text.trim().isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Please enter a title')),
                  );
                  return;
                }
                Navigator.pop(context, true);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (result == true) {
      try {
        if (announcement == null) {
          // Create new
          await Supabase.instance.client.from('announcements').insert({
            'household_id': _household!['id'],
            'created_by_member_id': _myMembership!['id'],
            'title': titleController.text.trim(),
            'message': messageController.text.trim(),
            'is_pinned': isPinned,
          });
        } else {
          // Update existing
          await Supabase.instance.client
              .from('announcements')
              .update({
                'title': titleController.text.trim(),
                'message': messageController.text.trim(),
                'is_pinned': isPinned,
              })
              .eq('id', announcement['id']);
        }
        await _loadData();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error saving announcement: $e')),
          );
        }
      }
    }
  }

  Future<void> _deleteAnnouncement(Map<String, dynamic> announcement) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete announcement?'),
        content: const Text('This action cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await Supabase.instance.client.from('announcements').delete().eq('id', announcement['id']);
        await _loadData();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error deleting announcement: $e')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Announcements'),
        actions: [
          if (_isAdmin)
            IconButton(
              icon: const Icon(Icons.add_rounded),
              onPressed: () => _showCreateEditDialog(),
              tooltip: 'New announcement',
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _announcements.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.campaign_outlined, size: 64, color: Colors.grey.shade300),
                      const SizedBox(height: 16),
                      Text(
                        'No announcements yet',
                        style: TextStyle(fontSize: 16, color: Colors.grey.shade500, fontWeight: FontWeight.w600),
                      ),
                      if (_isAdmin) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Tap + to create one',
                          style: TextStyle(fontSize: 13, color: Colors.grey.shade400),
                        ),
                      ],
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _announcements.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, i) {
                    final announcement = _announcements[i];
                    final member = announcement['household_members'] as Map<String, dynamic>?;
                    final displayName = member?['display_name'] ?? 'Unknown';
                    final kind = member?['kind'] ?? 'adult_auth_user';
                    final avatarUrl = member?['avatar_url'];
                    final isPinned = announcement['is_pinned'] ?? false;
                    final createdAt = announcement['created_at'];

                    return Container(
                      decoration: BoxDecoration(
                        color: isPinned ? AppColors.honeyGold.withOpacity(.1) : Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: isPinned ? AppColors.honeyGold : Colors.grey.shade200,
                          width: isPinned ? 2 : 1,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(.05),
                            blurRadius: 10,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Header
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: isPinned ? AppColors.honeyGold.withOpacity(.15) : Colors.grey.shade50,
                              borderRadius: const BorderRadius.only(
                                topLeft: Radius.circular(16),
                                topRight: Radius.circular(16),
                              ),
                            ),
                            child: Row(
                              children: [
                                // Avatar
                                CircleAvatar(
                                  radius: 16,
                                  backgroundColor: AppColors.honeyGold.withOpacity(.2),
                                  backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl) : null,
                                  child: avatarUrl == null
                                      ? Text(
                                          kind == 'sub_profile' ? '\ud83d\udc76' : displayName[0].toUpperCase(),
                                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                                        )
                                      : null,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Text(
                                            displayName,
                                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                                          ),
                                          if (isPinned) ...[
                                            const SizedBox(width: 6),
                                            const Icon(Icons.push_pin_rounded, size: 14, color: AppColors.honeyGold),
                                          ],
                                        ],
                                      ),
                                      Text(
                                        _formatTimestamp(createdAt),
                                        style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                                      ),
                                    ],
                                  ),
                                ),
                                if (_isAdmin)
                                  PopupMenuButton<String>(
                                    icon: const Icon(Icons.more_vert_rounded),
                                    onSelected: (action) {
                                      if (action == 'edit') {
                                        _showCreateEditDialog(announcement);
                                      } else if (action == 'delete') {
                                        _deleteAnnouncement(announcement);
                                      }
                                    },
                                    itemBuilder: (context) => [
                                      const PopupMenuItem(value: 'edit', child: Row(children: [Icon(Icons.edit_rounded, size: 18), SizedBox(width: 12), Text('Edit')])),
                                      const PopupMenuItem(value: 'delete', child: Row(children: [Icon(Icons.delete_rounded, size: 18, color: Colors.red), SizedBox(width: 12), Text('Delete', style: TextStyle(color: Colors.red))])),
                                    ],
                                  ),
                              ],
                            ),
                          ),

                          // Title and message
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  announcement['title'] ?? '',
                                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  announcement['message'] ?? '',
                                  style: const TextStyle(fontSize: 14, height: 1.5),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }

  String _formatTimestamp(String? ts) {
    if (ts == null) return '';
    try {
      final dt = DateTime.parse(ts).toLocal();
      final now = DateTime.now();
      final diff = now.difference(dt);

      if (diff.inMinutes < 1) return 'Just now';
      if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
      if (diff.inHours < 24) return '${diff.inHours}h ago';
      if (diff.inDays < 7) return '${diff.inDays}d ago';
      return '${dt.month}/${dt.day}/${dt.year}';
    } catch (_) {
      return ts;
    }
  }
}