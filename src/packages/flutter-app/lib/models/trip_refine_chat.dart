import 'package:json_annotation/json_annotation.dart';

import 'chat_session.dart';

part 'trip_refine_chat.g.dart';

/// Presence + freshness for the caller's own saved conversation about one trip
/// (specs/trip-refine-memory), as it rides `GET /trips/{id}` in `refine_chat`.
///
/// Deliberately carries **no identifier**: a refine conversation is addressed
/// by its trip and nothing else, so it can never be opened as a freeform plan
/// chat (which would silently drop the trip binding). Not to be confused with
/// [Trip.chatId], the owner's itinerary version-lineage key.
@JsonSerializable()
class TripRefineChat {
  @JsonKey(name: 'message_count')
  final int messageCount;

  /// The assistant's last reply, truncated — what the "Continue chat" row shows.
  final String preview;

  @JsonKey(name: 'updated_at')
  final String updatedAt;

  const TripRefineChat({
    required this.messageCount,
    required this.preview,
    required this.updatedAt,
  });

  factory TripRefineChat.fromJson(Map<String, dynamic> json) =>
      _$TripRefineChatFromJson(json);
  Map<String, dynamic> toJson() => _$TripRefineChatToJson(this);
}

/// The full transcript from `GET /trips/{id}/refine-chat`.
///
/// Messages reuse [ChatSessionMessage] rather than growing a twin: the two
/// endpoints serialize the same server type, so one Dart model keeps them from
/// drifting (docs/zen.md — consume the first implementation).
@JsonSerializable(explicitToJson: true)
class TripRefineChatDetail {
  @JsonKey(name: 'trip_id')
  final String tripId;

  /// Running compaction summary; empty when the conversation was never
  /// compacted. Restored as the resumed session's compactedSummary.
  final String summary;
  final List<ChatSessionMessage> messages;
  @JsonKey(name: 'message_count')
  final int messageCount;
  @JsonKey(name: 'updated_at')
  final String updatedAt;

  const TripRefineChatDetail({
    required this.tripId,
    required this.summary,
    required this.messages,
    required this.messageCount,
    required this.updatedAt,
  });

  factory TripRefineChatDetail.fromJson(Map<String, dynamic> json) =>
      _$TripRefineChatDetailFromJson(json);
  Map<String, dynamic> toJson() => _$TripRefineChatDetailToJson(this);
}

/// One archived conversation in the "Previous chats" menu (#639), as listed
/// by `GET /trips/{id}/refine-chat/history`.
///
/// Unlike [TripRefineChat] this DOES carry an id: a history entry is
/// individually addressable — it is what
/// `POST /trips/{id}/refine-chat/history/{id}` resumes — where the trip's
/// single active conversation never needs one of its own.
@JsonSerializable()
class TripRefineChatHistoryEntry {
  final String id;
  final String preview;
  @JsonKey(name: 'message_count')
  final int messageCount;
  @JsonKey(name: 'created_at')
  final String createdAt;
  @JsonKey(name: 'updated_at')
  final String updatedAt;

  const TripRefineChatHistoryEntry({
    required this.id,
    required this.preview,
    required this.messageCount,
    required this.createdAt,
    required this.updatedAt,
  });

  factory TripRefineChatHistoryEntry.fromJson(Map<String, dynamic> json) =>
      _$TripRefineChatHistoryEntryFromJson(json);
  Map<String, dynamic> toJson() => _$TripRefineChatHistoryEntryToJson(this);
}

/// `GET /trips/{id}/refine-chat/history`: up to 5 past conversations, most
/// recently active first.
@JsonSerializable(explicitToJson: true)
class TripRefineChatHistory {
  @JsonKey(name: 'trip_id')
  final String tripId;
  final List<TripRefineChatHistoryEntry> chats;

  const TripRefineChatHistory({required this.tripId, required this.chats});

  factory TripRefineChatHistory.fromJson(Map<String, dynamic> json) =>
      _$TripRefineChatHistoryFromJson(json);
  Map<String, dynamic> toJson() => _$TripRefineChatHistoryToJson(this);
}
