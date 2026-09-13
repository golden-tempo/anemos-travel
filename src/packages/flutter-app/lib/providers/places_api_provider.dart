import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/places_api_service.dart';
import 'api_client_provider.dart';

final placesApiServiceProvider = Provider<PlacesApiService>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return PlacesApiService(
    baseUrl: apiClient.baseUrl,
    httpClient: apiClient.httpClient,
  );
});

// Provider for autocomplete search results
final placeAutocompleteProvider = 
    FutureProvider.family<List<dynamic>, String>((ref, input) async {
  if (input.isEmpty) return [];
  
  final placesService = ref.watch(placesApiServiceProvider);
  return await placesService.getAutocomplete(input);
});

// Provider for place search results
final placeSearchProvider = 
    FutureProvider.family<List<dynamic>, String>((ref, query) async {
  if (query.isEmpty) return [];
  
  final placesService = ref.watch(placesApiServiceProvider);
  return await placesService.searchPlaces(query);
});

// Provider for place details
final placeDetailsProvider = 
    FutureProvider.family<dynamic, String>((ref, placeId) async {
  final placesService = ref.watch(placesApiServiceProvider);
  return await placesService.getPlaceDetails(placeId);
});

/// What identifies one "Nearby" lookup (specs/booking-address-prompt): the
/// stay's coordinates plus the category being searched, so switching
/// category re-queries instead of reusing another category's cached family
/// member.
typedef NearbyQuery = ({double latitude, double longitude, String? query});

// Provider for nearby-place results — a location-biased search, distinct
// from [placeSearchProvider]'s plain text search.
final nearbyPlacesProvider =
    FutureProvider.family<List<dynamic>, NearbyQuery>((ref, q) async {
  final placesService = ref.watch(placesApiServiceProvider);
  return await placesService.searchNearby(q.latitude, q.longitude,
      query: q.query);
});
