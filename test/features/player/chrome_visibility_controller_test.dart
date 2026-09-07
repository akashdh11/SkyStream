import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/presentation/vlc/chrome_visibility_controller.dart';

/// Driven under the widget-test binding purely for its fake clock: the
/// controller is plain Dart with a Timer, and `tester.pump(duration)` is the
/// one clock this package already depends on. No widgets are built.
const Duration _hideAfter = Duration(seconds: 3);
const Duration _tick = Duration(milliseconds: 1);

void main() {
  late bool playing;
  late int notifications;

  /// Built inside each test body, not in setUp: the controller arms its first
  /// timer in its constructor, and the fake clock exists only inside the body.
  ChromeVisibilityController armed() {
    final chrome = ChromeVisibilityController(
      isPlaying: () => playing,
      hideAfter: _hideAfter,
    )..addListener(() => notifications++);
    addTearDown(chrome.dispose);
    return chrome;
  }

  setUp(() {
    playing = true;
    notifications = 0;
  });

  testWidgets('born visible and armed: hides once the delay runs out', (
    tester,
  ) async {
    final chrome = armed();
    expect(chrome.value, isTrue);
    await tester.pump(_hideAfter - _tick);
    expect(chrome.value, isTrue);
    await tester.pump(_tick);
    expect(chrome.value, isFalse);
    expect(notifications, 1);
  });

  testWidgets('never hides while paused, and hides once playback resumes', (
    tester,
  ) async {
    final chrome = armed();
    playing = false;
    await tester.pump(_hideAfter * 5);
    expect(chrome.value, isTrue, reason: 'paused viewers are looking');

    // The clock re-checks rather than hiding on a schedule, so resuming is
    // noticed within one more period.
    playing = true;
    await tester.pump(_hideAfter);
    expect(chrome.value, isFalse);
  });

  testWidgets('poke restarts the clock from now', (tester) async {
    final chrome = armed();
    await tester.pump(_hideAfter - _tick);
    chrome.poke();
    await tester.pump(_hideAfter - _tick);
    expect(chrome.value, isTrue, reason: 'the poke bought a full period');
    await tester.pump(_tick);
    expect(chrome.value, isFalse);
  });

  testWidgets('poke reveals hidden chrome and arms it', (tester) async {
    final chrome = armed();
    await tester.pump(_hideAfter);
    expect(chrome.value, isFalse);

    chrome.poke();
    expect(chrome.value, isTrue);
    await tester.pump(_hideAfter);
    expect(chrome.value, isFalse);
  });

  testWidgets('a hold pins the chrome; release re-arms it', (tester) async {
    final chrome = armed();
    chrome.poke(hold: true);
    await tester.pump(_hideAfter * 5);
    expect(chrome.value, isTrue, reason: 'held chrome does not hide');
    expect(chrome.isHeld, isTrue);

    chrome.release();
    expect(chrome.isHeld, isFalse);
    await tester.pump(_hideAfter - _tick);
    expect(chrome.value, isTrue, reason: 'release starts a fresh period');
    await tester.pump(_tick);
    expect(chrome.value, isFalse);
  });

  testWidgets('holds nest: the last release is the one that re-arms', (
    tester,
  ) async {
    final chrome = armed();
    chrome.poke(hold: true);
    chrome.poke(hold: true);
    chrome.release();
    await tester.pump(_hideAfter * 2);
    expect(chrome.value, isTrue, reason: 'one hold is still outstanding');

    chrome.release();
    await tester.pump(_hideAfter);
    expect(chrome.value, isFalse);
  });

  testWidgets('whileHeld holds for the life of the future', (tester) async {
    final chrome = armed();
    final sheet = chrome.whileHeld(() => Future<void>.delayed(_hideAfter * 3));

    await tester.pump(_hideAfter * 2);
    expect(chrome.value, isTrue, reason: 'the sheet is still open');

    await tester.pump(_hideAfter);
    await sheet;
    expect(chrome.isHeld, isFalse);
    await tester.pump(_hideAfter);
    expect(chrome.value, isFalse, reason: 'closing re-armed the clock');
  });

  testWidgets('toggle hides at once, even when paused, and reveals armed', (
    tester,
  ) async {
    final chrome = armed();
    playing = false;
    chrome.toggle();
    expect(
      chrome.value,
      isFalse,
      reason: 'an explicit tap is the viewer\'s choice',
    );

    chrome.toggle();
    expect(chrome.value, isTrue);
    playing = true;
    await tester.pump(_hideAfter);
    expect(chrome.value, isFalse);
  });

  testWidgets('toggle does not hide held chrome', (tester) async {
    final chrome = armed();
    chrome.poke(hold: true);
    chrome.toggle();
    expect(chrome.value, isTrue);
  });

  testWidgets('keepAlive restarts visible chrome but never reveals it', (
    tester,
  ) async {
    final chrome = armed();
    await tester.pump(_hideAfter - _tick);
    chrome.keepAlive();
    await tester.pump(_tick);
    expect(chrome.value, isTrue, reason: 'restarted');

    await tester.pump(_hideAfter);
    expect(chrome.value, isFalse);
    chrome.keepAlive();
    await tester.pump(_hideAfter);
    expect(chrome.value, isFalse, reason: 'a pointer-down must not re-show');
  });

  testWidgets('notifies exactly once per visibility change', (tester) async {
    final chrome = armed();
    chrome.poke();
    chrome.poke();
    chrome.keepAlive();
    expect(notifications, 0, reason: 'visible stayed visible');

    await tester.pump(_hideAfter);
    expect(notifications, 1);

    chrome.poke();
    chrome.poke();
    expect(notifications, 2);

    await tester.pump(_hideAfter);
    expect(notifications, 3);
  });
}
