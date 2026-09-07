import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../widgets/hotstar_player_style.dart';
import '../widgets/player_activation.dart';

/// What the media stopping actually means, once the screen has asked the
/// episode list.
///
/// Two values, both load-bearing. The spec proposed `{film, seriesFinished}`,
/// but nothing renders differently between those two — the headline names
/// `widget.item.title` either way and the actions are identical — while the
/// third state owner decision 2 creates is genuinely different: an episode
/// *does* follow, the viewer declined it during the credits, and the card owes
/// them a one-press way back into the binge.
enum EndedKind {
  /// Nothing follows at all: a film, or the last episode of a series.
  finished,

  /// An episode follows, but the viewer pressed Cancel on the up-next card.
  ///
  /// Owner decision 2: the refusal is honoured — playback does **not**
  /// auto-advance — so this card carries Next as its primary action instead.
  declinedNext,
}

/// The key the screen hangs on the card, and the only handle the screen tests
/// need on it.
const Key endedCardKey = Key('player-ended-card');

/// Focus node labels, in [kPlayNextFocusLabel]'s convention. Public so a test
/// can say where the remote is without the card owning a [FocusNode] of its
/// own: its only node is the scope that carries the remote into it, and
/// traversal between the actions stays entirely native.
const String kEndedNextFocusLabel = 'ended_next_episode';
const String kEndedStartOverFocusLabel = 'ended_start_over';
const String kEndedCloseFocusLabel = 'ended_close';

/// What a film — or the last episode of a series — ends on, instead of a dead
/// frame.
///
/// Before this, end of media on anything [nextEpisodeFor] had no answer for
/// left the last decoded frame frozen under nothing at all: the 3 s chrome
/// clock had hidden the bars long before the credits, and nudging the remote
/// brought back a Play glyph whose press calls `play()` on a player that is
/// already at Ended. There was no Replay, and no way out but Back.
///
/// Engine-agnostic and stateless about playback, exactly like
/// [NextEpisodeCountdown]: every value it renders and every outcome is handed
/// in, so this file imports nothing from the player package and is testable
/// with no fake engine.
///
/// Rendering is a **paint, not a layer**: a [ColoredBox] rather than an
/// [AnimatedOpacity] or a [BackdropFilter]. A full-bleed effect layer over a
/// platform view is re-surfaced on every show/hide — the exact shape that
/// black-framed macOS and iOS, and the exact shape controls_layer_shape_test's
/// 40 %-of-viewport rule exists to forbid.
class EndedCard extends StatefulWidget {
  const EndedCard({
    required this.title,
    required this.kind,
    required this.onStartOver,
    required this.onClose,
    this.onNextEpisode,
    this.nextLabel,
    this.isTv = false,
    super.key,
  }) : assert(
         (kind == EndedKind.declinedNext) == (onNextEpisode != null),
         'declinedNext is the only kind with a next episode to offer, and it '
         'always has one',
       );

  /// What the headline says has finished. The film or series title for
  /// [EndedKind.finished]; the episode's own name for a declined advance,
  /// where "you have finished `<series>`" would be a lie.
  final String title;

  final EndedKind kind;

  /// Reopens the media from the start. Non-null always: a finished thing can
  /// always be watched again.
  final VoidCallback onStartOver;

  /// Leaves the player.
  final VoidCallback onClose;

  /// Plays the episode the viewer declined during the credits. Null unless
  /// [kind] is [EndedKind.declinedNext].
  final VoidCallback? onNextEpisode;

  /// The next action's label, already localised and already decorated with
  /// `S2 E5` where the numbers are known — the details screen's own idiom
  /// (`details_layout_widgets.dart:136-143`). Null falls back to a plain
  /// [AppLocalizations.next].
  final String? nextLabel;

  final bool isTv;

  @override
  State<EndedCard> createState() => _EndedCardState();
}

