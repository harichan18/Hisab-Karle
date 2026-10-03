import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:hisab_kitab/database/database_helper.dart';
import 'package:hisab_kitab/models/transaction_model.dart';
import 'package:hisab_kitab/core/utils/transaction_display_helper.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Issue A — Deletion Refresh & Local SQLite Integrity Tests', () {
    late Database db;

    setUp(() async {
      DatabaseHelper.deletedFirebaseIds.clear();
      db = await openDatabase(
        inMemoryDatabasePath,
        version: 9,
        onCreate: (db, version) async {
          await db.execute('''
CREATE TABLE transactions(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  firebaseId TEXT,
  createdBy TEXT,
  peerUserId TEXT,
  friendName TEXT,
  amount REAL,
  note TEXT,
  date TEXT,
  iGave INTEGER,
  receiptPath TEXT,
  receiptUrl TEXT,
  sync_status INTEGER DEFAULT 0
);
''');
          await db.execute('''
CREATE TABLE IF NOT EXISTS deleted_entries(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  originalEntryId INTEGER,
  personId INTEGER,
  userId TEXT,
  friendName TEXT,
  date TEXT,
  note TEXT,
  amount REAL,
  isGiven INTEGER,
  clearedDate TEXT,
  receiptPath TEXT,
  receiptUrl TEXT
);
''');
          await db.execute('''
CREATE TABLE IF NOT EXISTS cached_friends(
  friendUid TEXT PRIMARY KEY,
  friendName TEXT,
  email TEXT,
  friendCode TEXT,
  photoUrl TEXT,
  upiId TEXT,
  mobileNumber TEXT
);
''');
          await db.execute('''
CREATE TABLE IF NOT EXISTS friend_nicknames(
  friendName TEXT PRIMARY KEY,
  nickname TEXT
);
''');
          await db.execute('''
CREATE TABLE IF NOT EXISTS migration_meta(
  key TEXT PRIMARY KEY,
  value TEXT
);
''');
        },
      );
      DatabaseHelper.setTestDatabase(db);
    });

    tearDown(() async {
      DatabaseHelper.setTestDatabase(null);
      await db.close();
      DatabaseHelper.deletedFirebaseIds.clear();
    });

    test('1. Transaction with local SQLite id can be deleted', () async {
      final tx = TransactionModel(
        firebaseId: 'tx_local_001',
        friendName: 'Aman',
        amount: 300.0,
        note: 'Snacks',
        date: '2026-10-01',
        iGave: true,
        createdBy: 'user_x',
      );
      final id = await DatabaseHelper.instance.insertTransaction(tx);
      expect(id, isPositive);

      final before = await DatabaseHelper.instance.getTransactions(userId: 'user_x');
      expect(before.length, 1);

      // Delete by local SQLite id
      final count = await DatabaseHelper.instance.deleteTransaction(id);
      expect(count, 1);

      final after = await DatabaseHelper.instance.getTransactions(userId: 'user_x');
      expect(after, isEmpty);
      expect(DatabaseHelper.deletedFirebaseIds.contains('tx_local_001'), isTrue);
    });

    test('2. Transaction with id == null and valid firebaseId can be deleted', () async {
      final tx = TransactionModel(
        firebaseId: 'cloud_tx_fb_999',
        friendName: 'Rohan',
        amount: 750.0,
        note: 'Dinner',
        date: '2026-10-02',
        iGave: false,
        createdBy: 'user_x',
      );
      await DatabaseHelper.instance.insertTransaction(tx);

      // Confirm row exists in SQLite
      final rows = await DatabaseHelper.instance.getTransactions(userId: 'user_x');
      expect(rows.length, 1);
      expect(rows.first.firebaseId, 'cloud_tx_fb_999');

      // Representing an in-memory/remote model where t.id == null
      const remoteFirebaseId = 'cloud_tx_fb_999';
      final deletedCount = await DatabaseHelper.instance.deleteTransactionByFirebaseId(
        remoteFirebaseId,
      );
      expect(deletedCount, 1);

      final remaining = await DatabaseHelper.instance.getTransactions(userId: 'user_x');
      expect(remaining, isEmpty);
      expect(DatabaseHelper.deletedFirebaseIds.contains(remoteFirebaseId), isTrue);
    });

    test('3. Deleted transaction disappears from Home immediately', () async {
      // Setup: 2 transactions in SQLite and in Home in-memory list
      final tx1 = TransactionModel(
        id: 1,
        firebaseId: 'home_tx_1',
        friendName: 'Rohan',
        amount: 500.0,
        note: 'Lunch',
        date: '2026-10-01',
        iGave: true,
      );
      final tx2 = TransactionModel(
        id: 2,
        firebaseId: 'home_tx_2',
        friendName: 'Aman',
        amount: 250.0,
        note: 'Coffee',
        date: '2026-10-02',
        iGave: false,
      );
      await DatabaseHelper.instance.insertTransaction(tx1);
      await DatabaseHelper.instance.insertTransaction(tx2);

      // Home in-memory state
      List<TransactionModel> homeTransactions = [tx1, tx2];
      List<TransactionModel> latestRemote = [tx1, tx2];

      // User deletes tx1
      await DatabaseHelper.instance.deleteTransaction(tx1.id!);

      // Immediate in-memory prune (what Home now does)
      homeTransactions.removeWhere((t) => t.id == tx1.id || t.firebaseId == tx1.firebaseId);
      latestRemote.removeWhere((t) => t.id == tx1.id || t.firebaseId == tx1.firebaseId);

      expect(homeTransactions.length, 1);
      expect(homeTransactions.first.friendName, 'Aman');

      // Simulate loadTransactions reload with active remote filtering
      final localData = await DatabaseHelper.instance.getTransactions();
      final activeRemote = latestRemote
          .where((t) =>
              t.firebaseId == null ||
              !DatabaseHelper.deletedFirebaseIds.contains(t.firebaseId))
          .toList();
      final merged = mergeTransactions(
        remote: activeRemote,
        local: localData,
      );

      expect(merged.length, 1);
      expect(merged.first.friendName, 'Aman');
      expect(merged.any((t) => t.firebaseId == 'home_tx_1'), isFalse);
    });

    test('4. Deleted transaction disappears from Person Detail immediately', () async {
      final tx1 = TransactionModel(
        id: 10,
        firebaseId: 'person_tx_10',
        friendName: 'Priya',
        amount: 400.0,
        note: 'Petrol',
        date: '2026-10-01',
        iGave: true,
      );
      final tx2 = TransactionModel(
        id: 11,
        firebaseId: 'person_tx_11',
        friendName: 'Priya',
        amount: 200.0,
        note: 'Tea',
        date: '2026-10-02',
        iGave: true,
      );
      await DatabaseHelper.instance.insertTransaction(tx1);
      await DatabaseHelper.instance.insertTransaction(tx2);

      List<TransactionModel> personTransactions = [tx1, tx2];
      List<TransactionModel> latestRemote = [tx1, tx2];

      // Delete tx1
      await DatabaseHelper.instance.deleteTransaction(tx1.id!);
      personTransactions.removeWhere((t) => t.id == tx1.id || t.firebaseId == tx1.firebaseId);
      latestRemote.removeWhere((t) => t.id == tx1.id || t.firebaseId == tx1.firebaseId);

      // Verify balance calculation updates immediately
      double totalGiven = personTransactions
          .where((t) => t.iGave)
          .fold(0.0, (acc, t) => acc + t.amount);
      expect(totalGiven, 200.0);

      // Local reload
      final localAll = await DatabaseHelper.instance.getTransactions();
      final activeRemote = latestRemote
          .where((t) =>
              t.firebaseId == null ||
              !DatabaseHelper.deletedFirebaseIds.contains(t.firebaseId))
          .toList();
      final merged = mergeTransactions(
        remote: activeRemote,
        local: localAll,
      );
      final forPerson = merged.where((t) => t.friendName == 'Priya').toList();

      expect(forPerson.length, 1);
      expect(forPerson.first.id, 11);
      expect(forPerson.first.amount, 200.0);
    });

    test('5. Whole friend deletion removes the friend immediately', () async {
      await DatabaseHelper.instance.saveCachedFriend(
        friendUid: 'rohan_uid',
        friendName: 'Rohan',
      );
      await DatabaseHelper.instance.saveFriendNickname('Rohan', 'Bro');

      final tx = TransactionModel(
        id: 1,
        firebaseId: 'rohan_tx_1',
        friendName: 'Rohan',
        peerUserId: 'rohan_uid',
        amount: 500.0,
        note: 'Movie',
        date: '2026-10-01',
        iGave: true,
      );
      await DatabaseHelper.instance.insertTransaction(tx);

      // Before deletion
      var cached = await DatabaseHelper.instance.getAllCachedFriends();
      expect(cached.length, 1);

      // Execute whole friend deletion steps
      await DatabaseHelper.instance.deleteTransactionsForFriend('Rohan');
      await DatabaseHelper.instance.deleteDeletedEntriesForFriend('Rohan');
      await DatabaseHelper.instance.deleteCachedFriend('rohan_uid');
      await DatabaseHelper.instance.deleteCachedFriendByName('Rohan');
      await DatabaseHelper.instance.deleteFriendNickname('Rohan');

      // Verify friend data is purged locally
      cached = await DatabaseHelper.instance.getAllCachedFriends();
      expect(cached, isEmpty);

      final nick = await DatabaseHelper.instance.getFriendNickname('Rohan');
      expect(nick, isNull);

      final remainingTx = await DatabaseHelper.instance.getTransactions();
      expect(remainingTx, isEmpty);
    });

    test('6. Whole friend deletion removes associated transactions locally', () async {
      await DatabaseHelper.instance.insertTransaction(TransactionModel(
        firebaseId: 'f1_tx_1',
        friendName: 'Amit',
        amount: 100.0,
        note: 'Snack',
        date: '2026-10-01',
        iGave: true,
      ));
      await DatabaseHelper.instance.insertTransaction(TransactionModel(
        firebaseId: 'f1_tx_2',
        friendName: 'Amit',
        amount: 200.0,
        note: 'Drinks',
        date: '2026-10-02',
        iGave: false,
      ));
      await DatabaseHelper.instance.insertTransaction(TransactionModel(
        firebaseId: 'f2_tx_1',
        friendName: 'Suresh',
        amount: 300.0,
        note: 'Cab',
        date: '2026-10-03',
        iGave: true,
      ));

      final deletedCount = await DatabaseHelper.instance.deleteTransactionsForFriend('Amit');
      expect(deletedCount, 2);

      final remaining = await DatabaseHelper.instance.getTransactions();
      expect(remaining.length, 1);
      expect(remaining.first.friendName, 'Suresh');

      // Deleted firebaseIds tracked
      expect(DatabaseHelper.deletedFirebaseIds.contains('f1_tx_1'), isTrue);
      expect(DatabaseHelper.deletedFirebaseIds.contains('f1_tx_2'), isTrue);
      expect(DatabaseHelper.deletedFirebaseIds.contains('f2_tx_1'), isFalse);
    });

    test('7. Deletion works while offline without throwing', () async {
      final tx = TransactionModel(
        id: 77,
        firebaseId: 'offline_del_77',
        friendName: 'Deepak',
        amount: 900.0,
        note: 'Hotel',
        date: '2026-10-01',
        iGave: true,
      );
      await DatabaseHelper.instance.insertTransaction(tx);

      // Simulate offline: cloud delete throws or is unreachable
      Future<void> simulateCloudDelete() async {
        throw Exception('Network unreachable / offline');
      }

      // Safe deletion wrapper pattern used in production
      try {
        await simulateCloudDelete();
      } catch (_) {
        // Ignored in offline mode
      }
      final localDeleteResult = await DatabaseHelper.instance.deleteTransaction(77);
      expect(localDeleteResult, 1);

      final all = await DatabaseHelper.instance.getTransactions();
      expect(all, isEmpty);
      expect(DatabaseHelper.deletedFirebaseIds.contains('offline_del_77'), isTrue);
    });

    test('8. Stale in-memory transaction cannot resurrect after deletion', () async {
      // Simulate remote stream snapshot having transaction
      final remoteTx = TransactionModel(
        firebaseId: 'resurrect_candidate_tx',
        friendName: 'Vikas',
        amount: 1000.0,
        note: 'Rent share',
        date: '2026-10-01',
        iGave: true,
      );
      await DatabaseHelper.instance.insertTransaction(remoteTx);

      // User deletes the transaction
      await DatabaseHelper.instance.deleteTransactionByFirebaseId('resurrect_candidate_tx');

      // Old in-memory snapshot still holds the item (e.g. from stream before deletion)
      final List<TransactionModel> staleSnapshot = [remoteTx];

      // Filter active remote using deletedFirebaseIds
      final activeRemote = staleSnapshot
          .where((t) =>
              t.firebaseId == null ||
              !DatabaseHelper.deletedFirebaseIds.contains(t.firebaseId))
          .toList();

      final localData = await DatabaseHelper.instance.getTransactions();
      final result = mergeTransactions(
        remote: activeRemote,
        local: localData,
      );

      // Transaction MUST NOT resurrect
      expect(result, isEmpty);
    });

    test('9. Clear transaction moves entry to deleted_entries with metadata and prunes active', () async {
      final tx = TransactionModel(
        id: 5,
        firebaseId: 'clear_tx_5',
        friendName: 'Neha',
        amount: 350.0,
        note: 'Coffee',
        date: '2026-10-01',
        iGave: true,
        createdBy: 'user_neha_creator',
      );
      await DatabaseHelper.instance.insertTransaction(tx);

      // Clear by id
      await DatabaseHelper.instance.clearEntry(5, userId: 'user_neha_creator');

      final active = await DatabaseHelper.instance.getTransactions(userId: 'user_neha_creator');
      expect(active, isEmpty);

      final deleted = await DatabaseHelper.instance.getDeletedEntries(
        DatabaseHelper.personIdForName('Neha'),
        userId: 'user_neha_creator',
      );
      expect(deleted.length, 1);
      expect(deleted.first.amount, 350.0);
      expect(deleted.first.friendName, 'Neha');
    });

    test('10. Scoped user transaction deletion preserves other users data', () async {
      // User A transaction
      await DatabaseHelper.instance.insertTransaction(TransactionModel(
        firebaseId: 'user_a_tx',
        friendName: 'SharedFriend',
        amount: 150.0,
        note: 'Lunch A',
        date: '2026-10-01',
        iGave: true,
        createdBy: 'user_a',
      ));
      // User B transaction
      await DatabaseHelper.instance.insertTransaction(TransactionModel(
        firebaseId: 'user_b_tx',
        friendName: 'SharedFriend',
        amount: 250.0,
        note: 'Lunch B',
        date: '2026-10-01',
        iGave: true,
        createdBy: 'user_b',
      ));

      // User A deletes transactions for SharedFriend
      final deleted = await DatabaseHelper.instance.deleteTransactionsForFriend(
        'SharedFriend',
        userId: 'user_a',
      );
      expect(deleted, 1);

      // User A sees 0 transactions
      final userATxs = await DatabaseHelper.instance.getTransactions(userId: 'user_a');
      expect(userATxs, isEmpty);

      // User B transactions remain intact
      final userBTxs = await DatabaseHelper.instance.getTransactions(userId: 'user_b');
      expect(userBTxs.length, 1);
      expect(userBTxs.first.createdBy, 'user_b');
      expect(userBTxs.first.amount, 250.0);
    });
  });
}
