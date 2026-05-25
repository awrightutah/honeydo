import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';

/// Inline thumbnail for a chore verification photo (kid Batch 4a submission
/// path). Tap to open [ChorePhotoFullScreenView] with pinch-to-zoom.
///
/// `storagePath` may be null when the kid skipped the photo (Batch 4a's
/// "Skip Photo" branch — `submit_kid_chore_with_photo` accepts a null path
/// per migration 0019). In that case, the widget renders an "empty state"
/// placeholder rather than attempting to load anything.
///
/// The chore-photos bucket is private; rendering requires a 1-hour signed
/// URL via `Supabase.storage.from('chore-photos').createSignedUrl(...)`.
/// The signed-URL future is cached for the widget's lifetime so a parent
/// rebuild doesn't trigger a round-trip.
class ChorePhotoThumbnail extends StatefulWidget {
  const ChorePhotoThumbnail({
    super.key,
    required this.storagePath,
    this.size = 64.0,
    this.photoId,
    this.canDelete = false,
    this.onDeleted,
  });

  /// Storage path inside the chore-photos bucket. `null` = empty state.
  final String? storagePath;

  /// Edge length of the (square) thumbnail.
  final double size;

  /// `chore_verification_photos.id` — required when an admin should be able
  /// to delete the photo from the full-screen view.
  final String? photoId;

  /// Show a Delete button in the full-screen modal (admin only).
  final bool canDelete;

  /// Called after a successful delete (so callers can refresh their list).
  final VoidCallback? onDeleted;

  @override
  State<ChorePhotoThumbnail> createState() => _ChorePhotoThumbnailState();
}

class _ChorePhotoThumbnailState extends State<ChorePhotoThumbnail> {
  Future<String>? _signedUrl;

  @override
  void initState() {
    super.initState();
    if (widget.storagePath != null) {
      _signedUrl = _generateSignedUrl(widget.storagePath!);
    }
  }

  @override
  void didUpdateWidget(ChorePhotoThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-generate the signed URL only when the underlying path changes (e.g.
    // after admin deletes the photo and a new submission lands).
    if (oldWidget.storagePath != widget.storagePath) {
      _signedUrl = widget.storagePath == null
          ? null
          : _generateSignedUrl(widget.storagePath!);
    }
  }

  Future<String> _generateSignedUrl(String path) async {
    return Supabase.instance.client.storage
        .from('chore-photos')
        .createSignedUrl(path, 3600);
  }

  void _openFullScreen() {
    if (widget.storagePath == null) return;
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black87,
        pageBuilder: (_, __, ___) => ChorePhotoFullScreenView(
          storagePath: widget.storagePath!,
          photoId: widget.photoId,
          canDelete: widget.canDelete,
          onDeleted: widget.onDeleted,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Empty state: kid skipped the photo on this submission.
    if (widget.storagePath == null) {
      return Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.no_photography_outlined,
                size: widget.size * 0.4, color: Colors.grey.shade500),
            if (widget.size >= 100) ...[
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  'No photo submitted',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ],
        ),
      );
    }

