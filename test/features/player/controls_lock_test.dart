/// The screen lock, phone and tablet only.
///
/// On a phone there is nothing between the player and a pocket, a lap, a child
/// or a handset propped on a chest. Every one of those fires a real gesture:
/// the chrome toggle, a ±10 s double-tap seek, a free horizontal scrub, a
/// vertical brightness or volume change, or a jump to 2x. The scrub and the
/// long-press are both destructive and near-silent - the viewer looks back and
/// the film is somewhere else, with nothing on screen to say why.
///
/// So the contract this file holds has two halves and both are load-bearing:
///
///  * **Locked, nothing the player owns answers a finger.** Not one of the
///    five gestures, not the centre play/pause, not the skip chip - and the
///    unlock chip itself is dead while it is faded out, or the very first
///    accidental contact would undo the lock.
///  * **The lock does not exist off touch.** Not hidden, not disabled:
///    `VlcPlayerControls.locked` is null on a television and on a desktop, so
///    there is no padlock to render and no locked branch to reach. A remote
///    has no accidental surface, and the only key a TV lock could eat - Back -
///    is already the load-bearing "hide the bars".
///
/// Every other controls suite forces `isTv: true`, which is exactly the build
/// the lock is absent from, so this file hosts its own phone profile.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/providers/device_info_provider.dart';
import 'package:skystream/features/player/presentation/vlc/player_rail.dart';
import 'package:skystream/features/player/presentation/vlc/vlc_player_controls.dart';
import 'package:skystream/features/player/presentation/widgets/player_control_components.dart'
    show
        PlayerActionButton,
        PlayerBottomBar,
        PlayerCenterPlayButton,
        PlayerTopBar;
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';
import 'package:skystream/features/skip/data/skip_service.dart'
    show SkipSegment, SkipType;
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:vlc_player/vlc_player.dart';

import 'fake_vlc_engine.dart';

/// A phone held sideways, which is what the player actually runs at on touch.
const Size _phone = Size(844, 390);
const Duration _hideAfter = Duration(seconds: 3);
const EventChannel _events = EventChannel('vlc_player/events/1');

/// One native snapshot, as the engine would send it.
///
/// Position 0 by default on purpose: the controller only arms its 1 s stall
/// watchdog once the clock has moved, and a test ending in healthy playback
/// with that timer pending fails flutter_test's pending-timer check.
Future<void> _snapshot(
  WidgetTester tester, {
  String state = 'playing',
  int position = 0,
  int duration = 30000,
}) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        _events.name,
        _events.codec.encodeSuccessEnvelope(<String, Object?>{
          'state': state,
          'position': position,
          'duration': duration,
          'volume': 100,
          'playbackSpeed': 1.0,
          'isReady': true,
          'isSeekable': true,
          'isLive': false,
        }),
        null,
      );
  await tester.pump();
}

Widget _host(Widget child, {required bool isTv, required bool isDesktopOS}) {
  return ProviderScope(
    overrides: [
      deviceProfileProvider.overrideWithValue(
        AsyncValue.data(DeviceProfile(isTv: isTv, isDesktopOS: isDesktopOS)),
      ),
      playerSettingsProvider.overrideWithBuild(
        (_, _) => const PlayerSettings(),
      ),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(fit: StackFit.expand, children: [child]),
      ),
    ),
  );
}

/// [desktop] sets both halves of what a desktop is, because the two are set
/// separately in production and only ever agree there: the device profile's
/// `isDesktopOS`, which is what the lock reads, and `onToggleFullscreen`,
/// which is what the rest of the file calls desktop. [locked] null stands for
/// "the screen offers no lock", which is what a television and a desktop are
/// handed.
Future<VlcPlayerController> _pump(
  WidgetTester tester, {
  bool isTv = false,
  bool desktop = false,
  ValueNotifier<bool>? locked,
  FakeVlcEngine? engine,
  List<SkipSegment> skipSegments = const <SkipSegment>[],
}) async {
  tester.view.physicalSize = _phone;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final fake = engine ?? FakeVlcEngine();
  fake.install();
  // Tear-downs run last-in first-out: the controller goes first, while the
  // channel it sends `dispose` on still has a handler.
  addTearDown(fake.dispose);
  final controller = await fake.attach();
  addTearDown(controller.dispose);

  await tester.pumpWidget(
    _host(
      VlcPlayerControls(
        controller: controller,
        title: 'The Body',
        subtitle: 'S5 E16',
        onBack: () {},
        onNextEpisode: () {},
        onToggleFullscreen: desktop ? () {} : null,
        skipSegments: skipSegments,
        locked: locked,
      ),
      isTv: isTv,
      isDesktopOS: desktop,
    ),
  );
  await tester.pump();
  // The hide clock refuses to fire until the engine reports playing.
  await _snapshot(tester);
  return controller;
}

