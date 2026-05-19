import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final pageController = PageController();
  int index = 0;

  final steps = const [
    _OnboardingStep('Welcome to your hive 🐝', 'Chores, meals, shopping, and family reminders in one playful home base.'),
    _OnboardingStep('Create your household', 'Name your home, pick a theme, and invite adults or add kid-safe sub-profiles.'),
    _OnboardingStep('Add chore templates', 'Start fast with room-based templates and suggested point values.'),
    _OnboardingStep('Choose rewards', 'Turn completed chores into points, prizes, streaks, and celebrations.'),
    _OnboardingStep('Plan meals and lists', 'Import recipes, plan meals, and move selected ingredients to your shopping list.'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Expanded(
                child: PageView.builder(
                  controller: pageController,
                  itemCount: steps.length,
                  onPageChanged: (value) => setState(() => index = value),
                  itemBuilder: (context, i) => _StepCard(step: steps[i]),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(steps.length, (i) => AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: i == index ? 28 : 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: i == index ? AppColors.honeyGold : Colors.grey.shade400,
                    borderRadius: BorderRadius.circular(999),
                  ),
                )),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () {
                  if (index < steps.length - 1) {
                    pageController.nextPage(duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
                  } else {
                    // TODO: Navigate to account creation / Supabase auth.
                  }
                },
                child: Text(index < steps.length - 1 ? 'Next' : 'Start setup'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OnboardingStep {
  const _OnboardingStep(this.title, this.body);
  final String title;
  final String body;
}

class _StepCard extends StatelessWidget {
  const _StepCard({required this.step});
  final _OnboardingStep step;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 140,
              height: 140,
              decoration: BoxDecoration(
                color: AppColors.honeyGold.withOpacity(.18),
                shape: BoxShape.circle,
              ),
              child: const Center(child: Text('🐝', style: TextStyle(fontSize: 72))),
            ),
            const SizedBox(height: 32),
            Text(step.title, textAlign: TextAlign.center, style: textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900)),
            const SizedBox(height: 16),
            Text(step.body, textAlign: TextAlign.center, style: textTheme.titleMedium?.copyWith(height: 1.35)),
          ],
        ),
      ),
    );
  }
}
