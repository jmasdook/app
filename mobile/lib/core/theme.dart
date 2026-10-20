import 'package:flutter/material.dart';

/// Warm-white surfaces, deep navy text, one teal accent. Min touch target 48dp, AA contrast.
class AppColors {
  static const bg = Color(0xFFFAF8F5);
  static const surface = Colors.white;
  static const navy = Color(0xFF14213D);
  static const muted = Color(0xFF5C6578);
  static const border = Color(0xFFE7E2D9);
  static const accent = Color(0xFF0F8B7D);
  static const accentSoft = Color(0xFFDFF3EF);
  static const danger = Color(0xFFB3261E);
  static const warn = Color(0xFF9A6700);
  static const ok = Color(0xFF1A7F4B);
}

ThemeData buildTheme({Brightness brightness = Brightness.light}) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.accent,
    brightness: brightness,
    primary: dark ? const Color(0xFF3CC3B2) : AppColors.accent,
    surface: dark ? const Color(0xFF161D2E) : AppColors.surface,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: brightness);
  return base.copyWith(
    scaffoldBackgroundColor: dark ? const Color(0xFF0E1422) : AppColors.bg,
    textTheme: base.textTheme.apply(bodyColor: dark ? const Color(0xFFEDF0F7) : AppColors.navy, displayColor: dark ? const Color(0xFFEDF0F7) : AppColors.navy),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: dark ? const Color(0xFF263049) : AppColors.border)),
      margin: EdgeInsets.zero,
    ),
    appBarTheme: AppBarTheme(backgroundColor: Colors.transparent, elevation: 0, scrolledUnderElevation: 0, centerTitle: false,
        titleTextStyle: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, color: dark ? const Color(0xFFEDF0F7) : AppColors.navy)),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)), textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)))),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surface,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: dark ? const Color(0xFF263049) : AppColors.border)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    ),
    navigationBarTheme: NavigationBarThemeData(backgroundColor: scheme.surface, indicatorColor: dark ? const Color(0xFF133A37) : AppColors.accentSoft),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {TargetPlatform.android: FadeForwardsPageTransitionsBuilder()}),
  );
}
