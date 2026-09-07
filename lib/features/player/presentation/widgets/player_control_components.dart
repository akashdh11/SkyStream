import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../../shared/widgets/custom_widgets.dart';
import 'hotstar_player_style.dart';
import 'player_activation.dart';

/// Top zone: back button + title/subtitle. Paints its own top scrim so the
/// chrome no longer needs a separate fixed-height Positioned gradient.
class PlayerTopBar extends StatelessWidget {
  final String title;
  final String? subtitle;
  final VoidCallback? onBack;
  final bool isTv;
  final FocusNode? backFocusNode;

  const PlayerTopBar({
    super.key,
    required this.title,
    this.subtitle,
    this.onBack,
    this.isTv = false,
    this.backFocusNode,
  });

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.viewPaddingOf(context);
    final edge = isTv
        ? HotstarPlayerStyle.tvEdgeInset
        : HotstarPlayerStyle.edgeInset;
    final double leftPadding = isTv
        ? edge
        : (padding.left > edge ? padding.left : edge);
    final double rightPadding = isTv
        ? edge
        : (padding.right > edge ? padding.right : edge);
    return DecoratedBox(
      decoration: const BoxDecoration(gradient: HotstarPlayerStyle.topGradient),
      child: SafeArea(
        left: false,
        right: false,
        bottom: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(leftPadding, 14, rightPadding, 24),
          child: Row(
            children: [
              PlayerIconButton(
                icon: Icons.arrow_back_rounded,
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                onPressed: onBack,
                isTv: isTv,
                focusNode: backFocusNode,
                iconSize: isTv ? 34 : 30,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (subtitle != null && subtitle!.isNotEmpty)
                      Text(
                        subtitle!,
                        style: const TextStyle(
                          color: HotstarPlayerStyle.secondaryText,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    Text(
                      title,
                      style: TextStyle(
                        color: HotstarPlayerStyle.primaryText,
                        fontSize: isTv ? 22 : 18,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bottom zone shell: scrubber row on top, then a single flat controls row —
/// [leading] (playback) pinned left, a [Spacer], then [actions] (everything
/// else) on the right. All buttons are direct siblings of one [Row].
///
/// The [leading] group is pinned left; the [actions] group lives in a
/// horizontal scroll view that is right-anchored when it fits and scrolls to
/// reveal overflow when there are more buttons than fit (otherwise the extras
/// were simply clipped and unreachable).
///
/// Left/Right/Up/Down are left to [DirectionalFocusAction]: the buttons are
/// siblings in one [Row] inside one [FocusTraversalGroup], so geometric
/// traversal already walks the row and stops at its ends. An earlier version
/// drove Left/Right by hand with [FocusNode.nextFocus]/[previousFocus]; those
/// operate on the enclosing *scope* (the route), not the group, and wrap to
/// the route's first/last node — so Right from the last button landed somewhere
/// else on screen. Paints its own scrim.
class PlayerBottomBar extends StatelessWidget {
  final Widget progressBar;
  final List<Widget> leading;
  final List<Widget> actions;
  final bool isTv;

  /// On touch the [actions] go in a finger-scrollable strip (so a long list is
  /// reachable); on TV/desktop they stay a fixed right-aligned group navigated
  /// by D-pad. A keyboard [Scrollable] would re-introduce the focus trap, so it
  /// is used only where there's no directional focus (touch).
  final bool isTouch;

  const PlayerBottomBar({
    super.key,
    required this.progressBar,
    this.leading = const [],
    this.actions = const [],
    this.isTv = false,
    this.isTouch = false,
  });

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.viewPaddingOf(context);
    final edge = isTv
        ? HotstarPlayerStyle.tvEdgeInset
        : HotstarPlayerStyle.edgeInset;
    final double leftPadding = isTv
        ? edge
        : (padding.left > edge ? padding.left : edge);
    final double rightPadding = isTv
        ? edge
        : (padding.right > edge ? padding.right : edge);
    // The same shape as the top bar's scrim: a gradient is paint, not a
    // compositing layer, so it costs nothing over the platform view and stays
    // inside the bar's own fade. Without it every reveal on a bright scene
    // puts white glyphs on white.
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: HotstarPlayerStyle.bottomGradient,
      ),
      child: SafeArea(
        left: false,
        right: false,
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(leftPadding, 2, rightPadding, 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              progressBar,
              FocusTraversalGroup(
                child: Row(
                  children: [
                    // Left group: play/pause, lock, next — always visible.
                    ...leading,
                    if (isTouch)
                      // Touch: right-anchored finger-scroll strip so a long
                      // action list is never clipped out of reach.
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          reverse: true,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: actions,
                          ),
                        ),
                      )
                    else ...[
                      // TV/desktop: fixed right-aligned group (D-pad nav).
                      const Spacer(),
                      ...actions,
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact icon-only button for utilities (resize, PiP, fullscreen) and the
/// top-bar back button. Tooltip doubles as the semantics label.
class PlayerIconButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool isTv;
  final bool highlight;
  final FocusNode? focusNode;

  /// {@macro flutter.widgets.Focus.autofocus}
  final bool autofocus;

  /// Optional icon-size override (the tap target grows to match). Used by the
  /// top-bar back button so it reads at the same weight as the title.
  final double? iconSize;

  const PlayerIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.isTv = false,
    this.highlight = false,
    this.focusNode,
    this.autofocus = false,
    this.iconSize,
  });

  @override
  State<PlayerIconButton> createState() => _PlayerIconButtonState();
}

class _PlayerIconButtonState extends State<PlayerIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final double glyph = widget.iconSize ?? (widget.isTv ? 28 : 26);
    final double box = glyph + (widget.isTv ? 20 : 18);

    Color iconColor;
    if (_hovered) {
      iconColor = HotstarPlayerStyle.accent;
    } else if (widget.highlight) {
      iconColor = HotstarPlayerStyle.accent;
    } else {
      iconColor = Colors.white;
    }

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: CustomButton(
          onPressed: widget.onPressed,
          showFocusHighlight: widget.isTv,
          focusNode: widget.focusNode,
          autofocus: widget.autofocus,
          shape: const CircleBorder(),
          child: SizedBox(
            width: box,
            height: box,
            child: Icon(widget.icon, color: iconColor, size: glyph),
          ),
        ),
      ),
    );
  }
}

/// The big centred play/pause a phone or tablet expects over the video.
///
/// Sits beside [PlayerIconButton] so the two stay one design: same white
/// glyph, same rounded Material icons, and the disc is the only thing the
/// bottom-bar copy does not have. It is a second control, not a replacement -
/// the bar keeps its own play/pause, because the chrome's focus machinery
/// names that node and both Netflix and Prime ship two on a tablet.
///
/// Deliberately **not** a [CustomButton] and deliberately **not** a [Focus]:
/// it holds no [FocusNode], so it is not a traversal candidate and can never
/// compete for the autofocus the bottom bar's play/pause owns on television.
/// It is built on touch only, so on a remote it does not exist at all.
///
/// [HitTestBehavior.translucent] is load-bearing rather than a default. The
/// player's screen-wide gesture detector is the *first* child of the same
/// Stack and this glyph is a later one, so hit testing reaches the glyph
/// first. Opaque would stop [RenderStack.defaultHitTestChildren] dead and the
/// screen-wide detector would never enter the gesture arena - which kills
/// swipe-to-seek and swipe-for-volume started from the dead centre of the
/// frame. Translucent puts both in the arena: a tap goes to the deeper member
/// and a drag to the parent as soon as the pointer moves.
///
/// Translucent alone is not enough, and this is the part that is easy to get
/// wrong. `RenderProxyBoxWithHitTestBehavior.hitTest` returns `hitTarget`,
/// which is true whenever a *child* was hit - and `RenderParagraph.hitTestSelf`
/// returns true unconditionally, so the [Icon] in the middle of the disc makes
/// the detector answer "hit" and the Stack stops walking exactly as if it were
/// opaque. Measured: a `dragFrom(centre)` stopped seeking. So the disc is
/// wrapped in an [IgnorePointer] - it is paint, and the gesture belongs to the
/// square around it. The detector then reports no hit, adds itself to the
/// result anyway (that is what translucent means) and the walk carries on down
/// to the screen-wide detector.
///
/// The label is passed in rather than looked up here: this file is not a
/// localization boundary, and `lib/features/player/**` has a zero budget for
/// hardcoded user-visible strings.
class PlayerCenterPlayButton extends StatelessWidget {
  /// Whether playback is running - a rebuffer counts as running, exactly as it
  /// does for the bottom bar, since the film resumes without a press.
  final bool playing;

  /// The localized "Play"/"Pause" the semantics layer announces.
  final String label;

  final VoidCallback onPressed;

  const PlayerCenterPlayButton({
    super.key,
    required this.playing,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    // A phone gets the smaller disc; anything with a 600 dp short side is a
    // tablet held further away and takes the larger one.
    final double diameter = MediaQuery.sizeOf(context).shortestSide < 600
        ? 72
        : 88;
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: onPressed,
        child: IgnorePointer(
          child: SizedBox.square(
            dimension: diameter,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                // A paint, not a layer: no opacity or filter here, so nothing
                // new is composited over the platform view.
                color: Colors.black.withValues(alpha: 0.34),
              ),
              // 0.52 is the Netflix/Prime proportion - a glyph inside a disc.
              // Filling the disc reads as a bare icon with a smudge behind it.
              child: Icon(
                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: Colors.white,
                size: diameter * 0.52,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Labelled icon button for the controls row (Sources, Subtitles, Speed, …)
/// and for the Skip Intro/Outro chip. Activates on tap and, when focused, on
/// every key [isPlayerActivation] names — select, enter, space and a game
/// controller's A; directional navigation between buttons is handled natively
/// by the enclosing traversal group — this widget never moves focus itself.
class PlayerActionButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool highlight;
  final bool isTv;
  final FocusNode? focusNode;

  /// {@macro flutter.widgets.Focus.autofocus}
  final bool autofocus;

  const PlayerActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.highlight = false,
    this.isTv = false,
    this.focusNode,
    this.autofocus = false,
  });

  @override
  State<PlayerActionButton> createState() => _PlayerActionButtonState();
}

class _PlayerActionButtonState extends State<PlayerActionButton> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final showBg = (widget.highlight || _focused || _pressed) && !_hovered;
    final color = (widget.highlight || _hovered || _focused || _pressed)
        ? HotstarPlayerStyle.accent
        : Colors.white;
    final showTvFocusRing = widget.isTv && _focused;

    return Semantics(
      button: true,
      selected: widget.highlight,
      label: widget.label,
      child: Focus(
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        onFocusChange: (value) => setState(() => _focused = value),
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (isPlayerActivation(event.logicalKey)) {
            widget.onTap();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() {
            _hovered = false;
            _pressed = false;
          }),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              onTap: widget.onTap,
              onHighlightChanged: _setPressed,
              borderRadius: BorderRadius.circular(8),
              hoverColor: Colors.transparent,
              focusColor: Colors.transparent,
              splashColor: Colors.transparent,
              highlightColor: Colors.transparent,
              child: AnimatedContainer(
                duration: HotstarPlayerStyle.fastMotionDuration,
                constraints: const BoxConstraints(minHeight: 44),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: showBg
                      ? HotstarPlayerStyle.accent.withValues(alpha: 0.16)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: showTvFocusRing
                      ? Border.all(color: HotstarPlayerStyle.accent, width: 2)
                      : null,
                  boxShadow: showTvFocusRing
                      ? [
                          BoxShadow(
                            color: HotstarPlayerStyle.accent.withValues(
                              alpha: 0.2,
                            ),
                            blurRadius: 8,
                          ),
                        ]
                      : null,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(widget.icon, color: color, size: 20),
                    const SizedBox(width: 6),
                    Text(
                      widget.label,
                      style: TextStyle(
                        color: color,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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
