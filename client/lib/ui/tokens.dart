/// Design tokens (docs/UI_PLAN.md section 3, with the owner amendments A1 to
/// A3): one palette per sky, night and day, five type steps, a 4 px spacing
/// grid, two radii and a few slow motion curves. UI files use only these;
/// no raw colours, font sizes or radii.
library;

import 'dart:math' as math;

import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/painting.dart';

/// The named colours behind [Palette.night] and [Palette.day], for the few
/// places that need a compile-time constant (caption presets).
abstract final class SkyColors {
  /// Behind the sky, before it is drawn.
  static const space = Color(0xFF000000);

  static const nightInk = Color(0xFFF5F2EA); // CaptionInk.pale
  static const nightInk2 = Color(0xFFB4BBCB); // moonlit grey
  static const nightAccent = Color(0xFFC5D4FF); // star tint, star_field.dart
  static const nightGlass = Color(0xFF0B1630); // CaptionInk.nightSky
  static const nightHalo = Color(0x8C000000);

  static const dayInk = Color(0xFF1C2333); // CaptionInk.dark
  static const dayInk2 = Color(0xFF3E475A); // dusk ink
  static const dayAccent = Color(0xFF24457F); // deepened zenith #3B78C9
  static const dayGlass = Color(0xFFE8EEF5); // CaptionInk.daySky
  static const dayHalo = Color(0x99FFFFFF);
}

/// Colours for one sky. Text pairs are [ink], [ink2] and [accent]; each
/// reaches 4.5:1 on the glass as composited over the sky behind it (the
/// glass tint is solved for that, see sky_light.dart).
@immutable
class Palette {
  const Palette({
    required this.ink,
    required this.ink2,
    required this.accent,
    required this.glass,
    required this.rimTop,
    required this.rimSide,
    required this.selection,
    required this.halo,
  });

  /// Main text: warm paper white at night, deep blue-black by day.
  final Color ink;

  /// Hints, notes, units: moonlit grey at night, dusk ink by day.
  final Color ink2;

  /// The one accent (cursor, handles, focus, the primary action): the
  /// blue-white of the brightest stars at night, deep zenith blue by day.
  final Color accent;

  /// The glass tint colour; its alpha is solved per surface.
  final Color glass;

  /// The 1 px light edge, brightest on top where the light falls.
  final Color rimTop, rimSide;

  /// Selected text background (behind [ink]).
  final Color selection;

  /// A soft halo for text set straight on the sky (captions).
  final Color halo;

  /// Field baselines and table rules (non-text, 3:1 or more on the glass).
  Color get rule => ink2;

  /// Every text colour that must reach 4.5:1.
  List<Color> get texts => [ink, ink2, accent];

  static const night = Palette(
    ink: SkyColors.nightInk,
    ink2: SkyColors.nightInk2,
    accent: SkyColors.nightAccent,
    glass: SkyColors.nightGlass,
    rimTop: Color(0x38F5F2EA), // ink at 0.22
    rimSide: Color(0x14F5F2EA), // ink at 0.08
    selection: Color(0x47C5D4FF), // accent at 0.28
    halo: SkyColors.nightHalo,
  );

  static const day = Palette(
    ink: SkyColors.dayInk,
    ink2: SkyColors.dayInk2,
    accent: SkyColors.dayAccent,
    glass: SkyColors.dayGlass,
    rimTop: Color(0xB3FFFFFF), // white at 0.70
    rimSide: Color(0x59FFFFFF), // white at 0.35
    selection: Color(0x4024457F), // accent at 0.25
    halo: SkyColors.dayHalo,
  );

