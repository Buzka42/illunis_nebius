/// The breathwork view (build plan B7, research section 6.2). Opened only
/// through ViewHost after a yes. It walks [BreathFlow] (onboarding, screens,
/// "Start ... now?") on one glass sheet with Close at the top right, then
/// plays a [BreathSession] on the open sky: a ring of light that grows on
/// the inhale and shrinks on the exhale, or a text countdown when reduced
/// motion is on. Pause and Stop stay on screen during a session. Inks and
/// glass come from SkyLight (night or day); text on the open sky keeps a
/// soft halo, the cue sits on one small glass whose tint is solved for 4.5:1.
/// 16 px side gutters; content scrolls vertically only.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../app/view_requests.dart';
import '../ui/sky_light.dart';
import '../ui/tokens.dart';
import '../widgets/glass/glass_actions.dart';
import '../widgets/glass/glass_field.dart';
import '../widgets/glass/glass_sheet.dart';
import '../widgets/glass/glass_surface.dart';
import 'breath_onboarding.dart';
import 'breath_session.dart';
import 'breath_wiring.dart';
import 'technique.dart';

class BreathView extends StatefulWidget {
  const BreathView({super.key, required this.request, required this.deps, required this.onClose});

  final ViewRequest request;
  final BreathDeps deps;
  final VoidCallback onClose;

  static const yesKey = ValueKey('breath-yes');
  static const noKey = ValueKey('breath-no');
  static const closeKey = ValueKey('breath-close');
  static const stopKey = ValueKey('breath-stop');
  static const pauseKey = ValueKey('breath-pause');
  static const nameKey = ValueKey('breath-name');
  static const chooseKey = ValueKey('breath-choose');
  static const listKey = ValueKey('breath-list');
  static const visualKey = ValueKey('breath-visual');
  static const countdownKey = ValueKey('breath-countdown');

  /// The list when no technique is installed: never a heading over nothing.
  static const emptyLibraryText = 'No breathwork techniques are installed on this phone yet.';

  /// The sheet's title before a technique is known.
  static const title = 'Breathwork';

  /// The most the sheet header's text grows with the system text size.
  static const double titleMaxScale = 1.6;

  @override
  State<BreathView> createState() => _BreathViewState();
}

