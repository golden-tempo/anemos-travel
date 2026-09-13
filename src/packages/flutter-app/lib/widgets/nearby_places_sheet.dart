import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../models/place_search_result.dart';
import '../providers/places_api_provider.dart';
import '../theme/spacing.dart';
import '../utils/tracked_launch.dart';

/// Opens a bottom sheet of real places near [latitude]/[longitude] —
/// (specs/booking-address-prompt): once a confirmed stay has coordinates
/// (from the address the traveler entered when checking it booked), this is
/// the trip page's "recommend things nearby" surface, the same
/// location-biased search the chat agent's search_nearby tool gives it.
Future<void> showNearbyPlacesSheet(
  BuildContext context, {
  required double latitude,
  required double longitude,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => _NearbyPlacesSheet(latitude: latitude, longitude: longitude),
  );
}

class _NearbyPlacesSheet extends ConsumerWidget {
  final double latitude;
  final double longitude;

  const _NearbyPlacesSheet({required this.latitude, required this.longitude});

  Future<void> _openDirections(
      BuildContext context, PlaceSearchResult place) async {
    final query = place.placeId.isNotEmpty
        ? Uri.encodeComponent('${place.name}, ${place.address}')
        : '${place.latitude},${place.longitude}';
    final url =
        'https://www.google.com/maps/search/?api=1&query=$query'
        '${place.placeId.isNotEmpty ? '&query_place_id=${place.placeId}' : ''}';
    await trackedLaunchUrl(
      context,
      url,
      provider: 'google_maps',
      surface: 'bookings_nearby',
      webOnlyWindowName: '_self',
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final results =
        ref.watch(nearbyPlacesProvider((latitude: latitude, longitude: longitude, query: null)));
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: AppSpacing.lg,
          right: AppSpacing.lg,
          top: AppSpacing.lg,
          bottom: AppSpacing.lg,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.nearbyTitle, style: theme.textTheme.titleMedium),
              const SizedBox(height: AppSpacing.md),
              Flexible(
                child: results.when(
                  data: (list) {
                    final places = list.cast<PlaceSearchResult>();
                    if (places.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        child: Text(l10n.nearbyEmpty),
                      );
                    }
                    return ListView.builder(
                      shrinkWrap: true,
                      itemCount: places.length,
                      itemBuilder: (context, i) {
                        final place = places[i];
                        return ListTile(
                          leading: const Icon(Icons.place_outlined),
                          title: Text(place.name),
                          subtitle:
                              place.address.isEmpty ? null : Text(place.address),
                          trailing: IconButton(
                            icon: const Icon(Icons.directions_outlined),
                            tooltip: l10n.nearbyDirections,
                            onPressed: () => _openDirections(context, place),
                          ),
                        );
                      },
                    );
                  },
                  loading: () => const Padding(
                    padding: EdgeInsets.all(AppSpacing.lg),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  error: (e, _) => Padding(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    child: Text(l10n.nearbyError,
                        style: TextStyle(color: theme.colorScheme.error)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
