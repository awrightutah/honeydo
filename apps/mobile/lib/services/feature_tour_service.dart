import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

// Need to import AppColors
import '../theme/app_theme.dart';
