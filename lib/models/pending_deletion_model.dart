import 'dart:convert';

/// Represents a durable local record of an intended deletion that must be
/// synchronized with Cloud Firestore.
class PendingDeletionModel {
  final int? id;
  final String userId;
  final String type; // 'friend' or 'transaction'
  final String friendName;
  final String? friendUid;
  final String? localFriendId;
  final List<String> firebaseIds;
  final DateTime createdAt;

  const PendingDeletionModel({
    this.id,
    required this.userId,
    required this.type,
    required this.friendName,
    this.friendUid,
    this.localFriendId,
    required this.firebaseIds,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'userId': userId,
      'type': type,
      'friendName': friendName,
      'friendUid': friendUid,
      'localFriendId': localFriendId,
      'firebaseIds': jsonEncode(firebaseIds),
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory PendingDeletionModel.fromMap(Map<String, dynamic> map) {
    List<String> parsedIds = [];
    final rawIds = map['firebaseIds'] as String?;
    if (rawIds != null && rawIds.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawIds);
        if (decoded is List) {
          parsedIds = decoded.map((e) => e.toString()).toList();
        }
      } catch (_) {
        parsedIds = rawIds
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
      }
    }

    return PendingDeletionModel(
      id: map['id'] as int?,
      userId: map['userId'] as String? ?? '',
      type: map['type'] as String? ?? 'friend',
      friendName: map['friendName'] as String? ?? '',
      friendUid: map['friendUid'] as String?,
      localFriendId: map['localFriendId'] as String?,
      firebaseIds: parsedIds,
      createdAt:
          DateTime.tryParse(map['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}
