// Text straight on the sky (owner, 2026-10-29: no plates), in inverse
// colour (owner, 2026-10-30): white at TypeScale.inverseOpacity through a
// difference blend. Every step of the type scale is rendered with the real
// fonts over skies sampled from the phone, night and day, and the stroke
// cores are read against the pixels right beside them: with no halo where
// the sky alone reaches 4.5:1, and with the solved halo where it does not.
// Halo.reach and Halo.cover are checked against the same renders, so the
// solver's model cannot be kinder than the pixels.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:illunis_client/ui/tokens.dart';

import '../app/view_audit_helpers.dart';

/// Sky behind the text, sampled from phone screenshots (Blade V 5G, sky
/// time 2026-10-24 23:00 and 13:00, 3 px box blur, docs/UI_PLAN.md
/// "Typography decision 2026-10-29"). Night: the 1st and 99th percentile
/// where the reply sits, the brightest upper sky (the title band), the
/// input over the water, and the moon. Day: the lit clouds.
const nightSkies = {
  'night reply, dark': Color(0xFF12171D),
  'night reply, bright': Color(0xFF1D252F),
  'night upper, bright': Color(0xFF26313D),
  'night input, water': Color(0xFF0F1318),
  'night moon': moon,
};
const daySkies = {
  'day cloud': Color(0xFF919FA6),
  'day cloud, bright': Color(0xFFB9C2C8),
  'day blue, deep': Color(0xFF0E2139),
};

/// Skies past what a soft halo can do for inverse text at
/// [TypeScale.inverseOpacity]: the mid-tone day sky, whose inverse is a
/// mid-tone too (the median and the open blue between clouds, 10th
/// percentile). The full day halo lifts them; these are the floors measured.
const moon = Color(0xFFE9E7DF);
const beyond = {
  'day median': (Color(0xFF5D6D78), 3.9),
  'day blue': (Color(0xFF375565), 3.1),
};

typedef Step = (String, TextStyle Function(Color));
final steps = <Step>[
  ('display', TypeScale.display),
  ('caption', (c) => TypeScale.caption(c)),
  ('reply 22', (c) => TypeScale.reply(c)),
  ('reply 18', (c) => TypeScale.reply(c, size: 18)),
  ('body', (c) => TypeScale.body(c)),
  ('label', TypeScale.label),
  ('note', TypeScale.note),
];

const sample = 'Slow breath, 4 in and 6 out';
const ratio = 3.0; // device px per logical px, near the phone's 2.75

Future<(ByteData, int, int)> render(WidgetTester t, TextStyle style, Color sky) async {
  final key = GlobalKey();
  await t.pumpWidget(Directionality(
    textDirection: TextDirection.ltr,
    child: Center(
      child: RepaintBoundary(
        key: key,
        child: ColoredBox(
          color: sky,
          child: Padding(padding: const EdgeInsets.all(16), child: Text(sample, style: style)),
        ),
      ),
    ),
  ));
  final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(key));
  return (await t.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: ratio);
    final data = await image.toByteData();
    final out = (data!, image.width, image.height);
    image.dispose();
    return out;
  }))!;
}

int _ch(ByteData b, int i, int c) => b.getUint8(i * 4 + c);

Color _mean(List<double> sum, int n) =>
    Color.fromARGB(255, (sum[0] / n).round(), (sum[1] / n).round(), (sum[2] / n).round());

