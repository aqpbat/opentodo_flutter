// Light and dark ThemeData built from the OpenTodo design tokens
// (lib/ui/tokens.dart; source web/src/index.css, docs/design-system.md).
//
// Screens read colours in two ways:
//  * Material components pick them up from ThemeData/ColorScheme as usual.
//  * Semantic tokens that Material has no slot for (priority, status, palette
//    hues, canvas/raised/sunken surfaces, text tones) come from the
//    [OtColors] extension: `context.ot.p1`, `context.ot.muted`,
//    `context.ot.hue(OtHue.blue).soft`, `context.ot.priority(1)`.

import 'package:material_ui/material_ui.dart';

import 'tokens.dart';

/// Semantic colour tokens of the current theme, as a [ThemeExtension] so they
/// animate with theme changes and switch with brightness.
@immutable
class OtColors extends ThemeExtension<OtColors> {
  const OtColors(this.palette);

  static const OtColors light = OtColors(OtPalette.light);
  static const OtColors dark = OtColors(OtPalette.dark);

  /// Every `--ot-*` colour token of this theme.
  final OtPalette palette;

  // Shortcuts for the tokens screens use most; everything else is on [palette].
  Color get canvas => palette.canvas;
  Color get surface => palette.surface;
  Color get raised => palette.raised;
  Color get sunken => palette.sunken;
  Color get pop => palette.pop;
  Color get hover => palette.hover;
  Color get selected => palette.selected;
  Color get selectedRow => palette.selectedRow;
  Color get textStrong => palette.textStrong;
  Color get text => palette.text;
  Color get muted => palette.muted;
  Color get faint => palette.faint;
  Color get border => palette.border;
  Color get borderSoft => palette.borderSoft;
  Color get borderInput => palette.borderInput;
  Color get lineStrong => palette.lineStrong;
  Color get accent => palette.accent;
  Color get accentText => palette.accentText;
  Color get accentSoft => palette.accentSoft;
  Color get accentSoftText => palette.accentSoftText;
  Color get onAccent => palette.onAccent;
  Color get focus => palette.focus;
  Color get p1 => palette.p1;
  Color get p2 => palette.p2;
  Color get p3 => palette.p3;
  Color get p4 => palette.p4;
  Color get success => palette.success;
  Color get successSoft => palette.successSoft;
  Color get successSoftText => palette.successSoftText;
  Color get warning => palette.warning;
  Color get warningSoft => palette.warningSoft;
  Color get warningSoftText => palette.warningSoftText;
  Color get danger => palette.danger;
  Color get dangerSoft => palette.dangerSoft;
  Color get dangerSoftText => palette.dangerSoftText;
  Color get info => palette.info;
  Color get infoSoft => palette.infoSoft;
  Color get infoSoftText => palette.infoSoftText;
  Color get scrim => palette.scrim;
  Color get highlight => palette.highlight;
  Color get highlightText => palette.highlightText;

  /// The mark colour of task priority 1 (highest) … 4 (none). Values outside
  /// 1–4 fall back to 4, like the web's default priority.
  Color priority(int p) => switch (p) {
        1 => palette.p1,
        2 => palette.p2,
        3 => palette.p3,
        _ => palette.p4,
      };

  /// The soft tint of task priority 1 … 4.
  Color prioritySoft(int p) => switch (p) {
        1 => palette.p1Soft,
        2 => palette.p2Soft,
        3 => palette.p3Soft,
        _ => palette.p4Soft,
      };

  /// Solid, soft and text steps of a project/label palette hue.
  OtHueSteps hue(OtHue h) => palette.hues[h]!;

  @override
  OtColors copyWith({OtPalette? palette}) => OtColors(palette ?? this.palette);

  @override
  OtColors lerp(covariant ThemeExtension<OtColors>? other, double t) {
    if (other is! OtColors) return this;
    return OtColors(OtPalette.lerp(palette, other.palette, t));
  }
}

/// `context.ot` — the semantic colours of the nearest theme.
extension OtThemeContext on BuildContext {
  OtColors get ot => Theme.of(this).extension<OtColors>() ?? OtColors.light;
}

/// The OpenTodo themes.
abstract final class OtTheme {
  static final ThemeData light = build(Brightness.light);
  static final ThemeData dark = build(Brightness.dark);

