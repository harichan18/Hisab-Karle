class FirestoreFriendProfile {
  const FirestoreFriendProfile({
    required this.uid,
    required this.name,
    required this.email,
    required this.friendCode,
  });

  final String uid;
  final String name;
  final String email;
  final String friendCode;

  String get displayName {
    if (name.trim().isNotEmpty) {
      return name.trim();
    }
    if (email.trim().isNotEmpty) {
      return email.trim();
    }
    if (friendCode.trim().isNotEmpty) {
      return friendCode.trim();
    }
    return uid;
  }
}

class FriendListItem {
  const FriendListItem({
    required this.name,
    this.uid,
    this.localId,
    this.isLocal = false,
    this.email = '',
    this.friendCode = '',
    this.fromFirestore = false,
    this.nickname,
  });

  final String name;
  final String? uid;
  final String? localId;
  final bool isLocal;
  final String email;
  final String friendCode;
  final bool fromFirestore;
  final String? nickname;

  String get displayName {
    if (nickname != null && nickname!.trim().isNotEmpty) {
      return nickname!.trim();
    }
    return name;
  }
}

class LocalFriendModel {
  final String id;
  final String name;
  final String userId;
  final DateTime createdAt;
  final DateTime updatedAt;

  const LocalFriendModel({
    required this.id,
    required this.name,
    required this.userId,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'userId': userId,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  factory LocalFriendModel.fromMap(Map<String, dynamic> map) {
    return LocalFriendModel(
      id: map['id'] as String,
      name: map['name'] as String,
      userId: map['userId'] as String? ?? '',
      createdAt: DateTime.tryParse(map['createdAt'] as String? ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(map['updatedAt'] as String? ?? '') ?? DateTime.now(),
    );
  }
}
