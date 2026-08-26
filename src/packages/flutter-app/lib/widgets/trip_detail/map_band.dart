// The trip detail map band (specs/trip-detail-extract): the rounded map
// card shared by both layouts, plus the layout shells that host it — the
// phone scroll-away sliver slot and the wide side-by-side map row
// ([TripDetailMapRow], map-row redesign 2026-08-26). The band's heights and
// row proportions live HERE; every screen interaction arrives as a
// constructor callback.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../models/trip.dart';
import '../../providers/home_overlay_provider.dart';
import '../../screens/trip_detail_derivation.dart';
import '../../screens/trip_map_screen.dart';
import '../../theme/spacing.dart';
import '../app_map.dart';
import '../map_leg_chips.dart';
import '../trip_map.dart';

/// The seam the phone band keeps below the map card, before the tab row.
const double _seamGap = AppSpacing.lg;

/// Minimum height of the wide layout's map card inside [TripDetailMapRow].
///
/// 300, up from the pinned band's 280 — and a minimum now, not an extent.
/// The band stopped being permanent chrome (map-row redesign): it scrolls
/// with the page, so extra height costs one scroll-through instead of a
/// slice of every viewport, and wave 2's 340→280 argument no longer binds.
/// At ~55% of the 900px content cap the card runs ≈1.55:1 — the approved
/// wireframe's ≈1.6:1, the shape that fits the taller-than-wide Mercator
/// footprint of a regional route without the old band's flanks of empty
/// ocean. The right card column can stretch the row past this via
/// [TripDetailMapRow]'s IntrinsicHeight, never below it.
const double mapRowMinHeight = 300;

/// Map card height on phones, where the map is a scroll-away preview (the
/// full-screen map is one tap away).
const double mapBandHeightNarrow = 180;

/// The phone layout's band slot: a fixed-height scroll-away preview card in
/// the page flow. Wide layouts render the map inside the header block's
/// [TripDetailMapRow] instead — since the map-row redesign nothing above the
/// tab row pins on any width.
Widget tripDetailMapBandSliver({
  required double gutter,
  required Widget child,
}) {
  return SliverToBoxAdapter(
    child: Padding(
      // The header's own AppSpacing.lg already sits above this card, so the
      // top gap stays md; the seam below introduces the same tab row the
      // wide layout's row runs into.
      padding: EdgeInsets.fromLTRB(gutter, AppSpacing.md, gutter, _seamGap),
      child: SizedBox(height: mapBandHeightNarrow, child: child),
    ),
  );
}

/// The wide layout's side-by-side map row: map card left at flex 6:5 (~55%,
/// the approved wireframe's 1.2:1), the given [cards] stacked in the right
/// column and stretched so the column matches the map's height. With no
/// cards (read-only trip, no saved conversation) the map spans the full
/// content width at [mapRowMinHeight].
///
/// IntrinsicHeight is what makes the stretch safe: the row's height is the
/// LARGER of [mapRowMinHeight] and the card column's own need, so a long
/// Spanish title or a two-line preview grows the row instead of overflowing
/// a fixed box. One extra intrinsics pass over one row — the map side
/// reports a constant (its Stack children are all positioned), so the cost
/// is the cards' text measurement only.
class TripDetailMapRow extends StatelessWidget {
  final Widget map;
  final List<Widget> cards;

  const TripDetailMapRow({
    super.key,
    required this.map,
    required this.cards,
  });