  /// [night] at 0, [day] at 1.
  static Palette lerp(Palette a, Palette b, double t) {
    if (t <= 0) return a;
    if (t >= 1) return b;
    Color c(Color x, Color y) => Color.lerp(x, y, t)!;
    return Palette(
      ink: c(a.ink, b.ink),
      ink2: c(a.ink2, b.ink2),
      accent: c(a.accent, b.accent),
      glass: c(a.glass, b.glass),
      rimTop: c(a.rimTop, b.rimTop),
      rimSide: c(a.rimSide, b.rimSide),
      selection: c(a.selection, b.selection),
      halo: c(a.halo, b.halo),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Palette &&
      other.ink == ink &&
      other.ink2 == ink2 &&
      other.accent == accent &&
      other.glass == glass &&
      other.rimTop == rimTop &&
      other.rimSide == rimSide &&
      other.selection == selection &&
      other.halo == halo;

  @override
  int get hashCode => Object.hash(ink, ink2, accent, glass, rimTop, rimSide, selection, halo);
}

/// WCAG 2.2 contrast ratio of two opaque colours, 1..21.
double contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// Bundled families (assets/fonts, SIL OFL 1.1).
abstract final class Fonts {
  /// Illunis speaks in Cormorant Garamond.
  static const serif = 'CormorantGaramond';

  /// You and the controls speak in Jost.
  static const sans = 'Jost';
}

/// The five type steps. Tracking 0 on body text; figures lining in the
/// serif and tabular in the sans steps that hold numbers.
abstract final class TypeScale {
  /// The reply's fit ladder: size and line height, largest first.
  static const replySteps = [(22.0, 30.0), (20.0, 27.0), (18.0, 25.0)];

  /// The floor for [reply]; every other step stops at [floor].
  static const replyFloor = 18.0;
  static const floor = 13.0;

  static const _lnum = [FontFeature.liningFigures()];
  static const _tnum = [FontFeature.tabularFigures()];

  static TextStyle _style(String family, double size, double line, double wght, Color color,
          {double tracking = 0, List<FontFeature>? features}) =>
      TextStyle(
        fontFamily: family,
        fontSize: size,
        height: line / size,
        fontVariations: [FontVariation('wght', wght)],
        fontWeight: FontWeight.values[((wght / 100).round() - 1).clamp(0, 8)],
        letterSpacing: tracking,
        fontFeatures: features,
        color: color,
      );

  /// View titles, breath phase: Cormorant 28 / 34.
  static TextStyle display(Color c) => _style(Fonts.serif, 28, 34, 420, c, features: _lnum);

  /// The AI reply: Cormorant 22 / 30, or a smaller [replySteps] size.
  static TextStyle reply(Color c, {double size = 22}) {
    final line = replySteps.firstWhere((s) => s.$1 == size, orElse: () => (size, size * 1.36)).$2;
    return _style(Fonts.serif, size, line, 460, c, features: _lnum);
  }

  /// Input text, the user's line, log rows, empty states: Jost 16 / 24.
  static TextStyle body(Color c, {bool tabular = false}) =>
      _style(Fonts.sans, 16, 24, 380, c, features: tabular ? _tnum : null);

  /// Actions, table headers, dates, timers: Jost 14 / 20.
  static TextStyle label(Color c) => _style(Fonts.sans, 14, 20, 480, c, tracking: 0.2, features: _tnum);

  /// Sources, the disclaimer, a host name, the "advanced" tag: Jost 13 / 18.
  static TextStyle note(Color c) => _style(Fonts.sans, 13, 18, 420, c, tracking: 0.2, features: _tnum);
}

/// The 4 px grid.
abstract final class Space {
  static const double s4 = 4, s8 = 8, s12 = 12, s24 = 24, s32 = 32;

  /// Side gutter.
  static const double gutter = 16;

  /// Horizontal inset inside glass.
  static const double inset = 20;

  /// Smallest touch target.
  static const double target = 48;
}

/// Two radii and no pills: nothing is rounded by 0.4 x its height or more.
abstract final class Radii {
  static const double glass = 18;
  static const double control = 8;

  /// The largest radius a shape [height] tall may have.
  static double maxFor(double height) => height * 0.4;
}

/// Slow, organic motion (owner amendment A2). With reduced motion only
/// opacity changes, in at most [reduced].
abstract final class Motion {
  /// A pressed control's ink overlay.
  static const press = Duration(milliseconds: 120);
  static const pressCurve = Curves.linear;

  /// An exchange fading in, glass growing to fit.
  static const enter = Duration(milliseconds: 420);
  static const enterCurve = Curves.easeOutCubic;
  static const exit = Duration(milliseconds: 240);
  static const exitCurve = Curves.easeInCubic;

  /// A view opening (fade and a [viewRise] px rise) and closing.
  static const viewIn = Duration(milliseconds: 520);
  static const viewOut = Duration(milliseconds: 320);
  static const viewCurve = Curves.easeOutCubic;
  static const double viewRise = 12;

  /// The glass thickening or clearing as the sky behind it changes.
  static const glass = Duration(milliseconds: 900);
  static const glassCurve = Curves.easeInOutSine;

  /// The ink turning from night to day (or back) with the sun.
  static const ink = Duration(milliseconds: 2400);
  static const inkCurve = Curves.easeInOutSine;

  /// The longest opacity fade with reduced motion.
  static const reduced = Duration(milliseconds: 120);
}

/// One glass depth (UI_PLAN 3.2, A1: as clear as contrast allows).
abstract final class GlassSpec {
  /// Backdrop blur sigma, logical px.
  static const double sigma = 14;

  /// Tint alpha bounds. The floor keeps a trace of the glass; the cap is
  /// the most of the sky any surface may hide.
  static const double alphaFloor = 0.06;
  static const double alphaMax = 0.86;

  /// Contrast every text pair must reach on the glass, with a margin for
  /// the sky moving between two looks at it.
  static const double target = 4.5;
  static const double margin = 0.3;

  /// Before the sky has been looked at (first frames, voice builds): the
  /// model alphas from the plan. [unknown] also applies with no SkyLight.
  static const double modelNight = 0.40, modelDay = 0.45, modelTwilight = 0.65, unknown = 0.80;
}
