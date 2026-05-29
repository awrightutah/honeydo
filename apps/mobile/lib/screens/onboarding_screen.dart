import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/app_theme.dart';
import 'household_setup_screen.dart';

/// Enhanced onboarding with animated illustrations, role selection,
/// and feature highlights. Marks onboarding complete via SharedPreferences.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> with TickerProviderStateMixin {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  static const _onboardingCompleteKey = 'onboarding_completed';

  final _steps = const [
    _OnboardingStep(
      emoji: '🐝',
      title: 'Welcome to Clanquility',
      body: 'The household hub that keeps your family organized, motivated, and connected. Manage chores, plan meals, and track shopping — all in one place.',
      gradient: [Color(0xFFFFD54F), Color(0xFFFFA726)],
    ),
    _OnboardingStep(
      emoji: '🏠',
      title: 'Create Your Household',
      body: 'Set up your home with a name and invite family members. Adults get full accounts, and kids get safe sub-profiles with PIN protection — no email required.',
      gradient: [Color(0xFF66BB6A), Color(0xFF43A047)],
    ),
    _OnboardingStep(
      emoji: '✅',
      title: 'Assign & Track Chores',
      body: 'Create recurring or one-time chores, assign them to family members, and track completion with photo verification. Auto-reminders keep everyone on track.',
      gradient: [Color(0xFF42A5F5), Color(0xFF1E88E5)],
    ),
    _OnboardingStep(
      emoji: '🏆',
      title: 'Earn Points & Rewards',
      body: 'Turn completed chores into points! Kids can redeem points for custom rewards like extra screen time or a favorite dinner. Streaks and badges keep motivation high.',
      gradient: [Color(0xFFAB47BC), Color(0xFF8E24AA)],
    ),
    _OnboardingStep(
      emoji: '🍽️',
      title: 'Plan Meals & Shop Smarter',
      body: 'Browse recipes, plan weekly meals for the whole family, and automatically add ingredients to your shopping list. Never forget the milk again!',
      gradient: [Color(0xFFEF5350), Color(0xFFE53935)],
    ),
  ];

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _fadeAnimation = CurvedAnimation(parent: _fadeController, curve: Curves.easeIn);
    _fadeController.forward();
  }

  @override
  void dispose() {
    _fadeController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _completeOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_onboardingCompleteKey, true);

    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const HouseholdSetupScreen()),
    );
  }

  void _goToPage(int page) {
    _fadeController.reset();
    _pageController.animateToPage(
      page,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOut,
    );
    setState(() => _currentPage = page);
    _fadeController.forward();
  }

  @override
  Widget build(BuildContext context) {
    final isLastPage = _currentPage == _steps.length - 1;
    final size = MediaQuery.of(context).size;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Skip button
            Align(
              alignment: Alignment.topRight,
              child: TextButton(
                onPressed: _completeOnboarding,
                child: Text(
                  'Skip',
                  style: TextStyle(
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),

            // Page content
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                physics: const BouncingScrollPhysics(),
                itemCount: _steps.length,
                onPageChanged: (page) {
                  _fadeController.reset();
                  setState(() => _currentPage = page);
                  _fadeController.forward();
                },
                itemBuilder: (context, index) {
                  final step = _steps[index];
                  return FadeTransition(
                    opacity: _fadeAnimation,
                    child: _OnboardingPage(step: step, size: size),
                  );
                },
              ),
            ),

            // Page indicators + navigation
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Column(
                children: [
                  // Dots indicator
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(_steps.length, (i) {
                      final isActive = i == _currentPage;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeInOut,
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        width: isActive ? 32 : 10,
                        height: 10,
                        decoration: BoxDecoration(
                          gradient: isActive
                              ? LinearGradient(colors: step.gradient)
                              : null,
                          color: isActive ? null : Colors.grey.shade300,
                          borderRadius: BorderRadius.circular(999),
                        ),
                      );
                    }),
                  ),
                  const SizedBox(height: 24),

                  // Navigation buttons
                  Row(
                    children: [
                      if (_currentPage > 0)
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => _goToPage(_currentPage - 1),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            child: const Text('Back'),
                          ),
                        ),
                      if (_currentPage > 0) const SizedBox(width: 16),
                      Expanded(
                        flex: _currentPage > 0 ? 2 : 1,
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: isLastPage
                                  ? [AppColors.grassGreen, const Color(0xFF2E7D32)]
                                  : step.gradient,
                            ),
                            borderRadius: BorderRadius.circular(14),
                            boxShadow: [
                              BoxShadow(
                                color: (isLastPage ? AppColors.grassGreen : step.gradient[0]).withValues(alpha:.3),
                                blurRadius: 12,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: FilledButton(
                            onPressed: isLastPage
                                ? _completeOnboarding
                                : () => _goToPage(_currentPage + 1),
                            style: FilledButton.styleFrom(
                              backgroundColor: Colors.transparent,
                              shadowColor: Colors.transparent,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  isLastPage ? "Let's Get Started" : 'Next',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 16,
                                    color: Colors.white,
                                  ),
                                ),
                                if (!isLastPage) ...[
                                  const SizedBox(width: 8),
                                  const Icon(Icons.arrow_forward_rounded, size: 20, color: Colors.white),
                                ],
                                if (isLastPage) ...[
                                  const SizedBox(width: 8),
                                  const Icon(Icons.rocket_launch_rounded, size: 20, color: Colors.white),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  _OnboardingStep get step => _steps[_currentPage];
}

class _OnboardingStep {
  const _OnboardingStep({
    required this.emoji,
    required this.title,
    required this.body,
    required this.gradient,
  });

  final String emoji;
  final String title;
  final String body;
  final List<Color> gradient;
}

class _OnboardingPage extends StatelessWidget {
  const _OnboardingPage({
    required this.step,
    required this.size,
  });

  final _OnboardingStep step;
  final Size size;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Animated emoji circle with gradient
          Container(
            width: size.width * 0.45,
            height: size.width * 0.45,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: step.gradient.map((c) => c.withValues(alpha:.15)).toList(),
              ),
              shape: BoxShape.circle,
              border: Border.all(
                color: step.gradient[0].withValues(alpha:.3),
                width: 3,
              ),
              boxShadow: [
                BoxShadow(
                  color: step.gradient[0].withValues(alpha:.1),
                  blurRadius: 24,
                  spreadRadius: 8,
                ),
              ],
            ),
            child: Center(
              child: Text(
                step.emoji,
                style: TextStyle(
                  fontSize: size.width * 0.18,
                ),
              ),
            ),
          ),
          const SizedBox(height: 40),

          // Title
          Text(
            step.title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w900,
                  letterSpacing: -.5,
                ),
          ),
          const SizedBox(height: 16),

          // Body text
          Text(
            step.body,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  height: 1.6,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 24),

          // Feature chips
          _FeatureChips(emoji: step.emoji),
        ],
      ),
    );
  }
}

