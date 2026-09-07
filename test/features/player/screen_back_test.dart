import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/services/download_service.dart';
import 'package:skystream/features/player/presentation/vlc/next_episode_countdown.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_panel.dart'
    show PlayerPanel;
import 'package:skystream/features/player/presentation/vlc/vlc_player_controls.dart';
import 'package:skystream/features/player/presentation/vlc/vlc_player_screen.dart';
import 'package:skystream/features/player/presentation/widgets/player_control_components.dart'
    show PlayerActionButton, PlayerBottomBar;
import 'package:skystream/l10n/generated/app_localizations.dart';

import 'vlc_screen_harness.dart';

/// What Back means on a television.
///
/// The bars up and the video playing, Back means "put the bars away": that is
/// the convention every TV player follows, the old player kept it
/// (38da335:player_screen.dart:587-597), and a viewer who has learned it
/// presses Back to clear the picture and expects the picture to still be
/// there. Only Back over bare video leaves.
///
/// Pausing makes no difference. A viewer who paused to read the seek bar is
/// still watching, and the pause exception this file used to pin - Back over
/// a paused picture leaving at once - meant the most ordinary press on a
/// television threw the session away. It is gone: the rule has one clause.
///
/// Some televisions deliver one press twice, as a key event and as a
/// `popRoute` in the same frame. The second delivery must not be the second
/// press.
void main() {
  setUp(installEngineMocks);
  tearDown(removeEngineMocks);

  /// Tells the screen the activity has entered or left picture-in-picture,
  /// over the same channel `MainActivity.onPictureInPictureModeChanged` uses.
  /// The screen registers the handler itself, in initState.
  Future<void> setPipMode(WidgetTester tester, bool inPip) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      pipChannel.name,
      pipChannel.codec.encodeMethodCall(MethodCall('pipModeChanged', inPip)),
      (_) {},
    );
    await tester.pump();
  }

  /// Read off the fades' targets, so it does not wait on the animation.
  Iterable<AnimatedOpacity> fades(WidgetTester tester) =>
      tester.widgetList<AnimatedOpacity>(
        find.descendant(
          of: find.byType(VlcPlayerControls),
          matching: find.byType(AnimatedOpacity),
        ),
      );

  void expectBarsShown(WidgetTester tester) {
    final targets = fades(tester);
    expect(targets, isNotEmpty);
    expect(targets.map((f) => f.opacity), everyElement(1.0));
  }

  void expectBarsHidden(WidgetTester tester, {required String reason}) {
    final targets = fades(tester);
    expect(targets, isNotEmpty);
    expect(targets.map((f) => f.opacity), everyElement(0.0), reason: reason);
  }

  group('Back on a television', () {
    testWidgets(
      'with the bars down, a Back key then popRoute leaves the player',
      variant: texturePlatform,
      (tester) async {
        // The sequence a real remote produces. The harness's sendBack only
        // ever sent the popRoute half, which is why the key half raising the
        // bars - and the pop then being swallowed as "hide the bars" - went
        // unseen.
        await pumpPlayer(tester, pushed: true);
        await sendFirstFrame(tester);
        await tester.pump(const Duration(seconds: 4));
        expectBarsHidden(tester, reason: 'the hide timer has run out');

        await tester.sendKeyEvent(
          LogicalKeyboardKey.goBack,
          // flutter_test has no physical key on file for Go Back, and no
          // Windows key code for it either; Android's table has both. The
          // controls only ever read the logical key.
          platform: 'android',
          physicalKey: PhysicalKeyboardKey.escape,
        );
        await tester.pump();
        expectBarsHidden(
          tester,
          reason: 'the key half of Back must not raise the bars',
        );

        await sendBack(tester);
        await tester.pump(const Duration(seconds: 1));
        expect(
          find.byType(VlcPlayerScreen),
          findsNothing,
          reason: 'bars were down, so Back means leave',
        );
      },
    );

    testWidgets(
      'with the bars up puts them away instead of leaving',
      variant: texturePlatform,
      (tester) async {
        await pumpPlayer(tester, pushed: true);
        await sendFirstFrame(tester);
        expectBarsShown(tester);

        await sendBack(tester);

        expect(
          find.byType(VlcPlayerScreen),
          findsOneWidget,
          reason: 'the viewer meant to clear the bars, not lose playback',
        );
        expectBarsHidden(tester, reason: 'the press was spent on the bars');

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'a second press over bare video leaves',
      variant: texturePlatform,
      (tester) async {
        await pumpPlayer(tester, pushed: true);
        await sendFirstFrame(tester);

        await sendBack(tester);
        // Past the window in which a second delivery is taken for an echo.
        await tester.pump(const Duration(milliseconds: 400));
        await sendBack(tester);
        // The pop transition.
        await tester.pump(const Duration(seconds: 1));

        expect(find.byType(VlcPlayerScreen), findsNothing);
      },
    );

    testWidgets(
      'one press delivered twice is still one press',
      variant: texturePlatform,
      (tester) async {
        await pumpPlayer(tester, pushed: true);
        await sendFirstFrame(tester);

        await sendBack(tester);
        await sendBack(tester);
        await tester.pump(const Duration(seconds: 1));

        expect(
          find.byType(VlcPlayerScreen),
          findsOneWidget,
          reason: 'a key event and a popRoute for one press must not pop',
        );
        expectBarsHidden(tester, reason: 'the first delivery did its work');

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'over a paused picture the first Back hides the bars, the second leaves',
      variant: texturePlatform,
      (tester) async {
        // Pausing to study the seek bar is what a viewer does immediately
        // before pressing Back, so a pause exception here would spend that
        // press on the whole session. The chrome controller obliges: its
        // clock will not auto-hide over a still picture, but toggle() - the
        // viewer asking - hides while paused all the same.
        await pumpPlayer(tester, pushed: true);
        await sendFirstFrame(tester);
        await sendEvent(tester, snapshot(state: 'paused'));
        expectBarsShown(tester);

        await sendBack(tester);
        await tester.pump(const Duration(seconds: 1));

        expect(
          find.byType(VlcPlayerScreen),
          findsOneWidget,
          reason:
              'a paused viewer is still watching; the bars go, not the '
              'session',
        );
        expectBarsHidden(
          tester,
          reason: 'the press was spent on the bars, paused or not',
        );

        await sendBack(tester);
        await tester.pump(const Duration(seconds: 1));

        expect(
          find.byType(VlcPlayerScreen),
          findsNothing,
          reason: 'the bars are down now, so the next press means leave',
        );
      },
    );

    testWidgets(
      'one press delivered twice over a paused picture is still one press',
      variant: texturePlatform,
      (tester) async {
        // The echo swallow shares the paused path, so it has to be proved on
        // it: before this rule changed, the second delivery could not reach
        // the pop because the first never claimed the press.
        await pumpPlayer(tester, pushed: true);
        await sendFirstFrame(tester);
        await sendEvent(tester, snapshot(state: 'paused'));
        expectBarsShown(tester);

        await sendBack(tester);
        await sendBack(tester);
        await tester.pump(const Duration(seconds: 1));

        expect(
          find.byType(VlcPlayerScreen),
          findsOneWidget,
          reason: 'a key event and a popRoute for one press must not pop',
        );
        expectBarsHidden(tester, reason: 'the first delivery did its work');

        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  group('Back over the panel on a television', () {
    /// Opens the panel from the bottom bar's Subtitles button, the way a
    /// remote does, and waits out the slide-in.
    Future<void> openPanel(WidgetTester tester) async {
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      await tester.tap(find.byTooltip(l10n.subtitles));
      await settle(tester);
      expect(find.byType(PlayerPanel), findsOneWidget);
    }

    testWidgets(
      'Subtitles opens the panel; Back closes the panel and not the player',
      variant: texturePlatform,
      (tester) async {
        // The panel is a route on top of the player, so the Navigator pops
        // it and the player is never consulted: one press, one thing closed.
        await pumpPlayer(tester, pushed: true);
        await sendFirstFrame(tester);
        await openPanel(tester);

        await sendBack(tester);
        await settle(tester);

        expect(find.byType(PlayerPanel), findsNothing);
        expect(
          find.byType(VlcPlayerScreen),
          findsOneWidget,
          reason: 'the press was spent on the panel',
        );
        expectBarsShown(tester);

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      "a second Back during the panel's exit transition hides the bars",
      variant: texturePlatform,
      (tester) async {
        // Mid-slide the panel's element is still mounted but its route is no
        // longer current, its hold on the chrome has been released and the
        // screen has forgotten its context. So the second press reaches the
        // player, finds the bars up and puts them away - it does not pop the
        // player out from under the closing panel.
        await pumpPlayer(tester, pushed: true);
        await sendFirstFrame(tester);
        await openPanel(tester);

        await sendBack(tester);
        await sendBack(tester);
        await settle(tester);

        expect(find.byType(PlayerPanel), findsNothing);
        expect(
          find.byType(VlcPlayerScreen),
          findsOneWidget,
          reason: 'the second press must not leave playback',
        );
        expectBarsHidden(tester, reason: 'the second press hid the bars');

        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  /// Back on a locked screen, which is the half of the lock that lives here
  /// rather than in the controls.
  ///
  /// The flag is the *screen's* for exactly this reason. 38da335's lock kept
  /// its `_isLocked` in a widget State that the screen's Back handling could
  /// not see, so an edge swipe left the player while locked - on an Android
  /// phone, the one device the lock existed for. And the answer is two
  /// presses rather than a permanent swallow, because on Android the Back
  /// gesture is *the* way out of a screen: a player that ignored it forever
  /// would read as hung, with the only escape a chip the viewer has already
  /// failed to find.
  group('Back on a locked phone', () {
    /// Locks through the padlock, the way a viewer does.
    ///
    /// `settle` rather than one pump: the bars are wrapped in the controls'
    /// gesture absorber, whose double-tap recogniser holds the arena open for
    /// its timeout, so a button press lands ~300 ms after the finger leaves.
    Future<void> lock(WidgetTester tester) async {
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      expect(
        find.byTooltip(l10n.lock),
        findsOneWidget,
        reason: 'the padlock is phone and tablet only, and this is a phone',
      );
      await tester.tap(find.byTooltip(l10n.lock));
      await settle(tester);
      expect(find.byType(PlayerBottomBar), findsNothing);
    }

    Future<Finder> chip() async {
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      return find.widgetWithText(PlayerActionButton, l10n.unlock);
    }

    testWidgets(
      'the first Back reveals the chip and does not pop; the second leaves',
      variant: texturePlatform,
      (tester) async {
        await pumpPlayer(tester, pushed: true, isTv: false);
        await sendFirstFrame(tester);
        await lock(tester);

        // Long enough for the chrome's own three-second clock to have taken
        // the chip away, so the poke below is doing real work rather than
        // looking at a chip that never left.
        await tester.pump(const Duration(seconds: 4));
        expect(
          tester.widget<AnimatedOpacity>(
            find.ancestor(
              of: await chip(),
              matching: find.byType(AnimatedOpacity),
            ),
          ).opacity,
          0.0,
          reason: 'the chip rides the same clock the bars do',
        );

        await sendBack(tester);
        await tester.pump(const Duration(milliseconds: 500));

        expect(
          find.byType(VlcPlayerScreen),
          findsOneWidget,
          reason: 'a locked player does not leave on one press',
        );
        expect(
          tester.widget<AnimatedOpacity>(
            find.ancestor(
              of: await chip(),
              matching: find.byType(AnimatedOpacity),
            ),
          ).opacity,
          1.0,
          reason:
              'poke(), not keepAlive(): the press has to summon the chip, not '
              'merely keep an already-visible one alive',
        );

        // Inside the two-second window and past the 300 ms same-press echo.
        await sendBack(tester);
        await tester.pump(const Duration(seconds: 1));

        expect(
          find.byType(VlcPlayerScreen),
          findsNothing,
          reason: 'a deliberate second press unlocks and leaves',
        );
      },
    );

    testWidgets(
      'one press delivered twice is still the first press',
      variant: texturePlatform,
      (tester) async {
        // The escape window is two seconds and some devices deliver one press
        // as a key event and a popRoute in the same frame. Without the
        // 300 ms echo guard the second delivery would read as the deliberate
        // second press and take the viewer straight out of a screen they had
        // just locked.
        await pumpPlayer(tester, pushed: true, isTv: false);
        await sendFirstFrame(tester);
        await lock(tester);

        await sendBack(tester);
        await sendBack(tester);
        await tester.pump(const Duration(seconds: 1));

        expect(
          find.byType(VlcPlayerScreen),
          findsOneWidget,
          reason: 'the echo is the same press, not a confirmation',
        );
        expect(await chip(), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'a lone press does not arm an escape that outlives it',
      variant: texturePlatform,
      (tester) async {
        // The lock is a lock, not a two-press countdown left running. A press
        // now and another one a minute later are two first presses.
        await pumpPlayer(tester, pushed: true, isTv: false);
        await sendFirstFrame(tester);
        await lock(tester);

        await sendBack(tester);
        await tester.pump(const Duration(seconds: 3));
        await sendBack(tester);
        await tester.pump(const Duration(seconds: 1));

        expect(
          find.byType(VlcPlayerScreen),
          findsOneWidget,
          reason: 'the window had closed, so this was a first press again',
        );
        expect(await chip(), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'the lock clears on an episode advance',
      variant: texturePlatform,
      (tester) async {
        // The lock belongs to the picture that was on screen when it was set.
        // Every path that takes that picture away goes through
        // `_setSawFrames(false)` - a failover, a live reconnect, Start Over
        // and, as here, an advance - so that is the one place that clears it.
        // Left standing, a lock set on the last episode would greet the next
        // one with a chip over media nobody locked, set by a padlock inside
        // controls that have just been unmounted.
        //
        // Driven by the up-next countdown running out rather than by pressing
        // anything, so the assertion is about the advance itself and not about
        // which controls happen to be reachable while locked.
        final first = Episode(
          name: 'Ep 01',
          url: 'https://example.com/e1.mp4',
          season: 1,
          episode: 1,
        );
        final show = MultimediaItem(
          title: 'Show',
          url: 'https://example.com/show',
          posterUrl: '',
          contentType: MultimediaContentType.series,
          episodes: [
            first,
            Episode(
              name: 'Ep 02',
              url: 'https://example.com/e2.mp4',
              season: 1,
              episode: 2,
            ),
          ],
          provider: 'Remote',
        );
        await pumpPlayer(
          tester,
          item: show,
          episode: first,
          videoUrl: first.url,
          pushed: true,
          isTv: false,
          overrides: [
            // Held shut, so the advance parks on the disk lookup - which is
            // the first await *after* the flag this test is about is cleared.
            downloadServiceProvider.overrideWith(GatedDownloads.new),
          ],
        );
        await sendFirstFrame(tester);
        await lock(tester);

        // Inside the fifteen-second lead-in, so the up-next card comes up.
        await sendEvent(tester, snapshot(position: 100000, duration: 120000));
        await sendEvent(tester, snapshot(position: 110000, duration: 120000));
        expect(find.byType(NextEpisodeCountdown), findsOneWidget);

        // The countdown runs out and advances on its own.
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(seconds: 1));
        }
        expect(
          find.byType(VlcPlayerControls),
          findsNothing,
          reason: 'the outgoing picture is down while the next one opens',
        );

        await sendBack(tester);
        await tester.pump(const Duration(seconds: 1));
        expect(
          find.byType(VlcPlayerScreen),
          findsNothing,
          reason:
              'one press leaves: the lock went with the episode that set it',
        );
      },
    );

    testWidgets(
      'the lock clears when the media ends',
      variant: texturePlatform,
      (tester) async {
        // The ended card unmounts the entire controls subtree, and the unlock
        // chip goes with it. A lock left standing there is a lock with nothing
        // on screen to undo it - the trap the two-press escape would then be
        // the only way out of.
        await pumpPlayer(tester, pushed: true, isTv: false);
        await sendFirstFrame(tester);
        await lock(tester);

        await sendEvent(tester, snapshot(state: 'ended'));
        await settle(tester);
        expect(
          find.byType(VlcPlayerControls),
          findsNothing,
          reason: 'the card replaces the controls rather than covering them',
        );

        await sendBack(tester);
        await tester.pump(const Duration(seconds: 1));
        expect(
          find.byType(VlcPlayerScreen),
          findsNothing,
          reason: 'one press leaves; nothing is left to swallow it',
        );
      },
    );

    testWidgets(
      'the lock clears on picture-in-picture',
      variant: texturePlatform,
      (tester) async {
        // A locked PiP window is unrecoverable: the controls are not built in
        // PiP at all, so there is no chip in it and no gesture that would
        // reach one. Proved through Back rather than through a flag, because
        // Back is the only thing that can tell the two states apart from
        // outside.
        await pumpPlayer(tester, pushed: true, isTv: false);
        await sendFirstFrame(tester);
        await lock(tester);

        await setPipMode(tester, true);
        await setPipMode(tester, false);
        await settle(tester);

        expect(await chip(), findsNothing);
        expect(
          find.byType(PlayerBottomBar),
          findsOneWidget,
          reason: 'the bars are back, so the player is not locked',
        );

        await sendBack(tester);
        await tester.pump(const Duration(seconds: 1));
        expect(
          find.byType(VlcPlayerScreen),
          findsNothing,
          reason: 'one press leaves, because nothing swallowed it',
        );
      },
    );
  });

  testWidgets(
    'on a phone Back leaves with the bars up',
    variant: texturePlatform,
    (tester) async {
      // A phone has a tap to dismiss the bars with; Back there has always
      // meant leave, and a swipe that only cleared the chrome would read as
      // the gesture failing.
      await pumpPlayer(tester, pushed: true, isTv: false);
      await sendFirstFrame(tester);
      expectBarsShown(tester);

      await sendBack(tester);
      await tester.pump(const Duration(seconds: 1));

      expect(find.byType(VlcPlayerScreen), findsNothing);
    },
  );
}
