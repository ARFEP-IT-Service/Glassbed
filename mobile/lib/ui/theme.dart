import 'package:flutter/material.dart';

/// Colours of the Windows app, so both look like one product.
class Palette {
  const Palette({
    required this.background,
    required this.surface,
    required this.raised,
    required this.line,
    required this.text,
    required this.muted,
    required this.accent,
    required this.danger,
  });

  final Color background;
  final Color surface;
  final Color raised;
  final Color line;
  final Color text;
  final Color muted;
  final Color accent;
  final Color danger;

  static const dark = Palette(
    background: Color(0xFF111316),
    surface: Color(0xFF1B1E22),
    raised: Color(0xFF24282D),
    line: Color(0xFF30353B),
    text: Color(0xFFE9ECEF),
    muted: Color(0xFF8B939C),
    accent: Color(0xFF1581FF),
    danger: Color(0xFFFF4FA8),
  );

  static const light = Palette(
    background: Color(0xFFDDE2E6),
    surface: Color(0xFFF7F8F9),
    raised: Color(0xFFFFFFFF),
    line: Color(0xFFCBD2D8),
    text: Color(0xFF15181B),
    muted: Color(0xFF5B646D),
    accent: Color(0xFF0A5FCC),
    danger: Color(0xFFD6247F),
  );

  static Palette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

ThemeData buildTheme(Brightness brightness) {
  final p = brightness == Brightness.dark ? Palette.dark : Palette.light;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: p.accent,
    onPrimary: Colors.white,
    secondary: p.accent,
    onSecondary: Colors.white,
    error: p.danger,
    onError: Colors.white,
    surface: p.surface,
    onSurface: p.text,
    onSurfaceVariant: p.muted,
    surfaceContainerLowest: p.background,
    surfaceContainerLow: p.surface,
    surfaceContainer: p.surface,
    surfaceContainerHigh: p.raised,
    surfaceContainerHighest: p.raised,
    outline: p.line,
    outlineVariant: p.line,
    primaryContainer: p.accent.withValues(alpha: 0.18),
    onPrimaryContainer: p.text,
    secondaryContainer: p.accent.withValues(alpha: 0.22),
    onSecondaryContainer: p.text,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.background,
    dividerColor: p.line,
    appBarTheme: AppBarTheme(
      backgroundColor: p.background,
      foregroundColor: p.text,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    cardTheme: CardThemeData(
      color: p.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: p.line),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.raised,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: p.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: p.line),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    // Comfortable touch targets everywhere.
    materialTapTargetSize: MaterialTapTargetSize.padded,
    visualDensity: VisualDensity.standard,
  );
}