Future<AppLocalizations> _english() =>
    AppLocalizations.delegate.load(const Locale('en'));

/// The padlock in the bottom bar's left group, resolved by its tooltip - which
/// is also its semantics label.
Finder _padlock(AppLocalizations l10n) => find.byTooltip(l10n.lock);

/// The unlock chip. Resolved by its label rather than by its icon so it cannot
/// be confused with the padlock, which is a different widget entirely.
Finder _chip(AppLocalizations l10n) =>
    find.widgetWithText(PlayerActionButton, l10n.unlock);

/// Runs the chrome clock out and lets the frame that hides it settle.
Future<void> _letHide(WidgetTester tester) async {
  await tester.pump(_hideAfter);
  await tester.pump();
}

/// Every seekTo the engine received, as the millisecond it was asked for.
List<int> _seeks(FakeVlcEngine engine) => engine
    .callsTo('seekTo')
    .map((call) => (call.arguments as Map)['position'] as int)
    .toList(growable: false);

/// A tap that resolves through the screen-wide detector's double-tap
/// recogniser rather than in front of it.
Future<void> _tapAt(WidgetTester tester, Offset at) async {
  await tester.tapAt(at);
  await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
}

/// Presses a control and waits for the press to actually resolve.
///
/// A plain `pump()` is not enough anywhere in this tree. The bars are wrapped
/// in the controls' own gesture absorber, which registers a double-tap and a
/// long-press of its own, and a double-tap recogniser holds the arena open
/// until its timeout - so a button's tap is delivered ~300 ms after the finger
/// leaves, not on the frame after it.
Future<void> _press(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
}

/// Two taps close enough together to be one double-tap.
Future<void> _doubleTapAt(WidgetTester tester, Offset at) async {
  await tester.tapAt(at);
  await tester.pump(kDoubleTapMinTime);
  await tester.tapAt(at);
  await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
}

