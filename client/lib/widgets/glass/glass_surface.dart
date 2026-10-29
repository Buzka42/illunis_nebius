/// Clear glass over the sky (owner amendments A1 and A2; UI_PLAN 3.2): a
/// backdrop blur, a tint only as thick as the text on it needs over the real
/// sky behind it ([SkyLight]), and a 1 px light edge brightest on top where
/// the light falls. One depth: no shadow, no sheen, never glass on glass.
library;

import 'dart:ui' as ui;

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
  final BorderRadius borderRadius;

  @override
  State<GlassPanel> createState() => GlassPanelState();
}

/// Public for tests: [alpha] is the tint alpha the glass is settling on.
class GlassPanelState extends State<GlassPanel> {
  double _alpha = GlassSpec.unknown;
  bool _measured = false;
  SkyLight? _sky;

  double get alpha => _alpha;

  /// After layout: where the glass is on screen decides how thick it is.
  void _measure() {
    if (!mounted) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final a = _sky?.glassAlpha(rect) ?? GlassSpec.unknown;
    if (_measured && (a - _alpha).abs() < 0.005) return;
    setState(() {
      _alpha = a;
      _measured = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    assert(context.findAncestorStateOfType<GlassPanelState>() == null,
        'A GlassPanel inside a GlassPanel: glass has one depth (UI_PLAN 3.2).');
    _sky = SkyLight.maybeOf(context);
    final p = _sky?.palette ?? Palette.night;
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final radius = widget.borderRadius;
    return TweenAnimationBuilder<double>(
      tween: Tween(end: _alpha),
      // The first look sets the tint at once (the glass is fading in).
      duration: reduce || !_measured ? Duration.zero : Motion.glass,
      curve: Motion.glassCurve,
      builder: (context, a, child) => ClipRSuperellipse(
        borderRadius: radius,
        child: BackdropFilter.grouped(
          filter: ui.ImageFilter.blur(sigmaX: GlassSpec.sigma, sigmaY: GlassSpec.sigma),
          child: CustomPaint(
            painter: _Tint(p.glass.withValues(alpha: a), radius),
            foregroundPainter: _Rim(p.rimTop, p.rimSide, radius),
            child: child,
          ),
        ),
      ),
      child: Padding(padding: widget.padding, child: widget.child),
    );
  }
}

class _Tint extends CustomPainter {
  const _Tint(this.color, this.radius);
  final Color color;
  final BorderRadius radius;

  @override
  void paint(Canvas canvas, Size size) =>
      canvas.drawRSuperellipse(radius.toRSuperellipse(Offset.zero & size), Paint()..color = color);

  @override
  bool shouldRepaint(_Tint old) => old.color != color || old.radius != radius;
}

/// A hairline edge: [top] where the light falls, easing to [side] by a
/// third of the way down. Light, not a gradient you notice.
class _Rim extends CustomPainter {
  const _Rim(this.top, this.side, this.radius);
  final Color top, side;
  final BorderRadius radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(0.5);
    final reach = (Radii.glass * 2 / size.height).clamp(0.0, 1.0);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..shader = ui.Gradient.linear(rect.topCenter, rect.bottomCenter, [top, side, side], [0, reach, 1]);
    canvas.drawRSuperellipse(radius.toRSuperellipse(rect), paint);
  }

  @override
  bool shouldRepaint(_Rim old) => old.top != top || old.side != side || old.radius != radius;
}
