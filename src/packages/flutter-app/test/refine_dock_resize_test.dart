import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/providers/refine_dock_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/plan_service.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/widgets/refine_dock_handle.dart';
import 'package:travel_route_planner/widgets/trip_refine_panel.dart';

import 'support/l10n_test_app.dart';

/// The docked refine chat is resizable (this feature's whole point), so the
/// width it renders at is a number the code sets outright — a
/// [SizedBox]'s constraint, not a measurement of text — and therefore
/// something a widget test may hold. Nothing here asserts a wrap, a fold or a
/// line count; see the font caveat in CLAUDE.md.
///
/// The arithmetic itself is exercised as plain math below, because the clamp
/// is the one thing every caller shares.

class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

class _SilentPlanService extends PlanService {
  _SilentPlanService() : super('http://unused');

  @override
  Stream<PlanEvent> streamPlan(
    List<Map<String, dynamic>> messages, {
    String? bearerToken,
    String? chatId,
    String? tripId,
    String? summary,
    Future<void>? abortTrigger,
  }) async* {}
}

ItineraryItem _item(int pos, String name, {int? day, String? city}) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      address: '$city, Colombia',
      // Zero coords so the screen skips the map widget in the test env.
      latitude: 0,
      longitude: 0,
      category: 'attraction',
      day: day,
      city: city,
    );

Trip _trip() => Trip(
      id: 't1',
      title: 'Colombia Hop',
      startDate: '2037-08-01',
      endDate: '2037-08-05',
      createdAt: '2037-07-01',
      updatedAt: '2037-07-01',
      items: [
        _item(0, 'Johnny Cay', day: 1, city: 'San Andrés'),
        _item(1, 'Comuna 13', day: 3, city: 'Medellín'),
      ],
    );

Widget _app() => ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(_trip())),
        tripRefineProvider.overrideWith((ref, tripId) =>
            PlanNotifier(_SilentPlanService(), ApiClient(), tripId: tripId)),
      ],
      child: MaterialApp(
        localizationsDelegates: testLocalizationsDelegates,
        home: const TripDetailScreen(tripId: 't1'),
      ),
    );

/// A window wide enough that the dock's own limits, not the window, decide
/// how far it can be dragged: 720 + 8 + 500 is 1228, so 1400 clears the
/// widest dock with the itinerary's floor to spare.
const Size _wide = Size(1400, 900);

/// Opens the trip page at [size] with the refine chat docked.
Future<void> _openDockedChat(WidgetTester tester,
    {Size size = _wide}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_app());
  await tester.pumpAndSettle();
  await tester.tap(find.byType(FloatingActionButton));
  await tester.pumpAndSettle();
}

/// What the dock actually renders at: the panel fills the SizedBox the screen
/// sizes, so this is the screen's own number coming back.
double _dockWidth(WidgetTester tester) =>
    tester.getSize(find.byType(TripRefinePanel)).width;