/// A band under the current position, so the skip chip is on screen.
List<SkipSegment> _segmentHere() => <SkipSegment>[
  SkipSegment(startTime: 0, endTime: 20, type: SkipType.intro),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the lock is absent off touch, by construction', () {
    testWidgets('a phone with a lock offered has a padlock', (tester) async {
      final locked = ValueNotifier(false);
      addTearDown(locked.dispose);
      await _pump(tester, locked: locked);

      expect(_padlock(await _english()), findsOneWidget);

      await _snapshot(tester, state: 'paused');
    });

    testWidgets('a television has none, even handed the notifier', (
      tester,
    ) async {
      // Two independent gates, and this exercises the second: the screen
      // passes null off `PlayerFormFactor.isTouch`, and the controls refuse
      // on top of that. A caller that got it wrong still gets nothing.
      final locked = ValueNotifier(false);
      addTearDown(locked.dispose);
      await _pump(tester, isTv: true, locked: locked);

      expect(
        _padlock(await _english()),
        findsNothing,
        reason: 'a remote has no accidental surface to lock against',
      );

      await _snapshot(tester, state: 'paused');
    });

    testWidgets('nor does a desktop, where the pointer is precise', (
      tester,
    ) async {
      // Read off the device profile rather than off `onToggleFullscreen`, and
      // this test is why: dart:io reports the *host*, so a screen-level test
      // on a Mac looks like a desktop whatever profile it overrode - which
      // would have made the lock unreachable in every screen test there is.
      // Both halves are set here, because in production they always agree.
      final locked = ValueNotifier(false);
      addTearDown(locked.dispose);
      await _pump(tester, desktop: true, locked: locked);

      expect(_padlock(await _english()), findsNothing);

      await _snapshot(tester, state: 'paused');
    });

    testWidgets('and a touch build offered no lock has no padlock either', (
      tester,
    ) async {
      // The other half of "by construction": with `locked` null there is
      // nothing to render from at all, which is the state every screen test
      // that predates this feature runs in.
      await _pump(tester);

      expect(_padlock(await _english()), findsNothing);

      await _snapshot(tester, state: 'paused');
    });
  });

  group('locked', () {
    /// Locks through the padlock, the way a viewer does, and returns the
    /// notifier so a test can read the answer back.
    Future<void> lock(WidgetTester tester) async {
      await _press(tester, _padlock(await _english()));
    }

    testWidgets('locking swallows every screen-wide gesture', (tester) async {
      // THE LOAD-BEARING TEST. All five gestures the player owns are
      // registered on one screen-wide GestureDetector, and locking rebuilds
      // that detector with a bare onTap. Each is checked against what reached
      // the engine, not against what is on screen: a guard that merely hid
      // the readout would leave the seek.
      final engine = FakeVlcEngine();
      final locked = ValueNotifier(false);
      addTearDown(locked.dispose);
      await _pump(tester, locked: locked, engine: engine);
      await _snapshot(tester, position: 5000);
      await lock(tester);
      expect(locked.value, isTrue);

      final rect = tester.getRect(find.byType(VlcPlayerControls));
      final centre = rect.center;
      final right = Offset(rect.left + rect.width * 0.8, rect.center.dy);

      // 1. The chrome toggle. The bars are not built at all while locked, so
      //    this asks the stronger question: nothing put them back.
      await _tapAt(tester, centre);
      expect(find.byType(PlayerTopBar), findsNothing);
      expect(find.byType(PlayerBottomBar), findsNothing);

      // 2. The double-tap seek.
      await _doubleTapAt(tester, right);
      expect(
        _seeks(engine),
        isEmpty,
        reason: 'a pocket must not move the film ten seconds',
      );

      // 3. The horizontal scrub - the most destructive of the five, because
      //    it is a free seek to anywhere in the file.
      await tester.dragFrom(centre, const Offset(300, 0));
      await tester.pump(const Duration(milliseconds: 50));
      expect(_seeks(engine), isEmpty, reason: 'nor a free scrub');

      // 4. The vertical rail. On the right half that is volume, which reaches
      //    the engine, so both the readout and the effect are checkable.
      await tester.dragFrom(right, const Offset(0, -100));
      await tester.pump(const Duration(milliseconds: 50));
      expect(engine.callsTo('setVolume'), isEmpty);
      expect(find.byType(PlayerRail), findsNothing);

      // 5. The long-press speed boost.
      await tester.longPressAt(centre);
      await tester.pump(const Duration(milliseconds: 50));
      expect(engine.callsTo('setPlaybackSpeed'), isEmpty);

      // And the centre play/pause, which is outside the bars and would
      // otherwise still be up and hit-testable whenever a poke revealed the
      // chrome.
      expect(find.byType(PlayerCenterPlayButton), findsNothing);
      expect(engine.callsTo('pause'), isEmpty);

      expect(locked.value, isTrue, reason: 'none of that unlocked anything');
      await _snapshot(tester, state: 'paused', position: 5000);
    });

    testWidgets('and every one of them fires when it is not locked', (
      tester,
    ) async {
      // The control for the test above. Without it a typo in any of those
      // five gesture drivers would read as a green lock, which is the one
      // way this whole file could lie.
      final engine = FakeVlcEngine();
      final locked = ValueNotifier(false);
      addTearDown(locked.dispose);
      await _pump(tester, locked: locked, engine: engine);
      await _snapshot(tester, position: 5000);

      final rect = tester.getRect(find.byType(VlcPlayerControls));
      final centre = rect.center;
      final right = Offset(rect.left + rect.width * 0.8, rect.center.dy);

      await _doubleTapAt(tester, right);
      expect(_seeks(engine), isNotEmpty, reason: 'the double-tap seek works');

      await tester.dragFrom(centre, const Offset(300, 0));
      await tester.pump(const Duration(milliseconds: 50));
      expect(_seeks(engine), hasLength(greaterThan(1)));

      await tester.dragFrom(right, const Offset(0, -100));
      await tester.pump(const Duration(milliseconds: 50));
      expect(engine.callsTo('setVolume'), isNotEmpty);

      await tester.longPressAt(centre);
      await tester.pump(const Duration(milliseconds: 50));
      expect(engine.callsTo('setPlaybackSpeed'), isNotEmpty);

      expect(find.byType(PlayerCenterPlayButton), findsOneWidget);
      await _snapshot(tester, state: 'paused', position: 5000);
    });

    testWidgets('a tap while locked shows only the unlock chip', (
      tester,
    ) async {
      // A segment under the position, so the skip chip would be on screen -
      // it lives outside the chrome gate precisely so hiding the bars does
      // not take it away, which makes it the one control the lock has to
      // withdraw by name.
      final locked = ValueNotifier(false);
      addTearDown(locked.dispose);
      await _pump(tester, locked: locked, skipSegments: _segmentHere());
      final l10n = await _english();
      await _snapshot(tester, position: 5000);
      expect(
        find.widgetWithText(PlayerActionButton, l10n.skipIntro),
        findsOneWidget,
        reason: 'otherwise the assertion below proves nothing',
      );

      await lock(tester);
      await _letHide(tester);
      await _tapAt(tester, tester.getCenter(find.byType(VlcPlayerControls)));

      expect(_chip(l10n), findsOneWidget);
      expect(find.byType(PlayerTopBar), findsNothing);
      expect(find.byType(PlayerBottomBar), findsNothing);
      expect(
        find.widgetWithText(PlayerActionButton, l10n.skipIntro),
        findsNothing,
        reason: 'the skip chip is outside the chrome and would have survived',
      );

      await _snapshot(tester, state: 'paused', position: 5000);
    });

    testWidgets('the chip rides the chrome clock', (tester) async {
      // No second timer and no second opacity controller: the chip goes
      // through the same `_fading` the bars do, so it appears on a touch and
      // leaves on the same three seconds. Read off the fade's target rather
      // than waited for, so this does not depend on the animation.
      final locked = ValueNotifier(false);
      addTearDown(locked.dispose);
      await _pump(tester, locked: locked);
      final l10n = await _english();
      await lock(tester);

      double opacity() => tester
          .widget<AnimatedOpacity>(
            find.ancestor(
              of: _chip(l10n),
              matching: find.byType(AnimatedOpacity),
            ),
          )
          .opacity;

      expect(opacity(), 1.0, reason: 'the press that locked also poked');

      await _letHide(tester);
      expect(opacity(), 0.0);
      expect(locked.value, isTrue, reason: 'faded out is not unlocked');

      await _tapAt(tester, tester.getCenter(find.byType(VlcPlayerControls)));
      expect(opacity(), 1.0, reason: 'a touch brings the one control back');

      await _snapshot(tester, state: 'paused');
    });

    testWidgets('a faded-out chip does not answer a touch', (tester) async {
      // `AnimatedOpacity` at zero paints nothing and still hit-tests. Without
      // an IgnorePointer of its own the chip would be an invisible target at
      // the bottom of a locked screen, and the first accidental contact would
      // land on it - which is the one failure that would make the whole
      // feature worthless.
      final locked = ValueNotifier(false);
      addTearDown(locked.dispose);
      await _pump(tester, locked: locked);
      final l10n = await _english();
      await lock(tester);

      final at = tester.getCenter(_chip(l10n));
      await _letHide(tester);
      await _tapAt(tester, at);

      expect(
        locked.value,
        isTrue,
        reason: 'an invisible chip must not unlock the screen',
      );

      await _snapshot(tester, state: 'paused');
    });

    testWidgets('the chip gives the player back', (tester) async {
      final engine = FakeVlcEngine();
      final locked = ValueNotifier(false);
      addTearDown(locked.dispose);
      await _pump(tester, locked: locked, engine: engine);
      final l10n = await _english();
      await _snapshot(tester, position: 5000);
      await lock(tester);

      await _press(tester, _chip(l10n));

      expect(locked.value, isFalse);
      expect(_chip(l10n), findsNothing);
      expect(find.byType(PlayerBottomBar), findsOneWidget);
      expect(_padlock(l10n), findsOneWidget, reason: 'and can be locked again');

      // The gestures are back with it, which is the half a findsOneWidget
      // cannot see.
      await tester.dragFrom(
        tester.getCenter(find.byType(VlcPlayerControls)),
        const Offset(300, 0),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(_seeks(engine), isNotEmpty);

      await _snapshot(tester, state: 'paused', position: 5000);
    });

    testWidgets('the chip answers a game controller A', (tester) async {
      // The item's one dependency on W1.1. The lock is touch-only, but the
      // chip is a [PlayerActionButton] and every player control that takes
      // Select has to take a pad's A as well - a Shield remote and an Android
      // phone with a controller paired both send it.
      final locked = ValueNotifier(false);
      addTearDown(locked.dispose);
      await _pump(tester, locked: locked);
      await lock(tester);

      // [PlayerActionButton] wraps an [InkWell] in a [Focus], and the InkWell
      // makes a node of its own, so the button owns two focus stops at
      // identical geometry. Either will do here and the inner one is what
      // traversal actually lands on: the key handler lives on the outer
      // wrapper, and a key event that is not claimed by the focused node
      // bubbles up through its ancestors to reach it. Resolved from the icon
      // upwards rather than by node label, because neither node carries one.
      final node = Focus.of(tester.element(find.byIcon(Icons.lock_rounded)));
      node.requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
      await tester.pump();

      expect(locked.value, isFalse);

      await _snapshot(tester, state: 'paused');
    });
  });
}
