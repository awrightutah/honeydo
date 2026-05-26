import 'package:flutter/material.dart';
import '../utils/music_apps.dart';

/// Bottom sheet that lets a user pick one of the supported music apps.
///
/// Returns the chosen [MusicAppInfo] (or `null` if dismissed). The caller is
/// responsible for persisting the selection — this widget is a pure picker.
///
/// Use [MusicPickerSheet.show] as the entry point; the constructor is private.
class MusicPickerSheet extends StatelessWidget {
  const MusicPickerSheet._();

  /// Opens the sheet. Resolves with the selected `MusicAppInfo`, or `null` if
  /// the user dismissed without choosing.
  static Future<MusicAppInfo?> show(BuildContext context) {
    return showModalBottomSheet<MusicAppInfo>(
      context: context,
      builder: (_) => const MusicPickerSheet._(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 20, 24, 8),
            child: Text(
              'Choose a music app',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
          ),
          for (final info in MusicAppInfo.allApps)
            ListTile(
              key: ValueKey(info.dbValue),
              leading: Text(info.emoji, style: const TextStyle(fontSize: 26)),
              title: Text(
                info.label,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              onTap: () => Navigator.pop(context, info),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
