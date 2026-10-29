// The glass kit (UI_PLAN UI-1, owner amendments A1 and A3): one glass depth
// whose tint follows the sky behind it, one field, one action row, thin
// line glyphs. Synthetic text only.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/ui/icons.dart';
import 'package:illunis_client/ui/sky_light.dart';
import 'package:illunis_client/ui/tokens.dart';
import 'package:illunis_client/widgets/glass/glass_actions.dart';
import 'package:illunis_client/widgets/glass/glass_field.dart';
import 'package:illunis_client/widgets/glass/glass_sheet.dart';
import 'package:illunis_client/widgets/glass/glass_surface.dart';

/// A 360 x 800 screen with an optional SkyLight and one glass panel at
/// [panel] (global).
Future<void> pumpPanel(WidgetTester t, {SkyLight Function(Widget child)? sky, Rect panel = const Rect.fromLTWH(16, 500, 328, 120)}) async {
  t.view.physicalSize = const Size(360, 800);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final glass = Stack(children: [
    Positioned.fromRect(rect: panel, child: const GlassPanel(child: SizedBox.expand())),
  ]);
  await t.pumpWidget(MaterialApp(home: sky == null ? glass : sky(glass)));
  await t.pump();
}

double alphaOf(WidgetTester t) => t.state<GlassPanelState>(find.byType(GlassPanel)).alpha;

