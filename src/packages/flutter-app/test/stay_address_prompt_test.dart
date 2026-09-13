import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/place_search_result.dart';
import 'package:travel_route_planner/providers/places_api_provider.dart';
import 'package:travel_route_planner/widgets/stay_address_prompt.dart';

import 'support/l10n_test_app.dart';

PlaceSearchResult _estherea() => const PlaceSearchResult(
      placeId: 'pid-estherea',
      name: 'Hotel Estherea',
      address: 'Singel 303-309, Amsterdam',
      latitude: 52.5,
      longitude: 4.875,
      types: ['lodging'],
    );

Future<Future<StayAddressDraft?>> _pumpPrompt(
  WidgetTester tester, {
  List<PlaceSearchResult> results = const [],
  String stayTitle = 'Stay in Amsterdam',
}) async {
  late Future<StayAddressDraft?> result;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        placeSearchProvider.overrideWith((ref, query) async => results),
      ],
      child: localizedTestApp(
        home: Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () {
                result =
                    showStayAddressPrompt(context, stayTitle: stayTitle);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return result;
}

Future<void> _search(WidgetTester tester, String text) async {
  await tester.enterText(
      find.byKey(kStayAddressPromptSearchFieldKey), text);
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the stay title and asks for the address', (tester) async {
    await _pumpPrompt(tester, stayTitle: 'Stay in Lisbon');

    expect(find.text("Add your stay's address?"), findsOneWidget);
    expect(find.textContaining('Stay in Lisbon'), findsOneWidget);
    expect(find.byKey(kStayAddressPromptAddressFieldKey), findsOneWidget);
  });

  testWidgets('Skip pops null', (tester) async {
    final result = await _pumpPrompt(tester);

    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(await result, isNull);
  });

  testWidgets('Save with a blank address stays open', (tester) async {
    await _pumpPrompt(tester);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text("Add your stay's address?"), findsOneWidget);
  });

  testWidgets('a hand-typed address saves with no coordinates',
      (tester) async {
    final result = await _pumpPrompt(tester);

    await tester.enterText(
        find.byKey(kStayAddressPromptAddressFieldKey), '12 Rue de Rivoli');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final draft = await result;
    expect(draft, isNotNull);
    expect(draft!.address, '12 Rue de Rivoli');
    expect(draft.latitude, isNull);
    expect(draft.longitude, isNull);
  });

  testWidgets('picking a search result attaches coordinates', (tester) async {
    final result = await _pumpPrompt(tester, results: [_estherea()]);

    await _search(tester, 'Estherea');
    await tester.tap(find.text('Hotel Estherea'));
    await tester.pumpAndSettle();

    // The pick filled the address field and swapped search for the
    // attached-location row, mirroring AddStaySheet.
    expect(find.byKey(kStayAddressPromptPlacedRowKey), findsOneWidget);
    expect(find.byKey(kStayAddressPromptSearchFieldKey), findsNothing);
    expect(
        tester
            .widget<TextField>(find.byKey(kStayAddressPromptAddressFieldKey))
            .controller!
            .text,
        'Singel 303-309, Amsterdam');

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final draft = await result;
    expect(draft!.address, 'Singel 303-309, Amsterdam');
    expect(draft.latitude, 52.5);
    expect(draft.longitude, 4.875);
  });

  testWidgets('detaching an attached pick returns to search', (tester) async {
    final result = await _pumpPrompt(tester, results: [_estherea()]);

    await _search(tester, 'Estherea');
    await tester.tap(find.text('Hotel Estherea'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kStayAddressPromptPlacedRemoveKey));
    await tester.pumpAndSettle();

    expect(find.byKey(kStayAddressPromptSearchFieldKey), findsOneWidget);
    // The typed address (from the earlier pick) is untouched; only the
    // coordinates detach.
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final draft = await result;
    expect(draft!.address, 'Singel 303-309, Amsterdam');
    expect(draft.latitude, isNull);
    expect(draft.longitude, isNull);
  });
}
