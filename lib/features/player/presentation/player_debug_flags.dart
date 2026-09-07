/// Compile-time switches for hunting the macOS black flicker on a real machine.
///
/// All three are `--dart-define` flags, so a build carries none of them unless
/// asked, and none of them can be reached from settings. They exist because
/// every explanation of the flicker so far has come from reading code, and two
/// of those explanations were wrong; these produce evidence instead.
///
///   flutter run --dart-define=PLAYER_PLATFORM_VIEW=true
///       Renders video through the platform view - AppKitView / UiKitView /
///       AndroidView - instead of a Flutter texture. The texture became the
///       default on every platform on 2026-09-06 after the macOS view was
///       shown to drop the video for a frame on every control interaction.
///       This is the escape hatch for an A/B if a texture path ever looks
///       wrong on a device.
///
///   flutter run -d macos --dart-define=PLAYER_DEBUG_COLORS=true
///       Paints the surface BELOW the video magenta and the player widget's
///       own backdrop lime. A flash that shows either colour is Flutter letting
///       something underneath through - an overlay surface presented before it
///       was rastered. A flash that stays BLACK is the VLC view itself going
///       blank, which is a different bug in a different layer.
///
///   flutter run -d macos --dart-define=PLAYER_REPAINT_RAINBOW=true
///       Flutter's repaint rainbow: every repainted region cycles colour. Shows
///       exactly how much of the overlay repaints when the pointer moves over
///       a control.
library;

import 'package:flutter/material.dart';
import 'package:vlc_player/vlc_player.dart';

const bool kPlayerDebugPlatformView = bool.fromEnvironment(
  'PLAYER_PLATFORM_VIEW',
);
const bool kPlayerDebugColors = bool.fromEnvironment('PLAYER_DEBUG_COLORS');
const bool kPlayerRepaintRainbow = bool.fromEnvironment(
  'PLAYER_REPAINT_RAINBOW',
);

/// Which Darwin renderer this build should use.
VlcDarwinRenderer get playerDarwinRenderer => kPlayerDebugPlatformView
    ? VlcDarwinRenderer.platformView
    : VlcPlayerConfig.defaultDarwinRenderer;

/// Which Android renderer this build should use. Same flag, same meaning.
VlcAndroidRenderer get playerAndroidRenderer => kPlayerDebugPlatformView
    ? VlcAndroidRenderer.platformView
    : VlcPlayerConfig.defaultAndroidRenderer;

/// The colour under the whole player. Black in a normal build.
Color get playerScaffoldColor =>
    kPlayerDebugColors ? const Color(0xFFFF00FF) : Colors.black;

/// The colour the player widget paints behind the video. Black normally.
Color get playerBackdropColor =>
    kPlayerDebugColors ? const Color(0xFF00FF00) : Colors.black;
