import 'package:flutter/services.dart';

/// The keys that mean "press the player control that currently has focus".
///
/// This exists because a D-pad "OK" is not one key. A television remote sends
/// [LogicalKeyboardKey.select]; a keyboard sends [LogicalKeyboardKey.enter] or
/// [LogicalKeyboardKey.space]; and a game controller — a Shield remote, an
/// Xbox or PlayStation pad, and every Android TV device whose HID layer
/// reports DPAD_CENTER as BUTTON_A — sends [LogicalKeyboardKey.gameButtonA].
/// All four have to activate, which is already the rule every control in
/// `presentation/vlc/panel/` follows; the overlays outside the panel took only
/// the first three, so on a controller Skip Intro, Play now, Cancel and Start
/// Over did nothing while the whole bottom bar worked — a failure that reads
/// as random rather than systematic.
///
/// Nothing rescues a miss further up the tree. WidgetsApp does bind
/// gameButtonA to an ActivateIntent, but its default actions map ships no
/// ActivateAction to answer it, and in these widgets the `Focus` sits *above*
/// the `InkWell`, so the InkWell's own `Actions` map is a descendant of the
/// focused node and `Actions.invoke` never walks down to find it. (The
/// bottom-bar icon buttons work only because they render a Material
/// `TextButton`, whose `Actions` really is an ancestor of its focus node.)
///
/// Four explicit keys in one predicate rather than an `Actions` wrapper is
/// this codebase's stated idiom: a control is one focus stop with one key
/// test, and directional movement is left entirely to native traversal.
bool isPlayerActivation(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.select ||
    key == LogicalKeyboardKey.enter ||
    key == LogicalKeyboardKey.space ||
    key == LogicalKeyboardKey.gameButtonA;
