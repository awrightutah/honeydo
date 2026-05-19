import 'package:flutter/material.dart';
import 'theme/app_theme.dart';
import 'screens/onboarding_screen.dart';
import 'screens/home_shell_screen.dart';

void main() {
  runApp(const HomeHubApp());
}

class HomeHubApp extends StatelessWidget {
  const HomeHubApp({super.key});

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
    // TODO: Replace with Supabase auth/session state.
    const hasCompletedOnboarding = false;
    return hasCompletedOnboarding ? const HomeShellScreen() : const OnboardingScreen();
  }
}
