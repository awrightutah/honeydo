import 'package:flutter/material.dart';

class ShoppingListScreen extends StatelessWidget {
  const ShoppingListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Shopping List 🛒')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          ListTile(leading: Icon(Icons.add_circle_outline), title: Text('Manual item entry')),
          ListTile(leading: Icon(Icons.restaurant), title: Text('Add selected ingredients from a recipe')),
          ListTile(leading: Icon(Icons.storefront), title: Text('Multi-store sections like Apple shopping lists')),
        ],
      ),
    );
  }
}
