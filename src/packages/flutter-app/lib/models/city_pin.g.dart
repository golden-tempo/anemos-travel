// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'city_pin.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

CityPin _$CityPinFromJson(Map<String, dynamic> json) => CityPin(
      city: json['city'] as String,
      lat: (json['lat'] as num).toDouble(),
      lng: (json['lng'] as num).toDouble(),
      country: json['country'] as String?,
    );

Map<String, dynamic> _$CityPinToJson(CityPin instance) => <String, dynamic>{
      'city': instance.city,
      'lat': instance.lat,
      'lng': instance.lng,
      'country': instance.country,
    };
