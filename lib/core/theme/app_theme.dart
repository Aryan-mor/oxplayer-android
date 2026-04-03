import 'package:flutter/material.dart';

/// Visual language aligned with the legacy Tailwind palette (`telecima-*`).
class AppColors {
  static const bg = Color(0xFF0B0F14);
  static const card = Color(0xFF151B24);
  static const border = Color(0xFF2A3441);
  static const highlight = Color(0xFF38BDF8);
  static const textMuted = Color(0xFF9CA3AF);
}

/// Shared TV-safe layout (bezel / overscan breathing room).
class AppLayout {
  AppLayout._();

  static const double screenBottomInset = 28;
}

ThemeData buildTeleCimaTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: AppColors.bg,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.highlight,
      brightness: Brightness.dark,
      surface: AppColors.card,
    ),
    dividerColor: AppColors.border,
  );
  return base.copyWith(
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.bg,
      foregroundColor: Colors.white,
      elevation: 0,
    ),
    cardTheme: CardThemeData(
      color: AppColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.black.withValues(alpha: 0.35),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.highlight, width: 2),
      ),
    ),
  );
}
