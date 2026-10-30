// Text straight on the sky (owner, 2026-10-29: no plates). Every step of
// the type scale is rendered with the real fonts over skies sampled from the
// phone, night and day, and the ink is read against the pixels right beside
// its strokes: with no halo where the sky alone reaches 4.5:1, and with the
// solved halo where it does not. Halo.reach is checked against the same
// renders, so the solver's model cannot be kinder than the pixels.
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
/// where the reply sits, the brightest upper sky (the title band), and the
/// input over the water. Day: the median sky and the lit clouds.
const nightSkies = {
  'night reply, dark': Color(0xFF12171D),
  'night reply, bright': Color(0xFF1D252F),
  'night upper, bright': Color(0xFF26313D),
  'night input, water': Color(0xFF0F1318),
};
const daySkies = {
  'day median': Color(0xFF5D6D78),
  'day cloud': Color(0xFF919FA6),
  'day cloud, bright': Color(0xFFB9C2C8),
};

/// Skies past what a soft halo can do: the moon behind pale ink, and the
/// open blue between day clouds behind dark ink (10th and 1st percentile).
const moon = Color(0xFFE9E7DF);
const beyond = {
  'night moon': (moon, true),
  'day blue': (Color(0xFF375565), false),
  'day blue, deep': (Color(0xFF0E2139), false),
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

/// The mean colour of the pixels within [reach] px of a stroke but not on
/// one, in [halo]'s render; strokes found in [plain] (no halo).
Color besideStrokes(ByteData plain, ByteData halo, Color sky, int w, int h, {int reach = 2}) {
  int ch(ByteData b, int i, int c) => b.getUint8(i * 4 + c);
  final sr = (sky.r * 255).round(), sg = (sky.g * 255).round(), sb = (sky.b * 255).round();
  final ink = List<bool>.generate(w * h, (i) =>
      (ch(plain, i, 0) - sr).abs() > 2 || (ch(plain, i, 1) - sg).abs() > 2 || (ch(plain, i, 2) - sb).abs() > 2);
  var n = 0;
  var r = 0.0, g = 0.0, b = 0.0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      if (ink[i]) continue;
      var near = false;
      for (var dy = -reach; dy <= reach && !near; dy++) {
        for (var dx = -reach; dx <= reach && !near; dx++) {
          final xx = x + dx, yy = y + dy;
          if (xx >= 0 && yy >= 0 && xx < w && yy < h && ink[yy * w + xx]) near = true;
        }
      }
      if (!near) continue;
      n++;
      r += ch(halo, i, 0);
      g += ch(halo, i, 1);
      b += ch(halo, i, 2);
    }
  }
  return Color.fromARGB(255, (r / n).round(), (g / n).round(), (b / n).round());
}

/// What the ink is read against: [style] in [ink] with the halo at
/// [strength] over [sky], beside the strokes.
Future<Color> readAgainst(WidgetTester t, TextStyle Function(Color) style, Color ink, Color halo, double strength,
    Color sky) async {
  final (plain, w, h) = await render(t, style(ink), sky);
  final (lit, _, _) = await render(t, style(ink).copyWith(shadows: Halo.shadows(halo, strength)), sky);
  return besideStrokes(plain, lit, sky, w, h);
}

/// The halo's share at a stroke's side, from the channel it moves most.
double measuredReach(Color beside, Color sky, Color halo) {
  double d(Color c) => [c.r - sky.r, c.g - sky.g, c.b - sky.b].reduce((a, b) => a.abs() > b.abs() ? a : b);
  final full = Color.from(alpha: 1, red: halo.r, green: halo.g, blue: halo.b);
  return d(beside) / d(full) / halo.a;
}

void main() {
  setUpAll(loadCaptionFonts);

  testWidgets('Halo.reach is no kinder than the pixels beside the strokes', (t) async {
    var least = 1.0;
    final rows = <String>[];
    for (final (name, style) in steps) {
      for (final (p, sky) in [(Palette.night, moon), (Palette.day, const Color(0xFF3B78C9))]) {
        final beside = await readAgainst(t, style, p.ink, p.halo, 1, sky);
        final r = measuredReach(beside, sky, p.halo);
        least = math.min(least, r);
        rows.add('$name over ${p == Palette.night ? 'moon' : 'day blue'}: reach ${r.toStringAsFixed(3)}');
      }
    }
    debugPrint('${rows.join('\n')}\nleast ${least.toStringAsFixed(3)}, token ${Halo.reach}');
    expect(least, greaterThanOrEqualTo(Halo.reach));
  });

  testWidgets('every step reaches 4.5:1 on the sampled night and day skies, with the solved halo', (t) async {
    final rows = <String>[];
    for (final (p, skies) in [(Palette.night, nightSkies), (Palette.day, daySkies)]) {
      for (final MapEntry(key: where, value: sky) in skies.entries) {
        final strength = solveHalo(p, [sky]);
        for (final (name, style) in steps) {
          for (final (role, ink) in [('ink', p.ink), ('ink2', p.ink2), ('accent', p.accent)]) {
            final bare = contrast(ink, sky);
            final beside = strength == 0 ? sky : await readAgainst(t, style, ink, p.halo, strength, sky);
            final read = contrast(ink, beside);
            rows.add('$where | $name | $role | bare ${bare.toStringAsFixed(1)} | '
                'halo ${strength.toStringAsFixed(2)} | read ${read.toStringAsFixed(1)}');
            expect(read, greaterThanOrEqualTo(4.5), reason: rows.last);
          }
        }
      }
    }
    debugPrint(rows.join('\n'));
  });

  test('no halo where none is needed: the night sky, a bright cloud, haze', () {
    for (final sky in nightSkies.values) {
      expect(solveHalo(Palette.night, [sky]), 0, reason: '$sky');
    }
    expect(solveHalo(Palette.day, [daySkies['day cloud, bright']!]), 0);
    expect(solveHalo(Palette.day, [const Color(0xFFE8EEF5)]), 0);
  });

  testWidgets('past a soft halo: full strength, and what the main ink then reads at', (t) async {
    final rows = <String>[];
    for (final MapEntry(key: where, value: (sky, night)) in beyond.entries) {
      final p = night ? Palette.night : Palette.day;
      expect(solveHalo(p, [sky]), 1, reason: where);
      final beside = await readAgainst(t, (c) => TypeScale.reply(c), p.ink, p.halo, 1, sky);
      rows.add('$where | reply | ink | bare ${contrast(p.ink, sky).toStringAsFixed(1)} | '
          'full halo ${contrast(p.ink, beside).toStringAsFixed(1)}');
    }
    debugPrint(rows.join('\n'));
  });

  test('halo shadows: none at 0, two soft zero-offset shadows otherwise, never a box', () {
    expect(Halo.shadows(Palette.night.halo, 0), isEmpty);
    final s = Halo.shadows(Palette.day.halo, 0.5);
    expect([for (final x in s) x.blurRadius], [Halo.tight, Halo.wide]);
    for (final x in s) {
      expect(x.offset, Offset.zero);
      expect(x.color.a, closeTo(Palette.day.halo.a * 0.5, 0.01));
    }
  });
}