void main() {
  group('tint alpha (plan model, before the sky has been looked at)', () {
    testWidgets('no SkyLight: the worst-case alpha', (t) async {
      await pumpPanel(t);
      expect(alphaOf(t), GlassSpec.unknown);
    });

    testWidgets('night 0.40 and day 0.45 with no disc behind', (t) async {
      await pumpPanel(t, sky: (c) => SkyLight(daylight: 0, palette: Palette.night, child: c));
      expect(alphaOf(t), 0.40);
      await pumpPanel(t, sky: (c) => SkyLight(daylight: 1, palette: Palette.day, child: c));
      expect(alphaOf(t), 0.45);
    });

    testWidgets('0.80 with the moon behind the panel, 0.65 in twilight', (t) async {
      await pumpPanel(t,
          sky: (c) => SkyLight(
              daylight: 0, palette: Palette.night, discs: const [Rect.fromLTWH(170, 470, 24, 24)], child: c));
      expect(alphaOf(t), 0.80);
      await pumpPanel(t, sky: (c) => SkyLight(daylight: 0.5, palette: Palette.night, child: c));
      expect(alphaOf(t), 0.65);
    });
  });

  testWidgets('with a look at the sky: clear over the dark night, thicker over the moon', (t) async {
    final dark = _probe((x, y) => const Color(0xFF0B1630));
    await pumpPanel(t, sky: (c) => SkyLight(daylight: 0, palette: Palette.night, probe: dark, child: c));
    expect(alphaOf(t), GlassSpec.alphaFloor);
    final moonlit = _probe((x, y) => y > 60 && y < 80 ? const Color(0xFFE0E0D8) : const Color(0xFF0B1630));
    await pumpPanel(t, sky: (c) => SkyLight(daylight: 0, palette: Palette.night, probe: moonlit, child: c));
    expect(alphaOf(t), greaterThan(0.5));
  });

  testWidgets('one depth: no BackdropFilter under another, and glass in glass asserts', (t) async {
    await pumpPanel(t);
    for (final f in t.widgetList(find.byType(BackdropFilter))) {
      expect(find.descendant(of: find.byWidget(f), matching: find.byType(BackdropFilter)), findsNothing);
    }
    await t.pumpWidget(const MaterialApp(home: GlassPanel(child: GlassPanel(child: SizedBox()))));
    expect(t.takeException(), isAssertionError);
  });

  testWidgets('the glass has no pill radius and no sheen', (t) async {
    await pumpPanel(t);
    final clip = t.widget<ClipRSuperellipse>(find.byType(ClipRSuperellipse));
    final r = (clip.borderRadius as BorderRadius).topLeft.x;
    expect(r, Radii.glass);
    expect(r, lessThan(Radii.maxFor(120)));
    expect(find.byWidgetPredicate((w) => w is DecoratedBox && w.decoration is BoxDecoration &&
        (w.decoration as BoxDecoration).gradient != null), findsNothing);
  });

  group('GlassActions', () {
    testWidgets('every cell is at least 48 x 48, with no pill, and calls back', (t) async {
      final said = <String>[];
      await t.pumpWidget(MaterialApp(
        home: Material(
          child: Center(
            child: SizedBox(
              width: 320,
              child: GlassActions(actions: [
                GlassAction('Yes', () => said.add('Yes'), key: const ValueKey('y'), primary: true),
                GlassAction('No', () => said.add('No'), key: const ValueKey('n')),
              ]),
            ),
          ),
        ),
      ));
      for (final k in ['y', 'n']) {
        final s = t.getSize(find.byKey(ValueKey(k)));
        expect(s.height, greaterThanOrEqualTo(48));
        expect(s.width, greaterThanOrEqualTo(48));
        await t.tap(find.byKey(ValueKey(k)));
      }
      expect(said, ['Yes', 'No']);
      for (final w in t.widgetList<InkWell>(find.byType(InkWell))) {
        final shape = w.customBorder as RoundedRectangleBorder;
        expect((shape.borderRadius as BorderRadius).topLeft.x, lessThan(Radii.maxFor(48)));
      }
      // The primary cell is in the accent, the other in ink, both in label type.
      expect(t.widget<Text>(find.text('Yes')).style!.color, Palette.night.accent);
      expect(t.widget<Text>(find.text('No')).style!.color, Palette.night.ink);
      expect(t.widget<Text>(find.text('No')).style!.fontFamily, Fonts.sans);
      expect(find.byType(GlassPanel), findsNothing);
    });
  });

  group('GlassField', () {
    Future<List<String>> pumpField(WidgetTester t) async {
      final sent = <String>[];
      await t.pumpWidget(MaterialApp(
        home: Material(
          child: GlassField(
            hint: 'Write to Illunis',
            fieldKey: const ValueKey('f'),
            sendKey: const ValueKey('s'),
            onSubmit: sent.add,
          ),
        ),
      ));
      return sent;
    }

    testWidgets('hint in ink2, body type, a rule baseline, the send glyph', (t) async {
      await pumpField(t);
      final field = t.widget<TextField>(find.byKey(const ValueKey('f')));
      expect(field.decoration!.hintStyle!.color, Palette.night.ink2);
      expect(field.style!.fontSize, 16);
      expect(field.style!.fontFamily, Fonts.sans);
      expect(field.minLines, 1);
      expect(field.maxLines, 4);
      final base = t.widget<DecoratedBox>(find.byKey(const ValueKey('glass-field-baseline')));
      expect(((base.decoration as BoxDecoration).border as Border).bottom.color, Palette.night.rule);
      expect(find.descendant(of: find.byKey(const ValueKey('s')), matching: find.byType(IllunisIcon)), findsOneWidget);
    });

    testWidgets('send is inert and dim while the field is empty', (t) async {
      final sent = await pumpField(t);
      await t.tap(find.byKey(const ValueKey('s')));
      expect(sent, isEmpty);
      final dim = find.ancestor(of: find.byKey(const ValueKey('s')), matching: find.byType(AnimatedOpacity));
      expect(t.widget<AnimatedOpacity>(dim).opacity, GlassField.idleAlpha);
      expect(t.getSemantics(find.byKey(const ValueKey('s'))), isSemantics(hasEnabledState: true, isEnabled: false));
      await t.enterText(find.byKey(const ValueKey('f')), '   ');
      await t.pump();
      await t.tap(find.byKey(const ValueKey('s')));
      expect(sent, isEmpty);
      await t.enterText(find.byKey(const ValueKey('f')), 'Synthetic line');
      await t.pump();
      expect(t.widget<AnimatedOpacity>(dim).opacity, 1);
      await t.tap(find.byKey(const ValueKey('s')));
      expect(sent, ['Synthetic line']);
    });

    testWidgets('Enter submits the trimmed text and clears the field', (t) async {
      final sent = await pumpField(t);
      await t.enterText(find.byKey(const ValueKey('f')), '  Synthetic line ');
      await t.testTextInput.receiveAction(TextInputAction.send);
      await t.pump();
      expect(sent, ['Synthetic line']);
      expect(t.widget<TextField>(find.byKey(const ValueKey('f'))).controller!.text, isEmpty);
    });
  });

  testWidgets('a view sheet: one glass with top corners, the title, Close as a 48 px word at the top right',
      (t) async {
    t.view.physicalSize = const Size(360, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    var closed = 0, next = 0;
    await t.pumpWidget(MaterialApp(
      home: SkyLight(
        daylight: 1,
        palette: Palette.day,
        child: GlassSheet(
          child: Column(children: [
            SheetHeader(title: 'Food', onClose: () => closed++, closeKey: const ValueKey('close')),
            GlassGlyphAction(IllunisGlyph.forward, () => next++, key: const ValueKey('next'), label: 'Next day'),
          ]),
        ),
      ),
    ));
    await t.pump();
    expect(find.byType(GlassPanel), findsOneWidget);
    expect(t.widget<GlassPanel>(find.byType(GlassPanel)).borderRadius, GlassSheet.radius);
    final title = t.widget<Text>(find.text('Food')).style!;
    expect((title.fontFamily, title.fontSize, title.color), (Fonts.serif, 28, Palette.day.ink));
    final close = t.getRect(find.byKey(const ValueKey('close')));
    expect(close.height, greaterThanOrEqualTo(48));
    expect(close.width, greaterThanOrEqualTo(48));
    expect(close.right, lessThanOrEqualTo(360 - 8));
    expect(close.top, lessThan(t.getRect(find.text('Food')).bottom));
    expect(t.widget<Text>(find.text('Close')).style!.fontFamily, Fonts.sans);
    await t.tap(find.byKey(const ValueKey('close')));
    expect(closed, 1);
    expect(t.getSize(find.byKey(const ValueKey('next'))), const Size(48, 48));
    await t.tap(find.byKey(const ValueKey('next')));
    expect(next, 1);
    expect(find.bySemanticsLabel('Next day'), findsOneWidget);
  });

  testWidgets('every glyph paints a thin stroke and nothing filled', (t) async {
    for (final g in IllunisGlyph.values) {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      GlyphPainter(g, const Color(0xFFFFFFFF)).paint(canvas, const Size.square(20));
      final image = await t.runAsync(() => recorder.endRecording().toImage(20, 20));
      final bytes = (await t.runAsync(() => image!.toByteData()))!;
      var lit = 0;
      for (var i = 3; i < bytes.lengthInBytes; i += 4) {
        if (bytes.getUint8(i) > 0) lit++;
      }
      // Lines, not shapes: well under half the 400 px are touched.
      expect(lit, greaterThan(10), reason: '$g');
      expect(lit, lessThan(200), reason: '$g');
    }
  });
}

SkyProbe _probe(Color Function(int x, int y) at) {
  const w = 45, h = 100;
  final b = ByteData(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final c = at(x, y);
      final i = (y * w + x) * 4;
      b
        ..setUint8(i, (c.r * 255).round())
        ..setUint8(i + 1, (c.g * 255).round())
        ..setUint8(i + 2, (c.b * 255).round())
        ..setUint8(i + 3, 255);
    }
  }
  return SkyProbe.fromRgba(b, w, h);
}
