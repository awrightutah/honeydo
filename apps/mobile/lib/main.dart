import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'theme/app_theme.dart';
import 'screens/auth_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/home_shell_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load environment variables
  await dotenv.load(fileName: '.env');

  // Initialize Supabase
  await Supabase.initialize(
    url: dotenv.env['SUPABASE_URL']!,
    anonKey: dotenv.env['SUPABASE_ANON_KEY']!,
  );

  runApp(const HoneydoApp());
}

class HoneydoApp extends StatelessWidget {
  const HoneydoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Honeydo',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      home: const AppEntryGate(),
    );
  }
}

class AppEntryGate extends StatelessWidget {
  const AppEntryGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, snapshot) {
        final session = snapshot.data?.session;

        // Not signed in → show auth screen
        if (session == null) {
          return const AuthScreen();
        }

        // Signed in → check if user has a household
        return FutureBuilder<List<Map<String, dynamic>>>(
          future: Supabase.instance.client
              .from('household_members')
              .select('household_id')
              .eq('auth_user_id', session.user.id)
              .limit(1),
          builder: (context, householdSnapshot) {
            if (householdSnapshot.connectionState == ConnectionState.waiting) {
              return const Scaffold(body: Center(child: CircularProgressIndicator()));
            }

            final hasHousehold = householdSnapshot.hasData && householdSnapshot.data!.isNotEmpty;

            if (hasHousehold) {
              return const HomeShellScreen();
            } else {
              return const OnboardingScreen();
            }
          },
        );
      },
    );
  }
}