import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/place_search_result.dart';
import '../models/place_autocomplete_result.dart';
import '../models/place_details_result.dart';

class PlacesApiService {
  final String baseUrl;
  final http.Client httpClient;

  PlacesApiService({
    required this.baseUrl,
    http.Client? httpClient,
  }) : httpClient = httpClient ?? http.Client();

  /// Search for places by text query
  Future<List<PlaceSearchResult>> searchPlaces(String query) async {
    try {
      final uri = Uri.parse('$baseUrl/places/search').replace(
        queryParameters: {'q': query},
      );

      final response = await httpClient.get(uri);

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = json.decode(response.body);
        
        if (data['status'] == 'success' && data['results'] != null) {
          final List<dynamic> resultsJson = data['results'];
          return resultsJson
              .map((json) => PlaceSearchResult.fromJson(json))
              .toList();
        } else {
          throw Exception('API returned error: ${data['status']}');
        }
      } else {
        throw Exception('HTTP ${response.statusCode}: ${response.body}');
      }
    } catch (e) {
      throw Exception('Failed to search places: $e');
    }
  }

  /// Search for real places near a coordinate — the trip page's "Nearby"
  /// action on a confirmed stay (specs/booking-address-prompt), the same
  /// location-biased Text Search the chat agent's search_nearby tool uses.
  /// [query] defaults server-side to a mixed dining/things-to-do search when
  /// omitted.
  Future<List<PlaceSearchResult>> searchNearby(
    double latitude,
    double longitude, {
    String? query,
  }) async {
    try {
      final uri = Uri.parse('$baseUrl/places/nearby').replace(
        queryParameters: {
          'lat': '$latitude',
          'lng': '$longitude',
          if (query != null && query.isNotEmpty) 'q': query,
        },
      );

      final response = await httpClient.get(uri);

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = json.decode(response.body);

        if (data['status'] == 'success' && data['results'] != null) {
          final List<dynamic> resultsJson = data['results'];
          return resultsJson
              .map((json) => PlaceSearchResult.fromJson(json))
              .toList();
        } else {
          throw Exception('API returned error: ${data['status']}');
        }
      } else {
        throw Exception('HTTP ${response.statusCode}: ${response.body}');
      }
    } catch (e) {
      throw Exception('Failed to search nearby places: $e');
    }
  }

  /// Get autocomplete suggestions for place input
  Future<List<PlaceAutocompleteResult>> getAutocomplete(String input) async {
    try {
      final uri = Uri.parse('$baseUrl/places/autocomplete').replace(
        queryParameters: {'input': input},
      );

      final response = await httpClient.get(uri);

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = json.decode(response.body);
        
        if (data['status'] == 'success' && data['predictions'] != null) {
          final List<dynamic> predictionsJson = data['predictions'];
          return predictionsJson
              .map((json) => PlaceAutocompleteResult.fromJson(json))
              .toList();
        } else {
          throw Exception('API returned error: ${data['status']}');
        }
      } else {
        throw Exception('HTTP ${response.statusCode}: ${response.body}');
      }
    } catch (e) {
      throw Exception('Failed to get autocomplete: $e');
    }
  }

  /// Get detailed place information by place ID
  Future<PlaceDetailsResult> getPlaceDetails(String placeId) async {
    try {
      final uri = Uri.parse('$baseUrl/places/details').replace(
        queryParameters: {'place_id': placeId},
      );

      final response = await httpClient.get(uri);

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = json.decode(response.body);
        
        if (data['status'] == 'success' && data['result'] != null) {
          return PlaceDetailsResult.fromJson(data['result']);
        } else {
          throw Exception('API returned error: ${data['status']}');
        }
      } else {
        throw Exception('HTTP ${response.statusCode}: ${response.body}');
      }
    } catch (e) {
      throw Exception('Failed to get place details: $e');
    }
  }
}
