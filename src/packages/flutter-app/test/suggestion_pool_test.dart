import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/l10n/l10n.dart';
import 'package:travel_route_planner/models/city_pin.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/providers/suggestions_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trip_cache.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';

/// The suggestion pool's contracts: picks are distinct in-range indices, the
/// whole pool is reachable (no prompt is dead weight), and every label is
/// usable as BOTH display text and sent message in each shipped locale.

/// [TripsNotifier] seeded with [trips] at construction, with no network or
/// cache I/O — [TripsNotifier] itself has no "just set the trips" hook
/// because production code only ever learns trips from [loadTrips], so tests
/// that need a populated list go through this constructor instead of adding
/// a test-only method to the real notifier.
class _SeededTripsNotifier extends TripsNotifier {
  _SeededTripsNotifier(List<Trip> trips)
      : super(TripsApiService(ApiClient()), TripCache(null)) {
    state = state.copyWith(trips: trips);
  }
}

void main() {
  test('pickSuggestionIndices returns distinct in-range indices', () {
    expect(suggestionPool.length, greaterThanOrEqualTo(kSuggestionCount));
    for (var seed = 0; seed < 20; seed++) {
      final picks = pickSuggestionIndices(Random(seed));
      expect(picks, hasLength(kSuggestionCount));
      expect(picks.toSet(), hasLength(kSuggestionCount));
      for (final i in picks) {
        expect(i, inInclusiveRange(0, suggestionPool.length - 1));
      }
    }
  });

  test('the rail order is the WHOLE pool, shuffled', () {
    // The destination rails scroll this order, so a short draw would silently
    // hide destinations from a rail that claims to carry the whole pool.
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final order = container.read(suggestionOrderProvider)();
    expect(order, hasLength(suggestionPool.length));
    expect(order.toSet(), hasLength(suggestionPool.length));
  });

  test('every pool prompt is reachable', () {
    final random = Random(42);
    final seen = <int>{};
    for (var draw = 0;
        draw < 200 && seen.length < suggestionPool.length;
        draw++) {
      seen.addAll(pickSuggestionIndices(random));
    }
    expect(seen, hasLength(suggestionPool.length));
  });

  test('every suggestion names a destination country', () {
    for (final prompt in suggestionPool) {
      expect(prompt.country, isNotEmpty);
    }
  });

  test('visitedCountries biases toward new countries without hiding any', () {
    // Rome and Amalfi are both IT; every other entry is a distinct country —
    // marking IT visited should push both behind every other destination
    // while still keeping all twelve reachable.
    final random = Random(7);
    final order = pickSuggestionIndices(random,
        count: suggestionPool.length, visitedCountries: const {'IT'});
    expect(order, hasLength(suggestionPool.length));
    expect(order.toSet(), hasLength(suggestionPool.length));

    final visitedCount = suggestionPool.where((p) => p.country == 'IT').length;
    final tail = order.sublist(order.length - visitedCount);
    expect(tail.every((i) => suggestionPool[i].country == 'IT'), isTrue,
        reason: 'every visited-country destination sorts behind every new one');
  });

  test('an empty visitedCountries draws exactly the plain shuffle', () {
    final a = pickSuggestionIndices(Random(11), count: suggestionPool.length);
    final b = pickSuggestionIndices(Random(11),
        count: suggestionPool.length, visitedCountries: const {});
    expect(b, a);
  });

  test('visiting every country in the pool still returns all of it', () {
    final all = {for (final p in suggestionPool) p.country};
    final order = pickSuggestionIndices(Random(3),
        count: suggestionPool.length, visitedCountries: all);
    expect(order.toSet(), hasLength(suggestionPool.length));
  });

  test('personalizedSuggestionOrderProvider no-ops with no trip history', () {
    // tripsProvider is overridden directly (bypassing the auth/cache chain
    // its real implementation sits behind, which this plain-Dart test has no
    // platform channels for) with its own default empty TripsState — the
    // same starting state every session boots with before trips load.
    final container = ProviderContainer(overrides: [
      tripsProvider.overrideWith((ref) => _SeededTripsNotifier(const [])),
    ]);
    addTearDown(container.dispose);

    final order = container.read(personalizedSuggestionOrderProvider)();
    expect(order, hasLength(suggestionPool.length));
    expect(order.toSet(), hasLength(suggestionPool.length));
  });

  test('personalizedSuggestionOrderProvider pushes visited countries back', () {
    final roundTrip = Trip(
      id: 't1',
      title: 'Roman holiday',
      startDate: '2020-01-01',
      endDate: '2020-01-10',
      createdAt: '2020-01-01T00:00:00Z',
      updatedAt: '2020-01-01T00:00:00Z',
      cityPins: const [
        CityPin(city: 'Rome', lat: 41.9, lng: 12.5, country: 'IT'),
      ],
    );
    final container = ProviderContainer(overrides: [
      tripsProvider.overrideWith((ref) => _SeededTripsNotifier([roundTrip])),
    ]);
    addTearDown(container.dispose);

    final order = container.read(personalizedSuggestionOrderProvider)();
    final italyCount = suggestionPool.where((p) => p.country == 'IT').length;
    final tail = order.sublist(order.length - italyCount);
    expect(tail.every((i) => suggestionPool[i].country == 'IT'), isTrue);
  });

  test('labels are non-empty and distinct in every shipped locale', () {
    for (final locale in kSupportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      final labels = [for (final pick in suggestionPool) pick.label(l10n)];
      expect(labels.where((s) => s.trim().isEmpty), isEmpty,
          reason: 'empty label in $locale');
      // Distinctness is load-bearing: labels are find.text targets in tests
      // and become literal user messages when tapped.
      expect(labels.toSet(), hasLength(labels.length),
          reason: 'duplicate label in $locale');
    }
  });
}
