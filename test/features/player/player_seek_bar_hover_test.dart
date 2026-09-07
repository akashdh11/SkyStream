import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/presentation/widgets/hotstar_player_style.dart';
import 'package:skystream/features/player/presentation/widgets/player_stream_widgets.dart';

void main() {
  /// The 1.5px hover line is the only widget in the scrubber with that width.
  final hoverLine = find.byWidgetPredicate(
    (w) => w is Container && w.constraints?.maxWidth == 1.5,
  );

  Future<void> pumpSeekBar(
    WidgetTester tester, {
    bool isTv = false,
    double value = 0,
    FocusNode? focusNode,
    ValueChanged<double>? onChanged,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              child: PlayerSeekBar(
                value: value,
                min: 0,
                max: 100000,
                step: 10000,
                isTv: isTv,
                focusNode: focusNode,
                canSeek: true,
                bufferRatio: 0,
                skipSegments: const [],
                onChanged: onChanged,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Target heights of the bar's animated boxes: the track's own band is the
  /// first one painted, the thumb is the last. Read off the widget rather than
  /// the render box so the 150 ms morph is not in the way.
  List<double> bandHeights(WidgetTester tester) => tester
      .widgetList<AnimatedContainer>(
        find.descendant(
          of: find.byType(PlayerSeekBar),
          matching: find.byType(AnimatedContainer),
        ),
      )
      .map((c) => c.constraints!.maxHeight)
      .toList();

  /// The focus ring: the outermost Container is the only decorated one.
  BoxBorder? ring(WidgetTester tester) =>
      (tester
                  .widget<Container>(
                    find
                        .descendant(
                          of: find.byType(PlayerSeekBar),
                          matching: find.byType(Container),
                        )
                        .first,
                  )
                  .decoration
              as BoxDecoration)
          .border;

  testWidgets('mouse move over the track moves the hover line without '
      'rebuilding the scrubber', (tester) async {
    await pumpSeekBar(tester);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    final track = find.byType(GestureDetector);
    final start = tester.getCenter(track);
    await mouse.moveTo(start);
    await tester.pump();
    expect(hoverLine, findsOneWidget);
    expect(tester.getCenter(hoverLine).dx, moreOrLessEquals(start.dx));

    // Instances built by the scrubber's own build: if it runs again on hover,
    // these are replaced with fresh objects.
    final gestureBefore = tester.widget<GestureDetector>(track);
    final mouseRegionBefore = tester.widget<MouseRegion>(
      find.ancestor(of: track, matching: find.byType(MouseRegion)).first,
    );

    await mouse.moveTo(start + const Offset(60, 0));
    await tester.pump();

    expect(tester.getCenter(hoverLine).dx, moreOrLessEquals(start.dx + 60));
    expect(
      identical(tester.widget<GestureDetector>(track), gestureBefore),
      isTrue,
      reason: 'pointer motion must not rebuild the scrubber',
    );
    expect(
      identical(
        tester.widget<MouseRegion>(
          find.ancestor(of: track, matching: find.byType(MouseRegion)).first,
        ),
        mouseRegionBefore,
      ),
      isTrue,
    );

    await mouse.moveTo(Offset.zero);
    await tester.pump();
    expect(hoverLine, findsNothing);
  });

  // Ten-foot sizing. `isTv` was declared on VlcProgressBar and read by nobody,
  // so the one control a remote seeks with was drawn at phone scale: an 8 px
  // track and a 14 px thumb, three metres away.
  testWidgets('the TV bar has a fatter track, a fatter focused thumb and the '
      'accent ring', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);

    await pumpSeekBar(tester, value: 30000, focusNode: focus);
    focus.requestFocus();
    await tester.pump();
    final phoneBar = tester.getSize(find.byType(PlayerSeekBar)).height;
    expect(bandHeights(tester).first, 8, reason: 'the track');
    expect(bandHeights(tester).last, 14, reason: 'the focused thumb');

    await pumpSeekBar(tester, value: 30000, focusNode: focus, isTv: true);
    await tester.pump();

    expect(tester.getSize(find.byType(PlayerSeekBar)).height, phoneBar + 12);
    expect(bandHeights(tester).first, 10, reason: 'the track');
    expect(bandHeights(tester).last, 20, reason: 'the focused thumb');
  });

  testWidgets('the focus ring is the accent every other control uses', (
    tester,
  ) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);

    await pumpSeekBar(tester, focusNode: focus);
    expect(
      ring(tester),
      Border.all(color: Colors.transparent, width: 2),
      reason: 'unfocused, the ring only holds the space',
    );

    focus.requestFocus();
    await tester.pump();

    final theme = ThemeData();
    expect(
      HotstarPlayerStyle.accent,
      isNot(theme.colorScheme.primary),
      reason: 'the bar used to ring itself in the Material seed colour',
    );
    expect(
      ring(tester),
      Border.all(color: HotstarPlayerStyle.accent, width: 2),
    );
  });

  // Without this the bar is invisible to a screen reader: no role, no
  // position, and no way to move it.
  testWidgets('the bar is a slider with a position and working step actions', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final changed = <double>[];
    await pumpSeekBar(tester, value: 30000, onChanged: changed.add);

    final node = tester.getSemantics(find.byType(PlayerSeekBar));
    final data = node.getSemanticsData();
    expect(data.flagsCollection.isSlider, isTrue);
    expect(data.value, '0:30');
    expect(data.increasedValue, '0:40');
    expect(data.decreasedValue, '0:20');

    node.owner!.performAction(node.id, SemanticsAction.increase);
    await tester.pump();
    expect(changed, [40000]);

    node.owner!.performAction(node.id, SemanticsAction.decrease);
    await tester.pump();
    expect(changed, [40000, 20000]);

    // Let the bar's coalescing commit timer fire.
    await tester.pump(const Duration(milliseconds: 500));
    semantics.dispose();
  });

  testWidgets('at the end of the track there is no step to announce', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpSeekBar(tester, value: 0);

    final data = tester
        .getSemantics(find.byType(PlayerSeekBar))
        .getSemanticsData();
    expect(data.value, '0:00');
    expect(data.decreasedValue, '0:00', reason: 'nowhere left to go');
    expect(data.hasAction(SemanticsAction.decrease), isFalse);
    expect(data.hasAction(SemanticsAction.increase), isTrue);

    semantics.dispose();
  });
}