/// What the eye reads in [style] with [halo] at [strength] over [sky]: the
/// mean colour of the stroke cores (glyph coverage above 95 %) and of the
/// sky within [reach] px of a stroke but not on one. Coverage comes from
/// the same text in plain black on white.
Future<(Color, Color)> read(WidgetTester t, TextStyle style, Color halo, double strength, Color sky,
    {int reach = 2}) async {
  final (mask, w, h) =
      await render(t, style.copyWith(foreground: Paint()..color = const Color(0xFF000000)), const Color(0xFFFFFFFF));
  final (lit, _, _) = await render(t, style.copyWith(shadows: Halo.shadows(halo, strength)), sky);
  final cover = List<double>.generate(w * h, (i) => 1 - _ch(mask, i, 0) / 255);
  var nc = 0, nb = 0;
  final core = [0.0, 0.0, 0.0], beside = [0.0, 0.0, 0.0];
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      if (cover[i] > 0.95) {
        nc++;
        for (var c = 0; c < 3; c++) {
          core[c] += _ch(lit, i, c);
        }
        continue;
      }
      if (cover[i] > 0) continue;
      var near = false;
      for (var dy = -reach; dy <= reach && !near; dy++) {
        for (var dx = -reach; dx <= reach && !near; dx++) {
          final xx = x + dx, yy = y + dy;
          if (xx >= 0 && yy >= 0 && xx < w && yy < h && cover[yy * w + xx] > 0) near = true;
        }
      }
      if (!near) continue;
      nb++;
      for (var c = 0; c < 3; c++) {
        beside[c] += _ch(lit, i, c);
      }
    }
  }
  return (_mean(core, nc), _mean(beside, nb));
}

/// The channel the halo moves most over [sky].
int _channel(Color sky, Color halo) {
  final d = [halo.r - sky.r, halo.g - sky.g, halo.b - sky.b];
  var k = 0;
  for (var c = 1; c < 3; c++) {
    if (d[c].abs() > d[k].abs()) k = c;
  }
  return k;
}

double _at(Color c, int k) => [c.r, c.g, c.b][k];

/// The halo's share at a stroke's side (beside it) or under it (from the
/// stroke, undoing the difference blend), as a fraction of [halo]'s alpha.
double measuredShare(Color seen, Color sky, Color halo) {
  final k = _channel(sky, halo);
  return (_at(seen, k) - _at(sky, k)) / (_at(halo, k) - _at(sky, k)) / halo.a;
}

Color undoInverse(Color stroke) {
  const a = TypeScale.inverseOpacity;
  double ch(double t) => (a - t) / (2 * a - 1);
  return Color.from(alpha: 1, red: ch(stroke.r), green: ch(stroke.g), blue: ch(stroke.b));
}

