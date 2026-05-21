import 'dart:math';

/// Generates a cryptographically random household invite code.
///
/// Draws characters from an alphabet that excludes visually ambiguous
/// glyphs (I, O, 0, 1). Uses [Random.secure] so codes cannot be predicted
/// from creation time.
String generateInviteCode({int length = 6}) {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  final r = Random.secure();
  final buffer = StringBuffer();
  for (var i = 0; i < length; i++) {
    buffer.write(chars[r.nextInt(chars.length)]);
  }
  return buffer.toString();
}
