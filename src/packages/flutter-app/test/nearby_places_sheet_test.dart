import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher_platform_interface/link.dart' show LinkDelegate;
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'package:travel_route_planner/models/place_search_result.dart';
import 'package:travel_route_planner/providers/places_api_provider.dart';
import 'package:travel_route_planner/widgets/nearby_places_sheet.dart';

import 'support/l10n_test_app.dart';

class _FakeUrlLauncher extends UrlLauncherPlatform {
  final launched = <String>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return true;
  }
}

PlaceSearchResult _cafe() => const PlaceSearchResult(
      placeId: 'pid-cafe',
      name: 'Corner Cafe',
      address: '5 Rue de Rivoli, Paris',
      latitude: 48.86,
      longitude: 2.35,
      types: ['cafe'],
    );

Future<void> _open(
  WidgetTester tester, {
  required List<PlaceSearchResult> results,
  Object? error,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        nearbyPlacesProvider.overrideWith((ref, q) async {
          if (error != null) throw error;
          return results;
        }),
      ],
      child: localizedTestApp(
        home: Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () => showNearbyPlacesSheet(context,
                  latitude: 48.8566, longitude: 2.3522),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  late _FakeUrlLauncher launcher;

  setUp(() {
    launcher = _FakeUrlLauncher();
    UrlLauncherPlatform.instance = launcher;
  });

  testWidgets('lists nearby places with name and address', (tester) async {
    await _open(tester, results: [_cafe()]);

    expect(find.text('Nearby'), findsOneWidget);
    expect(find.text('Corner Cafe'), findsOneWidget);
    expect(find.text('5 Rue de Rivoli, Paris'), findsOneWidget);
  });

  testWidgets('empty results show the empty state', (tester) async {
    await _open(tester, results: const []);

    expect(find.text('No nearby places found.'), findsOneWidget);
  });

  testWidgets('a failed lookup shows the error state', (tester) async {
    await _open(tester, results: const [], error: Exception('boom'));

    expect(find.text("Couldn't load nearby places."), findsOneWidget);
  });

  testWidgets('tapping Directions opens Google Maps for the place',
      (tester) async {
    await _open(tester, results: [_cafe()]);

    await tester.tap(find.byIcon(Icons.directions_outlined));
    await tester.pumpAndSettle();

    expect(launcher.launched, hasLength(1));
    final url = launcher.launched.single;
    expect(url, contains('google.com/maps/search'));
    expect(url, contains('query_place_id=pid-cafe'));
  });
}
