import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/thumbnail_error_placeholder.dart';
import '../widgets/hotstar_player_style.dart';
import '../widgets/player_activation.dart';

/// The "up next" card shown in the closing seconds of an episode.
///
/// Engine-agnostic and stateless about playback, exactly like [PlayerRail]:
/// every value it renders and both outcomes are handed in. The old
/// NextEpisodeOverlay was armed from player_controller.dart:2122-2157 and then
/// read the controller back for `isPlaying`, so the countdown had two owners.
/// Here [paused] is a plain bool in, which is why this file has no imports from
/// the player package at all and can be tested without an engine.
///
/// Contract, because auto-advance is destructive and a double fire skips two
/// episodes: **exactly one of [onPlayNext] and [onCancel] is ever called, and
/// it is called at most once.** The parent unmounts the card in response to
/// either. After [onCancel] it must not be shown again for this episode —
/// "cancel" means the viewer declined the advance, not "ask again in a second".
class NextEpisodeCountdown extends StatefulWidget {
  const NextEpisodeCountdown({
    required this.title,
    required this.onPlayNext,
    required this.onCancel,
    this.posterUrl,
    this.season,
    this.episode,
    this.rating,
    this.runtime,
    this.description,
    this.countdown = const Duration(seconds: 15),
    this.paused = false,
    this.isTv = false,
    super.key,
  });

  /// Title of the episode that will play, not of the series.
  final String title;

  /// Episode still or series poster. Null renders the on-device placeholder
  /// rather than a gap, so the card keeps its shape either way.
  final String? posterUrl;

  final int? season;
  final int? episode;

  /// Out of 10, matching the catalogue's scale. Null or <= 0 hides it.
  final double? rating;

  /// Episode runtime. Anything under a minute is treated as unknown — a
  /// handful of seconds is metadata noise, not a runtime.
  final Duration? runtime;

  final String? description;

  /// How long before the advance happens on its own. Matches the old
  /// overlay's 15 s.
  final Duration countdown;

  /// Holds the countdown where it is. Playback pausing must not burn the
  /// timer down: the viewer who pauses at the credits is the one most likely
  /// to be reading this card.
  final bool paused;

  final bool isTv;

  /// Fired by "Play now" and by the countdown reaching zero. The card does not
  /// distinguish them because the outcome is identical.
  final VoidCallback onPlayNext;

  /// The viewer declined. Nothing else happens — the episode plays out.
  final VoidCallback onCancel;

  @override
  State<NextEpisodeCountdown> createState() => _NextEpisodeCountdownState();
}

