import 'package:flutter/painting.dart';

import '../ui/tokens.dart';

/// Caption families bundled in assets/fonts (SIL OFL 1.1).
enum CaptionFont {
  /// Cormorant Garamond, the approved caption face.
  serif('CormorantGaramond', 400),

  /// Jost Light, the sans alternative.
  sans('Jost', 300);

  const CaptionFont(this.family, this.weight);
  final String family;

  /// Default wght axis value (both files are variable fonts).
  final double weight;
}

/// Ink and halo for a caption, from the tokens. [dark] is for pale (day)
/// sky, [pale] for night. Both meet WCAG 1.4.3 4.5:1 on their intended sky
/// without counting the halo; the halo only separates the ink from busy
/// cloud edges, and only [CaptionView] draws it.
class CaptionInk {
  const CaptionInk._(this.color, this.halo);
  final Color color;
  final Color halo;

  /// Deep blue-black ink: 15.9:1 on white, 7:1 or more on mid-blue sky.
  static const dark = CaptionInk._(SkyColors.dayInk, SkyColors.dayHalo);

  /// Warm paper white for night sky: 15:1 or more on #0B1630.
  static const pale = CaptionInk._(SkyColors.nightInk, SkyColors.nightHalo);

  /// The preset with the higher contrast against [sky].
  static CaptionInk forBackground(Color sky) =>
      contrastRatio(dark.color, sky) >= contrastRatio(pale.color, sky) ? dark : pale;

  /// Reference skies for [forDaylight]: deep night blue and pale day haze.
  static const nightSky = SkyColors.nightGlass;
  static const daySky = SkyColors.dayGlass;

  /// Ink for a sky [daylight] of the way from night (0) to day (1), via a
  /// stand-in sky colour between [nightSky] and [daySky].
  static CaptionInk forDaylight(double daylight) =>
      forBackground(Color.lerp(nightSky, daySky, daylight.clamp(0.0, 1.0))!);

  List<Shadow> get shadows => [Shadow(blurRadius: 10, color: halo)];
}

/// WCAG 2.2 contrast ratio of two opaque colours, 1..21.
double contrastRatio(Color a, Color b) => contrast(a, b);

/// Caption text style for [font] and [ink]: tracking 0 and no shadow (the
/// halo is the caption's own, [CaptionView] adds it).
TextStyle captionTextStyle({
  CaptionFont font = CaptionFont.serif,
  CaptionInk ink = CaptionInk.dark,
  double fontSize = 26,
  double? weight,
}) {
  final w = weight ?? font.weight;
  return TextStyle(
    fontFamily: font.family,
    fontSize: fontSize,
    // Variable fonts: the wght axis sets the weight; fontWeight keeps
    // fallback fonts and semantics in step.
    fontVariations: [FontVariation('wght', w)],
    fontWeight: FontWeight.values[((w / 100).round() - 1).clamp(0, 8)],
    letterSpacing: 0,
    height: 1.4,
    color: ink.color,
  );
}
