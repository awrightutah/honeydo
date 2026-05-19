import 'package:flutter/material.dart';

class ChoreDashboardScreen extends StatelessWidget {
  const ChoreDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Today’s Chores 🐝')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          _HeroCard(title: 'Chore of the Day', body: 'Wipe Kitchen Counters · +5 bonus points'),
          SizedBox(height: 16),
          _HeroCard(title: 'Pending Verification', body: 'Completed chores will wait here for an Admin to approve.'),
          SizedBox(height: 16),
          _HeroCard(title: 'Rewards Progress', body: 'Earn points, keep streaks, and unlock household rewards.'),
        ],
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.title, required this.body});
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          Text(body),
        ]),
      ),
    );
  }
}
