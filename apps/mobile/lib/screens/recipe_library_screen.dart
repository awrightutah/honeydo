import 'package:flutter/material.dart';

class RecipeLibraryScreen extends StatelessWidget {
  const RecipeLibraryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Recipe Library 📚')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          ListTile(leading: Icon(Icons.public), title: Text('Browse master recipe library')),
          ListTile(leading: Icon(Icons.link), title: Text('Import recipes from URL')),
          ListTile(leading: Icon(Icons.playlist_add), title: Text('Move selected ingredients to shopping list')),
        ],
      ),
    );
  }
}