    return InkWell(
      onTap: _openFullScreen,
      borderRadius: BorderRadius.circular(12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: FutureBuilder<String>(
            future: _signedUrl,
            builder: (ctx, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return Container(
                  color: Colors.grey.shade100,
                  child: Center(
                    child: SizedBox(
                      width: widget.size * 0.4,
                      height: widget.size * 0.4,
                      child: const CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                );
              }
              if (snap.hasError || !snap.hasData) {
                debugPrint('chore photo signed URL failed: ${snap.error}');
                return Container(
                  color: Colors.grey.shade100,
                  child: Icon(Icons.broken_image_outlined,
                      size: widget.size * 0.5, color: Colors.grey.shade500),
                );
              }
              return Image.network(
                snap.data!,
                fit: BoxFit.cover,
                errorBuilder: (_, error, __) {
                  debugPrint('chore photo Image.network failed: $error');
                  return Container(
                    color: Colors.grey.shade100,
                    child: Icon(Icons.broken_image_outlined,
                        size: widget.size * 0.5, color: Colors.grey.shade500),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Full-screen photo view with pinch-to-zoom (via [InteractiveViewer]) and
/// an optional admin Delete button. Pushed by [ChorePhotoThumbnail] on tap.
class ChorePhotoFullScreenView extends StatefulWidget {
  const ChorePhotoFullScreenView({
    super.key,
    required this.storagePath,
    this.photoId,
    this.canDelete = false,
    this.onDeleted,
  });

  final String storagePath;
  final String? photoId;
  final bool canDelete;
  final VoidCallback? onDeleted;

  @override
  State<ChorePhotoFullScreenView> createState() =>
      _ChorePhotoFullScreenViewState();
}

class _ChorePhotoFullScreenViewState extends State<ChorePhotoFullScreenView> {
  late Future<String> _signedUrl;
  bool _isDeleting = false;

  @override
  void initState() {
    super.initState();
    _signedUrl = Supabase.instance.client.storage
        .from('chore-photos')
        .createSignedUrl(widget.storagePath, 3600);
  }

  Future<void> _confirmAndDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this photo?'),
        content: const Text(
          "This can't be undone. The chore will show 'No photo submitted' instead.",
        ),
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
    if (widget.photoId == null) return;

    setState(() => _isDeleting = true);

    try {
      // RPC validates admin + deletes the row + returns the storage_path.
      final returnedPath = await Supabase.instance.client.rpc(
        'delete_chore_photo',
        params: {'p_photo_id': widget.photoId},
      ) as String;

      // Client removes the Storage object. If this fails, the row is already
      // gone (correct UI state); the orphan would be caught by the deferred
      // pg_cron retention job later.
      try {
        await Supabase.instance.client.storage
            .from('chore-photos')
            .remove([returnedPath]);
      } catch (storageError) {
        debugPrint(
            'storage remove failed after row delete (orphan logged): $storageError');
      }

      if (!mounted) return;
      Navigator.pop(context); // close full-screen viewer
      widget.onDeleted?.call();
    } catch (e) {
      debugPrint('delete_chore_photo failed: $e');
      if (mounted) {
        setState(() => _isDeleting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not delete photo: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Photo + pinch-to-zoom
          Positioned.fill(
            child: FutureBuilder<String>(
              future: _signedUrl,
              builder: (ctx, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  );
                }
                if (snap.hasError || !snap.hasData) {
                  debugPrint('full-screen signed URL failed: ${snap.error}');
                  return const Center(
                    child: Icon(Icons.broken_image_outlined,
                        size: 80, color: Colors.white54),
                  );
                }
                return InteractiveViewer(
                  minScale: 0.5,
                  maxScale: 4.0,
                  child: Center(
                    child: Image.network(
                      snap.data!,
                      fit: BoxFit.contain,
                      errorBuilder: (_, error, __) {
                        debugPrint('full-screen Image.network failed: $error');
                        return const Icon(Icons.broken_image_outlined,
                            size: 80, color: Colors.white54);
                      },
                    ),
                  ),
                );
              },
            ),
          ),

          // Close button (top-right)
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            right: 12,
            child: IconButton.filled(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close),
              style: IconButton.styleFrom(
                backgroundColor: Colors.black54,
                foregroundColor: Colors.white,
              ),
            ),
          ),

          // Delete button (bottom; admin-only)
          if (widget.canDelete && widget.photoId != null)
            Positioned(
              left: 24,
              right: 24,
              bottom: MediaQuery.of(context).padding.bottom + 24,
              child: FilledButton.icon(
                onPressed: _isDeleting ? null : _confirmAndDelete,
                icon: _isDeleting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.delete_outline),
                label: Text(_isDeleting ? 'Deleting…' : 'Delete photo'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.coral,
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
