// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'trip_refine_chat.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

TripRefineChat _$TripRefineChatFromJson(Map<String, dynamic> json) =>
    TripRefineChat(
      messageCount: (json['message_count'] as num).toInt(),
      preview: json['preview'] as String,
      updatedAt: json['updated_at'] as String,
    );

Map<String, dynamic> _$TripRefineChatToJson(TripRefineChat instance) =>
    <String, dynamic>{
      'message_count': instance.messageCount,
      'preview': instance.preview,
      'updated_at': instance.updatedAt,
    };

TripRefineChatDetail _$TripRefineChatDetailFromJson(
        Map<String, dynamic> json) =>
    TripRefineChatDetail(
      tripId: json['trip_id'] as String,
      summary: json['summary'] as String,
      messages: (json['messages'] as List<dynamic>)
          .map((e) => ChatSessionMessage.fromJson(e as Map<String, dynamic>))
          .toList(),
      messageCount: (json['message_count'] as num).toInt(),
      updatedAt: json['updated_at'] as String,
    );

Map<String, dynamic> _$TripRefineChatDetailToJson(
        TripRefineChatDetail instance) =>
    <String, dynamic>{
      'trip_id': instance.tripId,
      'summary': instance.summary,
      'messages': instance.messages.map((e) => e.toJson()).toList(),
      'message_count': instance.messageCount,
      'updated_at': instance.updatedAt,
    };

TripRefineChatHistoryEntry _$TripRefineChatHistoryEntryFromJson(
        Map<String, dynamic> json) =>
    TripRefineChatHistoryEntry(
      id: json['id'] as String,
      preview: json['preview'] as String,
      messageCount: (json['message_count'] as num).toInt(),
      createdAt: json['created_at'] as String,
      updatedAt: json['updated_at'] as String,
    );

Map<String, dynamic> _$TripRefineChatHistoryEntryToJson(
        TripRefineChatHistoryEntry instance) =>
    <String, dynamic>{
      'id': instance.id,
      'preview': instance.preview,
      'message_count': instance.messageCount,
      'created_at': instance.createdAt,
      'updated_at': instance.updatedAt,
    };

TripRefineChatHistory _$TripRefineChatHistoryFromJson(
        Map<String, dynamic> json) =>
    TripRefineChatHistory(
      tripId: json['trip_id'] as String,
      chats: (json['chats'] as List<dynamic>)
          .map((e) =>
              TripRefineChatHistoryEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
    );

Map<String, dynamic> _$TripRefineChatHistoryToJson(
        TripRefineChatHistory instance) =>
    <String, dynamic>{
      'trip_id': instance.tripId,
      'chats': instance.chats.map((e) => e.toJson()).toList(),
    };
