import 'dart:io';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:image_picker/image_picker.dart';
import '../theme/app_theme.dart';

/// Normalizes an image MIME type so Supabase Storage accepts it.
/// iOS picks JPEGs with extension ".jpg", which produces "image/jpg" —
/// Supabase rejects that with 415 since the canonical type is "image/jpeg".
String _normalizeImageMime(String mime) {
  final lower = mime.toLowerCase();
  return lower == 'image/jpg' ? 'image/jpeg' : lower;
}

/// Service for uploading images to Supabase Storage buckets.
class ImageUploadService {
  static final _supabase = Supabase.instance.client;
  static final _imagePicker = ImagePicker();

  /// Pick an image from gallery or camera and upload to the specified bucket.
  /// Returns the public URL of the uploaded image, or null if cancelled.
  static Future<String?> pickAndUpload({
    required String bucketId,
    required String pathPrefix,
    int maxSizeBytes = 2097152, // 2MB default
    ImageSource source = ImageSource.gallery,
  }) async {
    // Pick image
    final XFile? image = await _imagePicker.pickImage(
      source: source,
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 80,
    );

    if (image == null) return null; // User cancelled

    // Check file size
    final fileSize = await image.length();
    if (fileSize > maxSizeBytes) {
      throw Exception('Image is too large. Maximum size is ${maxSizeBytes ~/ 1024 ~/ 1024}MB.');
    }

    // Upload to Supabase Storage
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) throw Exception('Not authenticated');

    final fileExt = image.path.split('.').last.toLowerCase();
    final fileName = '${DateTime.now().millisecondsSinceEpoch}.$fileExt';
    final filePath = '$pathPrefix/$fileName';

    final fileBytes = await image.readAsBytes();

    await _supabase.storage.from(bucketId).uploadBinary(
      filePath,
      fileBytes,
      fileOptions: FileOptions(
        contentType: _normalizeImageMime('image/$fileExt'),
        upsert: true,
      ),
    );

    // Get public URL
    final publicUrl = _supabase.storage.from(bucketId).getPublicUrl(filePath);
    return publicUrl;
  }

  /// Pick an image and upload to a PRIVATE Supabase Storage bucket.
  /// Returns the storage path (not a public URL — the bucket is private,
  /// so callers must use `createSignedUrl` later when displaying the image).
  ///
  /// Use this for private buckets like `chore-photos`. For public buckets
  /// (avatars, recipe images), use [pickAndUpload] instead — that helper
  /// returns a public URL ready for `Image.network`.
  ///
  /// The full storage object key is `$pathPrefix/${timestamp_ms}.jpg`.
  /// The first folder of `pathPrefix` should be the household_id so the
  /// chore-photos bucket's RLS policy (which checks
  /// `(storage.foldername(name))[1]`) can match.
  ///
  /// On RPC failure after the upload succeeded, the caller is expected
  /// to clean up via `Supabase.instance.client.storage.from(bucketId).remove([path])`
  /// — this method does not retain enough state to do that cleanup itself.
  ///
  /// Throws on upload failure (no swallow). Returns null if the user
  /// cancelled the picker.
  static Future<String?> pickAndUploadPrivate({
    required String bucketId,
    required String pathPrefix,
    ImageSource source = ImageSource.camera,
    int maxWidth = 1024,
    int maxHeight = 1024,
    int imageQuality = 80,
  }) async {
    final XFile? image = await _imagePicker.pickImage(
      source: source,
      maxWidth: maxWidth.toDouble(),
      maxHeight: maxHeight.toDouble(),
      imageQuality: imageQuality,
    );

    if (image == null) return null; // User cancelled

    final bytes = await image.readAsBytes();
    final fileName = '${DateTime.now().millisecondsSinceEpoch}.jpg';
    final storagePath = '$pathPrefix/$fileName';

    await _supabase.storage.from(bucketId).uploadBinary(
      storagePath,
      bytes,
      fileOptions: const FileOptions(
        contentType: 'image/jpeg',
        upsert: false,
      ),
    );

    return storagePath;
  }

  /// Upload an avatar image for the current user.
  /// Returns the public URL of the uploaded avatar.
  static Future<String?> uploadAvatar({ImageSource source = ImageSource.gallery}) async {
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) throw Exception('Not authenticated');

    return pickAndUpload(
      bucketId: 'avatars',
      pathPrefix: userId,
      maxSizeBytes: 2097152, // 2MB
      source: source,
    );
  }

  /// Upload a recipe image.
  /// Returns the public URL of the uploaded image.
  static Future<String?> uploadRecipeImage({
    required String recipeId,
    ImageSource source = ImageSource.gallery,
  }) async {
    return pickAndUpload(
      bucketId: 'recipe-images',
      pathPrefix: recipeId,
      maxSizeBytes: 5242880, // 5MB
      source: source,
    );
  }

  /// Delete an image from storage.
  static Future<void> deleteImage({
    required String bucketId,
    required String filePath,
  }) async {
    await _supabase.storage.from(bucketId).remove([filePath]);
  }

  /// Show a 3-button modal asking the user to choose between taking a photo,
  /// skipping the photo, or cancelling entirely. Used by the kid chore-
  /// completion flow (Batch 4a revised) where photo evidence is optional.
  ///
  /// Returns:
  ///   'photo' — user wants to take a photo
  ///   'skip'  — user wants to submit without a photo
  ///   null    — user cancelled (no submission should occur)
  ///
  /// Symmetric tap counts: 2 to photo (this dialog + camera), 2 to skip
  /// (this dialog + nothing else), 1 to cancel.
  static Future<String?> showPhotoChoiceDialog(
    BuildContext context, {
    String title = 'Submit chore as complete?',
  }) async {
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: const Text('Would you like to include a photo?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'photo'),
            child: const Text(
              '📷  Take Photo',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'skip'),
            child: const Text('✏️  Skip Photo'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  /// Show image source picker dialog (gallery vs camera).
  static Future<String?> showImageSourceDialog(BuildContext context) async {
    return showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Choose Image Source',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => Navigator.pop(context, 'gallery'),
                      icon: const Icon(Icons.photo_library),
                      label: const Text('Gallery'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.honeyGold,
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(48),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => Navigator.pop(context, 'camera'),
                      icon: const Icon(Icons.camera_alt),
                      label: const Text('Camera'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.skyBlue,
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(48),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => Navigator.pop(context, null),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
