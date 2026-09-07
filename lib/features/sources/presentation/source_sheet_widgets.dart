import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../core/network/link_probe_service.dart';
import '../../player/presentation/widgets/hotstar_player_style.dart';

/// Accent shared with the player chrome, so a source card's Play button and
/// the controls it launches read as one product. Both sheets use this instead
/// of re-declaring the literal.
const Color sourceSheetAccent = HotstarPlayerStyle.accent;

/// Why a sources sheet was opened. Both actions stay on every row; the mode
/// only decides the default tap action and the initial filtering.
enum SourcesMode { play, download }

/// Small coloured pill used for quality/source tags.
class SourceTag extends StatelessWidget {
  final String text;
  final Color color;
  const SourceTag({super.key, required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: color,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// Working / dead / testing indicator driven by [LinkProbeService].
class ProbeBadge extends StatelessWidget {
  final LinkProbeResult? probe;
  final bool probing;
  final bool isPeerToPeer;

  const ProbeBadge({
    super.key,
    required this.probe,
    required this.probing,
    this.isPeerToPeer = false,
  });

  static String _shortReason(String? reason) {
    if (reason == null || reason.isEmpty) return 'Dead link';
    final lower = reason.toLowerCase();
    if (lower.contains('failed host lookup') ||
        lower.contains('socketexception') ||
        lower.contains('connection refused') ||
        lower.contains('connection terminated')) {
      return 'Unreachable';
    }
    if (lower.contains('timeout') || lower.contains('timed out')) {
      return 'Timed out';
    }
    if (lower.contains('403') || lower.contains('forbidden')) {
      return 'Blocked (403)';
    }
    if (lower.contains('404') || lower.contains('not found')) {
      return 'Not found (404)';
    }
    if (lower.contains('500') ||
        lower.contains('502') ||
        lower.contains('503')) {
      return 'Server error';
    }
    if (reason.length > 18) {
      return 'Dead link';
    }
    return reason;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    if (isPeerToPeer) {
      return Text(
        'P2P',
        style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
      );
    }
    if (probing) {
      return SizedBox(
        width: 10,
        height: 10,
        child: CircularProgressIndicator(strokeWidth: 1.5, color: cs.primary),
      );
    }
    final result = probe;
    if (result == null) return const SizedBox.shrink();
    if (result.reachable) {
      return const SizedBox.shrink();
    }

    final reason = _shortReason(result.failureReason);
    final isNotFound = reason.toLowerCase().contains('not found');
    final isUnreachable = reason.toLowerCase().contains('unreachable');
    final Color badgeColor = isNotFound
        ? const Color(0xFFEF4444) // var(--text-danger)
        : (isUnreachable ? const Color(0xFFF59E0B) : cs.error); // var(--text-warning)
    final IconData badgeIcon = isNotFound
        ? Icons.cancel_rounded // circle-x
        : (isUnreachable ? Icons.warning_amber_rounded : Icons.error_outline_rounded); // alert-triangle

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 130),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(badgeIcon, size: 12, color: badgeColor),
          const SizedBox(width: 2),
          Flexible(
            child: Text(
              reason,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: badgeColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Wraps the Play / Download row of a source card.
///
/// **Focus.** The cards are the UP/DOWN stops; the buttons are reached with
/// LEFT/RIGHT once a card holds focus. Because the row sits at the bottom edge
/// of the card, from a neighbouring card those buttons pass Flutter's
/// directional filter (`centre.dy <= target.top` going up) and then win on
/// distance against the card they belong to — UP from card 3 lands on card 2's
/// Play button instead of card 2. Making the row untraversable unless
/// [cardFocusNode] holds focus keeps other cards' buttons out of the
/// candidate set entirely, while the focused card's own buttons stay in it so
/// LEFT/RIGHT (and Tab on desktop) resolve natively between them.
///
/// The buttons stay *focusable* the whole time — only traversal is gated — so
/// a card's key handler can still call `requestFocus()` on them directly.
///
/// **Hit target.** The chips paint at ~26dp so the cards keep their height;
/// [_TapTargetBand] widens the band that accepts pointers to
/// [kMinInteractiveDimension] without changing what is laid out or painted.
class SourceCardActions extends StatefulWidget {
  /// The focus node of the card this row belongs to. It must be an ancestor of
  /// the row, which is how a focused button keeps the card "in focus".
  final FocusNode cardFocusNode;
  final Widget child;

  const SourceCardActions({
    super.key,
    required this.cardFocusNode,
    required this.child,
  });

  @override
  State<SourceCardActions> createState() => _SourceCardActionsState();
}

class _SourceCardActionsState extends State<SourceCardActions> {
  late bool _cardHasFocus = widget.cardFocusNode.hasFocus;

  @override
  void initState() {
    super.initState();
    widget.cardFocusNode.addListener(_handleCardFocusChange);
  }

  @override
  void didUpdateWidget(SourceCardActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.cardFocusNode, widget.cardFocusNode)) {
      oldWidget.cardFocusNode.removeListener(_handleCardFocusChange);
      widget.cardFocusNode.addListener(_handleCardFocusChange);
      _cardHasFocus = widget.cardFocusNode.hasFocus;
    }
  }

  @override
  void dispose() {
    widget.cardFocusNode.removeListener(_handleCardFocusChange);
    super.dispose();
  }

  void _handleCardFocusChange() {
    final hasFocus = widget.cardFocusNode.hasFocus;
    if (hasFocus != _cardHasFocus && mounted) {
      setState(() => _cardHasFocus = hasFocus);
    }
  }

  @override
  Widget build(BuildContext context) {
    // The band has to be the outermost box: [Focus] wraps its child in a
    // [Semantics] proxy, and a proxy's bounds check would reject the pointer
    // before it ever reached the band.
    return _TapTargetBand(
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        descendantsAreTraversable: _cardHasFocus,
        child: widget.child,
      ),
    );
  }
}

/// Gives a hand-built action chip the button role assistive tech expects.
///
/// The chips are bare [InkWell]s — and a plain [Container] when disabled — so
/// nothing in the subtree reports a role or a disabled state on its own. The
/// chip's own [Text] supplies the label unless [label] overrides it.
class SourceActionSemantics extends StatelessWidget {
  final bool enabled;
  final String? label;
  final Widget child;

  const SourceActionSemantics({
    super.key,
    required this.enabled,
    this.label,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: child,
    );
  }
}

/// Accepts pointers within [kMinInteractiveDimension] of its child's centre
/// line, folding a near miss onto the row so it reaches whichever chip is
/// under the finger.
///
/// Layout and painting are untouched: a taller box here would push every card
/// taller, and a hit area cannot extend past an ancestor's bounds, so the
/// growth has to happen at the row rather than around each chip.
///
/// That ancestor rule also makes the band ASYMMETRIC in practice. The action
/// row is the last child of the card's Column, so a pointer below it is
/// already outside the Column and is rejected before it reaches here; only the
/// upward half is live. A tap in the gap below the chips therefore falls
/// through to the card itself, which is the intended behaviour for Play and a
/// known rough edge for Download. The maths below stays symmetric because it
/// is the correct general rule, not because both halves fire here.
class _TapTargetBand extends SingleChildRenderObjectWidget {
  const _TapTargetBand({required Widget super.child});

  @override
  _RenderTapTargetBand createRenderObject(BuildContext context) =>
      _RenderTapTargetBand();
}

class _RenderTapTargetBand extends RenderProxyBox {
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (super.hitTest(result, position: position)) return true;

    final RenderBox? child = this.child;
    if (child == null) return false;

    final overhang = (kMinInteractiveDimension - size.height) / 2;
    if (overhang <= 0) return false;
    if (position.dx < 0 || position.dx > size.width) return false;
    if (position.dy < -overhang || position.dy > size.height + overhang) {
      return false;
    }

    final folded = Offset(position.dx, size.height / 2);
    return result.addWithRawTransform(
      transform: MatrixUtils.forceToPoint(folded),
      position: position,
      hitTest: (BoxHitTestResult result, Offset position) {
        assert(position == folded);
        return child.hitTest(result, position: folded);
      },
    );
  }
}

/// Best-guess container extension for a link, used when naming downloads.
String extensionForUrl(String url) {
  final clean = url.split('?').first.toLowerCase();
  for (final ext in const ['.mp4', '.mkv', '.webm', '.avi', '.mov']) {
    if (clean.endsWith(ext)) return ext;
  }
  return '.mp4';
}

