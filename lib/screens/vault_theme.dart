import 'package:flutter/material.dart';

/// Shared dark theme for the vault section.
/// A vault should feel secure and premium: deep charcoal surfaces,
/// a single indigo accent, generous rounding.
class VaultTheme {
  static const background = Color(0xFF101014);
  static const surface = Color(0xFF1B1B23);
  static const surfaceLight = Color(0xFF262631);
  static const accent = Color(0xFF7C6CF6);
  static const accentSoft = Color(0xFF3A3560);
  static const textPrimary = Color(0xFFF2F2F5);
  static const textSecondary = Color(0xFF9C9CA8);
  static const danger = Color(0xFFE5484D);

  static const cardRadius = 18.0;

  static BoxDecoration cardDecoration() {
    return BoxDecoration(
      color: surface,
      borderRadius: BorderRadius.circular(cardRadius),
      border: Border.all(color: Colors.white.withOpacity(0.06)),
    );
  }

  static InputDecoration inputDecoration(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: textSecondary),
      filled: true,
      fillColor: surfaceLight,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    );
  }
}
