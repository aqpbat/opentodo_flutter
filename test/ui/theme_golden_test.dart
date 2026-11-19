// Golden sheets of the design tokens and themed components, light and dark.
// Regenerate after an intentional token change:
//   flutter test --update-goldens test/ui/theme_golden_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:opentodo_flutter/ui/theme.dart';
import 'package:opentodo_flutter/ui/tokens.dart';

void main() {
  for (final mode in ['light', 'dark']) {
    testWidgets('token sheet $mode', (tester) async {
      tester.view.physicalSize = const Size(800, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: mode == 'light' ? OtTheme.light : OtTheme.dark,
        home: const _Sheet(),
      ));
      await expectLater(find.byType(_Sheet), matchesGoldenFile('goldens/theme_$mode.png'));
    });
  }
}

class _Sheet extends StatelessWidget {
  const _Sheet();

  @override
  Widget build(BuildContext context) {
    final c = context.ot;
    final p = c.palette;
    final text = Theme.of(context).textTheme;
    Widget row(String title, List<(String, Color)> items) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: text.titleSmall),
              const SizedBox(height: 4),
              Wrap(spacing: 4, runSpacing: 4, children: [
                for (final (name, color) in items) _Swatch(name, color),
              ]),
            ],
          ),
        );
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            row('Surfaces', [
              ('canvas', p.canvas), ('surface', p.surface), ('raised', p.raised),
              ('sunken', p.sunken), ('pop', p.pop), ('hover', p.hover),
              ('selected', p.selected), ('selRow', p.selectedRow),
            ]),
            row('Text & lines', [
              ('strong', p.textStrong), ('text', p.text), ('muted', p.muted), ('faint', p.faint),
              ('border', p.border), ('soft', p.borderSoft), ('input', p.borderInput),
              ('lineStr', p.lineStrong),
            ]),
            row('Accent', [
              ('accent', p.accent), ('hover', p.accentHover), ('text', p.accentText),
              ('soft', p.accentSoft), ('softTx', p.accentSoftText), ('focus', p.focus),
            ]),
            row('Priority', [
              for (var i = 1; i <= 4; i++) ...[('p$i', c.priority(i)), ('p${i}s', c.prioritySoft(i))],
            ]),
            row('Status', [
              ('ok', p.success), ('okSoft', p.successSoft), ('warn', p.warning),
              ('warnSoft', p.warningSoft), ('danger', p.danger), ('dSoft', p.dangerSoft),
              ('info', p.info), ('iSoft', p.infoSoft), ('scrim', p.scrim), ('hl', p.highlight),
            ]),
            row('Hues', [for (final h in OtHue.values) (h.name, c.hue(h).solid)]),
            Wrap(spacing: 4, runSpacing: 4, children: [
              for (final h in OtHue.values)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: c.hue(h).soft,
                    borderRadius: BorderRadius.circular(OtRadii.chip),
                  ),
                  child: Text(h.name, style: OtType.meta.copyWith(color: c.hue(h).text)),
                ),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              FilledButton(onPressed: () {}, child: const Text('Add task')),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: () {}, child: const Text('Cancel')),
              const SizedBox(width: 8),
              TextButton(onPressed: () {}, child: const Text('Link')),
              const SizedBox(width: 8),
              Checkbox(value: true, onChanged: (_) {}),
              Checkbox(value: false, onChanged: (_) {}),
              const Chip(label: Text('label')),
            ]),
            const SizedBox(height: 8),
            const SizedBox(
              width: 300,
              child: TextField(decoration: InputDecoration(hintText: 'Task name')),
            ),
            const SizedBox(height: 8),
            Card(
              child: Column(children: [
                for (final prio in [1, 2, 4])
                  ListTile(
                    leading: Icon(Icons.circle_outlined, color: c.priority(prio)),
                    title: Text('Priority $prio task'),
                    subtitle: Text('Today', style: OtType.meta.copyWith(color: c.success)),
                  ),
              ]),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: p.pop,
                borderRadius: BorderRadius.circular(OtRadii.popover),
                border: Border.all(color: p.lineStrong),
                boxShadow: OtElevation.level2,
              ),
              child: Text('Popover with shadow-2', style: OtType.body.copyWith(color: p.text)),
            ),
            const SizedBox(height: 8),
            Text('Heading 1', style: text.headlineLarge),
            Text('Body text', style: text.bodyMedium),
            Text('Meta text', style: text.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch(this.name, this.color);

  final String name;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 72,
      child: Column(children: [
        Container(
          height: 28,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(OtRadii.chip),
            border: Border.all(color: context.ot.border),
          ),
        ),
        Text(name, style: OtType.hint.copyWith(color: context.ot.muted)),
      ]),
    );
  }
}
