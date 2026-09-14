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
