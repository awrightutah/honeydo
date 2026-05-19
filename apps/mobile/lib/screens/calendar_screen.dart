import 'package:flutter/material.dart';

class CalendarScreen extends StatelessWidget {
  const CalendarScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Family Calendar 📅')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          ListTile(leading: CircleAvatar(backgroundColor: Color(0xFFF5A623)), title: Text('Custom tags and colors')),
          ListTile(leading: CircleAvatar(backgroundColor: Color(0xFF4A90D9)), title: Text('Filter by event tag')),
          ListTile(leading: CircleAvatar(backgroundColor: Color(0xFF7ED321)), title: Text('Shared reminders for everyone')),
        ],
      ),
    );
  }
}
