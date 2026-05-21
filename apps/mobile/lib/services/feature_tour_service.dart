import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/app_theme.dart';

/// Manages the first-time feature walkthrough tutorial.
/// Shows contextual tooltips highlighting key features after onboarding.
class FeatureTourService {
  FeatureTourService._();
  static final FeatureTourService instance = FeatureTourService._();

  static const _tourCompletedKey = 'feature_tour_completed';
  static const _tourVersionKey = 'feature_tour_version';
  static const int _currentTourVersion = 1;

  bool _tourCompleted = false;
  int _completedVersion = 0;

  bool get tourCompleted => _tourCompleted && _completedVersion >= _currentTourVersion;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _tourCompleted = prefs.getBool(_tourCompletedKey) ?? false;
    _completedVersion = prefs.getInt(_tourVersionKey) ?? 0;
  }

  Future<void> markTourCompleted() async {
    _tourCompleted = true;
    _completedVersion = _currentTourVersion;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_tourCompletedKey, true);
    await prefs.setInt(_tourVersionKey, _currentTourVersion);
  }

  Future<void> resetTour() async {
    _tourCompleted = false;
    _completedVersion = 0;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tourCompletedKey);
    await prefs.remove(_tourVersionKey);
  }
}

/// Describes a single tour step with target context and position.
class TourStep {
  final String id;
  final String title;
  final String description;
  final IconData icon;
  final Color color;

  const TourStep({
    required this.id,
    required this.title,
    required this.description,
    required this.icon,
    required this.color,
  });
}

/// Predefined tour steps for the home screen features.
class HomeTourSteps {
  static const steps = [
    TourStep(
      id: 'chores',
      title: 'Chore Dashboard',
      description: 'View and manage your assigned chores. Tap a chore to see details, mark it complete, or verify it. Use the + button to create new chores with recurring schedules.',
      icon: Icons.task_alt_rounded,
      color: AppColors.grassGreen,
    ),
    TourStep(
      id: 'meals',
      title: 'Meal Planner',
      description: 'Plan your family\'s meals for the week. Link recipes, assign cooks, and automatically add ingredients to your shopping list. Move meals between breakfast, lunch, and dinner.',
      icon: Icons.restaurant_menu_rounded,
      color: AppColors.skyBlue,
    ),
    TourStep(
      id: 'shopping',
      title: 'Shopping List',
      description: 'Keep track of everything you need. Items are auto-added from meal plans and recipes. Check off items as you shop, and organize by category or store.',
      icon: Icons.shopping_cart_rounded,
      color: AppColors.coral,
    ),
    TourStep(
      id: 'calendar',
      title: 'Calendar',
      description: 'See all household chores, events, and meal plans in a monthly view. Create custom events with tags and colors to keep everyone on the same page.',
      icon: Icons.calendar_month_rounded,
      color: AppColors.honeyGold,
    ),
    TourStep(
      id: 'recipes',
      title: 'Recipe Library',
      description: 'Browse your household recipes and our master library. Import recipes from URLs, add your own, and share them with the family. Tap a recipe to view full details.',
      icon: Icons.menu_book_rounded,
      color: Color(0xFFAB47BC),
    ),
    TourStep(
      id: 'search',
      title: 'Search',
      description: 'Find anything across chores, recipes, and shopping items. Use the search icon in the top bar to quickly locate what you need.',
      icon: Icons.search_rounded,
      color: AppColors.skyBlue,
    ),
    TourStep(
      id: 'points',
      title: 'Points & Rewards',
      description: 'Earn points for completing chores and climb the leaderboard! Kids can redeem points for custom rewards. Check your balance in the top bar.',
      icon: Icons.star_rounded,
      color: AppColors.honeyGold,
    ),
    TourStep(
      id: 'menu',
      title: 'More Features',
      description: 'Tap the ⋯ menu to access your profile, household stats, invite codes, announcements, achievements, settings, and more. Explore everything Honeydo has to offer!',
      icon: Icons.more_horiz_rounded,
      color: Colors.grey,
    ),
  ];
}

/// Full-screen overlay that walks users through feature highlights.
class FeatureTourOverlay extends StatefulWidget {
  final VoidCallback onCompleted;

  const FeatureTourOverlay({super.key, required this.onCompleted});

  @override
  State<FeatureTourOverlay> createState() => _FeatureTourOverlayState();
}

class _FeatureTourOverlayState extends State<FeatureTourOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fadeIn;
  int _currentStep = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _fadeIn = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next() {
    if (_currentStep < HomeTourSteps.steps.length - 1) {
      setState(() => _currentStep++);
    } else {
      _complete();
    }
  }

  void _skip() {
    _complete();
  }

  void _complete() async {
    await FeatureTourService.instance.markTourCompleted();
    widget.onCompleted();
  }

  @override
  Widget build(BuildContext context) {
    final step = HomeTourSteps.steps[_currentStep];
    final isLast = _currentStep == HomeTourSteps.steps.length - 1;

    return FadeTransition(
      opacity: _fadeIn,
      child: Container(
        color: Colors.black.withOpacity(0.75),
        child: SafeArea(
          child: Column(
            children: [
              const Spacer(),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Material(
                  elevation: 8,
                  borderRadius: BorderRadius.circular(24),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(28),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            color: step.color.withOpacity(0.15),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(step.icon, size: 32, color: step.color),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          step.title,
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            color: AppColors.navy,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          step.description,
                          style: TextStyle(
                            fontSize: 15,
                            height: 1.5,
                            color: Colors.grey[700],
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 28),
                        // Progress dots
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: List.generate(
                            HomeTourSteps.steps.length,
                            (i) => Container(
                              width: i == _currentStep ? 20 : 8,
                              height: 8,
                              margin: const EdgeInsets.symmetric(horizontal: 3),
                              decoration: BoxDecoration(
                                color: i == _currentStep
                                    ? step.color
                                    : Colors.grey[300],
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        Row(
                          children: [
                            TextButton(
                              onPressed: _skip,
                              child: Text(
                                'Skip',
                                style: TextStyle(color: Colors.grey[500]),
                              ),
                            ),
                            const Spacer(),
                            FilledButton(
                              onPressed: _next,
                              style: FilledButton.styleFrom(
                                backgroundColor: step.color,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 28,
                                  vertical: 14,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              child: Text(
                                isLast ? 'Get Started!' : 'Next',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 15,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}
