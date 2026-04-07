import 'package:flutter/material.dart';

/// Visual language aligned with the app brand palette (`oxplayer-*` hues).
class AppColors {
  static const bg = Color(0xFF0B0F14);
  static const surface = Color(0xFF141A22);
  static const surfaceContainer = Color(0xFF1A2230);
  static const card = surfaceContainer;
  static const border = Color(0xFF3A4553);
  static const highlight = Color(0xFF38BDF8);
  static const onSurfacePrimary = Color(0xFFF4F7FB);
  static const textMuted = Color(0xFFB5C0CE);
  static const focusGlow = Color(0x804ECAFF);
}

/// Shared overscan-safe layout (bezel breathing room on Android TV).
class AppLayout {
  AppLayout._();

  static const double screenBottomInset = 28;

  /// Horizontal inset for browse rows and detail body (TV overscan).
  static const double tvHorizontalInset = 52;

  /// Vertical gap between major sections on browse / detail screens.
  static const double tvSectionVerticalGap = 28;

  /// Top bar horizontal padding (inside [SafeArea]).
  static const double tvTopBarHorizontalPad = 20;
}

@immutable
class SkinMotionTokens extends ThemeExtension<SkinMotionTokens> {
  const SkinMotionTokens({
    required this.fast,
    required this.normal,
    required this.focusScale,
    required this.focusBorderWidth,
  });

  final Duration fast;
  final Duration normal;
  final double focusScale;
  final double focusBorderWidth;

  @override
  ThemeExtension<SkinMotionTokens> copyWith({
    Duration? fast,
    Duration? normal,
    double? focusScale,
    double? focusBorderWidth,
  }) {
    return SkinMotionTokens(
      fast: fast ?? this.fast,
      normal: normal ?? this.normal,
      focusScale: focusScale ?? this.focusScale,
      focusBorderWidth: focusBorderWidth ?? this.focusBorderWidth,
    );
  }

  @override
  ThemeExtension<SkinMotionTokens> lerp(
    covariant ThemeExtension<SkinMotionTokens>? other,
    double t,
  ) {
    if (other is! SkinMotionTokens) return this;
    return SkinMotionTokens(
      fast: t < 0.5 ? fast : other.fast,
      normal: t < 0.5 ? normal : other.normal,
      focusScale: focusScale + (other.focusScale - focusScale) * t,
      focusBorderWidth:
          focusBorderWidth + (other.focusBorderWidth - focusBorderWidth) * t,
    );
  }
}

ThemeData buildOxplayerTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: AppColors.bg,
    colorScheme: const ColorScheme.dark(
      primary: AppColors.highlight,
      onPrimary: Colors.black,
      surface: AppColors.surface,
      onSurface: AppColors.onSurfacePrimary,
      surfaceContainerHighest: AppColors.surfaceContainer,
      outline: AppColors.border,
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
      shadowColor: Colors.black.withValues(alpha: 0.35),
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.border),
      ),
    ),
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.onSurfacePrimary,
      displayColor: AppColors.onSurfacePrimary,
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
    extensions: const [
      SkinMotionTokens(
        fast: Duration(milliseconds: 150),
        normal: Duration(milliseconds: 220),
        focusScale: 1.02,
        focusBorderWidth: 2.5,
      ),
    ],
  );
}
