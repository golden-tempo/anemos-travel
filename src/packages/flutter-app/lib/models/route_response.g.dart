// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'route_response.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

RouteResponse _$RouteResponseFromJson(Map<String, dynamic> json) =>
    RouteResponse(
      optimizedRoute: (json['optimized_route'] as List<dynamic>)
          .map((e) => Location.fromJson(e as Map<String, dynamic>))
          .toList(),
      totalDistanceKm: (json['total_distance_km'] as num).toDouble(),
      totalTravelTimeMin: (json['total_travel_time_minutes'] as num).toInt(),
      totalVisitTimeMin: (json['total_visit_time_minutes'] as num).toInt(),
      totalTripTimeMin: (json['total_trip_time_minutes'] as num).toInt(),
      locationTimings: (json['location_timings'] as List<dynamic>)
          .map((e) => LocationTiming.fromJson(e as Map<String, dynamic>))
          .toList(),
      algorithm: json['algorithm_used'] as String,
      originalDistance: (json['original_distance_km'] as num?)?.toDouble(),
      improvementPct: (json['improvement_percentage'] as num?)?.toDouble(),
      locationCount: (json['location_count'] as num).toInt(),
      status: json['status'] as String,
      unresolved: (json['unresolved'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
    );

Map<String, dynamic> _$RouteResponseToJson(RouteResponse instance) =>
    <String, dynamic>{
      'optimized_route': instance.optimizedRoute,
      'total_distance_km': instance.totalDistanceKm,
      'total_travel_time_minutes': instance.totalTravelTimeMin,
      'total_visit_time_minutes': instance.totalVisitTimeMin,
      'total_trip_time_minutes': instance.totalTripTimeMin,
      'location_timings': instance.locationTimings,
      'algorithm_used': instance.algorithm,
      'original_distance_km': instance.originalDistance,
      'improvement_percentage': instance.improvementPct,
      'location_count': instance.locationCount,
      'status': instance.status,
      'unresolved': instance.unresolved,
    };