class _NextEpisodeCountdownState extends State<NextEpisodeCountdown>
    with SingleTickerProviderStateMixin {
  /// One clock, not a timer plus an animation. The old overlay ran a [Timer]
  /// for the deadline alongside an [AnimationController] for the ring and had
  /// to reconcile them by hand across pause and resume (`_elapsedFraction`);
  /// driving the deadline off the controller's own completion means the ring
  /// cannot disagree with the moment it fires.
  late final AnimationController _clock;

  /// Latches on the first outcome so neither callback can fire twice — a
  /// second [onPlayNext] would skip an episode nobody asked to skip.
  bool _settled = false;

  /// The card's own focus scope, and the whole reason the remote can reach it.
  ///
  /// Flutter applies a pending autofocus only while the target scope has no
  /// focused child (`_Autofocus.applyIfValid` in focus_manager.dart). The card
  /// is a *sibling* of the controls in the player's Stack, and the controls
  /// guarantee the route scope always has a focused child — a chrome button,
  /// or their key sink, which exists for exactly that reason. So an autofocus
  /// resolved against the route scope was discarded every single time and
  /// "Play now" never took the remote: on a television the countdown ran down
  /// to a destructive auto-advance with no focus ring anywhere to aim at.
  ///
  /// A scope of the card's own is empty by definition, so the autofocus on the
  /// Play-now button lands: applying it walks the scope chain and makes this
  /// scope the route's focused child on the way. That is the whole mechanism —
  /// verified by ablation, the scope alone carries tv_overlay_focus_test. The
  /// post-frame [FocusScopeNode.requestFocus] in [_grabRemoteAfterFrame] is a
  /// rescue for the one case the autofocus cannot cover: an autofocus is
  /// discarded, permanently, if anything has already been focused inside this
  /// scope by the time the manager gets to it, whereas a request is not gated
  /// on `focusedChild`. It cannot fight the autofocus — a request on a scope
  /// with no focused child only marks the scope, and the autofocus then
  /// resolves it onto Play now in the same pass.
  ///
  /// The controls cannot take the focus back. Their sink only reclaims when
  /// primary focus is a [FocusScopeNode] that is an *ancestor* of the sink,
  /// and this scope is a sibling.
  final FocusScopeNode _cardScope = FocusScopeNode(
    debugLabel: 'next-episode-card',
  );

  /// Whether the player route is the one the remote belongs to.
  ///
  /// The card is raised off a position sample, so it can mount while a panel
  /// is open over the player. That panel is a [PopupRoute]
  /// (panel/player_panel.dart), so the player route underneath stays built and
  /// focusable — Flutter only stops a route taking focus while it is animating
  /// out or under a user gesture, never merely because something was pushed
  /// over it. Both of the grabs below therefore reach *across* the modal:
  /// [FocusScopeNode.requestFocus] on an empty scope re-points every ancestor
  /// scope, the navigator's included, and the autofocus on Play now then lands
  /// because this scope is empty by construction. The panel is left on screen
  /// with the remote on a control underneath the barrier, and the first Back
  /// is eaten by [_onCardKey] instead of popping it.
  ///
  /// So both are gated on this. `_ModalScopeStatus` is an [InheritedModel]
  /// keyed on exactly this aspect, so depending on it in [build] rebuilds the
  /// card when a route is pushed over the player or popped off it — which is
  /// what hands the remote to a card that has been waiting behind a panel: the
  /// `autofocus` flips true and `Focus.didUpdateWidget` re-arms it (it was
  /// never spent), and [didChangeDependencies] re-runs the scope rescue.
  bool _routeIsCurrent = true;

  @override
  void initState() {
    super.initState();
    _clock = AnimationController(vsync: this, duration: widget.countdown)
      ..addStatusListener(_onClockStatus);
    if (!widget.paused) _clock.forward();
    // Safe to schedule before the route is looked up: didChangeDependencies
    // and the first build both run before a post-frame callback does, so
    // [_routeIsCurrent] is already true to the tree by the time it fires.
    _grabRemoteAfterFrame();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final wasCurrent = _routeIsCurrent;
    _routeIsCurrent = ModalRoute.isCurrentOf(context) ?? true;
    // Only on the transition back to current: a panel closing over a card that
    // is already up is the one case the initial grab cannot cover.
    if (_routeIsCurrent && !wasCurrent) _grabRemoteAfterFrame();
  }

  /// See [_cardScope]. After the frame, because the scope has no parent - and
  /// so nothing to be focused within - until the first build has attached it;
  /// this is the rescue for a frame in which the autofocus was already spent.
  void _grabRemoteAfterFrame() {
    if (!widget.isTv) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _routeIsCurrent) _cardScope.requestFocus();
    });
  }

  @override
  void didUpdateWidget(covariant NextEpisodeCountdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.paused == oldWidget.paused || _settled) return;
    // forward() resumes from wherever stop() left the value, so pause/resume
    // needs no bookkeeping of its own.
    widget.paused ? _clock.stop() : _clock.forward();
  }

  @override
  void dispose() {
    _clock.dispose();
    _cardScope.dispose();
    super.dispose();
  }

  void _onClockStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) _settle(widget.onPlayNext);
  }

  void _settle(VoidCallback outcome) {
    if (_settled) return;
    _settled = true;
    _clock.stop();
    outcome();
  }

  /// Back/Escape while focus is inside the card means "no", not "leave the
  /// player". Only reached when the card actually holds focus, so it cannot
  /// swallow a Back the viewer aimed at the route.
  KeyEventResult _onCardKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack) {
      _settle(widget.onCancel);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // isTv first, compact only as the non-TV fallback — the shape ended_card
    // uses. A 1080p television reports 960x540 dp (a Shield, a Google TV and a
    // Fire TV all present 1920x1080 at devicePixelRatio 2), so a bare
    // `shortestSide < 600` is TRUE on every set and would shadow every branch
    // below: the ten-foot card would be laid out as a 300 dp phone card and
    // floated only 72 dp up, over the bottom bar it is written to clear.
    final compact =
        !widget.isTv && MediaQuery.sizeOf(context).shortestSide < 600;
    final padding = MediaQuery.viewPaddingOf(context);
    final edge = widget.isTv
        ? HotstarPlayerStyle.tvEdgeInset
        : HotstarPlayerStyle.edgeInset;

    final double width = compact ? 300 : (widget.isTv ? 460 : 380);

    return Align(
      alignment: Alignment.bottomRight,
      child: Padding(
        padding: EdgeInsets.only(
          right: widget.isTv ? edge : (padding.right > edge ? padding.right : edge),
          // Sits clear of the scrubber rather than over it, derived from the
          // shared chrome token so it follows the bottom bar instead of
          // repeating its metrics. Phone chrome is much shorter than the
          // desktop/TV estimate, hence the two values.
          bottom: (compact ? 60.0 : HotstarPlayerStyle.bottomChromeHeight) +
              12 +
              padding.bottom,
        ),
        child: FocusScope(
          node: _cardScope,
          onKeyEvent: _onCardKey,
          child: FocusTraversalGroup(
            child: SizedBox(
              width: width,
              child: DecoratedBox(
                // A solid translucent panel, not a BackdropFilter. The card is
                // composited over the native video surface, and a blur forces
                // a readback of that surface on every repaint — every frame
                // here, because the ring is driven by an AnimationController
                // and so repaints on each vsync, not once per counted second.
                decoration: BoxDecoration(
                  color: HotstarPlayerStyle.panel.withValues(alpha: 0.94),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: HotstarPlayerStyle.divider),
                ),
                child: Padding(
                  padding: EdgeInsets.all(compact ? 12 : 14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        l10n.upNext.toUpperCase(),
                        // Every size in the card carries a ten-foot ramp: the
                        // panel's floor is 14 sp (panel/player_panel_metrics)
                        // and an eyebrow is the one label allowed under it.
                        style: TextStyle(
                          color: HotstarPlayerStyle.accent,
                          fontSize: widget.isTv ? 12 : 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.6,
                        ),
                      ),
                      SizedBox(height: compact ? 8 : 10),
                      _body(compact),
                      SizedBox(height: compact ? 10 : 12),
                      _buttons(l10n),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(bool compact) {
    final double thumbWidth = compact ? 96 : (widget.isTv ? 148 : 124);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Thumbnail(url: widget.posterUrl, width: thumbWidth),
        SizedBox(width: compact ? 10 : 12),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_meta case final meta?) ...[
                Text(
                  meta,
                  style: TextStyle(
                    color: HotstarPlayerStyle.secondaryText,
                    fontSize: widget.isTv ? 13 : 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
              ],
              Text(
                widget.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: HotstarPlayerStyle.primaryText,
                  fontSize: compact ? 14 : (widget.isTv ? 19 : 16),
                  fontWeight: FontWeight.w700,
                  height: 1.25,
                ),
              ),
              // Dropped on a phone in landscape, where the card competes with
              // the video for a few hundred pixels of height.
              if (!compact && widget.description?.isNotEmpty == true) ...[
                const SizedBox(height: 6),
                Text(
                  widget.description!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: HotstarPlayerStyle.mutedText,
                    fontSize: widget.isTv ? 14 : 12,
                    height: 1.35,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// `S2 E5 · 42m · ★ 8.1`, with every part optional — catalogue metadata is
  /// routinely partial, and a card of empty separators looks broken.
  String? get _meta {
    final parts = <String>[];
    final season = widget.season;
    final episode = widget.episode;
    if (season != null && episode != null) {
      parts.add('S$season E$episode');
    } else if (episode != null) {
      parts.add('E$episode');
    }

    final runtime = widget.runtime;
    if (runtime != null && runtime.inMinutes >= 1) {
      final hours = runtime.inHours;
      final minutes = runtime.inMinutes.remainder(60);
      parts.add(hours > 0 ? '${hours}h ${minutes}m' : '${minutes}m');
    }

    final rating = widget.rating;
    if (rating != null && rating > 0) {
      parts.add('★ ${rating.toStringAsFixed(1)}');
    }

    return parts.isEmpty ? null : parts.join('  ·  ');
  }

  Widget _buttons(AppLocalizations l10n) {
    return Row(
      children: [
        Expanded(
          child: _CardButton(
            label: l10n.playNow,
            filled: true,
            isTv: widget.isTv,
            // The remote lands here because activating it is what the
            // countdown is about to do anyway — an accidental select costs
            // nothing, while landing on Cancel would make the common case the
            // slow one. This only resolves the card's scope onto a child; what
            // brings the remote into the scope at all is [_cardScope], and
            // [_routeIsCurrent] is why neither reaches over an open panel.
            autofocus: widget.isTv && _routeIsCurrent,
            debugLabel: kPlayNextFocusLabel,
            onPressed: () => _settle(widget.onPlayNext),
            leading: _CountdownRing(
              clock: _clock,
              total: widget.countdown,
              isTv: widget.isTv,
            ),
          ),
        ),
        const SizedBox(width: 10),
        _CardButton(
          label: l10n.cancel,
          filled: false,
          isTv: widget.isTv,
          debugLabel: kCancelFocusLabel,
          onPressed: () => _settle(widget.onCancel),
        ),
      ],
    );
  }
}

/// Focus node labels. Public so the integration and the tests can assert where
/// the remote is without either of them owning a [FocusNode] — the card's only
/// node is the scope that carries the remote into it, so traversal *between*
/// its two controls stays entirely native.
const String kPlayNextFocusLabel = 'next_episode_play_now';
const String kCancelFocusLabel = 'next_episode_cancel';

/// Ring plus remaining seconds, repainting in isolation.
///
/// Its own [RepaintBoundary] because it is the only part of the card that
/// changes: without one, every frame of the ring would repaint the poster,
/// the text and the buttons on a layer sitting over the video surface.
class _CountdownRing extends StatelessWidget {
  const _CountdownRing({
    required this.clock,
    required this.total,
    required this.isTv,
  });

  final Animation<double> clock;
  final Duration total;
  final bool isTv;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: clock,
        builder: (context, _) {
          final remaining = total * (1 - clock.value);
          // Ceil so the ring reads "15" the instant it appears and only shows
          // "0" at the moment it fires.
          final seconds = (remaining.inMilliseconds / 1000).ceil();
          final double diameter = isTv ? 30 : 26;
          return SizedBox(
            width: diameter,
            height: diameter,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(
                  value: 1 - clock.value,
                  strokeWidth: 2,
                  backgroundColor: HotstarPlayerStyle.trackInactive,
                  valueColor: const AlwaysStoppedAnimation(Colors.white),
                ),
                Text(
                  '$seconds',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: isTv ? 13 : 11,
                    fontWeight: FontWeight.w800,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// The card's two actions, in the chrome's button idiom: a [Focus] that
/// handles select/enter/space and an [InkWell] that cannot take focus itself.
///
/// The InkWell is deliberately not focusable. Left to its default it creates a
/// second focus node at the same geometry as the wrapper, and directional
/// traversal then has two indistinguishable targets per button — one of which
/// handles no keys.
class _CardButton extends StatefulWidget {
  const _CardButton({
    required this.label,
    required this.onPressed,
    required this.filled,
    required this.isTv,
    required this.debugLabel,
    this.leading,
    this.autofocus = false,
  });

  final String label;
  final VoidCallback onPressed;
  final bool filled;
  final bool isTv;
  final String debugLabel;
  final Widget? leading;
  final bool autofocus;

  @override
  State<_CardButton> createState() => _CardButtonState();
}

class _CardButtonState extends State<_CardButton> {
  bool _focused = false;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (isPlayerActivation(event.logicalKey)) {
      widget.onPressed();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final ring = _focused && widget.isTv;
    final Color border = ring
        ? (widget.filled ? Colors.white : HotstarPlayerStyle.accent)
        : (widget.filled ? Colors.transparent : HotstarPlayerStyle.divider);

    return Semantics(
      button: true,
      label: widget.label,
      child: Focus(
        debugLabel: widget.debugLabel,
        autofocus: widget.autofocus,
        onKeyEvent: _onKey,
        onFocusChange: (value) => setState(() => _focused = value),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            onTap: widget.onPressed,
            canRequestFocus: false,
            borderRadius: BorderRadius.circular(10),
            child: AnimatedContainer(
              duration: HotstarPlayerStyle.fastMotionDuration,
              constraints: const BoxConstraints(minHeight: 44),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: widget.filled
                    ? HotstarPlayerStyle.accent
                    : (_focused
                        ? HotstarPlayerStyle.accent.withValues(alpha: 0.16)
                        : Colors.transparent),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: border, width: ring ? 2 : 1),
                boxShadow: ring
                    ? [
                        BoxShadow(
                          color: HotstarPlayerStyle.accent.withValues(alpha: 0.3),
                          blurRadius: 10,
                        ),
                      ]
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (widget.leading case final leading?) ...[
                    leading,
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: widget.isTv ? 16 : 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.url, required this.width});

  final String? url;
  final double width;

  @override
  Widget build(BuildContext context) {
    final height = width * 9 / 16;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: width,
        height: height,
        child: url?.isNotEmpty == true
            ? CachedNetworkImage(
                imageUrl: url!,
                fit: BoxFit.cover,
                memCacheWidth: (width * 2).round(),
                errorWidget: (_, _, _) => const ThumbnailErrorPlaceholder(),
                placeholder: (_, _) => const ColoredBox(
                  color: HotstarPlayerStyle.panelElevated,
                ),
              )
            : const ThumbnailErrorPlaceholder(),
      ),
    );
  }
}
