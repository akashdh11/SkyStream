import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/providers/device_info_provider.dart';
import 'package:skystream/features/player/presentation/vlc/ended_card.dart';
import 'package:skystream/features/player/presentation/vlc/next_episode_countdown.dart';
import 'package:skystream/features/player/presentation/vlc/vlc_player_controls.dart';
import 'package:skystream/features/player/presentation/widgets/player_control_components.dart'
    show PlayerCenterPlayButton;
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:vlc_player/vlc_player.dart';

import 'fake_vlc_engine.dart';

/// The chrome is composited over a platform view on macOS and iOS. Flutter
/// backs every overlay layer over a platform view with an IOSurface sized to
/// that layer, and tears the surface down and rebuilds it whenever the layer
/// appears or disappears. A single opacity layer spanning both bars is therefore
/// window-sized, and its churn on show/hide is what produced black frames.
/// Android renders video as a texture and never showed it, which is why this
/// has to be pinned by a test rather than by looking at one platform.
///
/// 40% is generous. The two bars together cover well under a quarter of a
/// 16:9 viewport; the only way past this line is to wrap something that
/// spans the spacer between them.
const double _maxLayerFraction = 0.4;

const Size _tv = Size(2560, 1440);

/// A phone held sideways, which is what the player actually runs at on touch.
/// Its short side is under 600 dp, so the centre play/pause takes its smaller
/// diameter here - and, more to the point, the touch build is the one that
/// mounts the glyph at all.
const Size _phone = Size(844, 390);

