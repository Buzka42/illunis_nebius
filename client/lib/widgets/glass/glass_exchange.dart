/// The latest exchange on one clear glass, centred in the sky above the
/// input (UI_PLAN UI-2): your own line small in Jost and ink2, the reply in
/// Cormorant, notes (sources, the not-medical-advice line) under a hairline,
/// and an offer's Yes / No as the glass's bottom edge. It grows to fit and
/// never scrolls. When it would not fit, the fit ladder: the reply steps
/// 22, 20, 18 px (never back up within an exchange), then your line goes,
/// then the inset tightens, and only then does the whole glass scale down.
/// Text is never clipped.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/chat_thread.dart';
import '../../app/council_flow.dart' show notMedicalAdviceLine;
import '../../ui/sky_light.dart';
import '../../ui/tokens.dart';
import 'glass_actions.dart';
import 'glass_surface.dart';

/// Layout numbers shared by the layout and its measurement.
abstract final class ExchangeMetrics {
  static const double maxWidth = 560;

  /// Room for two 48 px actions with their labels.
  static const double minOfferWidth = 232;
  static const EdgeInsets inset = EdgeInsets.fromLTRB(Space.inset, Space.gutter, Space.inset, 18);
  static const EdgeInsets tightInset = EdgeInsets.symmetric(horizontal: Space.gutter, vertical: Space.s12);
  static const double echoGap = Space.s8;
  static const double paragraphGap = Space.s12;
  static const double notesGap = Space.s12;
  static const double noteGap = Space.s4;

  /// Where a short reply sits: a little above the middle of the open sky.
  static const Alignment place = Alignment(0, -0.12);
}

/// What one exchange shows, read from its thread entries.
@immutable
class ExchangeContent {
  const ExchangeContent({this.echo, this.paragraphs = const [], this.notes = const [], this.offerId});

  /// The user's own line.
  final String? echo;

  /// Reply text, one paragraph per assistant entry, without the disclaimer.
  final List<String> paragraphs;

  /// Sources and the disclaimer, each its own note line.
  final List<String> notes;

  /// The open offer's id (Yes / No show), if any.
  final String? offerId;

  factory ExchangeContent.of(List<ChatEntry> entries) {
    String? echo;
    final paragraphs = <String>[], notes = <String>[];
    String? offer;
    var disclaimer = false;
    for (final e in entries) {
      if (e.role == ChatRole.user) {
        echo = e.text;
        continue;
      }
      var text = e.text;
      if (text.contains(notMedicalAdviceLine)) {
        text = text.replaceAll(notMedicalAdviceLine, '').replaceAll(RegExp(r'\s{2,}'), ' ').trim();
        disclaimer = true;
      }
      if (text.isNotEmpty) paragraphs.add(text);
      if (e.sources case final s? when !notes.contains(s)) notes.add(s);
      if (e.offer case final o? when o.isOpen) offer = o.id;
    }
    if (disclaimer) notes.add(notMedicalAdviceLine);
    return ExchangeContent(echo: echo, paragraphs: paragraphs, notes: notes, offerId: offer);
  }
}

/// A rung of the fit ladder.
@immutable
class ExchangeFit {
  const ExchangeFit({required this.size, required this.echo, required this.inset, required this.width, required this.height});
  final double size;
  final bool echo;
  final EdgeInsets inset;
  final double width, height;
}

/// The reply size an exchange has reached; it only goes down within one.
class FitMemory {
  Object? exchange;
  double cap = TypeScale.replySteps.first.$1;

  double capFor(Object exchange) {
    if (this.exchange != exchange) {
      this.exchange = exchange;
      cap = TypeScale.replySteps.first.$1;
    }
    return cap;
  }
}

const _anyColour = SkyColors.space; // measurement only; colour never changes metrics

double _textHeight(String text, TextStyle style, double width, TextScaler scaler) {
  final p = TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr, textScaler: scaler)
    ..layout(maxWidth: width);
  final h = p.height;
  p.dispose();
  return h;
}

double _textWidth(String text, TextStyle style, TextScaler scaler) {
  final p = TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr, textScaler: scaler)
    ..layout();
  final w = p.maxIntrinsicWidth;
  p.dispose();
  return w;
}

/// Height of the Yes / No row: a 48 px target or the label's line, padded.
double offerHeight(TextScaler scaler) =>
    math.max(Space.target, _textHeight('Yes', TypeScale.label(_anyColour), double.infinity, scaler) + 2 * Space.s12);