class _BreathViewState extends State<BreathView> with SingleTickerProviderStateMixin {
  BreathFlow? _flow;
  BreathSession? _session;
  Object? _loadError;
  Technique? _requested;
  late final Ticker _ticker = createTicker(_tick);
  Duration _last = Duration.zero;
  final _name = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final lib = await widget.deps.library;
      final req = widget.request;
      final requested = req is BreathRequest ? lib.match(req.technique) : null;
      final flow = BreathFlow(library: lib, profiles: widget.deps.profiles, requested: requested)
        ..addListener(_flowChanged);
      if (!mounted) return;
      setState(() {
        _flow = flow;
        _requested = requested;
      });
      await flow.start();
    } on Object catch (e) {
      if (mounted) setState(() => _loadError = e);
    }
  }

  void _flowChanged() {
    final s = _flow!.step;
    if (s is BreathReady && _session == null) {
      _session = BreathSession(s.technique);
      _last = Duration.zero;
      _ticker.start();
    }
    if (mounted) setState(() {});
  }

  void _tick(Duration elapsed) {
    final s = _session;
    if (s == null) return;
    final dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    for (final cue in s.advance(dt)) {
      widget.deps.voice.speak(cue);
    }
    if (s.stage == BreathStage.ended) _ticker.stop();
    setState(() {});
  }

  void _togglePause() {
    final s = _session!;
    setState(() {
      if (s.paused) {
        s.resume();
      } else {
        s.pause();
        widget.deps.voice.stop();
      }
    });
  }

  void _stop() {
    _session?.stop();
    _ticker.stop();
    widget.deps.voice.stop();
    setState(() {});
  }

  @override
  void dispose() {
    _ticker.dispose();
    _flow?.removeListener(_flowChanged);
    _name.dispose();
    widget.deps.voice.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = SkyLight.paletteOf(context);
    final session = _session;
    if (session != null && session.stage != BreathStage.ended) return _sessionBody(context, session, p);
    final title = session?.technique.name ?? _requested?.name ?? BreathView.title;
    final body = session != null ? _endBody(session, p) : _stepBody(p);
    return _sheet(title, body);
  }

  // ---- steps, on one glass sheet -------------------------------------------

  Widget _sheet(String title, List<Widget> children) => GlassSheet(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The 28 px title grows to at most 1.6x, so a one-word title such as
        // "Breathwork" never breaks beside Close at the largest text sizes.
        MediaQuery.withClampedTextScaling(
          maxScaleFactor: BreathView.titleMaxScale,
          child: SheetHeader(title: title, onClose: widget.onClose, closeKey: BreathView.closeKey),
        ),
        Expanded(
          child: Padding(
            // The keyboard pushes the name field up instead of covering it.
            padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(0, Space.s12, Space.s8, Space.gutter),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
            ),
          ),
        ),
      ],
    ),
  );

  List<Widget> _stepBody(Palette p) {
    if (_loadError != null) return [_body('The breathwork library could not load.', p)];
    final step = _flow?.step ?? const BreathLoading();
    return switch (step) {
      BreathLoading() => [_body('Loading breathwork.', p, color: p.ink2)],
      BreathAsk(:final body, :final question) => [
        if (body != null) ...[_body(body, p), _gap],
        _question(question, p),
        _gap,
        GlassActions(
          actions: [
            GlassAction('Yes', () => _flow!.answer(true), key: BreathView.yesKey, primary: true),
            GlassAction('No', () => _flow!.answer(false), key: BreathView.noKey),
          ],
        ),
      ],
      BreathChoose(:final listed, :final miss) => [
        _question('Which technique? Type its name.', p),
        _gap,
        GlassField(
          fieldKey: BreathView.nameKey,
          controller: _name,
          hint: 'Technique name',
          showSend: false,
          clearOnSubmit: false,
          textInputAction: TextInputAction.done,
          onSubmit: _flow!.choose,
        ),
        if (miss) ...[_gap, _body('No technique by that name. Check the spelling or see the list.', p)],
        _gap,
        GlassActions(
          actions: [
            GlassAction('Choose', () => _flow!.choose(_name.text), key: BreathView.chooseKey, primary: true),
            if (listed == null) GlassAction('Show the list', _flow!.showList, key: BreathView.listKey),
          ],
        ),
        if (listed != null && listed.isEmpty) ...[_gap, _body(BreathView.emptyLibraryText, p)],
        if (listed != null && listed.isNotEmpty) ...[
          _gap,
          _body('The basic techniques, in order:', p, color: p.ink2),
          const SizedBox(height: Space.s4),
          for (final t in listed) _techniqueRow(t, p),
        ],
      ],
      BreathNotice(:final text, :final notice) => [
        _question(text, p),
        if (notice != null) ...[_gap, _body(notice, p, color: p.ink2)],
      ],
      // The session takes over at once (_flowChanged).
      BreathReady() => const [SizedBox.shrink()],
    };
  }

  List<Widget> _endBody(BreathSession s, Palette p) => [
    _question(s.endText, p),
    _gap,
    _body(s.technique.copy.notice, p, color: p.ink2),
  ];

  /// One technique as a 48 px text row; an advanced one carries a quiet tag.
  Widget _techniqueRow(Technique t, Palette p) => Semantics(
    button: true,
    child: Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: ValueKey('breath-item-${t.id}'),
        onTap: () => _flow!.choose(t.name),
        highlightColor: p.ink.withValues(alpha: 0.08),
        customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.control)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: Space.target),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.s12),
            // The tag follows the name, or goes under it when there is
            // no room, so a long one-word name never breaks.
            child: Wrap(
              spacing: Space.s8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(t.name, textAlign: TextAlign.start, style: TypeScale.body(p.ink)),
                if (!t.isBasic) Text('advanced', style: TypeScale.note(p.ink2)),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  static const _gap = SizedBox(height: Space.s12);

  Widget _question(String text, Palette p) => Text(text, textAlign: TextAlign.start, style: TypeScale.reply(p.ink));

  Widget _body(String text, Palette p, {Color? color}) =>
      Text(text, textAlign: TextAlign.start, style: TypeScale.body(color ?? p.ink));

  // ---- the session, on the open sky ----------------------------------------

  Widget _sessionBody(BuildContext context, BreathSession s, Palette p) {
    final t = s.technique;
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final halo = [Shadow(blurRadius: 10, color: p.halo)];
    final phase = _phaseLabel(s.phase.kind);
    final secs = s.phaseRemainingS.ceil();
    final status = switch (s.stage) {
      BreathStage.countIn => 'Getting ready: breath ${s.countInCycle} of ${t.countInCycles}',
      _ => '${_clock(s.remainingS)} left',
    };
    final cue = s.currentCue?.text ?? (s.stage == BreathStage.countIn ? t.copy.intent : null);
    final display = TypeScale.display(p.ink).copyWith(shadows: halo);
    // The session covers the chat below it; only its own controls take taps.
    return Listener(
      behavior: HitTestBehavior.opaque,
      child: Material(
        type: MaterialType.transparency,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(Space.gutter),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(t.name, style: TypeScale.label(p.ink).copyWith(shadows: halo)),
                      Text(
                        s.paused ? 'Paused. $status' : status,
                        style: TypeScale.label(p.ink).copyWith(shadows: halo),
                      ),
                      Expanded(
                        flex: 3,
                        child: reduce
                            ? Center(
                                child: Text(
                                  '$phase\n$secs',
                                  key: BreathView.countdownKey,
                                  textAlign: TextAlign.center,
                                  style: display,
                                ),
                              )
                            : Column(
                                children: [
                                  Expanded(
                                    child: CustomPaint(
                                      key: BreathView.visualKey,
                                      size: Size.infinite,
                                      painter: BreathPainter(
                                        level: s.level,
                                        guided: t.pacing?.guided ?? true,
                                        color: p.ink,
                                      ),
                                    ),
                                  ),
                                  Text(phase, textAlign: TextAlign.center, style: display),
                                ],
                              ),
                      ),
                      // Cue and stop prompts scroll in their own space, so Stop and
                      // Pause stay on screen at any text size.
                      Flexible(
                        flex: 2,
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.only(top: Space.s12),
                          child: cue == null && t.stopPrompts.isEmpty
                              ? const SizedBox.shrink()
                              : GlassPanel(
                                  padding: const EdgeInsets.symmetric(horizontal: Space.inset, vertical: Space.s12),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      if (cue != null) Text(cue, style: TypeScale.body(p.ink2)),
                                      if (cue != null && t.stopPrompts.isNotEmpty) const SizedBox(height: Space.s8),
                                      if (t.stopPrompts.isNotEmpty)
                                        Text(t.stopPrompts.join(' '), style: TypeScale.note(p.ink2)),
                                    ],
                                  ),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
                // Pause and Stop sit at the bottom, whatever the cue's length.
                const SizedBox(height: Space.s8),
                GlassActions(
                  actions: [
                    GlassAction(s.paused ? 'Resume' : 'Pause', _togglePause, key: BreathView.pauseKey),
                    GlassAction('Stop', _stop, key: BreathView.stopKey, primary: true),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _phaseLabel(BreathPhaseKind k) => switch (k) {
    BreathPhaseKind.inhale => 'Breathe in',
    BreathPhaseKind.topUp => 'A little more in',
    BreathPhaseKind.hold => 'Pause, if comfortable',
    BreathPhaseKind.exhale => 'Breathe out',
    BreathPhaseKind.holdEmpty => 'Rest', // never played (safePhases)
  };

  static String _clock(double s) {
    final total = s.ceil().clamp(0, 1 << 30);
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
  }
}

/// A ring of light whose size follows [level] (0 empty, 1 full): a 1.5 px
/// line with a soft glow, nothing filled, so the sky shows through the
/// middle. No flashing: only the radius changes. Unguided techniques draw a
/// fainter ring (an ambient reference, not a pace).
class BreathPainter extends CustomPainter {
  const BreathPainter({required this.level, required this.color, this.guided = true});
  final double level;
  final Color color;
  final bool guided;

  static const double stroke = 1.5;
  static const double glow = 6;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final maxR = math.max(0.0, math.min(size.width, size.height) / 2 - 2 * glow);
    final r = maxR * (0.35 + 0.65 * level.clamp(0.0, 1.0));
    final a = guided ? 1.0 : 0.55;
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3 * stroke
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, glow)
        ..color = color.withValues(alpha: 0.35 * a),
    );
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..isAntiAlias = true
        ..color = color.withValues(alpha: 0.9 * a),
    );
  }

  @override
  bool shouldRepaint(BreathPainter old) => old.level != level || old.guided != guided || old.color != color;
}
