import 'package:flutter/material.dart';

/// Semantic colours not covered by ColorScheme (docs/08_ui_spec.md §4).
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.diffAdded,
    required this.diffAddedText,
    required this.diffRemoved,
    required this.diffRemovedText,
    required this.cellBackground,
    required this.stderrBackground,
    required this.aiBadge,
  });

  final Color diffAdded;
  final Color diffAddedText;
  final Color diffRemoved;
  final Color diffRemovedText;
  final Color cellBackground;
  final Color stderrBackground;
  final Color aiBadge;

  static const light = AppColors(
    diffAdded: Color(0xFFE6F4EA),
    diffAddedText: Color(0xFF14532D),
    diffRemoved: Color(0xFFFCE8E8),
    diffRemovedText: Color(0xFF7F1D1D),
    cellBackground: Color(0xFFF5F6F8),
    stderrBackground: Color(0xFFFDECEC),
    aiBadge: Color(0xFF6D28D9),
  );

  static const dark = AppColors(
    diffAdded: Color(0xFF12301E),
    diffAddedText: Color(0xFFB7EBC6),
    diffRemoved: Color(0xFF3A1717),
    diffRemovedText: Color(0xFFF5B5B5),
    cellBackground: Color(0xFF1E2128),
    stderrBackground: Color(0xFF3A1D1D),
    aiBadge: Color(0xFFC4B5FD),
  );

  @override
  AppColors copyWith() => this;

  @override
  AppColors lerp(AppColors? other, double t) =>
      t < 0.5 ? this : (other ?? this);
}

extension AppColorsX on BuildContext {
  AppColors get colors => Theme.of(this).extension<AppColors>()!;
}

const _seed = Color(0xFF2F4B7C);

ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: VisualDensity.standard,
    extensions: [
      brightness == Brightness.dark ? AppColors.dark : AppColors.light,
    ],
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      space: 1,
      thickness: 1,
    ),
    listTileTheme: const ListTileThemeData(dense: true, minTileHeight: 44),
  );
}

/// Monospace text style using the platform font.
TextStyle monoStyle(BuildContext context, {double? size, Color? color}) =>
    TextStyle(
      fontFamily: 'monospace',
      fontFamilyFallback: const ['Menlo', 'Courier New', 'monospace'],
      fontSize: size ?? 13,
      height: 1.35,
      color: color ?? Theme.of(context).colorScheme.onSurface,
    );

/// Layout breakpoints (docs/08_ui_spec.md §2).
abstract final class Breakpoints {
  static const tablet = 600.0;
  static const wide = 840.0;
}
