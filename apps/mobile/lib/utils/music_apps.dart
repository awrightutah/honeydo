import 'package:flutter/material.dart';

/// The set of music apps Batch 8 supports deep-linking into.
///
/// Adding a fourth app means: extend the enum, add the matching `MusicAppInfo`
/// entry to `MusicAppInfo.allApps`, and register the scheme in
/// `ios/Runner/Info.plist` under `LSApplicationQueriesSchemes`. Without the
/// Info.plist entry iOS silently returns false from `canLaunchUrl()`.
enum MusicApp { spotify, appleMusic, youtubeMusic, pandora, amazonMusic }

/// Metadata for one music app — what it's called, what string we store in
/// `household_members.music_app_preference`, what URL scheme opens the app,
/// and a fallback https App Store URL when the app isn't installed.
@immutable
class MusicAppInfo {
  const MusicAppInfo({
    required this.app,
    required this.label,
    required this.dbValue,
    required this.urlScheme,
    required this.appStoreUrl,
    required this.emoji,
  });

  final MusicApp app;
  final String label;
  final String dbValue;
  final String urlScheme;
  final String appStoreUrl;
  final String emoji;

  /// Ordered list shown in the picker. Order matters for UX — Apple Music
  /// last because it's the default on every iPhone (kid is less likely to
  /// need to "pick" it intentionally).
  static const List<MusicAppInfo> allApps = <MusicAppInfo>[
    MusicAppInfo(
      app: MusicApp.spotify,
      label: 'Spotify',
      dbValue: 'spotify',
      urlScheme: 'spotify://',
      appStoreUrl:
          'https://apps.apple.com/app/spotify-music-and-podcasts/id324684580',
      emoji: '🟢',
    ),
    MusicAppInfo(
      app: MusicApp.youtubeMusic,
      label: 'YouTube Music',
      dbValue: 'youtube_music',
      urlScheme: 'youtubemusic://',
      appStoreUrl:
          'https://apps.apple.com/app/youtube-music/id1017492454',
      emoji: '🔴',
    ),
    MusicAppInfo(
      app: MusicApp.appleMusic,
      label: 'Apple Music',
      dbValue: 'apple_music',
      urlScheme: 'music://',
      appStoreUrl:
          'https://apps.apple.com/app/apple-music/id1108187390',
      emoji: '🍎',
    ),
    MusicAppInfo(
      app: MusicApp.pandora,
      label: 'Pandora',
      dbValue: 'pandora',
      urlScheme: 'pandora://',
      appStoreUrl:
          'https://apps.apple.com/app/pandora-music-podcasts/id284035177',
      emoji: '🔵',
    ),
    // Amazon Music URL scheme: the canonical scheme `amazonmusic://` is the
    // most commonly cited and works for app launching. Some older references
    // mention `amzn-mobile-music://` but that's deprecated. Verify on real
    // device — if `canLaunchUrl` returns false even when Amazon Music is
    // installed, try `amzn-mobile-music://` instead and update Info.plist.
    MusicAppInfo(
      app: MusicApp.amazonMusic,
      label: 'Amazon Music',
      dbValue: 'amazon_music',
      urlScheme: 'amzn-mobile-music://',
      appStoreUrl:
          'https://apps.apple.com/app/amazon-music/id510855668',
      emoji: '🟦',
    ),
  ];

  /// Look up the `MusicAppInfo` matching a `music_app_preference` column
  /// value. Returns `null` for unknown or null inputs (kid hasn't picked yet,
  /// or the column carries a legacy/typo string).
  static MusicAppInfo? fromDbValue(String? dbValue) {
    if (dbValue == null || dbValue.isEmpty) return null;
    for (final info in allApps) {
      if (info.dbValue == dbValue) return info;
    }
    return null;
  }
}
