// Design tokens of the OpenTodo "Precision" design system, ported from
// web/src/index.css (`@theme inline` and the `--ot-*` blocks) and
// docs/design-system.md. Colours are generated into palette_generated.dart
// (node tool/sync_tokens.mjs); sizes, radii, elevation, type and motion are
// small and stable, so they live here by hand with their CSS source noted.
//
// Rule from the design system: choose a token by what it *means*, never by
// its hue today, and never write a raw colour in a screen.

import 'package:flutter/animation.dart' show Cubic;
import 'package:flutter/painting.dart';

export 'palette_generated.dart';

/// Corner radii (`--radius-*`, precision-tokens D3), in logical pixels.
abstract final class OtRadii {
  /// Rows and chips (`rounded-chip`).
  static const double chip = 6;

  /// Buttons and inputs (`rounded-control`).
  static const double control = 7;

  /// Cards (`rounded-card`).
  static const double card = 8;

  /// The one inset content surface (`rounded-surface`).
  static const double surface = 10;

  /// Popovers, menus, dialogs, sheets (`rounded-popover`).
  static const double popover = 12;
}

/// Elevation (`--shadow-*`). Lists and cards are flat; only overlays cast a
/// shadow (precision-tokens D4). The shadow colour is slate-900
/// (`rgb(15 23 42 / a)`) in both themes, as on the web.
abstract final class OtElevation {
  /// `shadow-1`: no shadow.
  static const List<BoxShadow> level1 = <BoxShadow>[];

  /// `shadow-2`: popovers and menus — `0 4px 12px rgb(15 23 42 / 0.10)`.
  static const List<BoxShadow> level2 = <BoxShadow>[
    BoxShadow(color: Color(0x1A0F172A), offset: Offset(0, 4), blurRadius: 12),
  ];

  /// `shadow-3`: dialogs — `0 12px 32px rgb(15 23 42 / 0.16)`.
  static const List<BoxShadow> level3 = <BoxShadow>[
    BoxShadow(color: Color(0x290F172A), offset: Offset(0, 12), blurRadius: 32),
  ];
}

/// Type scale (`--text-*`, precision-tokens D2, tokens-v2 D7). Sizes are the
/// web's rem values at 16 px; line heights are absolute, as in the CSS.
abstract final class OtType {
  /// Font family. The web bundles Inter as "OpenTodo Inter"; the Flutter
  /// client uses the platform font until a font asset is bundled.
  static const String? fontFamily = null;

  /// `text-hint`: 11.5 px, weight 500.
  static const TextStyle hint =
      TextStyle(fontSize: 11.5, height: 16 / 11.5, fontWeight: FontWeight.w500);

  /// `text-meta`: 12.5 px (dates, counts, secondary row lines).
  static const TextStyle meta = TextStyle(fontSize: 12.5, height: 18 / 12.5);

  /// `text-body`: 13 px, the list and control step (`--ot-text-list`).
  static const TextStyle body = TextStyle(fontSize: 13, height: 20 / 13);

  /// `text-prose`: 15 px, running text (notes, help).
  static const TextStyle prose = TextStyle(fontSize: 15, height: 24 / 15);

  /// `text-h3`: 14 px, weight 600 (section headings).
  static const TextStyle h3 =
      TextStyle(fontSize: 14, height: 20 / 14, fontWeight: FontWeight.w600);

  /// `text-title`: 16 px, weight 600, tracking −0.005em (task panel title).
  static const TextStyle title = TextStyle(
      fontSize: 16, height: 24 / 16, fontWeight: FontWeight.w600, letterSpacing: -0.08);

  /// `text-h2`: 20 px, weight 600, tracking −0.01em.
  static const TextStyle h2 = TextStyle(
      fontSize: 20, height: 28 / 20, fontWeight: FontWeight.w600, letterSpacing: -0.2);

  /// `text-h1`: 22 px, weight 600, tracking −0.015em (page titles).
  static const TextStyle h1 = TextStyle(
      fontSize: 22, height: 28 / 22, fontWeight: FontWeight.w600, letterSpacing: -0.33);

  /// `text-display`: 28 px, tracking −0.025em. The web uses weight 650;
  /// without a variable font the nearest Flutter weight is w600.
  static const TextStyle display = TextStyle(
      fontSize: 28, height: 34 / 28, fontWeight: FontWeight.w600, letterSpacing: -0.7);

  /// Task title weight in rows and cards (`--ot-title-weight`).
  static const FontWeight taskTitleWeight = FontWeight.w400;
}

/// Motion (`--duration-*`, `--ease-*`, tokens-v2 D9). Nothing lasts longer
/// than [moment]; an exit takes about three quarters of its entrance.
abstract final class OtMotion {
  /// Interface feedback.
  static const Duration ui = Duration(milliseconds: 120);

  /// Emphasis.
  static const Duration emphasis = Duration(milliseconds: 250);

  /// The completion sequence, list reflow and overlay entrances.
  static const Duration moment = Duration(milliseconds: 400);

  /// `--ease-calm`: cubic-bezier(0.2, 0.8, 0.2, 1).
  static const Cubic calm = Cubic(0.2, 0.8, 0.2, 1);

  /// `--ease-spring`: cubic-bezier(0.22, 1, 0.36, 1), settles without overshoot.
  static const Cubic spring = Cubic(0.22, 1, 0.36, 1);
}

/// Sizes (`--size-row`, design-system touch rules).
abstract final class OtSizes {
  /// Row height with a fine pointer (`--size-row`).
  static const double row = 36;

  /// Row height and minimum touch target on touch screens (pointer: coarse).
  static const double rowTouch = 44;

  /// Focus ring width (2 px with offset on the web).
  static const double focusRing = 2;

  /// Hairline border width.
  static const double hairline = 1;
}
