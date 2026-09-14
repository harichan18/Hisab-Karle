import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../core/storage/receipt_storage.dart';
import '../core/utils/transaction_display_helper.dart';
import '../database/database_helper.dart';
import '../models/friend_model.dart';
import '../models/transaction_model.dart';

class FirebaseDataService {
  static User? get _user => FirebaseAuth.instance.currentUser;

  static String? get currentUid => _user?.uid;

  static DocumentReference<Map<String, dynamic>>? get _userRef {
    final uid = currentUid;
    if (uid == null) {
      return null;
    }
    return FirebaseFirestore.instance.collection('users').doc(uid);
  }

  static CollectionReference<Map<String, dynamic>>? get transactionsRef =>
      _userRef?.collection('transactions');

  static CollectionReference<Map<String, dynamic>>? _transactionsRefForUid(
    String? uid,
  ) {
    if (uid == null || uid.isEmpty) {
      return null;
    }
    return FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('transactions');
  }

  static CollectionReference<Map<String, dynamic>>? _deletedRefForUid(
    String? uid,
  ) {
    if (uid == null || uid.isEmpty) {
      return null;
    }
    return FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('deletedTransactions');
  }

  static Future<String?> resolvePeerUserIdByFriendName(
    String friendName,
  ) async {
    final cached = await DatabaseHelper.instance.getCachedFriendByName(
      friendName,
    );
    if (cached != null) {
      final uid = cached['friendUid'] as String?;
      if (uid != null && uid.isNotEmpty) {
        return uid;
      }
    }

    final uid = currentUid;
    if (uid == null) {
      return null;
    }

    final normalizedFriendName = friendName.trim().toLowerCase();
    if (normalizedFriendName.isEmpty) {
      return null;
    }

    final friendsCollection = FirebaseFirestore.instance.collection('friends');
    final user1Docs = await friendsCollection
        .where('user1', isEqualTo: uid)
        .get();
    final user2Docs = await friendsCollection
        .where('user2', isEqualTo: uid)
        .get();

    final friendUids = <String>{};
    for (final doc in [...user1Docs.docs, ...user2Docs.docs]) {
      final data = doc.data();
      final user1 = data['user1'] as String? ?? '';
      final user2 = data['user2'] as String? ?? '';
      final friendUid = user1 == uid ? user2 : user1;
      if (friendUid.isNotEmpty && friendUid != uid) {
        friendUids.add(friendUid);
      }
    }

    for (final friendUid in friendUids) {
      final friendDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(friendUid)
          .get();
      final data = friendDoc.data();
      if (data == null) {
        continue;
      }

      final displayName = (data['name'] as String? ?? '').trim().toLowerCase();
      if (displayName == normalizedFriendName) {
        return friendUid;
      }
    }

    return null;
  }

  static Future<String?> resolveEffectivePeerUserId(
    TransactionModel transaction,
  ) async {
    final uid = currentUid;
    if (uid == null) {
      return transaction.peerUserId ??
          await resolvePeerUserIdByFriendName(transaction.friendName);
    }

    if (transaction.peerUserId != null && transaction.peerUserId != uid) {
      return transaction.peerUserId;
    }

    return await resolvePeerUserIdByFriendName(transaction.friendName);
  }

