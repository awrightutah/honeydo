import 'package:flutter/material.dart';

class MealPlannerScreen extends StatelessWidget {
  const MealPlannerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Meal Planner 🍽️')),
      body: const Center(child: Text('30-day meal planner shell')),
    );
  }
}
