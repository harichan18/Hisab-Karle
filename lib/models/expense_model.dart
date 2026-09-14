import 'package:cloud_firestore/cloud_firestore.dart';
import 'transaction_model.dart';

class ExpenseModel {
  final String? id;
  final String userId;
  final double amount;
  final String category;
  final String description;
  final DateTime expenseDate;
  final String? receiptUrl;
  final DateTime createdAt;
  final int syncStatus;

  ExpenseModel({
    this.id,
    required this.userId,
    required this.amount,
    required this.category,
    required this.description,
    required this.expenseDate,
    this.receiptUrl,
    required this.createdAt,
    this.syncStatus = SyncStatus.synced,
  });

  Map<String, dynamic> toFirestoreMap() {
    return {
      'userId': userId,
      'amount': amount,
      'category': category,
      'description': description,
      'expenseDate': Timestamp.fromDate(expenseDate),
      if (receiptUrl != null) 'receiptUrl': receiptUrl,
      'createdAt': Timestamp.fromDate(createdAt),
    };
  }

  Map<String, dynamic> toLocalMap() {
    return {
      'id': id,
      'userId': userId,
      'amount': amount,
      'category': category,
      'description': description,
      'expenseDate': expenseDate.toIso8601String(),
      'receiptUrl': receiptUrl,
      'createdAt': createdAt.toIso8601String(),
      'sync_status': syncStatus,
    };
  }

  factory ExpenseModel.fromFirestore(String id, Map<String, dynamic> map) {
    DateTime parseDate(dynamic val) {
      if (val is Timestamp) {
        return val.toDate();
      } else if (val is String) {
        return DateTime.tryParse(val) ?? DateTime.now();
      } else {
        return DateTime.now();
      }
    }

    return ExpenseModel(
      id: id,
      userId: map['userId'] as String? ?? '',
      amount: (map['amount'] as num?)?.toDouble() ?? 0.0,
      category: map['category'] as String? ?? 'Other',
      description: map['description'] as String? ?? '',
      expenseDate: parseDate(map['expenseDate']),
      receiptUrl: map['receiptUrl'] as String?,
      createdAt: parseDate(map['createdAt']),
      syncStatus: SyncStatus.synced,
    );
  }

  factory ExpenseModel.fromLocalMap(Map<String, dynamic> map) {
    return ExpenseModel(
      id: map['id'] as String?,
      userId: map['userId'] as String? ?? '',
      amount: (map['amount'] as num?)?.toDouble() ?? 0.0,
      category: map['category'] as String? ?? 'Other',
      description: map['description'] as String? ?? '',
      expenseDate:
          DateTime.tryParse(map['expenseDate'] as String? ?? '') ??
          DateTime.now(),
      receiptUrl: map['receiptUrl'] as String?,
      createdAt:
          DateTime.tryParse(map['createdAt'] as String? ?? '') ??
          DateTime.now(),
      syncStatus: (map['sync_status'] as num?)?.toInt() ?? SyncStatus.synced,
    );
  }

  ExpenseModel copyWith({
    String? id,
    String? userId,
    double? amount,
    String? category,
    String? description,
    DateTime? expenseDate,
    String? receiptUrl,
    DateTime? createdAt,
    int? syncStatus,
  }) {
    return ExpenseModel(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      amount: amount ?? this.amount,
      category: category ?? this.category,
      description: description ?? this.description,
      expenseDate: expenseDate ?? this.expenseDate,
      receiptUrl: receiptUrl ?? this.receiptUrl,
      createdAt: createdAt ?? this.createdAt,
      syncStatus: syncStatus ?? this.syncStatus,
    );
  }
}
