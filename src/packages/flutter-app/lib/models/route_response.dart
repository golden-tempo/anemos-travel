import 'package:json_annotation/json_annotation.dart';
import 'location.dart';
import 'location_timing.dart';

part 'route_response.g.dart';

@JsonSerializable()
class RouteResponse {
  @JsonKey(name: 'optimized_route')
  final List<Location> optimizedRoute;
  
  @JsonKey(name: 'total_distance_km')
  final double totalDistanceKm;
  
  @JsonKey(name: 'total_travel_time_minutes')
  final int totalTravelTimeMin;
  
  @JsonKey(name: 'total_visit_time_minutes')
  final int totalVisitTimeMin;
  
  @JsonKey(name: 'total_trip_time_minutes')
  final int totalTripTimeMin;
  
  @JsonKey(name: 'location_timings')
  final List<LocationTiming> locationTimings;
  
  @JsonKey(name: 'algorithm_used')
  final String algorithm;
  
  @JsonKey(name: 'original_distance_km')
  final double? originalDistance;
  
  @JsonKey(name: 'improvement_percentage')
  final double? improvementPct;
  
  @JsonKey(name: 'location_count')
  final int locationCount;
  
  final String status;

  /// Names of input locations skipped because coordinate resolution failed
  /// (#577 contract): their timing entries are zeroed, everything else is
  /// real. Absent when every location resolved.
  final List<String>? unresolved;

  const RouteResponse({
    required this.optimizedRoute,
    required this.totalDistanceKm,
    required this.totalTravelTimeMin,
    required this.totalVisitTimeMin,
    required this.totalTripTimeMin,
    required this.locationTimings,
    required this.algorithm,
    this.originalDistance,
    this.improvementPct,
    required this.locationCount,
    required this.status,
    this.unresolved,
  });

  factory RouteResponse.fromJson(Map<String, dynamic> json) =>
      _$RouteResponseFromJson(json);

  Map<String, dynamic> toJson() => _$RouteResponseToJson(this);

  // Helper methods for formatting
  String get totalDistanceFormatted => '${totalDistanceKm.toStringAsFixed(1)} km';
  
  String get totalTravelTimeFormatted {
    if (totalTravelTimeMin < 60) {
      return '${totalTravelTimeMin} min';
    }
    final hours = totalTravelTimeMin ~/ 60;
    final minutes = totalTravelTimeMin % 60;
    return '${hours}h ${minutes}m';
  }
  
  String get totalVisitTimeFormatted {
    if (totalVisitTimeMin < 60) {
      return '${totalVisitTimeMin} min';
    }
    final hours = totalVisitTimeMin ~/ 60;
    final minutes = totalVisitTimeMin % 60;
    return '${hours}h ${minutes}m';
  }
  
  String get totalTripTimeFormatted {
    if (totalTripTimeMin < 60) {
      return '${totalTripTimeMin} min';
    }
    final hours = totalTripTimeMin ~/ 60;
    final minutes = totalTripTimeMin % 60;
    return '${hours}h ${minutes}m';
  }
  
  String get improvementFormatted {
    if (improvementPct == null) return 'N/A';
    return '${improvementPct!.toStringAsFixed(1)}%';
  }

  @override
  String toString() {
    return 'RouteResponse(optimizedRoute: ${optimizedRoute.length} locations, totalDistanceKm: $totalDistanceKm, algorithm: $algorithm, status: $status)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is RouteResponse &&
        other.optimizedRoute == optimizedRoute &&
        other.totalDistanceKm == totalDistanceKm &&
        other.totalTravelTimeMin == totalTravelTimeMin &&
        other.totalVisitTimeMin == totalVisitTimeMin &&
        other.totalTripTimeMin == totalTripTimeMin &&
        other.locationTimings == locationTimings &&
        other.algorithm == algorithm &&
        other.originalDistance == originalDistance &&
        other.improvementPct == improvementPct &&
        other.locationCount == locationCount &&
        other.status == status &&
        other.unresolved == unresolved;
  }

  @override
  int get hashCode {
    return optimizedRoute.hashCode ^
        totalDistanceKm.hashCode ^
        totalTravelTimeMin.hashCode ^
        totalVisitTimeMin.hashCode ^
        totalTripTimeMin.hashCode ^
        locationTimings.hashCode ^
        algorithm.hashCode ^
        originalDistance.hashCode ^
        improvementPct.hashCode ^
        locationCount.hashCode ^
        status.hashCode ^
        unresolved.hashCode;
  }
}
