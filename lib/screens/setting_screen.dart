// Setting Screen
// This screen allows users to adjust their preferences and settings f or the app."""

import 'package:flutter/material.dart';
class SettingScreen extends StatelessWidget {
  const SettingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Settings"),
      ),
      body: const Center(
        child: Text("Settings will be implemented here."),
      ),
    );
  }
}