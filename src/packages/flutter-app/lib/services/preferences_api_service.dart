import 'dart:convert';
import '../models/traveler_preferences.dart';
import 'api_client.dart';

/// Wraps the authenticated /preferences endpoints (bearer token from ApiClient).
class PreferencesApiService {
  final ApiClient apiClient;

  PreferencesApiService(this.apiClient);

  /// Boot-critical (home airport rides on this): [ApiClient.send] gives it a
  /// timeout + bounded retry; HTTP failures throw a typed [ApiException].
  Future<TravelerPreferences> getPreferences() async {
    final res = await apiClient.send('GET', '/preferences');
    return TravelerPreferences.fromJson(jsonDecode(res.body));
  }

  Future<TravelerPreferences> savePreferences({
    String? budget,
    String? pace,
    required List<String> interests,
    String? homeAirport,
    String? profileNotes,
    String? workStyle,
    String? fitnessRoutine,
    String? outdoorIntensity,
    // A list since 00079. Null omits (keep stored); a list — including an
    // empty one — replaces, matching how `interests` above behaves.
    List<String>? companions,
    String? baggage,
    String? gender,
    String? passportCountry,
    String? residenceCountry,
  }) async {
    final res = await apiClient.httpClient.put(
      Uri.parse('${apiClient.baseUrl}/preferences'),
      headers: apiClient.jsonHeaders(json: true),
      body: jsonEncode({
        'budget': budget,
        'pace': pace,
        'interests': interests,
        'home_airport': homeAirport,
        'profile_notes': profileNotes,
        'work_style': workStyle,
        'fitness_routine': fitnessRoutine,
        'outdoor_intensity': outdoorIntensity,
        // Sent as-is: null omits, [] clears. jsonEncode maps both to the
        // shapes the handler's *[]string already distinguishes.
        'companions': companions,
        'baggage': baggage,
        // null keeps the stored value; '' clears it (00076's clear flag).
        'gender': gender,
        // null keeps the stored value; no clear path yet (00081), same as
        // budget/pace/work_style above.
        'passport_country': passportCountry,
        'residence_country': residenceCountry,
      }),
    );
    if (res.statusCode == 200) {
      return TravelerPreferences.fromJson(jsonDecode(res.body));
    }
    throw Exception('Failed to save preferences (${res.statusCode})');
  }
}
