import 'package:flutter/material.dart';
import 'chore_dashboard_screen.dart';
import 'meal_planner_screen.dart';
import 'shopping_list_screen.dart';
import 'calendar_screen.dart';
import 'recipe_library_screen.dart';

class HomeShellScreen extends StatefulWidget {
  const HomeShellScreen({super.key});

  @override
  State<HomeShellScreen> createState() => _HomeShellScreenState();
}

class _HomeShellScreenState extends State<HomeShellScreen> {
  int index = 0;

  final screens = const [
    ChoreDashboardScreen(),
    MealPlannerScreen(),
    ShoppingListScreen(),
    CalendarScreen(),
    RecipeLibraryScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: screens[index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (value) => setState(() => index = value),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.task_alt_rounded), label: 'Chores'),
          NavigationDestination(icon: Icon(Icons.restaurant_menu_rounded), label: 'Meals'),
          NavigationDestination(icon: Icon(Icons.shopping_cart_rounded), label: 'Shop'),
          NavigationDestination(icon: Icon(Icons.calendar_month_rounded), label: 'Calendar'),
          NavigationDestination(icon: Icon(Icons.menu_book_rounded), label: 'Recipes'),
        ],
      ),
    );
  }
}
