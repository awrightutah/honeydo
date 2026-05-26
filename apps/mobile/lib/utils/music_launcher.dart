import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../widgets/music_picker_sheet.dart';
import 'music_apps.dart';

/// Launches the user's chosen music app via its URL scheme, falling back to
/// the App Store listing when the app isn't installed.
///
/// On iOS, `canLaunchUrl` only returns true for URL schemes registered in
/// `Info.plist`'s `LSApplicationQueriesSchemes`. Without that registration
/// every check silently returns false. All 5 supported schemes are
/// registered as of Batch 8.1.
///
/// Reads `context.mounted` before each post-await SnackBar to keep the
/// helper safe to call from widgets that may unmount mid-launch.
Future<void> launchMusicApp(BuildContext context, MusicAppInfo info) async {
  try {
    final uri = Uri.parse(info.urlScheme);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("${info.label} isn't installed — opening App Store"),
      ),
    );
    await launchUrl(
      Uri.parse(info.appStoreUrl),
      mode: LaunchMode.externalApplication,
    );
  } catch (e) {
    debugPrint('launchMusicApp failed: $e');
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't open music app: $e")),
      );
    }
  }
}

/// Shows the music picker sheet and, if the user picks an app, persists the
/// selection to `household_members.music_app_preference` for [memberId].
///
/// Returns the selected [MusicAppInfo] on success, `null` if the user
/// dismissed the sheet or the DB write failed (a SnackBar surfaces the
/// error per Pass 2 patterns).
Future<MusicAppInfo?> pickAndSaveMusicApp(
  BuildContext context, {
  required String memberId,
}) async {
  final selected = await MusicPickerSheet.show(context);
  if (selected == null) return null;
  try {
    await Supabase.instance.client
        .from('household_members')
        .update({'music_app_preference': selected.dbValue})
        .eq('id', memberId);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Music app set to ${selected.label}')),
      );
    }
    return selected;
  } catch (e) {
    debugPrint('update music_app_preference failed: $e');
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't save music app: $e")),
      );
    }
    return null;
  }
}