  static Future<void> saveMirroredTransaction(
    TransactionModel transaction, {
    required String firebaseId,
    String? peerUserId,
  }) async {
    final uid = currentUid;
    if (uid == null) {
      return;
    }

    final currentTransactionsRef = _transactionsRefForUid(uid);
    if (currentTransactionsRef == null) {
      return;
    }

    final resolvedPeerUid =
        peerUserId ??
        await resolvePeerUserIdByFriendName(transaction.friendName);
    final peerTransactionsRef = _transactionsRefForUid(resolvedPeerUid);
    final currentDisplayName = currentUserDisplayName();

    final ownerData = {
      ...transaction.toFirestoreMap(),
      'receiptPath': transaction.receiptPath ?? FieldValue.delete(),
      'receiptUrl': transaction.receiptUrl ?? FieldValue.delete(),
      'firebaseId': firebaseId,
      'peerUserId': resolvedPeerUid,
      'updatedAt': FieldValue.serverTimestamp(),
    };

    final mirroredData = {
      ...transaction
          .copyWith(
            friendName: currentDisplayName.isNotEmpty
                ? currentDisplayName
                : transaction.friendName,
            iGave: !transaction.iGave,
            peerUserId: uid,
          )
          .toFirestoreMap(),
      'receiptPath': FieldValue.delete(), // Private local path of creator is never mirrored
      'receiptUrl': transaction.receiptUrl ?? FieldValue.delete(),
      'firebaseId': firebaseId,
      'peerUserId': uid,
      'updatedAt': FieldValue.serverTimestamp(),
    };

    final batch = FirebaseFirestore.instance.batch();
    batch.set(
      currentTransactionsRef.doc(firebaseId),
      ownerData,
      SetOptions(merge: true),
    );

    if (peerTransactionsRef != null &&
        resolvedPeerUid != null &&
        resolvedPeerUid != uid) {
      batch.set(
        peerTransactionsRef.doc(firebaseId),
        mirroredData,
        SetOptions(merge: true),
      );
    }

    await batch.commit();
  }

  static Future<void> deleteMirroredTransaction({
    required String firebaseId,
    String? peerUserId,
  }) async {
    final uid = currentUid;
    if (uid == null) {
      return;
    }

    final currentTransactionsRef = _transactionsRefForUid(uid);
    if (currentTransactionsRef == null) {
      return;
    }

    final batch = FirebaseFirestore.instance.batch();
    batch.delete(currentTransactionsRef.doc(firebaseId));

    final peerTransactionsRef = _transactionsRefForUid(peerUserId);
    if (peerTransactionsRef != null &&
        peerUserId != null &&
        peerUserId != uid) {
      batch.delete(peerTransactionsRef.doc(firebaseId));
    }

    await batch.commit();
  }

  static CollectionReference<Map<String, dynamic>>? get deletedRef =>
      _userRef?.collection('deletedTransactions');

  static CollectionReference<Map<String, dynamic>>? get friendsRef =>
      _userRef?.collection('friends');

  static DocumentReference<Map<String, dynamic>>? get summaryRef =>
      _userRef?.collection('summary').doc('main');

  static CollectionReference<Map<String, dynamic>>? get settlementsRef =>
      _userRef?.collection('settlements');

  static Future<void> recordSettlement({
    required String friendName,
    required double amount,
  }) async {
    final ref = settlementsRef;
    if (ref == null) return;

    final docRef = ref.doc();
    final user = _user;
    final userEmail = user?.email ?? '';
    final settledBy = currentUserDisplayName();
    final createdBy = currentUid ?? '';

    await docRef.set({
      'settlementId': docRef.id,
      'friendName': friendName,
      'amount': amount,
      'settledBy': settledBy,
      'settledAt': Timestamp.now(),
      'createdBy': createdBy,
      'userEmail': userEmail,
    });
  }

  static Stream<List<TransactionModel>> transactionsStream() {
    final ref = transactionsRef;
    if (ref == null) {
      return const Stream.empty();
    }
    return ref.snapshots().map(
      (snapshot) =>
          snapshot.docs
              .map(
                (doc) => normalizeTransactionPerspective(
                  TransactionModel.fromFirestore(doc.id, doc.data()),
                ),
              )
              .toList()
            ..sort((a, b) => b.date.compareTo(a.date)),
    );
  }

  static Stream<double> bankBalanceStream() {
    final ref = summaryRef;
    if (ref == null) {
      return const Stream.empty();
    }
    return ref.snapshots().map(
      (snapshot) =>
          (snapshot.data()?['bankBalance'] as num?)?.toDouble() ?? 0.0,
    );
  }

  static Stream<List<DeletedEntryModel>> deletedEntriesStream(
    String friendName,
  ) {
    final ref = deletedRef;
    if (ref == null) {
      return const Stream.empty();
    }
    final personId = DatabaseHelper.personIdForName(friendName);
    return ref
        .where('personId', isEqualTo: personId)
        .snapshots()
        .map(
          (snapshot) =>
              snapshot.docs
                  .map(
                    (doc) =>
                        DeletedEntryModel.fromFirestore(doc.id, doc.data()),
                  )
                  .toList()
                ..sort((a, b) => b.clearedDate.compareTo(a.clearedDate)),
        );
  }

