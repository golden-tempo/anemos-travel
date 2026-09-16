import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:travel_route_planner/widgets/chat_recommendation_map.dart';
import 'package:travel_route_planner/widgets/place_photo_card.dart';

import 'support/l10n_test_app.dart';

/// The chat map/tile pairing (#652): a rail whose results carry a coordinate
/// gets a small map above it, one pin per card, and hovering a tile
/// highlights the matching pin — the ChatGPT recommendation-surface pairing.

const _accent = Colors.teal;

PlacePhotoCard _card(String title) => PlacePhotoCard(
      data: PlaceCardData(
        title: title,
        fallbackIcon: Icons.place,
        accent: _accent,
      ),
    );

MarkerLayer _markerLayer(WidgetTester tester) =>
    tester.widget<MarkerLayer>(find.byType(MarkerLayer));

void main() {
  group('recommendationPoint', () {
    test('null lat/lng and the 0,0 "no coordinate" sentinel both read null',
        () {
      expect(recommendationPoint(null, null), isNull);
      expect(recommendationPoint(0, 0), isNull);
      expect(recommendationPoint(37.39, -5.99), const LatLng(37.39, -5.99));
    });
  });

  group('ChatRecommendationMap', () {
    testWidgets('renders nothing when every point is null', (tester) async {
      await tester.pumpWidget(localizedTestApp(
        home: Scaffold(
          body: ChatRecommendationMap(
            points: const [null, null],
            highlighted: ValueNotifier<int?>(null),
            accent: _accent,
          ),
        ),
      ));
      await tester.pump();

      expect(find.byType(FlutterMap), findsNothing);
    });

    testWidgets('plots one pin per non-null point, skipping the gaps',
        (tester) async {
      await tester.pumpWidget(localizedTestApp(
        home: Scaffold(
          body: ChatRecommendationMap(
            points: const [
              LatLng(37.39, -5.99),
              null,
              LatLng(37.98, 23.72),
            ],
            highlighted: ValueNotifier<int?>(null),
            accent: _accent,
          ),
        ),
      ));
      await tester.pump();

      expect(find.byType(FlutterMap), findsOneWidget);
      expect(_markerLayer(tester).markers, hasLength(2));
    });

    testWidgets('the highlighted index grows its pin, the rest stay small',
        (tester) async {
      final highlighted = ValueNotifier<int?>(null);
      await tester.pumpWidget(localizedTestApp(
        home: Scaffold(
          body: ChatRecommendationMap(
            points: const [
              LatLng(37.39, -5.99),
              LatLng(37.98, 23.72),
            ],
            highlighted: highlighted,
            accent: _accent,
          ),
        ),
      ));
      await tester.pump();

      final atRest = _markerLayer(tester).markers;
      expect(atRest[0].width, atRest[1].width);

      highlighted.value = 0;
      await tester.pump();

      final markers = _markerLayer(tester).markers;
      expect(markers[0].width, greaterThan(markers[1].width));

      highlighted.value = null;
      await tester.pump();

      final reset = _markerLayer(tester).markers;
      expect(reset[0].width, reset[1].width);
    });
  });

  group('RecommendationMapStrip', () {
    testWidgets('falls back to a bare rail when nothing is mappable',
        (tester) async {
      await tester.pumpWidget(localizedTestApp(
        home: Scaffold(
          body: RecommendationMapStrip(
            icon: Icons.place_outlined,
            accent: _accent,
            label: '2 places',
            points: const [null, null],
            cards: [_card('Bar El Comercio'), _card('Ta Karamanlidika')],
          ),
        ),
      ));
      await tester.pump();

      expect(find.byType(FlutterMap), findsNothing);
      expect(find.byType(PlacePhotoStrip), findsOneWidget);
      expect(find.text('Bar El Comercio'), findsOneWidget);
    });

    testWidgets('hovering a card highlights its pin; leaving it un-highlights',
        (tester) async {
      await tester.pumpWidget(localizedTestApp(
        home: Scaffold(
          body: RecommendationMapStrip(
            icon: Icons.place_outlined,
            accent: _accent,
            label: '2 places',
            points: const [
              LatLng(37.39, -5.99),
              LatLng(37.98, 23.72),
            ],
            cards: [_card('Bar El Comercio'), _card('Ta Karamanlidika')],
          ),
        ),
      ));
      await tester.pump();

      expect(find.byType(FlutterMap), findsOneWidget);
      final atRest = _markerLayer(tester).markers;
      expect(atRest[0].width, atRest[1].width);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pump();

      await gesture
          .moveTo(tester.getCenter(find.text('Bar El Comercio').hitTestable()));
      await tester.pump();

      final hovered = _markerLayer(tester).markers;
      expect(hovered[0].width, greaterThan(hovered[1].width));

      // Move off both cards entirely: the highlight clears.
      await gesture.moveTo(Offset.zero);
      await tester.pump();

      final after = _markerLayer(tester).markers;
      expect(after[0].width, after[1].width);
    });
  });
}
