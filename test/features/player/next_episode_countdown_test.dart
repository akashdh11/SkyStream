import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/presentation/vlc/next_episode_countdown.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

/// Hosts the card the way the player does: an overlay layer in a [Stack] over
/// a (here, absent) video surface.
Widget _host(Widget child) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [child]),
    ),
  );
}

/// Unmounts the tree so a still-running countdown ticker does not outlive the
/// test.
Future<void> _teardown(WidgetTester tester) =>
    tester.pumpWidget(const SizedBox.shrink());

String? get _focusLabel => FocusManager.instance.primaryFocus?.debugLabel;

void main() {
  group('NextEpisodeCountdown', () {
    testWidgets('advances on its own when the countdown runs out', (
      tester,
    ) async {
      var played = 0;
      var cancelled = 0;

      await tester.pumpWidget(
        _host(
          NextEpisodeCountdown(
            title: 'The Body',
            countdown: const Duration(seconds: 15),
            onPlayNext: () => played++,
            onCancel: () => cancelled++,
          ),
        ),
      );

      expect(find.text('15'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('10'), findsOneWidget);
      expect(played, 0);

      await tester.pump(const Duration(seconds: 10));
      expect(find.text('0'), findsOneWidget);
      // An AnimationController's simulation is done only *past* its duration,
      // so the advance lands on the frame after zero rather than on it.
      await tester.pump(const Duration(milliseconds: 16));
      expect(played, 1);
      expect(cancelled, 0);

      // The clock is stopped, not merely past its end: no second advance.
      await tester.pump(const Duration(seconds: 30));
      expect(played, 1);

      await _teardown(tester);
    });

    testWidgets('holds while playback is paused and resumes with it', (
      tester,
    ) async {
      var played = 0;

      Widget build({required bool paused}) => _host(
        NextEpisodeCountdown(
          title: 'The Body',
          countdown: const Duration(seconds: 15),
          paused: paused,
          onPlayNext: () => played++,
          onCancel: () {},
        ),
      );

      await tester.pumpWidget(build(paused: true));
      await tester.pump(const Duration(seconds: 30));
      expect(played, 0, reason: 'a paused episode must not auto-advance');
      expect(find.text('15'), findsOneWidget);

      await tester.pumpWidget(build(paused: false));
      await tester.pump(const Duration(seconds: 16));
      expect(played, 1);

      await _teardown(tester);
    });

    testWidgets('Play now advances immediately and only once', (tester) async {
      var played = 0;

      await tester.pumpWidget(
        _host(
          NextEpisodeCountdown(
            title: 'The Body',
            countdown: const Duration(seconds: 15),
            onPlayNext: () => played++,
            onCancel: () {},
          ),
        ),
      );

      await tester.tap(find.text('Play Now'));
      expect(played, 1);

      // Pressing it again, or letting the original deadline pass, must not
      // advance a second time and skip an episode.
      await tester.tap(find.text('Play Now'));
      await tester.pump(const Duration(seconds: 30));
      expect(played, 1);

      await _teardown(tester);
    });

    testWidgets('Cancel stops the countdown for good', (tester) async {
      var played = 0;
      var cancelled = 0;

      await tester.pumpWidget(
        _host(
          NextEpisodeCountdown(
            title: 'The Body',
            countdown: const Duration(seconds: 15),
            onPlayNext: () => played++,
            onCancel: () => cancelled++,
          ),
        ),
      );

      await tester.tap(find.text('Cancel'));
      expect(cancelled, 1);
      expect(played, 0);

      await tester.pump(const Duration(minutes: 1));
      expect(played, 0, reason: 'cancel must not leave a live deadline');
      expect(cancelled, 1);

      await _teardown(tester);
    });

    testWidgets('D-pad reaches both controls and activates them', (
      tester,
    ) async {
      var played = 0;
      var cancelled = 0;

      await tester.pumpWidget(
        _host(
          NextEpisodeCountdown(
            title: 'The Body',
            countdown: const Duration(seconds: 15),
            isTv: true,
            onPlayNext: () => played++,
            onCancel: () => cancelled++,
          ),
        ),
      );
      await tester.pump();

      expect(
        _focusLabel,
        kPlayNextFocusLabel,
        reason: 'the remote should land on the action the timeout will take',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(_focusLabel, kCancelFocusLabel);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(_focusLabel, kPlayNextFocusLabel);

      // Select on the focused control, not a tap.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(cancelled, 1);
      expect(played, 0);

      await _teardown(tester);
    });

    testWidgets('Back while focused inside the card cancels', (tester) async {
      var played = 0;
      var cancelled = 0;

      await tester.pumpWidget(
        _host(
          NextEpisodeCountdown(
            title: 'The Body',
            countdown: const Duration(seconds: 15),
            isTv: true,
            onPlayNext: () => played++,
            onCancel: () => cancelled++,
          ),
        ),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(cancelled, 1);
      expect(played, 0);

      await _teardown(tester);
    });

    testWidgets('renders the metadata it is given and skips what it is not', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          NextEpisodeCountdown(
            title: 'The Body',
            season: 2,
            episode: 5,
            rating: 8.14,
            runtime: const Duration(minutes: 42),
            description: 'Buffy comes home to find her mother on the couch.',
            countdown: const Duration(seconds: 15),
            onPlayNext: () {},
            onCancel: () {},
          ),
        ),
      );

      expect(find.text('The Body'), findsOneWidget);
      expect(find.textContaining('S2 E5'), findsOneWidget);
      expect(find.textContaining('42m'), findsOneWidget);
      expect(find.textContaining('8.1'), findsOneWidget);
      expect(find.textContaining('on the couch'), findsOneWidget);

      await _teardown(tester);
    });

    testWidgets('omits the whole metadata line when nothing is known', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          NextEpisodeCountdown(
            title: 'The Body',
            // A sub-minute runtime is metadata noise, not a runtime.
            runtime: const Duration(seconds: 12),
            rating: 0,
            countdown: const Duration(seconds: 15),
            onPlayNext: () {},
            onCancel: () {},
          ),
        ),
      );

      expect(find.textContaining('·'), findsNothing);
      expect(find.textContaining('★'), findsNothing);

      await _teardown(tester);
    });
  });
}
