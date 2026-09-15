import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../theme/app_shadows.dart';
import '../theme/spacing.dart';
import 'app_map.dart';
import 'place_photo_card.dart';

/// One rail card's coordinate, or null when its source carries no usable
/// location. Google places and parking spots (AgentPlace) default `lat`/
/// `lng` to 0 for "no coordinate" rather than making them nullable; local
/// picks and hotel stays use a nullable pair instead. Both shapes collapse
/// through this one helper so callers never re-derive the "0,0 means
/// nothing" convention TripMapBand already relies on.
LatLng? recommendationPoint(double? lat, double? lng) {
  if (lat == null || lng == null) return null;
  if (lat == 0 && lng == 0) return null;
  return LatLng(lat, lng);
}

/// Height of a [ChatRecommendationMap] band.
const double kChatRecommendationMapHeight = 160;

/// A compact satellite map plotting one pin per rail card — the map half of
/// the ChatGPT-style "map + horizontally scrollable tiles, hovering a tile
/// highlights its pin" recommendation surface (#652). [points] is
/// index-aligned with the rail's cards; a null entry draws no pin. Which
/// entry is currently emphasized is read live off [highlighted], which
/// [RecommendationMapStrip] drives from the paired rail's hover state.
///
/// Non-interactive by design: this band sits directly above a horizontally
/// dragged card rail inside the chat's vertical scroll view, so accepting
/// pan/pinch here would fight both of those gestures for the same pointer —
/// the same reason TripMapBand keeps its preview `interactive: false`.
class ChatRecommendationMap extends StatelessWidget {
  final List<LatLng?> points;
  final ValueListenable<int?> highlighted;
  final Color accent;
  final double height;

  const ChatRecommendationMap({
    super.key,
    required this.points,
    required this.highlighted,
    required this.accent,
    this.height = kChatRecommendationMapHeight,
  });

  @override
  Widget build(BuildContext context) {
    final indexed = <int, LatLng>{
      for (final (i, p) in points.indexed)
        if (p != null) i: p,
    };
    if (indexed.isEmpty) return const SizedBox.shrink();
    final coords = indexed.values.toList();
    // A single pin, or several stacked on the exact same coordinate, fit to
    // a zero-area box — flutter_map's CameraFit.bounds divides by that area
    // and throws (see TripMap's _pointsCollapse); center on it instead.
    final collapsed = coords.every((p) =>
        p.latitude == coords.first.latitude &&
        p.longitude == coords.first.longitude);

    return ClipRRect(
      borderRadius: AppRadius.mdAll,
      child: SizedBox(
        height: height,
        child: AppMapVisibilityGate(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final minZoom = appMapMinZoomFor(constraints.maxWidth);
              const noInteraction =
                  InteractionOptions(flags: InteractiveFlag.none);
              final options = collapsed
                  ? appMapOptions(
                      initialCenter: coords.first,
                      initialZoom: 12,
                      minZoom: minZoom,
                      interactionOptions: noInteraction,
                    )
                  : appMapOptions(
                      initialCameraFit: AppCameraFitBounds(
                        bounds: LatLngBounds.fromPoints(coords),
                        padding: const EdgeInsets.all(28),
                      ),
                      minZoom: minZoom,
                      interactionOptions: noInteraction,
                    );
              return FlutterMap(
                options: options,
                children: [
                  ...appMapTileLayers(context),
                  ValueListenableBuilder<int?>(
                    valueListenable: highlighted,
                    builder: (context, hoveredIndex, _) => MarkerLayer(
                      markers: [
                        for (final entry in indexed.entries)
                          Marker(
                            point: entry.value,
                            width: entry.key == hoveredIndex ? 30 : 22,
                            height: entry.key == hoveredIndex ? 30 : 22,
                            child: _RecommendationPin(
                              accent: accent,
                              selected: entry.key == hoveredIndex,
                            ),
                          ),
                      ],
                    ),
                  ),
                  appMapAttribution(),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// A round, white-ringed dot pin — the same face family as TripMap's
/// `_Pin`, minus the category glyph (a chat rail's cards already carry that)
/// and the ordinal face (these pins are never numbered).
class _RecommendationPin extends StatelessWidget {
  final Color accent;
  final bool selected;

  const _RecommendationPin({required this.accent, required this.selected});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: accent,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: selected ? 3 : 2),
        boxShadow: selected ? AppShadows.pinSelected : AppShadows.pin,
      ),
    );
  }
}

/// Pairs a [ChatRecommendationMap] with a [PlacePhotoStrip]: hovering a tile
/// highlights its pin (#652). [points] is index-aligned with [cards] — a
/// card with no coordinate still renders in the rail, it just never earns a
/// pin. Falls back to a bare [PlacePhotoStrip] when nothing in the rail is
/// mappable, since a map with zero pins would be a wasted stack of tiles.
class RecommendationMapStrip extends StatefulWidget {
  final IconData icon;
  final Color accent;
  final String label;
  final VoidCallback? onViewTrip;
  final String? actionLabel;
  final List<LatLng?> points;
  final List<PlacePhotoCard> cards;

  const RecommendationMapStrip({
    super.key,
    required this.icon,
    required this.accent,
    required this.label,
    this.onViewTrip,
    this.actionLabel,
    required this.points,
    required this.cards,
  }) : assert(points.length == cards.length,
            'points must be index-aligned with cards');

  @override
  State<RecommendationMapStrip> createState() => _RecommendationMapStripState();
}

class _RecommendationMapStripState extends State<RecommendationMapStrip> {
  /// Index of the card currently under the pointer, or null. Owned here
  /// (not by the map or the rail) because it is the one piece of state the
  /// pair shares — a hover on card [i] drives pin `i` on the map below.
  final ValueNotifier<int?> _hovered = ValueNotifier<int?>(null);

  @override
  void dispose() {
    _hovered.dispose();
    super.dispose();
  }

  List<Widget> _hoverWiredCards() => [
        for (final (i, card) in widget.cards.indexed)
          MouseRegion(
            onEnter: (_) => _hovered.value = i,
            onExit: (_) {
              if (_hovered.value == i) _hovered.value = null;
            },
            child: card,
          ),
      ];

  @override
  Widget build(BuildContext context) {
    final hasPoints = widget.points.any((p) => p != null);
    final strip = PlacePhotoStrip(
      icon: widget.icon,
      accent: widget.accent,
      label: widget.label,
      onViewTrip: widget.onViewTrip,
      actionLabel: widget.actionLabel,
      cards: hasPoints ? _hoverWiredCards() : widget.cards,
    );
    if (!hasPoints) return strip;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.xs),
          child: ChatRecommendationMap(
            points: widget.points,
            highlighted: _hovered,
            accent: widget.accent,
          ),
        ),
        strip,
      ],
    );
  }
}
