import 'package:json_annotation/json_annotation.dart';
import 'location.dart';

part 'location_timing.g.dart';

@JsonSerializable()
class LocationTiming {
  final Location location;
  
  @JsonKey(name: 'arrival_time', defaultValue: '')
  final String arrivalTime;

  @JsonKey(name: 'departure_time', defaultValue: '')
  final String departureTime;

  @JsonKey(name: 'visit_duration_minutes')
  final int visitDurationMin;

  @JsonKey(name: 'travel_to_next_minutes', defaultValue: 0)
  final int travelToNextMin;

  @JsonKey(name: 'travel_to_next_km', defaultValue: 0.0)
  final double travelToNextKm;

  /// "walk" or "transit"; present exactly when the leg out of this location
  /// was computed (both endpoints resolved). Absent on zeroed legs and on the
  /// last stop of a one-way route — the icon follows this, never a distance
  /// constant (#577 contract).
  @JsonKey(name: 'travel_to_next_mode')
  final String? travelToNextMode;

  const LocationTiming({
    required this.location,
    required this.arrivalTime,
    required this.departureTime,
    required this.visitDurationMin,
    required this.travelToNextMin,
    this.travelToNextKm = 0.0,
    this.travelToNextMode,
  });

  factory LocationTiming.fromJson(Map<String, dynamic> json) =>
      _$LocationTimingFromJson(json);

  Map<String, dynamic> toJson() => _$LocationTimingToJson(this);

  @override
  String toString() {
    return 'LocationTiming(location: ${location.name}, arrivalTime: $arrivalTime, departureTime: $departureTime, visitDurationMin: $visitDurationMin, travelToNextMin: $travelToNextMin, travelToNextKm: $travelToNextKm, travelToNextMode: $travelToNextMode)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is LocationTiming &&
        other.location == location &&
        other.arrivalTime == arrivalTime &&
        other.departureTime == departureTime &&
        other.visitDurationMin == visitDurationMin &&
        other.travelToNextMin == travelToNextMin &&
        other.travelToNextKm == travelToNextKm &&
        other.travelToNextMode == travelToNextMode;
  }

  @override
  int get hashCode {
    return location.hashCode ^
        arrivalTime.hashCode ^
        departureTime.hashCode ^
        visitDurationMin.hashCode ^
        travelToNextMin.hashCode ^
        travelToNextKm.hashCode ^
        travelToNextMode.hashCode;
  }
}