  static Stream<List<DeletedEntryModel>> allDeletedEntriesStream() {
    final ref = deletedRef;
    if (ref == null) {
      return const Stream.empty();
    }
    return ref.snapshots().map(
      (snapshot) =>
          snapshot.docs
              .map((doc) => DeletedEntryModel.fromFirestore(doc.id, doc.data()))
              .toList()
            ..sort((a, b) => b.clearedDate.compareTo(a.clearedDate)),
    );
  }

  static Future<String?> saveTransaction(
    TransactionModel transaction, {
    String? firebaseId,
  }) async {
    const scope = 'FirebaseDataService.saveTransaction';
    receiptLog(
      scope,
      'Saving transaction: firebaseId=$firebaseId data=${transaction.toFirestoreMap()}',
    );
    final ref = transactionsRef;
    if (ref == null) {
      receiptLog(scope, 'transactionsRef is null. Save skipped.');
      return null;
    }

    final resolvedFirebaseId =
        firebaseId ?? transaction.firebaseId ?? ref.doc().id;
    final peerUserId = await resolveEffectivePeerUserId(transaction);
    receiptLog(
      scope,
      'Writing mirrored transaction id=$resolvedFirebaseId peerUserId=$peerUserId',
    );

    await saveMirroredTransaction(
      transaction.copyWith(
        firebaseId: resolvedFirebaseId,
        peerUserId: peerUserId,
      ),
      firebaseId: resolvedFirebaseId,
      peerUserId: peerUserId,
    );

    receiptLog(scope, 'Updating summary after transaction save.');
    await updateSummary();
    receiptLog(scope, 'Transaction save finished.');
    return resolvedFirebaseId;
  }

  static Future<void> deleteTransaction(TransactionModel transaction) async {
    final firebaseId = transaction.firebaseId;
    if (firebaseId == null) {
      return;
    }
    final peerUserId = await resolveEffectivePeerUserId(transaction);
    await deleteLocalReceipt(
      transaction.receiptPath,
      scope: 'FirebaseDataService.deleteTransaction',
    );
    await deleteMirroredTransaction(
      firebaseId: firebaseId,
      peerUserId: peerUserId,
    );
    await updateSummary();
  }

  static Future<void> clearTransaction(TransactionModel transaction) async {
    final firebaseId = transaction.firebaseId;
    final txRef = transactionsRef;
    final deleted = deletedRef;
    if (txRef == null || deleted == null || firebaseId == null) {
      return;
    }

    final uid = currentUid;
    final peerUserId = await resolveEffectivePeerUserId(transaction);
    final peerTxRef = _transactionsRefForUid(peerUserId);
    final peerDeletedRef = _deletedRefForUid(peerUserId);
    final currentDisplayName = currentUserDisplayName();

    final ownerDeletedEntry = DeletedEntryModel(
      originalEntryId: transaction.id ?? 0,
      originalFirebaseId: firebaseId,
      peerUserId: peerUserId,
      personId: DatabaseHelper.personIdForName(transaction.friendName),
      friendName: transaction.friendName,
      date: transaction.date,
      note: transaction.note,
      amount: transaction.amount,
      isGiven: transaction.iGave,
      clearedDate: _formatDate(DateTime.now()),
      receiptUrl: transaction.receiptUrl,
      receiptPath: transaction.receiptPath,
    );

    final mirroredDeletedEntry = DeletedEntryModel(
      originalEntryId: transaction.id ?? 0,
      originalFirebaseId: firebaseId,
      peerUserId: uid,
      personId: DatabaseHelper.personIdForName(
        currentDisplayName.isNotEmpty
            ? currentDisplayName
            : transaction.friendName,
      ),
      friendName: currentDisplayName.isNotEmpty
          ? currentDisplayName
          : transaction.friendName,
      date: transaction.date,
      note: transaction.note,
      amount: transaction.amount,
      isGiven: !transaction.iGave,
      clearedDate: _formatDate(DateTime.now()),
      receiptUrl: transaction.receiptUrl,
      receiptPath: transaction.receiptPath,
    );

    final batch = FirebaseFirestore.instance.batch();
    batch.set(deleted.doc(firebaseId), {
      ...ownerDeletedEntry.toFirestoreMap(),
      'createdAt': FieldValue.serverTimestamp(),
    });
    if (peerDeletedRef != null && peerUserId != null && peerUserId != uid) {
      batch.set(peerDeletedRef.doc(firebaseId), {
        ...mirroredDeletedEntry.toFirestoreMap(),
        'createdAt': FieldValue.serverTimestamp(),
      });
    }
    batch.delete(txRef.doc(firebaseId));
    if (peerTxRef != null && peerUserId != null && peerUserId != uid) {
      batch.delete(peerTxRef.doc(firebaseId));
    }
    await batch.commit();
    await updateSummary();
  }

