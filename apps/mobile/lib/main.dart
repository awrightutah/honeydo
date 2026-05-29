import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'theme/app_theme.dart';
import 'services/offline_service.dart';
import 'services/feature_tour_service.dart';
import 'services/active_member_service.dart';
import 'screens/splash_screen.dart';
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

  // Initialize offline service
  await OfflineService.instance.init();

  // Initialize feature tour and active member services
  await FeatureTourService.instance.init();
  await ActiveMemberService.instance.init();

  runApp(const HoneydoApp());
}

class HoneydoApp extends StatefulWidget {
  const HoneydoApp({super.key});

  static final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.system);

  @override
  State<HoneydoApp> createState() => _HoneydoAppState();
}

class _HoneydoAppState extends State<HoneydoApp> {
  @override
  void initState() {
    super.initState();
    _loadThemePreference();
  }

  Future<void> _loadThemePreference() async {
    final prefs = await SharedPreferences.getInstance();
    final isDark = prefs.getBool('dark_mode') ?? false;
    HoneydoApp.themeNotifier.value = isDark ? ThemeMode.dark : ThemeMode.light;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: HoneydoApp.themeNotifier,
      builder: (context, currentMode, child) {
        return MaterialApp(
          title: 'Clanquility',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: currentMode,
          home: const AppEntryGate(),
        );
      },
    );
  }
}

class AppEntryGate extends StatefulWidget {
  const AppEntryGate({super.key});

  @override
  State<AppEntryGate> createState() => _AppEntryGateState();
}

class _AppEntryGateState extends State<AppEntryGate> {
  bool _showSplash = true;

  @override
  void initState() {
    super.initState();
    // Show splash for 2 seconds, then transition to the app
    Future.delayed(const Duration(milliseconds: 2000), () {
      if (mounted) {
        setState(() => _showSplash = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_showSplash) {
      return const SplashScreen();
    }

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
