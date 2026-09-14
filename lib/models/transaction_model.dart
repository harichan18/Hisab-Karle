class SyncStatus {
  static const int synced = 0;
  static const int pending = 1;
  static const int syncing = 2;
  static const int failed = 3;
}

class TransactionModel {
  final int? id;
  final String? firebaseId;
  final String? peerUserId;
  final String? createdBy;
  final String? receiptUrl;
  final String? receiptPath;
  final String friendName;
  final double amount;
  final String note;
  final String date;
  final bool iGave;
  final int syncStatus;

  TransactionModel({
    this.id,
    this.firebaseId,
    this.peerUserId,
    this.createdBy,
    this.receiptUrl,
    this.receiptPath,
    required this.friendName,
    required this.amount,
    required this.note,
    required this.date,
    required this.iGave,
    this.syncStatus = SyncStatus.synced,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      if (firebaseId != null) 'firebaseId': firebaseId,
      if (peerUserId != null) 'peerUserId': peerUserId,
      if (createdBy != null) 'createdBy': createdBy,
      if (receiptUrl != null) 'receiptUrl': receiptUrl,
      'friendName': friendName,
      'amount': amount,
      'note': note,
      'date': date,
      'iGave': iGave ? 1 : 0,
      'receiptPath': receiptPath,
      'sync_status': syncStatus,
    };
  }

  Map<String, dynamic> toFirestoreMap() {
    return {
      'friendName': friendName,
      'amount': amount,
      'note': note,
      'date': date,
      'iGave': iGave,
      if (peerUserId != null) 'peerUserId': peerUserId,
      if (createdBy != null) 'createdBy': createdBy,
      if (receiptPath != null) 'receiptPath': receiptPath,
      if (receiptUrl != null) 'receiptUrl': receiptUrl,
    };
  }

  factory TransactionModel.fromMap(Map<String, dynamic> map) {
    return TransactionModel(
      id: map['id'],
      firebaseId: map['firebaseId'] as String?,
      peerUserId: map['peerUserId'] as String?,
      createdBy: map['createdBy'] as String?,
      receiptUrl: map['receiptUrl'] as String?,
      receiptPath: map['receiptPath'] as String?,
      friendName: map['friendName'],
      amount: (map['amount'] as num).toDouble(),
      note: map['note'],
      date: map['date'],
      iGave: map['iGave'] == 1,
      syncStatus: (map['sync_status'] as num?)?.toInt() ?? SyncStatus.synced,
    );
  }

  factory TransactionModel.fromFirestore(
    String firebaseId,
    Map<String, dynamic> map,
  ) {
    return TransactionModel(
      firebaseId: firebaseId,
      peerUserId: map['peerUserId'] as String?,
      createdBy: map['createdBy'] as String?,
      receiptUrl: map['receiptUrl'] as String?,
      receiptPath: map['receiptPath'] as String?,
      friendName: map['friendName'] as String? ?? '',
      amount: (map['amount'] as num?)?.toDouble() ?? 0.0,
      note: map['note'] as String? ?? '',
      date: map['date'] as String? ?? '',
      iGave: map['iGave'] == true,
      syncStatus: SyncStatus.synced,
    );
  }

  TransactionModel copyWith({
    int? id,
    String? firebaseId,
    String? peerUserId,
    String? createdBy,
    String? receiptUrl,
    String? receiptPath,
    String? friendName,
    double? amount,
    String? note,
    String? date,
    bool? iGave,
    int? syncStatus,
  }) {
    return TransactionModel(
      id: id ?? this.id,
      firebaseId: firebaseId ?? this.firebaseId,
      peerUserId: peerUserId ?? this.peerUserId,
      createdBy: createdBy ?? this.createdBy,
      receiptUrl: receiptUrl ?? this.receiptUrl,
      receiptPath: receiptPath ?? this.receiptPath,
      friendName: friendName ?? this.friendName,
      amount: amount ?? this.amount,
      note: note ?? this.note,
      date: date ?? this.date,
      iGave: iGave ?? this.iGave,
      syncStatus: syncStatus ?? this.syncStatus,
    );
  }
}

class DeletedEntryModel {
  final int? id;
  final String? firebaseId;
  final int originalEntryId;
  final String? originalFirebaseId;
  final String? peerUserId;
  final int personId;
  final String friendName;
  final String date;
  final String note;
  final double amount;
  final bool isGiven;
  final String clearedDate;
  final String? receiptUrl;
  final String? receiptPath;

  DeletedEntryModel({
    this.id,
    this.firebaseId,
    required this.originalEntryId,
    this.originalFirebaseId,
    this.peerUserId,
    required this.personId,
    required this.friendName,
    required this.date,
    required this.note,
    required this.amount,
    required this.isGiven,
    required this.clearedDate,
    this.receiptUrl,
    this.receiptPath,
  });

  factory DeletedEntryModel.fromMap(Map<String, dynamic> map) {
    return DeletedEntryModel(
      id: map['id'],
      originalEntryId: map['originalEntryId'],
      personId: map['personId'],
      friendName: map['friendName'] ?? '',
      date: map['date'],
      note: map['note'],
      amount: (map['amount'] as num).toDouble(),
      isGiven: map['isGiven'] == 1,
      clearedDate: map['clearedDate'],
      receiptUrl: map['receiptUrl'] as String?,
      receiptPath: map['receiptPath'] as String?,
      peerUserId: map['peerUserId'] as String?,
    );
  }

  Map<String, dynamic> toFirestoreMap() {
    return {
      'originalEntryId': originalEntryId,
      'originalFirebaseId': originalFirebaseId,
      'personId': personId,
      if (peerUserId != null) 'peerUserId': peerUserId,
      'friendName': friendName,
      'date': date,
      'note': note,
      'amount': amount,
      'isGiven': isGiven,
      'clearedDate': clearedDate,
      if (receiptPath != null) 'receiptPath': receiptPath,
      if (receiptUrl != null) 'receiptUrl': receiptUrl,
    };
  }

  factory DeletedEntryModel.fromFirestore(
    String firebaseId,
    Map<String, dynamic> map,
  ) {
    return DeletedEntryModel(
      firebaseId: firebaseId,
      originalEntryId: (map['originalEntryId'] as num?)?.toInt() ?? 0,
      originalFirebaseId: map['originalFirebaseId'] as String?,
      peerUserId: map['peerUserId'] as String?,
      personId: (map['personId'] as num?)?.toInt() ?? 0,
      friendName: map['friendName'] as String? ?? '',
      date: map['date'] as String? ?? '',
      note: map['note'] as String? ?? '',
      amount: (map['amount'] as num?)?.toDouble() ?? 0.0,
      isGiven: map['isGiven'] == true,
      clearedDate: map['clearedDate'] as String? ?? '',
      receiptUrl: map['receiptUrl'] as String?,
      receiptPath: map['receiptPath'] as String?,
    );
  }
}