/// Drags the seam by [dx] logical pixels. Negative widens the dock — it sits
/// at the row's end, so pulling the seam towards the itinerary gives the chat
/// the space.
///
/// Hand-driven rather than `tester.drag`, which spends its touch slop out of
/// the requested offset and would make every distance here 20px short. A drag
/// recognizer is handed nothing until the slop is crossed, and
/// `DragStartBehavior.start` then anchors where it was recognized — so the
/// slop is spent getting the gesture going, not applied to the width. That is
/// also what happens in the app; with a mouse it costs 1px.
Future<void> _dragSeam(WidgetTester tester, double dx) async {
  final gesture = await tester
      .startGesture(tester.getCenter(find.byType(RefineDockHandle)));
  await gesture.moveBy(const Offset(-kDragSlopDefault, 0));
  await tester.pump();
  await gesture.moveBy(Offset(dx, 0));
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('clampRefineDockWidth', () {
    test('hands back the preferred width when the window can afford it', () {
      expect(
        clampRefineDockWidth(kRefineDockDefaultWidth, layoutWidth: 1400),
        kRefineDockDefaultWidth,
      );
    });

    test('holds the traveler between the stated limits', () {
      expect(clampRefineDockWidth(100, layoutWidth: 1400),
          kRefineDockMinWidth);
      expect(clampRefineDockWidth(2000, layoutWidth: 1400),
          kRefineDockMaxWidth);
    });

    test('leaves the itinerary its floor on a window that cannot afford both',
        () {
      const layout = 1000.0;
      final width = clampRefineDockWidth(kRefineDockMaxWidth,
          layoutWidth: layout);
      expect(
        layout - width - kRefineDockHandleWidth,
        greaterThanOrEqualTo(kRefineDockMinBodyWidth),
      );
    });

    test('never narrows the chat below its minimum, even at the breakpoint',
        () {
      // At the dock's own breakpoint the floors do not both fit; the chat's
      // minimum wins, because a window this narrow would otherwise render a
      // dock too cramped to type in. (The itinerary still keeps more than the
      // 499 the old fixed 400px dock left it here.)
      final width = clampRefineDockWidth(kRefineDockDefaultWidth,
          layoutWidth: kRefineDockBreakpoint);
      expect(width, greaterThanOrEqualTo(kRefineDockMinWidth));
      expect(kRefineDockBreakpoint - width - kRefineDockHandleWidth,
          greaterThanOrEqualTo(kRefineDockMinBodyWidth));
    });

    test('a stored width from a wider window is folded, not honoured', () {
      // The preference survives; only what renders is narrowed. This is the
      // reason the clamp is a function of the layout rather than something
      // baked into the stored value.
      expect(clampRefineDockWidth(kRefineDockMaxWidth, layoutWidth: 1000),
          lessThan(kRefineDockMaxWidth));
      expect(clampRefineDockWidth(kRefineDockMaxWidth, layoutWidth: 1400),
          kRefineDockMaxWidth);
    });
  });

  testWidgets('the dock opens at its default width, wider than the old 400',
      (tester) async {
    await _openDockedChat(tester);
    expect(_dockWidth(tester), kRefineDockDefaultWidth);
    expect(kRefineDockDefaultWidth, greaterThan(400));
  });

  testWidgets('dragging the seam towards the itinerary widens the chat',
      (tester) async {
    await _openDockedChat(tester);
    await _dragSeam(tester, -120);
    expect(_dockWidth(tester), kRefineDockDefaultWidth + 120);
  });

  testWidgets('dragging the seam towards the chat narrows it', (tester) async {
    await _openDockedChat(tester);
    await _dragSeam(tester, 60);
    expect(_dockWidth(tester), kRefineDockDefaultWidth - 60);
  });

  testWidgets('a drag past either limit stops at it', (tester) async {
    await _openDockedChat(tester);
    await _dragSeam(tester, -900);
    expect(_dockWidth(tester), kRefineDockMaxWidth);
    await _dragSeam(tester, 900);
    expect(_dockWidth(tester), kRefineDockMinWidth);
  });

  testWidgets('double-clicking the seam puts the chat back', (tester) async {
    await _openDockedChat(tester);
    await _dragSeam(tester, -160);
    expect(_dockWidth(tester), isNot(kRefineDockDefaultWidth));

    // Two taps inside the double-tap window, on the seam itself.
    final seam = find.byType(RefineDockHandle);
    await tester.tap(seam);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(seam);
    await tester.pumpAndSettle();
    expect(_dockWidth(tester), kRefineDockDefaultWidth);
  });

  testWidgets('the width that landed is the width that persists',
      (tester) async {
    await _openDockedChat(tester);
    await _dragSeam(tester, -100);
    // The drag emits a width per frame; only the resting one is written, so
    // a drag costs one storage write rather than sixty.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble(refineDockWidthKey), kRefineDockDefaultWidth + 100);
  });

  testWidgets('a stored width is what the dock opens at next time',
      (tester) async {
    SharedPreferences.setMockInitialValues({refineDockWidthKey: 620.0});
    await _openDockedChat(tester);
    expect(_dockWidth(tester), 620);
  });

  testWidgets('the seam is a real target with a hairline actually in it',
      (tester) async {
    await _openDockedChat(tester);
    // The GestureDetector is opaque over the whole strip, so a drag would
    // still land if the hairline laid out to nothing — which would leave the
    // itinerary and the chat looking welded together. Both facts, separately.
    final seam = tester.getSize(find.byType(RefineDockHandle));
    expect(seam.width, kRefineDockHandleWidth);
    expect(seam.height, greaterThan(0));

    final line = tester.getSize(find.descendant(
      of: find.byType(RefineDockHandle),
      matching: find.byType(AnimatedContainer),
    ));
    expect(line.width, 1, reason: 'the resting hairline');
    expect(line.height, seam.height, reason: 'full height, like the divider');
  });

  testWidgets('arrow keys move the seam a step at a time', (tester) async {
    await _openDockedChat(tester);
    // A splitter you can only reach with a pointer is a splitter half the
    // people using this page cannot reach.
    // Reach the handle's OWN node: Focus.of walks up from its context, so it
    // has to be asked from inside the handle, not at it.
    final inside = tester.element(find
        .descendant(
          of: find.byType(RefineDockHandle),
          matching: find.byType(MouseRegion),
        )
        .first);
    Focus.of(inside).requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(_dockWidth(tester), greaterThan(kRefineDockDefaultWidth));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(_dockWidth(tester), kRefineDockDefaultWidth);
  });

  testWidgets('the itinerary keeps whatever the dock does not take',
      (tester) async {
    await _openDockedChat(tester);
    // The two halves are one number split, not two numbers kept in step: the
    // dock states its width and the trip is Expanded into the rest.
    final scaffoldBody =
        tester.getSize(find.byType(TripDetailScreen)).width;
    await _dragSeam(tester, -200);
    final dock = _dockWidth(tester);
    expect(dock, kRefineDockDefaultWidth + 200);
    expect(scaffoldBody - dock - kRefineDockHandleWidth,
        greaterThanOrEqualTo(kRefineDockMinBodyWidth));
  });
}