Widget _host(Widget child, {bool isTv = true}) {
  return ProviderScope(
    overrides: [
      deviceProfileProvider.overrideWithValue(
        AsyncValue.data(DeviceProfile(isTv: isTv)),
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

/// The real controller over the shared engine fake: `VlcPlayerController` has
/// no public fake, so the real one is attached to a stub engine. No panel
/// callback, so only the two always-present list buttons render - the layer
/// shape does not depend on how many buttons the bar holds.
///
/// [isTv] and [size] are parameters because the touch build is not the TV
/// build: it mounts a centred play/pause the remote build has no use for, and
/// that glyph is wrapped in a fade of its own. A fade nested one level wrong
/// there - `Positioned.fill(AnimatedOpacity(Center(...)))` instead of
/// `Center(AnimatedOpacity(...))` - is a viewport-sized effect layer over the
/// platform view, on the very platforms (macOS, iOS) this whole file exists
/// for. Pinned only on TV, that could not be caught at all.
Future<VlcPlayerController> _pumpControls(
  WidgetTester tester, {
  bool isTv = true,
  Size size = _tv,
  ValueNotifier<bool>? locked,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final engine = FakeVlcEngine();
  engine.install();
  // Tear-downs run last-in first-out: the controller goes first, while the
  // channel it sends `dispose` on still has a handler.
  addTearDown(engine.dispose);
  final controller = await engine.attach();
  addTearDown(controller.dispose);

  await tester.pumpWidget(
    _host(
      VlcPlayerControls(
        controller: controller,
        title: 'The Body',
        subtitle: 'S5 E16',
        onBack: () {},
        onNextEpisode: () {},
        locked: locked,
      ),
      isTv: isTv,
    ),
  );
  await tester.pump();
  return controller;
}

/// Every render object in the subtree that is composited as its own layer with
/// an effect applied - the kinds that become an IOSurface over a platform view.
List<RenderBox> _effectLayers(RenderObject root) {
  final found = <RenderBox>[];
  void visit(RenderObject node) {
    // ColorFiltered and ImageFiltered both use render objects the framework
    // keeps private, so those two are matched by name; the rest are public.
    const privateFilters = {
      '_ColorFilterRenderObject',
      '_ImageFilterRenderObject',
    };
    if (node is RenderAnimatedOpacity ||
        node is RenderOpacity ||
        node is RenderBackdropFilter ||
        node is RenderShaderMask ||
        privateFilters.contains(node.runtimeType.toString())) {
      found.add(node as RenderBox);
    }
    node.visitChildren(visit);
  }

  visit(root);
  return found;
}

double _fractionOfViewport(RenderBox box, Size viewport) {
  final bounds = box.paintBounds;
  return (bounds.width * bounds.height) / (viewport.width * viewport.height);
}

/// The body of the 40 % rule, run against whatever viewport was pumped.
void _expectNoLargeEffectLayer(WidgetTester tester, Size viewport) {
  final root = tester.renderObject(find.byType(VlcPlayerControls));
  final layers = _effectLayers(root);
  expect(layers, isNotEmpty, reason: 'the fade is expected to exist');

  for (final layer in layers) {
    expect(
      _fractionOfViewport(layer, viewport),
      lessThanOrEqualTo(_maxLayerFraction),
      reason:
          '${layer.runtimeType} covers ${layer.paintBounds.size} of $viewport. '
          'An opacity or filter layer this large over a platform view is '
          're-surfaced on every show/hide and blacks out the video.',
    );
  }
}

void _nothing() {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VlcPlayerControls compositing', () {
    testWidgets('no effect layer spans more than 40% of the viewport', (
      tester,
    ) async {
      await _pumpControls(tester);
      _expectNoLargeEffectLayer(tester, _tv);
    });

    // The same rule on the touch build, which is a different tree: it carries
    // a centred play/pause the TV build does not, and that glyph has a fade of
    // its own. macOS and iOS are exactly the platforms that composite this
    // chrome over a platform view *and* the platforms that get the glyph, so
    // leaving the touch path unmeasured left the rule unenforced precisely
    // where it bites.
    testWidgets('nor on the touch build, where the centre glyph fades too', (
      tester,
    ) async {
      await _pumpControls(tester, isTv: false, size: _phone);
      expect(
        find.byType(PlayerCenterPlayButton),
        findsOneWidget,
        reason: 'otherwise this variant is measuring the TV tree twice',
      );
      _expectNoLargeEffectLayer(tester, _phone);
    });

    // 38da335's lock painted its unlock affordance as a window-sized
    // `IgnorePointer > AnimatedOpacity > Center`, which is precisely the shape
    // this file forbids: a viewport-sized opacity layer over the platform
    // view, torn down and rebuilt every time the chip shows or hides - which
    // on a locked screen is every single accidental touch. Rebuilding it that
    // way would fail here on the 40 % cap *and* in the test below, whose
    // "every fade is 1.0 at rest" would then be measuring the whole window.
    testWidgets('nor on a locked screen, whose one control is a chip', (
      tester,
    ) async {
      final locked = ValueNotifier(true);
      addTearDown(locked.dispose);
      await _pumpControls(tester, isTv: false, size: _phone, locked: locked);

      expect(
        find.byType(PlayerCenterPlayButton),
        findsNothing,
        reason: 'locked withdraws the glyph, so this is the locked tree',
      );
      _expectNoLargeEffectLayer(tester, _phone);
    });

    testWidgets('the bars still fade out rather than snapping', (tester) async {
      await _pumpControls(tester);

      final root = tester.renderObject(find.byType(VlcPlayerControls));
      final fades = _effectLayers(root).whereType<RenderAnimatedOpacity>();
      expect(fades, isNotEmpty);
      for (final fade in fades) {
        expect(fade.opacity.value, 1.0);
      }

      // A bare tap on the video toggles the chrome. The screen-wide detector
      // also owns a double-tap, so the single tap resolves only after that
      // recogniser gives up.
      await tester.tapAt(tester.getCenter(find.byType(VlcPlayerControls)));
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));

      // Mid-fade, every bar is translucent: neither still solid nor gone.
      await tester.pump(const Duration(milliseconds: 100));
      for (final fade in fades) {
        expect(fade.opacity.value, greaterThan(0.0));
        expect(fade.opacity.value, lessThan(1.0));
      }

      await tester.pumpAndSettle();
      for (final fade in fades) {
        expect(fade.opacity.value, 0.0);
      }
    });
  });

  group('EndedCard compositing', () {
    testWidgets('the full-bleed backdrop is a paint, not a layer', (
      tester,
    ) async {
      tester.view.physicalSize = _tv;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _host(
          const EndedCard(
            key: endedCardKey,
            title: 'The Matrix',
            kind: EndedKind.finished,
            isTv: true,
            onStartOver: _nothing,
            onClose: _nothing,
          ),
        ),
      );
      await tester.pump();

      // The card covers the whole viewport by construction, so *any* effect
      // layer in it is window-sized - four times the 40 % this file exists to
      // forbid. A BackdropFilter added here later would black-frame macOS and
      // iOS exactly the way the chrome's window-sized opacity layer did.
      final layers = _effectLayers(
        tester.renderObject(find.byKey(endedCardKey)),
      );
      expect(
        layers,
        isEmpty,
        reason:
            'if a fade is ever wanted here, fade the inner Column - not the '
            'backdrop: ${layers.map((l) => l.runtimeType).join(', ')}',
      );
    });
  });

  group('NextEpisodeCountdown repaint containment', () {
    testWidgets('the ring repaints alone; the card above it does not', (
      tester,
    ) async {
      tester.view.physicalSize = _tv;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final cardKey = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            backgroundColor: Colors.black,
            body: Stack(
              fit: StackFit.expand,
              children: [
                // Stands in for the layer the chrome would put the card on. If
                // the ring's repaint escapes its own boundary, this is what
                // gets repainted every frame.
                RepaintBoundary(
                  key: cardKey,
                  child: NextEpisodeCountdown(
                    title: 'The Body',
                    countdown: const Duration(seconds: 15),
                    onPlayNext: () {},
                    onCancel: () {},
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      final card =
          cardKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final boundaries = <RenderRepaintBoundary>[];
      void visit(RenderObject node) {
        if (node is RenderRepaintBoundary && node != card) boundaries.add(node);
        node.visitChildren(visit);
      }

      card.visitChildren(visit);
      expect(
        boundaries,
        hasLength(1),
        reason: 'exactly one boundary: the ring',
      );
      final ring = boundaries.single;

      int paints(RenderRepaintBoundary b) =>
          b.debugSymmetricPaintCount + b.debugAsymmetricPaintCount;
      final cardBefore = paints(card);
      final ringBefore = paints(ring);

      const frames = 12;
      for (var i = 0; i < frames; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(
        paints(ring) - ringBefore,
        frames,
        reason:
            'the ring is driven by an AnimationController, one paint per vsync',
      );
      expect(
        paints(card) - cardBefore,
        0,
        reason: 'nothing above the ring may repaint while it animates',
      );

      // Unmount so the ticker does not outlive the test.
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