class _EndedCardState extends State<EndedCard> {
  /// The card's own focus scope, and the whole reason the remote can reach it.
  ///
  /// The same mechanism [NextEpisodeCountdown] documents at length: Flutter
  /// applies a pending autofocus only while the target scope has no focused
  /// child, so an autofocus resolved against the route scope is discarded
  /// whenever anything in the player already holds focus. A scope of the
  /// card's own is empty by definition, so the autofocus on the primary action
  /// lands.
  ///
  /// Belt and braces here rather than trust: the screen unmounts the whole
  /// [VlcPlayerControls] subtree — key sink and all — in the same frame this
  /// mounts, which *should* leave the route scope with no focused child, but
  /// "should" is what left Play now unreachable on a television for a release.
  final FocusScopeNode _cardScope = FocusScopeNode(debugLabel: 'ended-card');

  /// Whether the player's own route is the one the remote belongs to.
  ///
  /// The card is raised by an engine event, so it can mount while a panel is
  /// open over the player. That panel is a [PopupRoute]
  /// (`showPlayerPanel` in panel/player_panel.dart), and a route underneath a
  /// pushed route stays perfectly focusable: the framework expresses currency
  /// as `skipTraversal` alone (routes.dart, `_ModalScopeState.build`) and only
  /// withholds `canRequestFocus` while a route is animating out or under a
  /// user gesture. So *both* of the grabs below reach across the barrier —
  /// [FocusScopeNode.requestFocus] on an empty scope re-points every ancestor
  /// scope including the navigator's, and the `autofocus` on the primary
  /// action lands on its own because this scope is empty by construction.
  /// Ungated, a film ending under an open Subtitles panel moved the remote to
  /// a button the barrier covers, where the viewer's next OK reopened the film
  /// from zero or left the player.
  ///
  /// `_ModalScopeStatus` is an [InheritedModel] keyed on exactly this aspect,
  /// so reading it here rebuilds the card when a route is pushed over the
  /// player or popped off it. That is also what hands the remote to a card
  /// that has been waiting behind a panel: `autofocus` flips true and
  /// `Focus.didUpdateWidget` re-arms it (it was never spent, so the
  /// `_didAutofocus` latch is still down), and the scope rescue runs again.
  bool _routeIsCurrent = true;

  @override
  void initState() {
    super.initState();
    // didChangeDependencies runs before the first build and so before this
    // callback fires, which is what makes [_routeIsCurrent] true to the tree
    // by the time the grab reads it.
    _grabRemoteAfterFrame();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final wasCurrent = _routeIsCurrent;
    _routeIsCurrent = ModalRoute.isCurrentOf(context) ?? true;
    // Only on the way back to current: a panel closing over a card that is
    // already up is the one case the grab in [initState] cannot cover.
    if (_routeIsCurrent && !wasCurrent) _grabRemoteAfterFrame();
  }

