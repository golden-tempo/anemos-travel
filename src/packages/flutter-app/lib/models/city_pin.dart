import 'package:json_annotation/json_annotation.dart';

part 'city_pin.g.dart';

/// One located hub city on a list-row payload (specs/trips-page-insights):
/// the trips-list lateral emits a pin per hub whose itinerary has a real
/// coordinate — the (0,0) no-location sentinel never reaches the wire, so
/// [lat]/[lng] are non-nullable here. Pins arrive in first-appearance order
/// and are a subset of [Trip.cities].
@JsonSerializable()
class CityPin {
  final String city;
  final double lat;
  final double lng;

  /// ISO 3166-1 alpha-2 for the country [lat]/[lng] falls in, derived server
  /// side (countryForPoint) — the one derivation for the countries stat in
  /// "Your travels".
  ///
  /// Null on an old server, an offline snapshot cached before this shipped,
  /// and on the rare coordinate that resolves to no country at all. The count
  /// simply omits those pins rather than guessing a country from the city
  /// name, and drops out entirely when none resolve — the same
  /// zero-valued-stat rule the caption already uses.
  final String? country;

  const CityPin({
    required this.city,
    required this.lat,
    required this.lng,
    this.country,
  });

  factory CityPin.fromJson(Map<String, dynamic> json) =>
      _$CityPinFromJson(json);
  Map<String, dynamic> toJson() => _$CityPinToJson(this);
}