  @override
  Widget build(BuildContext context) {
    if (cards.isEmpty) {
      return SizedBox(height: mapRowMinHeight, child: map);
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 6,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: mapRowMinHeight),
              child: map,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            flex: 5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Equal flex per card (the wireframe's split): each gets the
                // tallest card's share, so the pair reads as one block. The
                // sm gap is the stacked layout's own next↔chat rhythm.
                for (var i = 0; i < cards.length; i++) ...[
                  if (i > 0) const SizedBox(height: AppSpacing.sm),
                  Expanded(child: cards[i]),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The rounded map card itself. When [TripDetailMapBand.expandable], the map
/// is a static preview whose single tap target opens the full-screen map.
class TripDetailMapBand extends StatelessWidget {
  final Trip trip;
  final TripDerivation derivation;
  final bool expandable;

  /// Whether the live tile map mounts. False during the screen's first
  /// content frame (time-to-interactive, lever 3): [TripMap] and its two
  /// stacked retina tile layers cost dozens of fetches and decodes, so the
  /// deferred frame paints [appMapBackground] instead — the exact canvas an
  /// unloaded map paints ([AppMapVisibilityGate]'s stand-in), so the live
  /// mount one frame later changes nothing visually. Chips and the expand
  /// control render either way: they are part of what the first frame
  /// shows, and their layout must not shift when the map arrives.
  final bool live;
  final ValueNotifier<String?> focusedLegKey;
  final ValueNotifier<int?> selectedPosition;
  final String? homeAirport;
  final bool isOffline;
  final bool readOnly;
  final Map<int, String> segmentLabels;
  final void Function(int? day) onAddPlace;
  final void Function(String groupKey) onRevealGroup;
  final void Function(String groupKey) onRevealCityHeader;
  final void Function(String? legKey) onSetFocusedLeg;
  final VoidCallback onOpenFullMap;
  final void Function(String message) onShowSnack;
  final String? Function(TripDerivation) clampLegKey;

  const TripDetailMapBand({
    super.key,
    required this.trip,
    required this.derivation,
    required this.expandable,
    required this.live,
    required this.focusedLegKey,
    required this.selectedPosition,
    required this.homeAirport,
    required this.isOffline,
    required this.readOnly,
    required this.segmentLabels,
    required this.onAddPlace,
    required this.onRevealGroup,
    required this.onRevealCityHeader,
    required this.onSetFocusedLeg,
    required this.onOpenFullMap,
    required this.onShowSnack,
    required this.clampLegKey,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final trip = this.trip;
    final expandable = this.expandable;
    final derivation = this.derivation;
    final endpoints = derivation.homeLegEndpoints;
    final legChips = derivation.legChips;
    // The strip and focus exist only with ≥2 legs — below that the
    // destination-overview mode never engages, so "All" and "the one leg"
    // would draw the identical map.
    final hasChips = legChips.length >= 2;
    String labelFor(String key) {
      for (final c in legChips) {
        if (c.key == key) return c.label;
      }
      return key;
    }

    // Focus + selection live in ValueNotifiers: this builder — not the whole
    // screen — is what a leg-chip tap or pin/row selection rebuilds. The
    // leg-filtered lists come from the derivation's lazy per-leg caches, so
    // a selection-only rebuild passes TripMap the identical lists and its
    // marker cache skips re-clustering.
    final card = ListenableBuilder(
      listenable: Listenable.merge([focusedLegKey, selectedPosition]),
      builder: (context, _) {
        final focusKey = clampLegKey(derivation);
        // Consumer, not the screen's ref: homeOverlayFor watches the
        // home-airport resolution provider, and that watch belongs to the
        // map subtree — resolution landing must not rebuild the screen.
        Widget map = Consumer(
          builder: (context, ref, _) {
            if (!live) {
              // Deferred first frame (see [live]): paint the canvas the
              // unloaded map would — no provider watches, no [TripMap], no
              // tile traffic — and let the frame after it mount the rest.
              return const SizedBox.expand(
                  child: ColoredBox(color: appMapBackground));
            }
            final candidates = homeOverlayFor(
              ref,
              homeAirport: homeAirport,
              travelMode: trip.travelMode,
              tripOrigin: trip.origin,
              tripOriginAirport: trip.originAirport,
              tripReturnAirport: trip.returnAirport,
              focusedLegIndex:
                  focusKey == null ? null : derivation.legIndexOf(focusKey),
              legCount: derivation.legs.length,
              firstCityPoint: endpoints.first,
              lastCityPoint: endpoints.last,
            );
            // The inline card defaults the overlay OFF at every width: the
            // hop home is context, not the trip, so the destinations own the
            // frame until the traveler toggles it on (a choice the shared
            // provider then carries to the full-screen map too).
            final showHome = homeOverlayVisible(
              choice: ref.watch(homeOverlayChoiceProvider),
            );
            return TripMap(
              items: derivation.legFilteredItems(focusKey),
              accommodations: derivation.legFilteredStays(focusKey),
              destinations:
                  focusKey == null ? derivation.mapDestinations : null,
              selectedPosition: selectedPosition.value,
              // Unfiltered by leg: TripMap's position+1 adjacency guard
              // already keeps labels within a city.
              segmentLabels: segmentLabels,
              home: showHome ? candidates : const [],
              homeShown: showHome,
              // Narrow preview (expandable) deliberately gets no toggle:
              // interactive:false suppresses the controls anyway, and the
              // full-screen map — one tap away — carries it.
              onToggleHome: (expandable || candidates.isEmpty)
                  ? null
                  : () => ref
                      .read(homeOverlayChoiceProvider.notifier)
                      .setShown(!showHome),
              fitSignature: focusKey,
              // Keep fitted markers clear of the chip row overlaid below.
              topOverlayInset: hasChips ? MapLegChips.mapTopInset : 0,
              interactive: !expandable,
              emptyLabel: focusKey == null
                  ? l10n.tripNoMappedPlaces
                  : l10n.tripNoPlacesInLeg(labelFor(focusKey)),
              // The preview absorbs pointers, so its empty-state add-place
              // hint and CTA would invite an action it can't take (tapping
              // opens the full-screen map, which has both); dropping them
              // also keeps the empty state inside the 180px preview card.
              // The pinned "+ Add place" button sits right below anyway.
              emptyMessage:
                  (expandable || isOffline) ? null : l10n.tripAddPlaceMapHint,
              emptyAction: (expandable || isOffline || readOnly)
                  ? null
                  : FilledButton.tonalIcon(
                      onPressed: () =>
                          onAddPlace(derivation.dayForLeg(focusKey)),
                      icon: const Icon(Icons.add, size: 18),
                      label: Text(l10n.tripAddPlace),
                    ),
              onPinTap: expandable
                  ? null
                  : (pos) {
                      final it =
                          trip.items!.firstWhere((i) => i.position == pos);
                      selectedPosition.value = pos;
                      // The highlighted row can only be seen if its run
                      // renders: un-collapse the tapped item's group in
                      // case the user closed it. Never a focus write —
                      // that would refit the camera out from under the
                      // zoom-to-pin move (the invariant holds by
                      // construction: nothing here touches
                      // focusedLegKey). Selection itself is
                      // notifier-driven, so setState only on a real
                      // un-collapse.
                      final d = derivation;
                      final groupKey =
                          d.groupKeyForLeg(d.legKeyOfPosition(pos));
                      if (groupKey != null) onRevealGroup(groupKey);
                      onShowSnack(it.name);
                    },
              // Region-pin navigation (All overview only — that's the only
              // mode destination pins render in): scroll the list to the
              // region's group. Deliberately NO focus write: focusing
              // would swap the map to per-item pins and delete the very
              // pins under the pointer; the camera must not move either.
              onDestinationTap: expandable
                  ? null // phone preview: AbsorbPointer'd, tap opens full map
                  : (legKey) {
                      final d = derivation;
                      final groupKey = d.groupKeyForLeg(legKey);
                      if (groupKey == null) return; // lens dropped the leg
                      onRevealGroup(groupKey);
                      // Under a bookings/budget lens no header builds and
                      // the scroll no-ops harmlessly (the chip-tap stance:
                      // no lens exit).
                      onRevealCityHeader(groupKey);
                    },
              onExpand: expandable ? null : onOpenFullMap,
            );
          },
        );
        if (expandable) {
          map = GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onOpenFullMap,
            child: AbsorbPointer(child: map),
          );
        }
        return ClipRRect(
          borderRadius: AppRadius.lgAll,
          child: Stack(
            children: [
              Positioned.fill(child: map),
              // Above the map's gesture layer, so chip taps and row scrolls
              // never pan the map.
              Positioned(
                top: 8,
                left: 8,
                right: 8,
                child: MapLegChips(
                  legs: legChips,
                  selected: focusKey,
                  mappedLegKeys: derivation.mappedLegKeys,
                  onSelected: onSetFocusedLeg,
                ),
              ),
              if (expandable)
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: MapControlButton(
                    icon: Icons.fullscreen,
                    tooltip: l10n.tripExpandMap,
                    onTap: onOpenFullMap,
                  ),
                ),
            ],
          ),
        );
      },
    );
    // Repaint-isolate the card: chip taps, pin selections and camera moves
    // rebuild and repaint this subtree (card chrome + chip strip —
    // flutter_map keeps its own internal boundary), and without a boundary
    // each would dirty the whole page layer. The card scrolls with the page
    // on every width now (the map-row redesign unpinned the wide band), so
    // the old every-scroll-frame re-record is gone — the boundary stays for
    // the tap-time isolation. Inside the method so both call sites (wide
    // map row, scroll-away phone card) are covered.
    return RepaintBoundary(child: card);
  }
}