  /// See [_cardScope]. After the frame, because the scope has no parent — and
  /// so nothing to be focused within — until the first build has attached it.
  void _grabRemoteAfterFrame() {
    if (!widget.isTv) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _routeIsCurrent) _cardScope.requestFocus();
    });
  }

  @override
  void dispose() {
    _cardScope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final compact = MediaQuery.sizeOf(context).shortestSide < 600;
    final actions = <Widget>[
      if (widget.onNextEpisode case final next?)
        _EndedButton(
          icon: Icons.skip_next_rounded,
          label: widget.nextLabel ?? l10n.next,
          filled: true,
          isTv: widget.isTv,
          // Gated on [_routeIsCurrent] as well as the scope grab: an autofocus
          // resolves against this card's own scope, which is empty whether or
          // not a panel is up, so the guard on the grab alone is a no-op.
          autofocus: widget.isTv && _routeIsCurrent,
          debugLabel: kEndedNextFocusLabel,
          onPressed: next,
        ),
      _EndedButton(
        icon: Icons.replay_rounded,
        label: l10n.startOver,
        // Primary only when nothing follows. With a declined episode on the
        // card, taking the remote here would make the common case the slow
        // one — the same reasoning that puts the up-next card's autofocus on
        // Play now.
        filled: widget.onNextEpisode == null,
        isTv: widget.isTv,
        autofocus:
            widget.isTv && widget.onNextEpisode == null && _routeIsCurrent,
        debugLabel: kEndedStartOverFocusLabel,
        onPressed: widget.onStartOver,
      ),
      _EndedButton(
        icon: Icons.close_rounded,
        label: l10n.close,
        filled: false,
        isTv: widget.isTv,
        debugLabel: kEndedCloseFocusLabel,
        onPressed: widget.onClose,
      ),
    ];

    return RepaintBoundary(
      child: ColoredBox(
        // Not opaque: a trace of the last frame under the words is the
        // difference between "this finished" and "the app closed the video".
        color: Colors.black.withValues(alpha: 0.92),
        child: FocusScope(
          node: _cardScope,
          child: FocusTraversalGroup(
            policy: ReadingOrderTraversalPolicy(),
            child: SafeArea(
              // Owner decision 5: the overscan token is honoured everywhere on
              // a television, and this surface is full-bleed by construction.
              minimum: EdgeInsets.all(
                widget.isTv
                    ? HotstarPlayerStyle.tvEdgeInset
                    : HotstarPlayerStyle.edgeInset,
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      l10n.playerFinished(widget.title),
                      textAlign: TextAlign.center,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: HotstarPlayerStyle.primaryText,
                        fontSize: widget.isTv ? 30 : (compact ? 20 : 24),
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                      ),
                    ),
                    SizedBox(height: widget.isTv ? 32 : 24),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      alignment: WrapAlignment.center,
                      children: actions,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One action, as one focus stop.
///
/// Deliberately not [PlayerActionButton], which the spec suggested: that
/// widget's `InkWell` is left focusable, so every one of its buttons is *two*
/// focus stops at identical geometry — the codebase says so itself in
/// `controls_focus_test.dart`'s `_skipChipNode` ("the chip owns two"). In the
/// bottom bar that costs a dead D-pad press between buttons; on a card that is
/// the only thing on screen, half of every press would do nothing. It also
/// carries no `debugLabel`, so no test could say where the remote is.
///
/// This is [NextEpisodeCountdown]'s `_CardButton` shape — a [Focus] that
/// handles the activation keys over an [InkWell] that cannot take focus — with
/// a leading icon and the television type ramp. The duplication is deliberate
/// and reported: the two cards are the only users, the sibling's copy lives in
/// a file this item does not own, and inventing a shared widget across an
/// ownership boundary mid-wave is how two agents collide.
class _EndedButton extends StatefulWidget {
  const _EndedButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    required this.filled,
    required this.isTv,
    required this.debugLabel,
    this.autofocus = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool filled;
  final bool isTv;
  final String debugLabel;
  final bool autofocus;

  @override
  State<_EndedButton> createState() => _EndedButtonState();
}

class _EndedButtonState extends State<_EndedButton> {
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
    // The ten-foot ramp owner decision 6 set for the panel's row labels, on
    // the one surface a viewer reads from the sofa with nothing else on it.
    final double fontSize = widget.isTv ? 17 : 14;

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
            // One control, one focus stop. Left focusable, the InkWell makes a
            // node of its own at the same geometry that answers no keys.
            canRequestFocus: false,
            borderRadius: BorderRadius.circular(10),
            child: AnimatedContainer(
              duration: HotstarPlayerStyle.fastMotionDuration,
              constraints: BoxConstraints(minHeight: widget.isTv ? 52 : 44),
              padding: EdgeInsets.symmetric(horizontal: widget.isTv ? 20 : 16),
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
                          color: HotstarPlayerStyle.accent.withValues(
                            alpha: 0.3,
                          ),
                          blurRadius: 10,
                        ),
                      ]
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    widget.icon,
                    color: Colors.white,
                    size: widget.isTv ? 22 : 18,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: fontSize,
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