  /// Builds the Material theme for [brightness] from the tokens.
  static ThemeData build(Brightness brightness) {
    final p = brightness == Brightness.dark ? OtPalette.dark : OtPalette.light;
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme(
      brightness: brightness,
      // Dark buttons keep the light accent; text and focus use the bright one.
      primary: p.accent,
      onPrimary: p.onAccent,
      primaryContainer: p.accentSoft,
      onPrimaryContainer: p.accentSoftText,
      secondary: p.accentText,
      onSecondary: dark ? p.canvas : p.onAccent,
      secondaryContainer: p.selected,
      onSecondaryContainer: p.textStrong,
      tertiary: p.info,
      onTertiary: dark ? p.canvas : p.onAccent,
      tertiaryContainer: p.infoSoft,
      onTertiaryContainer: p.infoSoftText,
      error: p.danger,
      onError: dark ? p.canvas : p.onAccent,
      errorContainer: p.dangerSoft,
      onErrorContainer: p.dangerSoftText,
      surface: p.surface,
      onSurface: p.text,
      onSurfaceVariant: p.muted,
      surfaceDim: p.canvas,
      surfaceBright: p.raised,
      surfaceContainerLowest: p.sunken,
      surfaceContainerLow: p.canvas,
      surfaceContainer: p.raised,
      surfaceContainerHigh: p.pop,
      surfaceContainerHighest: p.selected,
      outline: p.borderInput,
      outlineVariant: p.border,
      shadow: const Color(0xFF0F172A),
      scrim: p.scrim,
      inverseSurface: p.textStrong,
      onInverseSurface: p.surface,
      inversePrimary: p.accentText,
      surfaceTint: Colors.transparent,
    );

    TextStyle t(TextStyle s, Color c) => s.copyWith(color: c, fontFamily: OtType.fontFamily);
    final textTheme = TextTheme(
      displayLarge: t(OtType.display, p.textStrong),
      displayMedium: t(OtType.display, p.textStrong),
      displaySmall: t(OtType.display, p.textStrong),
      headlineLarge: t(OtType.h1, p.textStrong),
      headlineMedium: t(OtType.h1, p.textStrong),
      headlineSmall: t(OtType.h2, p.textStrong),
      titleLarge: t(OtType.h1, p.textStrong),
      titleMedium: t(OtType.title, p.textStrong),
      titleSmall: t(OtType.h3, p.textStrong),
      bodyLarge: t(OtType.prose, p.text),
      bodyMedium: t(OtType.body, p.text),
      bodySmall: t(OtType.meta, p.muted),
      labelLarge: t(OtType.body.copyWith(fontWeight: FontWeight.w500), p.text),
      labelMedium: t(OtType.meta, p.muted),
      labelSmall: t(OtType.hint, p.faint),
    );

    RoundedRectangleBorder rounded(double r, [BorderSide side = BorderSide.none]) =>
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(r), side: side);
    const buttonPadding = EdgeInsets.symmetric(horizontal: 12, vertical: 8);
    const buttonSize = Size(64, OtSizes.row);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: OtType.fontFamily,
      textTheme: textTheme,
      scaffoldBackgroundColor: p.canvas,
      canvasColor: p.canvas,
      dividerColor: p.borderSoft,
      hoverColor: p.hover,
      focusColor: p.focus.withValues(alpha: 0.24),
      highlightColor: Colors.transparent,
      splashFactory: NoSplash.splashFactory,
      visualDensity: VisualDensity.compact,
      extensions: <ThemeExtension<dynamic>>[OtColors(p)],
      appBarTheme: AppBarTheme(
        backgroundColor: p.canvas,
        foregroundColor: p.textStrong,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: t(OtType.h1, p.textStrong),
      ),
      cardTheme: CardThemeData(
        color: p.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: rounded(OtRadii.card, BorderSide(color: p.border)),
      ),
      dividerTheme: DividerThemeData(color: p.borderSoft, thickness: OtSizes.hairline, space: 1),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: p.accent,
          foregroundColor: p.onAccent,
          minimumSize: buttonSize,
          padding: buttonPadding,
          textStyle: OtType.body.copyWith(fontWeight: FontWeight.w500),
          shape: rounded(OtRadii.control),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: p.text,
          minimumSize: buttonSize,
          padding: buttonPadding,
          side: BorderSide(color: p.border),
          textStyle: OtType.body.copyWith(fontWeight: FontWeight.w500),
          shape: rounded(OtRadii.control),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: p.accentText,
          minimumSize: buttonSize,
          padding: buttonPadding,
          textStyle: OtType.body.copyWith(fontWeight: FontWeight.w500),
          shape: rounded(OtRadii.control),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.surface,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        hintStyle: t(OtType.body, p.faint),
        labelStyle: t(OtType.body, p.muted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(OtRadii.control),
          borderSide: BorderSide(color: p.borderInput),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(OtRadii.control),
          borderSide: BorderSide(color: p.borderInput),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(OtRadii.control),
          borderSide: BorderSide(color: p.focus, width: OtSizes.focusRing),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(OtRadii.control),
          borderSide: BorderSide(color: p.danger),
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: rounded(4),
        side: BorderSide(color: p.borderInput, width: 1.5),
        fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? p.success : Colors.transparent,
        ),
        checkColor: WidgetStatePropertyAll(dark ? p.canvas : p.onAccent),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: p.raised,
        side: BorderSide(color: p.border),
        shape: rounded(OtRadii.chip),
        labelStyle: t(OtType.meta, p.text),
        padding: const EdgeInsets.symmetric(horizontal: 6),
      ),
      listTileTheme: ListTileThemeData(
        dense: true,
        minTileHeight: OtSizes.row,
        iconColor: p.muted,
        textColor: p.text,
        selectedColor: p.textStrong,
        selectedTileColor: p.selectedRow,
        shape: rounded(OtRadii.chip),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: p.pop,
        surfaceTintColor: Colors.transparent,
        elevation: 2,
        shape: rounded(OtRadii.popover, BorderSide(color: p.lineStrong)),
        textStyle: t(OtType.body, p.text),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.pop,
        surfaceTintColor: Colors.transparent,
        shape: rounded(OtRadii.popover, BorderSide(color: p.lineStrong)),
        titleTextStyle: t(OtType.h2, p.textStrong),
        contentTextStyle: t(OtType.body, p.text),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: p.pop,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(OtRadii.popover)),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: p.canvas,
        surfaceTintColor: Colors.transparent,
        indicatorColor: p.selected,
        elevation: 0,
        labelTextStyle: WidgetStatePropertyAll(t(OtType.hint, p.muted)),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: p.textStrong,
        contentTextStyle: t(OtType.body, p.surface),
        actionTextColor: dark ? p.accent : OtPalette.dark.accentText,
        behavior: SnackBarBehavior.floating,
        shape: rounded(OtRadii.control),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: p.accentText),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: p.accentText,
        selectionColor: p.accentSoft,
        selectionHandleColor: p.accentText,
      ),
    );
  }
}