  static Future<void> restoreDeletedEntry(DeletedEntryModel entry) async {
    final deletedId = entry.firebaseId;
    final txRef = transactionsRef;
    final deleted = deletedRef;
    if (txRef == null || deleted == null || deletedId == null) {
      return;
    }

    final uid = currentUid;
    final peerUserId = entry.peerUserId == uid
        ? await resolvePeerUserIdByFriendName(entry.friendName)
        : entry.peerUserId ??
              await resolvePeerUserIdByFriendName(entry.friendName);
    final peerTxRef = _transactionsRefForUid(peerUserId);
    final peerDeletedRef = _deletedRefForUid(peerUserId);
    final restoredFirebaseId = entry.originalFirebaseId ?? txRef.doc().id;
    final currentDisplayName = currentUserDisplayName();

    final transaction = TransactionModel(
      peerUserId: entry.peerUserId,
      friendName: entry.friendName,
      amount: entry.amount,
      note: entry.note,
      date: entry.date,
      iGave: entry.isGiven,
      receiptUrl: entry.receiptUrl,
      receiptPath: entry.receiptPath,
    );

    final batch = FirebaseFirestore.instance.batch();
    batch.set(txRef.doc(restoredFirebaseId), {
      ...transaction.toFirestoreMap(),
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    if (peerTxRef != null && peerUserId != null && peerUserId != uid) {
      batch.set(peerTxRef.doc(restoredFirebaseId), {
        ...transaction
            .copyWith(
              friendName: currentDisplayName.isNotEmpty
                  ? currentDisplayName
                  : transaction.friendName,
              iGave: !transaction.iGave,
              peerUserId: uid,
            )
            .toFirestoreMap(),
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
    batch.delete(deleted.doc(deletedId));
    if (peerDeletedRef != null && peerUserId != null && peerUserId != uid) {
      batch.delete(peerDeletedRef.doc(entry.originalFirebaseId ?? deletedId));
    }
    await batch.commit();
    await updateSummary();
  }

  static Future<void> permanentlyDeleteEntry(DeletedEntryModel entry) async {
    final deletedId = entry.firebaseId;
    final deleted = deletedRef;
    if (deleted == null || deletedId == null) {
      return;
    }
    final peerDeletedRef = _deletedRefForUid(entry.peerUserId);
    await deleteLocalReceipt(
      entry.receiptPath,
      scope: 'FirebaseDataService.permanentlyDeleteEntry',
    );
    await deleted.doc(deletedId).delete();
    if (peerDeletedRef != null &&
        entry.peerUserId != null &&
        entry.peerUserId != currentUid) {
      await peerDeletedRef.doc(entry.originalFirebaseId ?? deletedId).delete();
    }
  }

  static Future<void> saveBankBalance(double amount) async {
    final ref = summaryRef;
    if (ref == null) {
      return;
    }
    await ref.set({
      'bankBalance': amount,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static Future<void> saveFriendProfile(FirestoreFriendProfile friend) async {
    final ref = friendsRef;
    if (ref == null) {
      return;
    }
    await ref.doc(friend.uid).set({
      'uid': friend.uid,
      'name': friend.name,
      'email': friend.email,
      'friendCode': friend.friendCode,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static Future<void> deleteFriendData({
    required String friendName,
    String? friendUid,
  }) async {
    final uid = currentUid;
    final txRef = transactionsRef;
    final deleted = deletedRef;
    if (uid == null || txRef == null || deleted == null) {
      return;
    }

    final normalizedName = friendName.trim().toLowerCase();
    final personId = DatabaseHelper.personIdForName(friendName);
    final batch = FirebaseFirestore.instance.batch();

    final transactionDocs = await txRef.get();
    for (final doc in transactionDocs.docs) {
      final transactionFriend = (doc.data()['friendName'] as String? ?? '')
          .trim()
          .toLowerCase();
      if (transactionFriend == normalizedName) {
        batch.delete(doc.reference);
      }
    }

    final deletedDocs = await deleted
        .where('personId', isEqualTo: personId)
        .get();
    for (final doc in deletedDocs.docs) {
      batch.delete(doc.reference);
    }

    if (friendUid != null && friendUid.isNotEmpty) {
      final friendsCollection = FirebaseFirestore.instance.collection(
        'friends',
      );
      final user1Docs = await friendsCollection
          .where('user1', isEqualTo: uid)
          .where('user2', isEqualTo: friendUid)
          .get();
      final user2Docs = await friendsCollection
          .where('user1', isEqualTo: friendUid)
          .where('user2', isEqualTo: uid)
          .get();

      for (final doc in [...user1Docs.docs, ...user2Docs.docs]) {
        batch.delete(doc.reference);
      }

      final profileRef = friendsRef?.doc(friendUid);
      if (profileRef != null) {
        batch.delete(profileRef);
      }
    }

    await batch.commit();
    await updateSummary();
  }

  static Future<void> updateSummary() async {
    final txRef = transactionsRef;
    final ref = summaryRef;
    if (txRef == null || ref == null) {
      return;
    }

    final transactions = await txRef.get();
    double toGet = 0;
    double toGive = 0;

    for (final doc in transactions.docs) {
      final data = doc.data();
      final amount = (data['amount'] as num?)?.toDouble() ?? 0.0;
      if (data['iGave'] == true) {
        toGet += amount;
      } else {
        toGive += amount;
      }
    }

    await ref.set({
      'toGet': toGet,
      'toGive': toGive,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static Future<void> migrateSQLiteCacheToFirestoreIfNeeded() async {
    final uid = currentUid;
    if (uid == null) {
      return;
    }

    const migrationKey = 'legacy_sqlite_imported_uid';
    final importedUid = await DatabaseHelper.instance.getMigrationMeta(
      migrationKey,
    );
    if (importedUid != null && importedUid.isNotEmpty) {
      debugPrint('[Migration] Legacy SQLite already imported for $importedUid');
      return;
    }

    final txRef = transactionsRef;
    final deleted = deletedRef;
    final summary = summaryRef;
    if (txRef == null || deleted == null || summary == null) {
      return;
    }

    final existingTransactions = await txRef.limit(1).get();
    if (existingTransactions.docs.isNotEmpty) {
      await DatabaseHelper.instance.setMigrationMeta(migrationKey, uid);
      debugPrint(
        '[Migration] Firestore already has data. Marked local import for $uid.',
      );
      return;
    }

    final localTransactions = await DatabaseHelper.instance.getTransactions();
    final localDeletedEntries = await DatabaseHelper.instance
        .getAllDeletedEntries();
    final localBankBalance = await DatabaseHelper.instance.getBankBalance();

    final batch = FirebaseFirestore.instance.batch();

    for (final transaction in localTransactions) {
      batch.set(txRef.doc(), {
        ...transaction.toFirestoreMap(),
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }

    for (final entry in localDeletedEntries) {
      batch.set(deleted.doc(), {
        ...entry.toFirestoreMap(),
        'createdAt': FieldValue.serverTimestamp(),
      });
    }

    batch.set(summary, {
      'bankBalance': localBankBalance,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await batch.commit();
    await updateSummary();
    await DatabaseHelper.instance.setMigrationMeta(migrationKey, uid);

    debugPrint(
      '[Migration] Imported ${localTransactions.length} transactions, '
      '${localDeletedEntries.length} cleared transactions, '
      'bank balance $localBankBalance for $uid.',
    );
  }

  static void clearCachedSessionData() {
    debugPrint('[Session] Cleared in-memory cached session data.');
  }

  static String _formatDate(DateTime date) {
    return "${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}";
  }
}

typedef TransactionService = FirebaseDataService;
