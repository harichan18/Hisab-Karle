import 'package:firebase_auth/firebase_auth.dart';
import '../../models/transaction_model.dart';

String currentUserDisplayName() {
  final user = FirebaseAuth.instance.currentUser;
  final displayName = user?.displayName?.trim() ?? '';
  if (displayName.isNotEmpty) {
    return displayName;
  }

  final email = user?.email?.trim() ?? '';
  if (email.isNotEmpty) {
    return email;
  }

  return user?.uid ?? '';
}

TransactionModel normalizeTransactionPerspective(TransactionModel transaction) {
  return transaction;
}

String transactionDisplayFriendName(TransactionModel transaction) {
  final currentUser = FirebaseAuth.instance.currentUser;
  if (currentUser == null) {
    return transaction.friendName;
  }

  final currentDisplayName = currentUserDisplayName();
  if (currentDisplayName.isEmpty) {
    return transaction.friendName;
  }

  if (transaction.peerUserId == currentUser.uid &&
      transaction.friendName.trim().toLowerCase() !=
          currentDisplayName.trim().toLowerCase()) {
    return currentDisplayName;
  }

  return transaction.friendName;
}

bool transactionDisplayIsGiven(TransactionModel transaction) {
  final currentUser = FirebaseAuth.instance.currentUser;
  if (currentUser == null) {
    return transaction.iGave;
  }

  final currentDisplayName = currentUserDisplayName();
  if (currentDisplayName.isEmpty) {
    return transaction.iGave;
  }

  if (transaction.peerUserId == currentUser.uid &&
      transaction.friendName.trim().toLowerCase() !=
          currentDisplayName.trim().toLowerCase()) {
    return !transaction.iGave;
  }

  return transaction.iGave;
}

/// Merges remote transactions from Firestore with local transactions from SQLite.
///
/// Guarantees:
/// 1. Stable deduplication using [firebaseId] as primary identity, falling back to [id].
/// 2. When a transaction exists both remotely and locally, the synced representation
///    is preferred while preserving local receiptPath if remote is null.
/// 3. Local pending transactions are never removed merely because they are absent from
///    the current remote/Firestore snapshot.
/// 4. Output is sorted in reverse-chronological order (newest date first, then highest id).
List<TransactionModel> mergeTransactions({
  required List<TransactionModel> remote,
  required List<TransactionModel> local,
}) {
  final Map<String, TransactionModel> byFirebaseId = {};
  final List<TransactionModel> unkeyed = [];

  // 1. Index all remote transactions
  for (final tx in remote) {
    final fid = tx.firebaseId?.trim();
    if (fid != null && fid.isNotEmpty) {
      byFirebaseId[fid] = tx;
    } else {
      unkeyed.add(tx);
    }
  }

  // 2. Merge local transactions
  for (final localTx in local) {
    final fid = localTx.firebaseId?.trim();
    if (fid != null && fid.isNotEmpty) {
      if (byFirebaseId.containsKey(fid)) {
        // If already present remotely, preserve local receiptPath if remote lacks it
        final existing = byFirebaseId[fid]!;
        if (existing.receiptPath == null && localTx.receiptPath != null) {
          byFirebaseId[fid] = existing.copyWith(
            receiptPath: localTx.receiptPath,
          );
        }
      } else {
        // Not in remote snapshot yet (e.g., pending offline transaction) -> preserve!
        byFirebaseId[fid] = localTx;
      }
    } else {
      // Unkeyed transaction: deduplicate by SQLite local id if present
      final alreadyPresent = unkeyed.any((item) =>
          item.id != null && localTx.id != null && item.id == localTx.id);
      if (!alreadyPresent) {
        unkeyed.add(localTx);
      }
    }
  }

  final merged = [...byFirebaseId.values, ...unkeyed];

  // 3. Sort newest first (date descending, secondary by id descending)
  merged.sort((a, b) {
    final dateCompare = b.date.compareTo(a.date);
    if (dateCompare != 0) return dateCompare;
    final aId = a.id ?? 0;
    final bId = b.id ?? 0;
    return bId.compareTo(aId);
  });

  return merged;
}

