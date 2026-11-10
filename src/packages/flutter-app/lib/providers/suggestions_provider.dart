import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../utils/trip_list_insights.dart';
import 'destination_photos.dart';
import 'trips_provider.dart';

/// One entry in [suggestionPool]: what the prompt says, and which destination
/// photo stands for it.
///
/// The two travel together deliberately. A parallel `suggestionImages` list
/// indexed by pool position would work right up until someone appended a
/// prompt and not an image — the implicit-convention coupling `docs/zen.md`
/// says this repo has already paid for once. Here a prompt without a photo
/// does not compile.
typedef SuggestionPrompt = ({
  /// Resolves the localized label at render time.
  String Function(AppLocalizations) label,

  /// Key into [kDestinationPhotos], which
  /// `scripts/fetch-destination-photos.py` generates alongside the images
  /// themselves.
  String photo,

  /// ISO 3166-1 alpha-2 country code the destination sits in — the same
  /// alphabet [CityPin.country] is stored in (`countryForPoint`), so a
  /// traveler's visited-countries set (`visitedCountryCodes`) can be compared
  /// against it directly with no lookup table of its own. Hand-tagged: the
  /// pool is a dozen curated entries, not a geocoded one, and most span one
  /// country only (Amalfi and Rome both sit in Italy on purpose — losing that
  /// overlap would cost the one case where the pool can say "you've been to
  /// this country, but not here").
  String country,
});

/// Shared pool of one-tap trip prompts for the agent chat's empty state and
/// the home hero card. Selectors, not strings: WHICH prompts show is
/// locale-independent; WHAT they say resolves at render time, so a locale
/// switch relabels the same picks without reshuffling. Every label is BOTH
/// what the traveler reads and what gets sent (see `DestinationSuggestionCard`
/// and the home hero's chips).
/// ORDER IS API: the first three are the legacy trio; tests pin picks by
/// pool index, so append new prompts at the tail and never reorder.
final List<SuggestionPrompt> suggestionPool = [
  (label: (l) => l.suggestionParis, photo: 'paris', country: 'FR'),
  (label: (l) => l.suggestionRome, photo: 'rome', country: 'IT'),
  (label: (l) => l.suggestionTokyo, photo: 'tokyo', country: 'JP'),
  (label: (l) => l.suggestionGreece, photo: 'greece', country: 'GR'),
  (label: (l) => l.suggestionLisbon, photo: 'lisbon', country: 'PT'),
  (label: (l) => l.suggestionBarcelona, photo: 'barcelona', country: 'ES'),
  (label: (l) => l.suggestionBangkok, photo: 'bangkok', country: 'TH'),
  (label: (l) => l.suggestionAmalfi, photo: 'amalfi', country: 'IT'),
  (label: (l) => l.suggestionNewYork, photo: 'newyork', country: 'US'),
  (label: (l) => l.suggestionBali, photo: 'bali', country: 'ID'),
  (label: (l) => l.suggestionPatagonia, photo: 'patagonia', country: 'AR'),
  (label: (l) => l.suggestionKenya, photo: 'kenya', country: 'KE'),
];

/// The photo for [prompt], or a thrown error naming the missing slug.
///
/// The pool and [kDestinationPhotos] are edited in different places — the
/// prompt by hand, the table by `scripts/fetch-destination-photos.py` — so a
/// slug can go stale between them. Failing here with the slug in the message
/// beats a bare null-check crash or, worse, a card that silently renders its
/// fallback box forever. `suggestion_pool_assets_test.dart` pins that every
/// pool entry resolves, so this should only ever fire mid-edit.
DestinationPhoto photoFor(SuggestionPrompt prompt) {
  final photo = kDestinationPhotos[prompt.photo];
  if (photo == null) {
    throw StateError(
      'No destination photo for "${prompt.photo}". Add it to SOURCES in '
      'scripts/fetch-destination-photos.py and re-run the script.',
    );
  }
  return photo;
}

/// How many suggestion chips a surface shows (the near-me chip is extra).
const int kSuggestionCount = 3;

/// Pure and unit-testable: [count] distinct pool indices, shuffled.
///
/// [visitedCountries] (specs/personalized-trip-suggestions) BIASES the draw
/// without ever hiding a destination: every index still shuffles first, then
/// the ones whose [SuggestionPrompt.country] is NOT in [visitedCountries]
/// are stably pulled ahead of the ones that are, so a destination the
/// traveler has already reached can still be drawn — just no longer ahead of
/// one that would be new to them. Empty (the default, and every anonymous or
/// trip-less session) partitions into nothing and the draw is the same plain
/// shuffle this always was.
List<int> pickSuggestionIndices(
  Random random, {
  int count = kSuggestionCount,
  Set<String> visitedCountries = const {},
}) {
  final shuffled = List<int>.generate(suggestionPool.length, (i) => i)
    ..shuffle(random);
  if (visitedCountries.isEmpty) return shuffled.sublist(0, count);
  final ordered = [
    for (final i in shuffled)
      if (!visitedCountries.contains(suggestionPool[i].country)) i,
    for (final i in shuffled)
      if (visitedCountries.contains(suggestionPool[i].country)) i,
  ];
  return ordered.sublist(0, count);
}

/// The one determinism seam. Production entropy lives only here; tests
/// override with an explicit-index picker such as `() => const [0, 1, 2]`
/// rather than a seeded [Random], whose mapping to picks would couple them
/// to `List.shuffle` internals.
final suggestionPickerProvider = Provider<List<int> Function()>((ref) {
  final random = Random();
  return () => pickSuggestionIndices(random);
});

/// EVERY pool index, in random order — the destination rails (the landing
/// page's, signed-out and so unpersonalizable) carry the whole pool rather
/// than a sample of it.
///
/// A sibling of [suggestionPickerProvider] rather than a parameter on it: the
/// home hero still shows [kSuggestionCount] chips it can fit, and the two
/// surfaces now want genuinely different draws. Which provider a surface
/// reads is stated at its call site (`RandomSuggestions.picker`), so neither
/// can silently inherit the other's count. Same determinism seam rules apply.
final suggestionOrderProvider = Provider<List<int> Function()>((ref) {
  final random = Random();
  return () => pickSuggestionIndices(random, count: suggestionPool.length);
});

/// [suggestionOrderProvider]'s in-app counterpart (specs/personalized-trip-
/// suggestions): the whole pool, shuffled, but biased toward countries NOT in
/// the signed-in traveler's [visitedCountryCodes] — "somewhere new" read
/// literally, for the two rails that can actually know what's new to this
/// traveler (Home's "Somewhere new" rail, the Plan tab's destination rail).
///
/// A sibling, not a parameterization of [suggestionOrderProvider], the same
/// way [suggestionOrderProvider] is a sibling of [suggestionPickerProvider]:
/// the landing page's rail is signed-out by construction (no trips to read),
/// so coupling it to [tripsProvider] would buy it nothing while pulling the
/// whole auth/trips provider graph into a page that today needs none of it.
/// A traveler with no trips, or none with a resolved country, draws exactly
/// [suggestionOrderProvider]'s plain shuffle — [pickSuggestionIndices] no-ops
/// on an empty [visitedCountryCodes] result.
final personalizedSuggestionOrderProvider =
    Provider<List<int> Function()>((ref) {
  final random = Random();
  return () => pickSuggestionIndices(
        random,
        count: suggestionPool.length,
        visitedCountries:
            visitedCountryCodes(ref.read(tripsProvider).trips, DateTime.now()),
      );
});