class _FeatureChips extends StatelessWidget {
  const _FeatureChips({required this.emoji});

  final String emoji;

  @override
  Widget build(BuildContext context) {
    final chips = <_ChipData>[];

    switch (emoji) {
      case '🐝':
        chips.addAll([
          _ChipData('Family-Friendly', Icons.family_restroom_rounded, AppColors.honeyGold),
          _ChipData('COPPA Safe', Icons.shield_rounded, AppColors.grassGreen),
          _ChipData('Free to Start', Icons.card_giftcard_rounded, AppColors.skyBlue),
        ]);
        break;
      case '🏠':
        chips.addAll([
          _ChipData('Adult Accounts', Icons.person_rounded, AppColors.skyBlue),
          _ChipData('Kid Profiles', Icons.child_care_rounded, AppColors.honeyGold),
          _ChipData('Invite Codes', Icons.mail_outline_rounded, AppColors.grassGreen),
        ]);
        break;
      case '✅':
        chips.addAll([
          _ChipData('Recurring', Icons.repeat_rounded, AppColors.skyBlue),
          _ChipData('Photo Verify', Icons.camera_alt_rounded, AppColors.grassGreen),
          _ChipData('Reminders', Icons.notifications_active_rounded, AppColors.coral),
        ]);
        break;
      case '🏆':
        chips.addAll([
          _ChipData('Points', Icons.stars_rounded, AppColors.honeyGold),
          _ChipData('Streaks', Icons.local_fire_department_rounded, AppColors.coral),
          _ChipData('Badges', Icons.military_tech_rounded, AppColors.skyBlue),
        ]);
        break;
      case '🍽️':
        chips.addAll([
          _ChipData('Recipes', Icons.menu_book_rounded, AppColors.coral),
          _ChipData('Meal Plans', Icons.calendar_month_rounded, AppColors.grassGreen),
          _ChipData('Auto Shopping', Icons.shopping_cart_rounded, AppColors.skyBlue),
        ]);
        break;
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: chips.map((chip) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: chip.color.withValues(alpha:.1),
          borderRadius: BorderRadius.circular(100),
          border: Border.all(color: chip.color.withValues(alpha:.2)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(chip.icon, size: 16, color: chip.color),
            const SizedBox(width: 6),
            Text(
              chip.label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: chip.color,
              ),
            ),
          ],
        ),
      )).toList(),
    );
  }
}

class _ChipData {
  const _ChipData(this.label, this.icon, this.color);
  final String label;
  final IconData icon;
  final Color color;
}

/// Helper to check if onboarding has been completed.
Future<bool> isOnboardingComplete() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool('onboarding_completed') ?? false;
}
