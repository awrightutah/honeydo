import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Supabase client singleton for the Clanquility mobile app.
///
/// Initialize this in main() before runApp() using:
/// ```dart
/// await Supabase.initialize(
///   url: dotenv.env['SUPABASE_URL']!,
///   anonKey: dotenv.env['SUPABASE_ANON_KEY']!,
/// );
/// ```
///
/// Access the client anywhere via `Supabase.instance.client`.
class ClanquilitySupabaseClient {
  ClanquilitySupabaseClient._();

  /// Get the Supabase client instance.
  static SupabaseClient get instance => Supabase.instance.client;

  /// Get the current authenticated user, or null if not signed in.
  static User? get currentUser => instance.auth.currentUser;

  /// Check if a user is currently signed in.
  static bool get isSignedIn => currentUser != null;

  /// Get the current session, or null if not signed in.
  static Session? get currentSession => instance.auth.currentSession;

  /// Sign up a new user with email and password.
  ///
  /// Returns the created user and session.
  /// Throws [AuthException] on failure.
  static Future<AuthResponse> signUp({
    required String email,
    required String password,
    String? displayName,
  }) async {
    final response = await instance.auth.signUp(
      email: email,
      password: password,
      data: displayName != null ? {'display_name': displayName} : null,
    );
    return response;
  }

  /// Sign in an existing user with email and password.
  ///
  /// Returns the user session.
  /// Throws [AuthException] on failure.
  static Future<AuthResponse> signIn({
    required String email,
    required String password,
  }) async {
    final response = await instance.auth.signInWithPassword(
      email: email,
      password: password,
    );
    return response;
  }

  /// Sign out the current user.
  static Future<void> signOut() async {
    await instance.auth.signOut();
  }

  /// Send a password reset email to the user.
  ///
  /// Returns true if the email was sent successfully.
  static Future<bool> resetPassword(String email) async {
    try {
      await instance.auth.resetPasswordForEmail(email);
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Update the user's password (after reset).
  ///
  /// The user must be authenticated.
  static Future<void> updatePassword(String newPassword) async {
    await instance.auth.updateUser(
      UserAttributes(password: newPassword),
    );
  }

  /// Update the user's display name.
  static Future<void> updateDisplayName(String displayName) async {
    await instance.auth.updateUser(
      UserAttributes(data: {'display_name': displayName}),
    );
  }

  /// Listen to auth state changes.
  ///
  /// Returns a [Stream] that emits [AuthState] changes.
  static Stream<AuthState> get onAuthStateChange => instance.auth.onAuthStateChange;
}