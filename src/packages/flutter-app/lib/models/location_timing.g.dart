// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'location_timing.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

LocationTiming _$LocationTimingFromJson(Map<String, dynamic> json) =>
    LocationTiming(
      location: Location.fromJson(json['location'] as Map<String, dynamic>),
      arrivalTime: json['arrival_time'] as String? ?? '',
      departureTime: json['departure_time'] as String? ?? '',
      visitDurationMin: (json['visit_duration_minutes'] as num).toInt(),
      travelToNextMin: (json['travel_to_next_minutes'] as num?)?.toInt() ?? 0,
      travelToNextKm: (json['travel_to_next_km'] as num?)?.toDouble() ?? 0.0,
      travelToNextMode: json['travel_to_next_mode'] as String?,
    );

Map<String, dynamic> _$LocationTimingToJson(LocationTiming instance) =>
    <String, dynamic>{
      'location': instance.location,
      'arrival_time': instance.arrivalTime,
      'departure_time': instance.departureTime,
      'visit_duration_minutes': instance.visitDurationMin,
      'travel_to_next_minutes': instance.travelToNextMin,
      'travel_to_next_km': instance.travelToNextKm,
      'travel_to_next_mode': instance.travelToNextMode,
    };
