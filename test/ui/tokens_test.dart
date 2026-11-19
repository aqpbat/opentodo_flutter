// Token values map correctly: generated colours match an independent
// OKLCH → sRGB conversion of the web literals (web/src/index.css), well-known
// Tailwind anchors, and the ThemeData slots they are wired into.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:opentodo_flutter/main.dart';
import 'package:opentodo_flutter/ui/theme.dart';
import 'package:opentodo_flutter/ui/tokens.dart';

/// OKLCH → sRGB channels 0–255 (OKLab matrices by Björn Ottosson).
List<int> oklch(double l, double c, double h) {
  final hr = h * math.pi / 180;
  final a = c * math.cos(hr), b = c * math.sin(hr);
  double cube(double v) => v * v * v;
  final lm = cube(l + 0.3963377774 * a + 0.2158037573 * b);
  final mm = cube(l - 0.1055613458 * a - 0.0638541728 * b);
  final sm = cube(l - 0.0894841775 * a - 1.2914855480 * b);
  final lin = [
    4.0767416621 * lm - 3.3077115913 * mm + 0.2309699292 * sm,
    -1.2684380046 * lm + 2.6097574011 * mm - 0.3413193965 * sm,
    -0.0041960863 * lm - 0.7034186147 * mm + 1.7076147010 * sm,
  ];
  return [
    for (final v in lin)
      (255 *
              (v <= 0.0031308
                  ? 12.92 * v.clamp(0, 1)
                  : 1.055 * math.pow(v.clamp(0, 1), 1 / 2.4) - 0.055))
          .round(),
  ];
}

void expectOklch(Color actual, double l, double c, double h, String name) {
  final want = oklch(l, c, h);
  final got = [actual.r, actual.g, actual.b].map((v) => (v * 255).round()).toList();
  for (var i = 0; i < 3; i++) {
    expect((got[i] - want[i]).abs(), lessThanOrEqualTo(1), reason: '$name: $got vs $want');
  }
}

