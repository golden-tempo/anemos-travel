import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../navigation/app_nav.dart';
import '../navigation/app_routes.dart';
import '../providers/trips_provider.dart';
import '../screens/travel_atlas_screen.dart';
import '../theme/spacing.dart';
import '../utils/trip_list_insights.dart';
import 'section_header.dart';
import 'travel_footprint_card.dart';

/// Home's way into the atlas.
///
/// Its own key rather than the Trips header's `kTravelAtlasSeeAllKey`, because
/// both headers are alive at the same time once the Trips tab has been visited
/// — the shell keeps visited tabs mounted under the active one — so one key
/// would match two widgets and every finder using it would go ambiguous the
/// moment this shipped.
const kHomeTravelAtlasSeeAllKey = ValueKey('travelAtlas.entry.home');

/// "Your travels" on Home: the traveled/planned footprint the Trips tab
/// already shows, so the page ends on where you have been rather than on
/// nothing.
///
/// Reuses [TravelFootprintCard] and [travelStats] outright rather than
/// restating them — a second arithmetic for the same two counts is how the two
/// surfaces would start disagreeing about how many cities you have visited.
/// Both gates come with it: **2+ owned trips**, because an aggregate over one
/// trip only restates the hero above it, and the card's own pin rules.
///
/// Reads `tripsProvider`, which is populated app-wide (`AppShell` fires the
/// boot `loadTrips()` from its own initState), so this costs no request of
/// its own — the same reason Home can watch it for `returning`.
///
/// Owned trips only. Shared-with-me is someone else's travel and its payload
/// carries no pins anyway, which is the rule the Trips tab already applies.
class HomeTravelsBand extends ConsumerWidget {
  const HomeTravelsBand({super.key});

  /// Below this an aggregate says nothing the trip cards above have not.
  static const int _minTrips = 2;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Length only, not the trip objects: a background refresh rebuilds every
    // Trip, and this band's numbers only change when the SET does. The full
    // list is read below, once the length says this build runs anyway.
    final tripCount = ref.watch(tripsProvider.select((s) => s.trips.length));
    if (tripCount < _minTrips) return const SizedBox.shrink();

    final trips = ref.read(tripsProvider).trips;
    final now = DateTime.now();
    final stats = travelStats(trips, now);
    final pins = footprintPins(trips, now);

    // The Trips header's gate, borrowed whole, and deliberately NOT this
    // band's own [_minTrips]: the two count different things. This band asks
    // for 2+ OWNED trips, because below that an aggregate only restates the
    // hero above it. The atlas asks for 2+ PAST trips, because below that
    // there is nothing behind the door — no traveled pins, no Traveled
    // colophon group, an index with no rows. A traveler with two trips still
    // ahead of them gets the band and no door, which is correct: the map they
    // are looking at is all of it.
    final showAtlas = pastTrips(trips, now).length >= 2;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          title: context.l10n.tripsListYourTravels,
          // Pushed on Home's OWN stack, the way Home's other "See all" (local
          // guides) already goes to its screen — so back returns here rather
          // than stranding the traveler on the Trips list they never asked
          // for. `openAtlasOnTripsTab` is the Trips-tab caller's helper and
          // exists to keep that tab's back button honest; from Home the same
          // concern points the other way.
          //
          // Only "See all" comes across. "+ Add past trip" stays in the Trips
          // header by a recorded decision (specs/log-past-trip) that a copy
          // here would quietly re-open.
          action: showAtlas
              ? TextButton(
                  key: kHomeTravelAtlasSeeAllKey,
                  onPressed: () => pushOnce(
                    context,
                    locatedRoute(const TravelAtlasScreen(),
                        utilityLocation(BootUtility.travelAtlas)),
                  ),
                  // The Trips entry's string, not `commonSeeAll`: one action,
                  // one label, so a future rewording moves both doors at once.
                  child: Text(context.l10n.travelAtlasSeeAll),
                )
              : null,
        ),
        const SizedBox(height: AppSpacing.md),
        TravelFootprintCard(
          pins: pins,
          traveled: stats.traveled,
          planned: stats.planned,
        ),
        const SizedBox(height: AppSpacing.xl),
      ],
    );
  }
}