void main() {
  setUpAll(loadCaptionFonts);

  test('the inverse rule: white at the opacity through a difference blend', () {
    expect(TypeScale.inverseText, isTrue);
    expect(TypeScale.inverseOpacity, 0.8);
    final s = TypeScale.body(Palette.night.ink);
    expect(TypeScale.isInverse(s), isTrue);
    expect(s.color, isNull);
    expect(s.foreground!.color.a, closeTo(TypeScale.inverseOpacity, 0.002));
    // a + d - 2ad per channel: 0.8 over black, 0.2 over white, a fixed point at mid grey.
    expect(inverseOf(const Color(0xFF000000)).r, closeTo(0.8, 1e-9));
    expect(inverseOf(const Color(0xFFFFFFFF)).r, closeTo(0.2, 1e-9));
    expect(inverseOf(const Color.from(alpha: 1, red: 0.5, green: 0.5, blue: 0.5)).g, closeTo(0.5, 1e-9));
    expect(inverseOf(const Color(0xFF000000), opacity: 1).b, closeTo(1, 1e-9));
  });

  testWidgets('Halo.reach and Halo.cover are no kinder than the pixels beside and under the strokes', (t) async {
    var leastReach = 1.0, leastCover = 2.0;
    final rows = <String>[];
    for (final (name, style) in steps) {
      for (final (p, sky) in [(Palette.night, moon), (Palette.day, const Color(0xFF3B78C9))]) {
        final (stroke, beside) = await read(t, style(p.ink), p.halo, 1, sky);
        final r = measuredShare(beside, sky, p.halo), c = measuredShare(undoInverse(stroke), sky, p.halo);
        leastReach = math.min(leastReach, r);
        leastCover = math.min(leastCover, c);
        rows.add('$name over ${p == Palette.night ? 'moon' : 'day blue'}: reach ${r.toStringAsFixed(3)} '
            'cover ${c.toStringAsFixed(3)}');
      }
    }
    debugPrint('${rows.join('\n')}\nleast reach ${leastReach.toStringAsFixed(3)}, token ${Halo.reach}; '
        'least cover ${leastCover.toStringAsFixed(3)}, token ${Halo.cover}');
    expect(leastReach, greaterThanOrEqualTo(Halo.reach));
    expect(leastCover, greaterThanOrEqualTo(Halo.cover));
  });

  testWidgets('every step reaches 4.5:1 on the night skies and the day clouds, with the solved halo', (t) async {
    final rows = <String>[];
    for (final (p, skies) in [(Palette.night, nightSkies), (Palette.day, daySkies)]) {
      for (final MapEntry(key: where, value: sky) in skies.entries) {
        final strength = solveHalo(p, [sky]);
        final model = textContrasts(p, strength, sky).single;
        for (final (name, style) in steps) {
          final (stroke, beside) = await read(t, style(p.ink), p.halo, strength, sky);
          final seen = contrast(stroke, beside);
          rows.add('$where | $name | halo ${strength.toStringAsFixed(2)} | model ${model.toStringAsFixed(1)} | '
              'read ${seen.toStringAsFixed(1)}');
          expect(seen, greaterThanOrEqualTo(4.5), reason: rows.last);
          // The solver's model is no kinder than the pixels.
          expect(model, lessThanOrEqualTo(seen + 0.1), reason: rows.last);
        }
      }
    }
    debugPrint(rows.join('\n'));
  });

  test('no halo where none is needed: the whole night sky, the moon, the deep day blue, haze', () {
    // Inverse text over a near-black sky is near white, not dark on dark:
    // the night needs no lighter base and no halo.
    for (final sky in nightSkies.values) {
      expect(solveHalo(Palette.night, [sky]), 0, reason: '$sky');
    }
    expect(solveHalo(Palette.night, [const Color(0xFF0B1630)]), 0);
    expect(solveHalo(Palette.day, [daySkies['day blue, deep']!]), 0);
    expect(solveHalo(Palette.day, [const Color(0xFFE8EEF5)]), 0);
  });

  testWidgets('past a soft halo: the mid-tone day sky, full strength, and what the text then reads at', (t) async {
    final rows = <String>[];
    for (final MapEntry(key: where, value: (sky, floor)) in beyond.entries) {
      expect(solveHalo(Palette.day, [sky]), 1, reason: where);
      final (bareStroke, bareBeside) = await read(t, TypeScale.reply(Palette.day.ink), Palette.day.halo, 0, sky);
      for (final (name, style) in steps) {
        final (stroke, beside) = await read(t, style(Palette.day.ink), Palette.day.halo, 1, sky);
        final seen = contrast(stroke, beside);
        rows.add('$where | $name | bare ${contrast(bareStroke, bareBeside).toStringAsFixed(1)} | '
            'full halo ${seen.toStringAsFixed(1)}');
        expect(seen, greaterThanOrEqualTo(floor), reason: rows.last);
      }
    }
    debugPrint(rows.join('\n'));
  });

  test('halo shadows: none at 0, three soft zero-offset shadows otherwise, never a box', () {
    expect(Halo.shadows(Palette.night.halo, 0), isEmpty);
    final s = Halo.shadows(Palette.night.halo, 0.5);
    expect([for (final x in s) x.blurRadius], [Halo.tight, Halo.wide, Halo.wider]);
    for (final x in s) {
      expect(x.offset, Offset.zero);
      expect(x.color.a, closeTo(Palette.night.halo.a * 0.5 * Halo.boost, 0.01));
    }
  });
}
