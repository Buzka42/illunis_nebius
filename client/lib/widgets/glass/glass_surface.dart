/// Text straight on the sky (owner, 2026-10-29: no plates under text).
/// [GlassPanel] keeps its name and constructor for its callers but paints
/// nothing: no tint, no blur, no rim, no shape. It looks at the sky behind
/// its region ([SkyLight]) and gives the text inside the softest [Halo]
/// that keeps every text pair at 4.5:1; over a clear night or a pale day
/// sky that is no halo at all.
library;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../../ui/sky_light.dart';
import '../../ui/tokens.dart';

class GlassPanel extends StatefulWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.borderRadius = const BorderRadius.all(Radius.circular(Radii.glass)),
  });

  final Widget child;
  final EdgeInsets padding;

  /// Kept for callers; with no plate there is no shape to round.
  final BorderRadius borderRadius;

  @override
  State<GlassPanel> createState() => GlassPanelState();
}

/// Public for tests: [halo] is the halo strength the text is settling on.
class GlassPanelState extends State<GlassPanel> {
  double _halo = Halo.unknown;
  bool _measured = false;
  SkyLight? _sky;

  double get halo => _halo;

  /// After layout: the sky behind the region decides the halo.
  void _measure() {
    if (!mounted) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return;
    final h = haloFor(_sky, box.localToGlobal(Offset.zero) & box.size);
    if (_measured && (h - _halo).abs() < 0.005) return;
    setState(() {
      _halo = h;
      // The first look sets the halo at once (the text is fading in); later
      // changes ease.
      _jump = !_measured;
      _measured = true;
    });
  }

  bool _jump = true;

  @override
  Widget build(BuildContext context) {
    assert(context.findAncestorStateOfType<GlassPanelState>() == null,
        'A GlassPanel inside a GlassPanel: one text region, one halo.');
    _sky = SkyLight.maybeOf(context);
    final p = _sky?.palette ?? Palette.night;
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return TweenAnimationBuilder<double>(
      tween: Tween(end: _halo),
      duration: reduce || _jump ? Duration.zero : Motion.glass,
      curve: Motion.glassCurve,
      builder: (context, h, child) => TextHalo(shadows: Halo.shadows(p.halo, h), child: child!),
      child: Padding(padding: widget.padding, child: widget.child),
    );
  }
}

/// Halo strength for text covering [rect] (global). With a look at the sky,
/// the weakest halo at which [SkyLight.palette]'s texts reach the target
/// over the darkest and brightest sky under [rect]. Before the first look,
/// a model: full over a bright disc or at dusk, none by night, [dayModel]
/// by day. Full with no SkyLight at all.
double haloFor(SkyLight? sky, Rect rect) {
  if (sky == null) return Halo.unknown;
  final range = sky.probe?.range(rect);
  if (range != null) return solveHalo(sky.palette, [range.$1, range.$2]);
  if (sky.discs.any((d) => d.inflate(2 * GlassSpec.sigma).overlaps(rect))) return 1;
  if (sky.daylight > 0.15 && sky.daylight < 0.85) return 1;
  return sky.daylight >= 0.5 ? dayModel : 0;
}

/// The halo by day before the sky has been looked at: full, because the
/// day sky the phone draws is a mid-tone (median L 0.15) on which the day
/// inks need all of it (docs/UI_PLAN.md, "Typography decision 2026-10-29").
const double dayModel = 1;

/// The halo for the text below: [DefaultTextStyle] carries it to every
/// [Text] whose style leaves shadows unset, and fields read it with [of].
class TextHalo extends InheritedWidget {
  TextHalo({super.key, required this.shadows, required Widget child})
      : super(child: DefaultTextStyle.merge(style: TextStyle(shadows: shadows), child: child));

  final List<Shadow> shadows;

  /// The halo above [context]; none outside a [GlassPanel].
  static List<Shadow> of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TextHalo>()?.shadows ?? const [];

  @override
  bool updateShouldNotify(TextHalo old) => !listEquals(shadows, old.shadows);
}