/// Width and height of [c] at reply [size], with or without the [echo],
/// with [inset], at most [maxWidth] wide.
ExchangeFit measureExchange(ExchangeContent c,
    {required double size, required bool echo, required EdgeInsets inset, required double maxWidth,
    required TextScaler scaler, double hair = 1}) {
  final reply = TypeScale.reply(_anyColour, size: size);
  final body = TypeScale.body(_anyColour), note = TypeScale.note(_anyColour);
  final showEcho = echo && c.echo != null;
  // As wide as the longest line wants, never wider than the sky allows.
  var natural = [
    if (showEcho) _textWidth(c.echo!, body, scaler),
    for (final t in c.paragraphs) _textWidth(t, reply, scaler),
    for (final n in c.notes) _textWidth(n, note, scaler),
  ].fold(0.0, math.max).ceilToDouble() + 1 + inset.horizontal;
  if (c.offerId != null) natural = math.max(natural, ExchangeMetrics.minOfferWidth);
  final width = math.min(natural, maxWidth);
  final inner = width - inset.horizontal;
  var h = inset.vertical;
  if (showEcho) {
    h += _textHeight(c.echo!, body, inner, scaler);
    if (c.paragraphs.isNotEmpty || c.notes.isNotEmpty) h += ExchangeMetrics.echoGap;
  }
  for (final (i, t) in c.paragraphs.indexed) {
    if (i > 0) h += ExchangeMetrics.paragraphGap;
    h += _textHeight(t, reply, inner, scaler);
  }
  if (c.notes.isNotEmpty) {
    if (showEcho || c.paragraphs.isNotEmpty) h += 2 * ExchangeMetrics.notesGap + hair;
    for (final (i, n) in c.notes.indexed) {
      if (i > 0) h += ExchangeMetrics.noteGap;
      h += _textHeight(n, note, inner, scaler);
    }
  }
  if (c.offerId != null) h += offerHeight(scaler);
  return ExchangeFit(size: size, echo: showEcho, inset: inset, width: width, height: h);
}

/// The first rung of the ladder at which [c] fits [height]; the last rung
/// (the scale-down guard then applies) when none does.
ExchangeFit fitExchange(ExchangeContent c,
    {required double maxWidth, required double height, required TextScaler scaler, double cap = 22, double hair = 1}) {
  ExchangeFit at(double size, bool echo, EdgeInsets inset) => measureExchange(c,
      size: size, echo: echo, inset: inset, maxWidth: maxWidth, scaler: scaler, hair: hair);
  late ExchangeFit last;
  for (final (size, _) in TypeScale.replySteps.where((s) => s.$1 <= cap)) {
    last = at(size, true, ExchangeMetrics.inset);
    if (last.height <= height) return last;
  }
  final floor = math.min(cap, TypeScale.replyFloor);
  for (final (echo, inset) in [(false, ExchangeMetrics.inset), (false, ExchangeMetrics.tightInset)]) {
    last = at(floor, echo, inset);
    if (last.height <= height) return last;
  }
  return last;
}

class GlassExchange extends StatelessWidget {
  const GlassExchange({
    super.key,
    required this.entries,
    required this.onChoice,
    this.memory,
    this.exchange,
    this.grow = Motion.enter,
  });

  final List<ChatEntry> entries;

  /// A tapped Yes or No.
  final void Function(String label) onChoice;

  /// Remembers the reply size across rebuilds of one [exchange].
  final FitMemory? memory;
  final Object? exchange;

  /// How long the glass takes to grow to new text; zero with reduced motion.
  final Duration grow;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final hair = 1 / (MediaQuery.maybeDevicePixelRatioOf(context) ?? 1);
    final content = ExchangeContent.of(entries);
    return LayoutBuilder(builder: (context, box) {
      final cap = memory?.capFor(exchange ?? entries.length) ?? TypeScale.replySteps.first.$1;
      final fit = fitExchange(content,
          maxWidth: math.min(box.maxWidth, ExchangeMetrics.maxWidth),
          height: box.maxHeight,
          scaler: scaler,
          cap: cap,
          hair: hair);
      memory?.cap = fit.size;
      return Align(
        alignment: ExchangeMetrics.place,
        // The guard: scales down only if even the last rung is too tall.
        child: FittedBox(fit: BoxFit.scaleDown, child: _glass(context, content, fit, hair)),
      );
    });
  }

  Widget _glass(BuildContext context, ExchangeContent c, ExchangeFit fit, double hair) {
    final p = SkyLight.paletteOf(context);
    final offer = c.offerId;
    Widget sized(Widget child) => grow == Duration.zero
        ? child
        : AnimatedSize(duration: grow, curve: Motion.enterCurve, alignment: Alignment.topCenter, child: child);
    return GlassPanel(
      child: sized(
        SizedBox(
          width: fit.width,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: fit.inset,
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (fit.echo) ...[
                  Text(c.echo!, style: TypeScale.body(p.ink2)),
                  if (c.paragraphs.isNotEmpty || c.notes.isNotEmpty) const SizedBox(height: ExchangeMetrics.echoGap),
                ],
                if (c.paragraphs.isNotEmpty)
                  Semantics(
                    liveRegion: true,
                    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      for (final (i, t) in c.paragraphs.indexed) ...[
                        if (i > 0) const SizedBox(height: ExchangeMetrics.paragraphGap),
                        Text(t, style: TypeScale.reply(p.ink, size: fit.size)),
                      ],
                    ]),
                  ),
                if (c.notes.isNotEmpty) ...[
                  if (fit.echo || c.paragraphs.isNotEmpty) ...[
                    const SizedBox(height: ExchangeMetrics.notesGap),
                    Container(key: const ValueKey('exchange-notes-rule'), height: hair, color: p.rimSide),
                    const SizedBox(height: ExchangeMetrics.notesGap),
                  ],
                  for (final (i, n) in c.notes.indexed) ...[
                    if (i > 0) const SizedBox(height: ExchangeMetrics.noteGap),
                    Text(n, style: TypeScale.note(p.ink2)),
                  ],
                ],
              ]),
            ),
            if (offer != null)
              GlassActions(topRule: true, actions: [
                GlassAction('Yes', () => onChoice('Yes'), key: ValueKey('offer-$offer-yes'), primary: true),
                GlassAction('No', () => onChoice('No'), key: ValueKey('offer-$offer-no')),
              ]),
          ]),
        ),
      ),
    );
  }
}