void main() {
  group('palette matches index.css literals', () {
    test('light', () {
      const p = OtPalette.light;
      expectOklch(p.canvas, 0.9542, 0.0034, 247.86, 'canvas');
      expectOklch(p.surface, 1, 0, 0, 'surface');
      expectOklch(p.raised, 0.9757, 0, 0, 'raised');
      expectOklch(p.text, 0.2126, 0.0067, 258.37, 'text');
      expectOklch(p.muted, 0.491, 0.0142, 259.82, 'muted');
      expectOklch(p.border, 0.905, 0.0046, 258.33, 'border');
      expectOklch(p.accent, 0.5081, 0.1049, 165.61, 'accent');
      expectOklch(p.p1, 0.5771, 0.2152, 27.33, 'p1');
      expectOklch(p.p2, 0.6461, 0.1943, 41.12, 'p2');
      expectOklch(p.p3, 0.5461, 0.2152, 262.88, 'p3');
      expectOklch(p.p4, 0.5544, 0.0407, 257.42, 'p4');
      expectOklch(p.danger, 0.5283, 0.1796, 27.4, 'danger');
      expectOklch(p.warning, 0.4921, 0.1095, 66.01, 'warning');
      expectOklch(p.info, 0.5071, 0.162, 260.46, 'info');
      expectOklch(p.hues[OtHue.violet]!.solid, 0.5413, 0.2466, 293.01, 'violet');
    });

    test('dark', () {
      const p = OtPalette.dark;
      expectOklch(p.canvas, 0.1635, 0.0045, 264.44, 'canvas');
      expectOklch(p.surface, 0.1959, 0.0062, 271.09, 'surface');
      expectOklch(p.pop, 0.2271, 0.0079, 274.58, 'pop');
      expectOklch(p.text, 0.9459, 0.0029, 264.54, 'text');
      expectOklch(p.accentText, 0.7729, 0.1535, 163.22, 'accentText');
      expectOklch(p.p1, 0.7106, 0.1661, 22.22, 'p1');
      expectOklch(p.success, 0.7729, 0.1535, 163.22, 'success');
      expectOklch(p.danger, 0.6986, 0.1576, 23.81, 'danger');
      expectOklch(p.hues[OtHue.pink]!.solid, 0.7253, 0.1752, 349.76, 'pink');
    });
  });

  test('Tailwind anchors (the web palette was tuned from them)', () {
    expect(OtPalette.light.accent, const Color(0xFF047857)); // emerald-700
    expect(OtPalette.light.p1, const Color(0xFFDC2626)); // red-600
    expect(OtPalette.light.p3, const Color(0xFF2563EB)); // blue-600
    expect(OtPalette.light.p4, const Color(0xFF64748B)); // slate-500
  });

  test('derived steps and alpha', () {
    // Dark buttons keep the light accent; soft priority tints are translucent.
    expect(OtPalette.dark.accent, OtPalette.light.accent);
    expect(OtPalette.dark.p1Soft.a, closeTo(0.4, 0.01));
    expect(OtPalette.light.scrim.a, closeTo(0.35, 0.01));
    // Mixes toward black darken, into the surface lighten (light theme).
    final l = OtPalette.light;
    expect(l.accentHover.computeLuminance(), lessThan(l.accent.computeLuminance()));
    expect(l.accentSoft.computeLuminance(), greaterThan(l.accent.computeLuminance()));
    expect(l.hues.length, OtHue.values.length);
    expect(OtPalette.dark.hues.length, OtHue.values.length);
  });

  test('radii, elevation, type and motion', () {
    expect([OtRadii.chip, OtRadii.control, OtRadii.card, OtRadii.surface, OtRadii.popover],
        [6, 7, 8, 10, 12]);
    expect(OtElevation.level1, isEmpty);
    expect(OtElevation.level2.single.blurRadius, 12);
    expect(OtElevation.level3.single.offset, const Offset(0, 12));
    expect(OtType.body.fontSize, 13);
    expect(OtType.prose.fontSize, 15);
    expect(OtType.h1.fontSize, 22);
    expect(OtType.hint.fontWeight, FontWeight.w500);
    expect(OtMotion.ui, const Duration(milliseconds: 120));
    expect(OtMotion.moment, const Duration(milliseconds: 400));
  });

  group('ThemeData wiring', () {
    for (final (name, theme, palette) in [
      ('light', OtTheme.light, OtPalette.light),
      ('dark', OtTheme.dark, OtPalette.dark),
    ]) {
      test(name, () {
        final s = theme.colorScheme;
        expect(theme.brightness, palette == OtPalette.dark ? Brightness.dark : Brightness.light);
        expect(s.primary, palette.accent);
        expect(s.onPrimary, palette.onAccent);
        expect(s.error, palette.danger);
        expect(s.surface, palette.surface);
        expect(s.onSurface, palette.text);
        expect(theme.scaffoldBackgroundColor, palette.canvas);
        final ext = theme.extension<OtColors>()!;
        expect(ext.palette, same(palette));
        expect(ext.priority(1), palette.p1);
        expect(ext.priority(9), palette.p4);
        expect(ext.prioritySoft(2), palette.p2Soft);
        expect(ext.hue(OtHue.teal).solid, palette.hues[OtHue.teal]!.solid);
      });
    }

    test('extension lerps between themes', () {
      final mid = OtColors.light.lerp(OtColors.dark, 0.5);
      expect(mid.canvas, Color.lerp(OtPalette.light.canvas, OtPalette.dark.canvas, 0.5));
      expect(OtColors.light.lerp(OtColors.dark, 1).surface, OtPalette.dark.surface);
    });
  });

  testWidgets('app skeleton uses the token themes', (tester) async {
    await tester.pumpWidget(const OpenTodoApp());
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.theme, same(OtTheme.light));
    expect(app.darkTheme, same(OtTheme.dark));
    expect(find.text('OpenTodo'), findsOneWidget);
    final ctx = tester.element(find.text('Nothing here yet'));
    expect(ctx.ot.palette, same(OtPalette.light));
  });
}
