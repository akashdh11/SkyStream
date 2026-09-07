/// The shape the side panel takes, and the surface it is drawn on.
///
/// A 640px bottom sheet is the wrong container for this content anywhere but a
/// phone held upright. On a 1080p television or a wide desktop window it covers
/// the picture it is describing and gives a forty-source list four visible
/// rows; a right-hand drawer leaves the video alone and grows with the height
/// of the screen. So the shape follows the window rather than the platform:
/// drawer when there is width to spare, sheet when there is not.
///
/// OVERSCAN. On a television the drawer is held off the edges it touches by
/// [PlayerPanelMetrics.drawerEdgeInset], which is the app's own
/// `HotstarPlayerStyle.tvEdgeInset`. Consumer sets clip roughly 5 % of the
/// picture, and a right-anchored drawer puts the close button and every row's
/// badges exactly there. The width is worked out against what is left after
/// that inset, so the 34 % and the clamp still mean what they say.
library;

import 'package:flutter/material.dart';

import 'player_panel_metrics.dart';
import 'player_panel_row.dart' show kPanelSurface;

/// The panel's surface, as opposed to the transparent box it is aligned in.
/// Public so a test can measure where the panel actually sits.
const Key kPlayerPanelSurfaceKey = Key('player-panel-surface');

/// Where the panel is anchored.
enum PlayerPanelShape {
  /// Right-anchored, full height. Wide windows and every television.
  drawer,

  /// Bottom-anchored, part height. A phone in portrait, and nothing else.
  sheet,
}

/// Below this the window is too narrow to give up 380px of picture.
///
/// Width alone, not orientation or platform: a phone in landscape, a small
/// tablet and a half-width desktop window all want the same answer, and only
/// the width tells them apart.
const double kPanelDrawerMinWidth = 620;

/// The shape [size] calls for. A television is always a drawer — it is never
/// narrow, and a sheet on one is a strip of rows across the bottom of a room.
PlayerPanelShape playerPanelShapeFor(Size size, {required bool isTv}) =>
    isTv || size.width >= kPanelDrawerMinWidth
    ? PlayerPanelShape.drawer
    : PlayerPanelShape.sheet;

/// How far the panel travels on its way in, in the direction it comes from.
Offset playerPanelSlideFrom(PlayerPanelShape shape) =>
    shape == PlayerPanelShape.drawer ? const Offset(1, 0) : const Offset(0, 1);

/// Positions and paints the panel surface. Nothing about tabs or content: this
/// is the container, so its shape can be tested without building any of them.
///
/// Deliberately no [Stack] and no magic-offset [Positioned] — an [Align] over
/// a sized box is the whole layout, and it stays right when the window resizes
/// mid-session, which a hard-coded offset does not.
class PlayerPanelShell extends StatelessWidget {
  const PlayerPanelShell({
    required this.shape,
    required this.metrics,
    required this.child,
    super.key,
  });

  final PlayerPanelShape shape;

  /// The ramp the drawer is sized on. Passed rather than read from the tree so
  /// this widget has exactly one idea of which form factor it is on — the same
  /// instance `PlayerPanel` installs in the [PlayerPanelMetricsScope] below it.
  final PlayerPanelMetrics metrics;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final isDrawer = shape == PlayerPanelShape.drawer;

    // Overscan. Zero on touch and desktop, 48 dp on a television, where the
    // outer ~5 % of the panel is clipped by the set: without this the close
    // button and every row's right-hand badges are the first things to go.
    // Every other player surface already honours this token; the panel was the
    // one that did not.
    final edge = isDrawer ? metrics.drawerEdgeInset : 0.0;
    final verticalEdge = isDrawer ? metrics.drawerVerticalInset : 0.0;

    // Wide enough for a release name and a row of badges, capped so it never
    // becomes a second screen on a 4K desktop window. Measured against the
    // width the drawer can actually have, so the proportion and the clamp both
    // still mean what they say once the overscan inset is taken out.
    final width = isDrawer
        ? ((size.width - edge) * 0.34).clamp(
            metrics.drawerMinWidth,
            metrics.drawerMaxWidth,
          )
        : null;
    // Enough for six rows and the tab bar, and never so tall that the video
    // above it is a letterbox.
    final height = isDrawer ? null : (size.height * 0.66).clamp(280.0, 560.0);

    return Padding(
      // EdgeInsets.zero on every ramp but the television's, so this is a
      // layout no-op on a phone, a tablet and a desktop window.
      padding: EdgeInsets.only(
        right: edge,
        top: verticalEdge,
        bottom: verticalEdge,
      ),
      child: Align(
        alignment: isDrawer ? Alignment.centerRight : Alignment.bottomCenter,
        // Tight on the axis the shape is anchored across - a drawer is exactly
        // this wide, a sheet is the full width of the window - and bounded but
        // not forced on the other, so the content can be shorter than its cap.
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: width ?? size.width,
            maxWidth: width ?? size.width,
            maxHeight: height ?? double.infinity,
          ),
          child: _PanelSurface(shape: shape, child: child),
        ),
      ),
    );
  }
}

/// Opaque surface with an edge to lift it off the video.
///
/// No [BackdropFilter]: this is composited over a platform view on macOS, iOS
/// and Android, where a blur reads the surface back on every repaint and the
/// layer it needs is the size of the panel for the whole time it is up. The old
/// panel had five stacked effect layers here — a blur, two gradients and two
/// ShaderMasks — for a look nobody can see in motion.
class _PanelSurface extends StatelessWidget {
  const _PanelSurface({required this.shape, required this.child});

  final PlayerPanelShape shape;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isDrawer = shape == PlayerPanelShape.drawer;
    final radius = isDrawer
        ? const BorderRadius.only(
            topLeft: Radius.circular(14),
            bottomLeft: Radius.circular(14),
          )
        : const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
          );

    return DecoratedBox(
      key: kPlayerPanelSurfaceKey,
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x80000000),
            blurRadius: 32,
            offset: Offset(-6, 0),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Material(
          color: kPanelSurface,
          // The device's own cutout inset on the far side would phantom-indent
          // a right-anchored drawer, which is why left is off there.
          child: SafeArea(left: !isDrawer, top: isDrawer, child: child),
        ),
      ),
    );
  }
}
