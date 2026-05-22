import 'package:flutter/material.dart';

class AppColors {
  static const honeyGold = Color(0xFFF5A623);
  static const skyBlue = Color(0xFF4A90D9);
  static const grassGreen = Color(0xFF7ED321);
  static const coral = Color(0xFFFF6B6B);
  static const warmBackground = Color(0xFFFFF8F0);
  static const charcoal = Color(0xFF2D3436);
  static const darkBackground = Color(0xFF151A1E);
}

class AppTheme {
  static ThemeData get light {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: AppColors.honeyGold,
      brightness: Brightness.light,
      primary: AppColors.honeyGold,
      secondary: AppColors.skyBlue,
      tertiary: AppColors.grassGreen,
      error: AppColors.coral,
      surface: Colors.white,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: AppColors.warmBackground,
      fontFamily: 'Nunito',
      cardTheme: CardThemeData(
        elevation: 0,
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
        ),
      ),
    );
  }

  static ThemeData get dark {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: AppColors.honeyGold,
      brightness: Brightness.dark,
      primary: AppColors.honeyGold,
      secondary: const Color(0xFF73B7F2),
      tertiary: const Color(0xFF9BE564),
      error: AppColors.coral,
      surface: const Color(0xFF20262C),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: AppColors.darkBackground,
      fontFamily: 'Nunito',
      cardTheme: CardThemeData(
        elevation: 0,
        color: const Color(0xFF20262C),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
        ),
      ),
    );
  }
}
