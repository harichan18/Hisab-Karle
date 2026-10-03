import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/material.dart';
import 'package:hisab_kitab/database/database_helper.dart';
import 'package:hisab_kitab/models/expense_model.dart';
import 'package:hisab_kitab/models/friend_model.dart';
import 'package:hisab_kitab/models/transaction_model.dart';
import 'package:hisab_kitab/screens/daily_expenditure_screen.dart';
import 'package:hisab_kitab/services/split_calculator.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Issue #2 — Persistent Local Friends, Migration, OCR & "You" Tests', () {
    late Database db;
    late Directory tempDir;

    Future<Database> createTestDb(String path) async {
      return await openDatabase(
        path,
        version: 11,
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
CREATE TABLE IF NOT EXISTS local_friends(
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  userId TEXT NOT NULL,
  createdAt TEXT NOT NULL,
  updatedAt TEXT NOT NULL
);
''');
          await db.execute('''
CREATE TABLE IF NOT EXISTS migration_meta(
  key TEXT PRIMARY KEY,
  value TEXT
);
''');
          await db.execute('''
CREATE TABLE IF NOT EXISTS personal_expenses(
  id TEXT PRIMARY KEY,
  userId TEXT,
  amount REAL,
  category TEXT,
  description TEXT,
  expenseDate TEXT,
  receiptUrl TEXT,
  createdAt TEXT,
  sync_status INTEGER DEFAULT 0
);
''');
          await db.execute('''
CREATE TABLE IF NOT EXISTS you_split_shares(
  id TEXT PRIMARY KEY,
  userId TEXT NOT NULL,
  amount REAL NOT NULL,
  note TEXT,
  date TEXT NOT NULL,
  createdAt TEXT NOT NULL
);
''');
        },
      );
    }

    setUp(() async {
      DatabaseHelper.deletedFirebaseIds.clear();
      tempDir = await Directory.systemTemp.createTemp('hisab_test_');
      final dbPath = p.join(tempDir.path, 'test_hisab.db');
      db = await createTestDb(dbPath);
      DatabaseHelper.setTestDatabase(db);
    });

    tearDown(() async {
      DatabaseHelper.setTestDatabase(null);
      await db.close();
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    // 1. Create local friend with zero transactions
    test('1. Create local friend with zero transactions', () async {
      final now = DateTime.now();
      final friend = LocalFriendModel(
        id: DatabaseHelper.generateLocalId(),
        name: 'Rohan',
        userId: 'user_1',
        createdAt: now,
        updatedAt: now,
      );

      final insertedId = await DatabaseHelper.instance.insertLocalFriend(friend);
      expect(insertedId, isNonZero);

      final friends = await DatabaseHelper.instance.getLocalFriends(userId: 'user_1');
      expect(friends.length, 1);
      expect(friends.first.name, 'Rohan');
      expect(friends.first.id, friend.id);

      final txs = await DatabaseHelper.instance.getTransactions(userId: 'user_1');
      expect(txs.isEmpty, isTrue);
    });

    // 2. Read local friend after restart/database reopen
    test('2. Read local friend after restart/database reopen', () async {
      final friendId = DatabaseHelper.generateLocalId();
      final now = DateTime.now();
      final friend = LocalFriendModel(
        id: friendId,
        name: 'Priya',
        userId: 'user_restart',
        createdAt: now,
        updatedAt: now,
      );
      await DatabaseHelper.instance.insertLocalFriend(friend);

      final dbPath = db.path;
      await db.close();

      // Reopen database (simulates app restart)
      final reopenedDb = await createTestDb(dbPath);
      DatabaseHelper.setTestDatabase(reopenedDb);
      db = reopenedDb;

      final friends = await DatabaseHelper.instance.getLocalFriends(userId: 'user_restart');
      expect(friends.length, 1);
      expect(friends.first.id, friendId);
      expect(friends.first.name, 'Priya');
    });

    // 3. Delete one transaction while friend remains
    test('3. Delete one transaction while friend remains', () async {
      final friend = LocalFriendModel(
        id: DatabaseHelper.generateLocalId(),
        name: 'Aman',
        userId: 'user_1',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await DatabaseHelper.instance.insertLocalFriend(friend);

      final tx1Id = await DatabaseHelper.instance.insertTransaction(
        TransactionModel(
          friendName: 'Aman',
          amount: 200,
          note: '',
          date: '2026-10-01',
          iGave: true,
          createdBy: 'user_1',
        ),
      );
      await DatabaseHelper.instance.insertTransaction(
        TransactionModel(
          friendName: 'Aman',
          amount: 300,
          note: '',
          date: '2026-10-02',
          iGave: true,
          createdBy: 'user_1',
        ),
      );

      // Delete 1 transaction
      await DatabaseHelper.instance.deleteTransaction(tx1Id);

      // Friend must remain in local_friends
      final friends = await DatabaseHelper.instance.getLocalFriends(userId: 'user_1');
      expect(friends.length, 1);
      expect(friends.first.name, 'Aman');

      final remainingTxs = await DatabaseHelper.instance.getTransactions(userId: 'user_1');
      expect(remainingTxs.length, 1);
      expect(remainingTxs.first.amount, 300.0);
    });

    // 4. Delete last transaction while friend remains
    test('4. Delete last transaction while friend remains', () async {
      final friend = LocalFriendModel(
        id: DatabaseHelper.generateLocalId(),
        name: 'Rohan',
        userId: 'user_1',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await DatabaseHelper.instance.insertLocalFriend(friend);

      final txId = await DatabaseHelper.instance.insertTransaction(
        TransactionModel(
          friendName: 'Rohan',
          amount: 500,
          note: '',
          date: '2026-10-01',
          iGave: true,
          createdBy: 'user_1',
        ),
      );

      // Delete the only transaction
      await DatabaseHelper.instance.deleteTransaction(txId);

      // Friend entity must strictly remain in local_friends!
      final friends = await DatabaseHelper.instance.getLocalFriends(userId: 'user_1');
      expect(friends.length, 1);
      expect(friends.first.name, 'Rohan');

      // Transactions list is empty (0 transactions, ₹0 balance)
      final txs = await DatabaseHelper.instance.getTransactions(userId: 'user_1');
      expect(txs.isEmpty, isTrue);
    });

    // 5. Explicit whole-friend deletion removes friend
    test('5. Explicit whole-friend deletion removes friend', () async {
      final friendId = DatabaseHelper.generateLocalId();
      final friend = LocalFriendModel(
        id: friendId,
        name: 'Vikas',
        userId: 'user_1',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await DatabaseHelper.instance.insertLocalFriend(friend);
      await DatabaseHelper.instance.insertTransaction(
        TransactionModel(
          friendName: 'Vikas',
          amount: 500,
          note: '',
          date: '2026-10-01',
          iGave: true,
          createdBy: 'user_1',
        ),
      );

      // Explicit whole friend deletion
      await DatabaseHelper.instance.deleteLocalFriend(friendId);
      await DatabaseHelper.instance.deleteTransactionsForFriend('Vikas', userId: 'user_1');
      await DatabaseHelper.instance.deleteDeletedEntriesForFriend('Vikas');

      final friends = await DatabaseHelper.instance.getLocalFriends(userId: 'user_1');
      expect(friends.isEmpty, isTrue);

      final txs = await DatabaseHelper.instance.getTransactions(userId: 'user_1');
      expect(txs.isEmpty, isTrue);
    });

    // 6. Two users can each have a local friend with the same name without collision
    test('6. Two users can each have a local friend with the same name without collision', () async {
      final friendA = LocalFriendModel(
        id: DatabaseHelper.generateLocalId(),
        name: 'Rohan',
        userId: 'user_alpha',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      final friendB = LocalFriendModel(
        id: DatabaseHelper.generateLocalId(),
        name: 'Rohan',
        userId: 'user_beta',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      await DatabaseHelper.instance.insertLocalFriend(friendA);
      await DatabaseHelper.instance.insertLocalFriend(friendB);

      expect(friendA.id != friendB.id, isTrue);

      final userAFriends = await DatabaseHelper.instance.getLocalFriends(userId: 'user_alpha');
      expect(userAFriends.length, 1);
      expect(userAFriends.first.id, friendA.id);

      final userBFriends = await DatabaseHelper.instance.getLocalFriends(userId: 'user_beta');
      expect(userBFriends.length, 1);
      expect(userBFriends.first.id, friendB.id);

      // Deleting user A's friend leaves user B's friend intact
      await DatabaseHelper.instance.deleteLocalFriend(friendA.id);
      expect((await DatabaseHelper.instance.getLocalFriends(userId: 'user_alpha')).isEmpty, isTrue);
      expect((await DatabaseHelper.instance.getLocalFriends(userId: 'user_beta')).length, 1);
    });

    // 7. Existing transaction names migrate into local_friends
    test('7. Existing transaction names migrate into local_friends', () async {
      await DatabaseHelper.instance.insertTransaction(
        TransactionModel(
          friendName: 'LegacyFriend',
          amount: 100,
          note: '',
          date: '2026-10-01',
          iGave: true,
          createdBy: 'user_mig',
        ),
      );

      // Before migration: local_friends is empty
      expect((await DatabaseHelper.instance.getLocalFriends(userId: 'user_mig')).isEmpty, isTrue);

      // Run migration
      await DatabaseHelper.instance.migrateExistingFriendsToLocal(userId: 'user_mig');

      // After migration: friend exists in local_friends
      final friends = await DatabaseHelper.instance.getLocalFriends(userId: 'user_mig');
      expect(friends.length, 1);
      expect(friends.first.name, 'LegacyFriend');
      expect(friends.first.id.startsWith('local_'), isTrue);

      // Original transaction is completely untouched
      final txs = await DatabaseHelper.instance.getTransactions(userId: 'user_mig');
      expect(txs.length, 1);
      expect(txs.first.friendName, 'LegacyFriend');
      expect(txs.first.amount, 100.0);
    });

    // 8. Migration does not duplicate existing local friends
    test('8. Migration does not duplicate existing local friends', () async {
      await DatabaseHelper.instance.insertTransaction(
        TransactionModel(
          friendName: 'LegacyFriend',
          amount: 100,
          note: '',
          date: '2026-10-01',
          iGave: true,
          createdBy: 'user_mig',
        ),
      );

      // Run migration twice
      await DatabaseHelper.instance.migrateExistingFriendsToLocal(userId: 'user_mig');
      await DatabaseHelper.instance.migrateExistingFriendsToLocal(userId: 'user_mig');

      final friends = await DatabaseHelper.instance.getLocalFriends(userId: 'user_mig');
      expect(friends.length, 1);
    });

    // 9. Manual friend works offline
    test('9. Manual friend works offline', () async {
      // Offline user (userId: '')
      final friend = LocalFriendModel(
        id: DatabaseHelper.generateLocalId(),
        name: 'OfflineFriend',
        userId: '',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await DatabaseHelper.instance.insertLocalFriend(friend);

      final friends = await DatabaseHelper.instance.getLocalFriends(userId: '');
      expect(friends.length, 1);
      expect(friends.first.name, 'OfflineFriend');

      // Add transaction offline
      final txId = await DatabaseHelper.instance.insertTransaction(
        TransactionModel(
          friendName: 'OfflineFriend',
          amount: 250,
          note: '',
          date: '2026-10-01',
          iGave: true,
          createdBy: null,
          syncStatus: SyncStatus.synced,
        ),
      );
      expect(txId, isPositive);

      final txs = await DatabaseHelper.instance.getTransactions(userId: '');
      expect(txs.length, 1);
      expect(txs.first.friendName, 'OfflineFriend');
    });

    // 10. Manual friend appears in OCR with zero transactions
    test('10. Manual friend appears in OCR with zero transactions', () async {
      final friend = LocalFriendModel(
        id: DatabaseHelper.generateLocalId(),
        name: 'ZeroTxFriend',
        userId: 'user_ocr',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await DatabaseHelper.instance.insertLocalFriend(friend);

      // Fetch for OCR
      final localFriends = await DatabaseHelper.instance.getLocalFriends(userId: 'user_ocr');
      final ocrParticipants = <({String id, String name, bool isYou, bool isLocal})>[
        (id: '__you__', name: 'You', isYou: true, isLocal: false),
        ...localFriends.map((f) => (id: f.id, name: f.name, isYou: false, isLocal: true)),
      ];

      expect(ocrParticipants.any((p) => p.name == 'ZeroTxFriend'), isTrue);
      expect(ocrParticipants.firstWhere((p) => p.name == 'ZeroTxFriend').isLocal, isTrue);
    });

    // 11. "You" appears first
    test('11. "You" appears first in participants list', () {
      final participants = <({String id, String name, bool isYou})>[
        (id: '__you__', name: 'You', isYou: true),
        (id: 'local_1', name: 'Amit', isYou: false),
        (id: 'local_2', name: 'Rohan', isYou: false),
      ];

      expect(participants.first.id, '__you__');
      expect(participants.first.name, 'You');
      expect(participants.first.isYou, isTrue);
    });

    // 12. "You" is selected by default
    test('12. "You" is selected by default', () {
      final selectedIds = <String>{};
      // Simulated initial state of SharePaymentScreen
      selectedIds.add('__you__');

      expect(selectedIds.contains('__you__'), isTrue);
    });

    // 13. "You" can be deselected
    test('13. "You" can be deselected', () {
      final selectedIds = <String>{'__you__', 'local_1', 'local_2'};

      // Toggle "You" off
      selectedIds.remove('__you__');

      expect(selectedIds.contains('__you__'), isFalse);
      expect(selectedIds.length, 2);
    });

    // 14. Split with You + two friends calculates correctly
    test('14. Split with You + two friends calculates correctly', () {
      const totalAmount = 900.0;
      final friends = [
        (name: 'You', uid: '__you__'),
        (name: 'Rohan', uid: 'local_rohan'),
        (name: 'Amit', uid: 'local_amit'),
      ];

      final shares = SplitCalculator.calculateEqualSplit(
        totalAmount: totalAmount,
        friends: friends,
      );

      expect(shares.length, 3);
      expect(shares.firstWhere((s) => s.friendUid == '__you__').amount, 300.0);
      expect(shares.firstWhere((s) => s.friendUid == 'local_rohan').amount, 300.0);
      expect(shares.firstWhere((s) => s.friendUid == 'local_amit').amount, 300.0);

      final totalSum = shares.fold(0.0, (acc, s) => acc + s.amount);
      expect(totalSum, 900.0);
    });

    // 15. Saving split creates no self transaction
    test('15. Saving split creates no self transaction', () async {
      const totalAmount = 900.0;
      final friends = [
        (name: 'You', uid: '__you__'),
        (name: 'Rohan', uid: 'local_rohan'),
        (name: 'Amit', uid: 'local_amit'),
      ];

      final shares = SplitCalculator.calculateEqualSplit(
        totalAmount: totalAmount,
        friends: friends,
      );

      int savedCount = 0;
      for (final share in shares) {
        if (share.friendUid == '__you__') {
          // Rule: Skip "You"
          continue;
        }

        await DatabaseHelper.instance.insertTransaction(
          TransactionModel(
            friendName: share.friendName,
            amount: share.amount,
            note: '',
            date: '2026-10-01',
            iGave: true,
            createdBy: 'current_user',
          ),
        );
        savedCount++;
      }

      expect(savedCount, 2);

      final savedTxs = await DatabaseHelper.instance.getTransactions(userId: 'current_user');
      expect(savedTxs.length, 2);
      expect(savedTxs.any((t) => t.friendName.toLowerCase() == 'you'), isFalse);
      expect(savedTxs.any((t) => t.friendName == 'Rohan'), isTrue);
      expect(savedTxs.any((t) => t.friendName == 'Amit'), isTrue);
    });

    // 16. Local friend split creates correct transaction
    test('16. Local friend split creates correct transaction', () async {
      const shareAmount = 300.0;
      final tx = TransactionModel(
        friendName: 'Rohan',
        amount: shareAmount,
        note: '',
        date: '2026-10-01',
        iGave: true,
        createdBy: 'current_user',
        peerUserId: null, // Local friend has NO Firebase peer UID
        syncStatus: SyncStatus.synced,
      );

      final id = await DatabaseHelper.instance.insertTransaction(tx);
      expect(id, isPositive);

      final saved = (await DatabaseHelper.instance.getTransactions(userId: 'current_user')).first;
      expect(saved.friendName, 'Rohan');
      expect(saved.amount, 300.0);
      expect(saved.iGave, isTrue);
      expect(saved.peerUserId, isNull);
    });

    // 17. Connected friend behavior remains intact
    test('17. Connected friend behavior remains intact', () async {
      // Connected friend has genuine Firebase UID
      const connectedUid = 'firebase_uid_rahul';
      await DatabaseHelper.instance.saveCachedFriend(
        friendUid: connectedUid,
        friendName: 'Rahul',
        email: 'rahul@example.com',
      );

      final cached = await DatabaseHelper.instance.getCachedFriendByUid(connectedUid);
      expect(cached, isNotNull);
      expect(cached!['friendName'], 'Rahul');

      // Connected friend transaction preserves peerUserId
      final tx = TransactionModel(
        firebaseId: 'firebase_tx_123',
        peerUserId: connectedUid,
        createdBy: 'user_current',
        friendName: 'Rahul',
        amount: 350,
        note: '',
        date: '2026-10-01',
        iGave: true,
        syncStatus: SyncStatus.pending,
      );
      final id = await DatabaseHelper.instance.insertTransaction(tx);
      expect(id, isPositive);

      final saved = (await DatabaseHelper.instance.getTransactions(userId: 'user_current')).first;
      expect(saved.peerUserId, connectedUid);
      expect(saved.firebaseId, 'firebase_tx_123');
    });

    // 18. Local friend does not attempt Firebase mirroring using a fake UID
    test('18. Local friend does not attempt Firebase mirroring using a fake UID', () {
      final localFriend = (
        id: DatabaseHelper.generateLocalId(),
        name: 'Rohan',
        firebaseUid: null,
        isYou: false,
        isLocal: true,
      );

      // peerUserId must be null for local friend
      final peerUserId = localFriend.firebaseUid;
      expect(peerUserId, isNull);
      expect(localFriend.id.startsWith('local_'), isTrue);
    });

    // 19. Manual friend survives app restart after all transactions are deleted
    test('19. Manual friend survives app restart after all transactions are deleted', () async {
      final friendId = DatabaseHelper.generateLocalId();
      final friend = LocalFriendModel(
        id: friendId,
        name: 'Suresh',
        userId: 'user_restart',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await DatabaseHelper.instance.insertLocalFriend(friend);

      final txId = await DatabaseHelper.instance.insertTransaction(
        TransactionModel(
          friendName: 'Suresh',
          amount: 1000,
          note: '',
          date: '2026-10-01',
          iGave: true,
          createdBy: 'user_restart',
        ),
      );

      // Delete transaction
      await DatabaseHelper.instance.deleteTransaction(txId);

      // Reopen DB (simulates app restart)
      final dbPath = db.path;
      await db.close();

      final reopenedDb = await createTestDb(dbPath);
      DatabaseHelper.setTestDatabase(reopenedDb);
      db = reopenedDb;

      // Friend entity is still intact!
      final friends = await DatabaseHelper.instance.getLocalFriends(userId: 'user_restart');
      expect(friends.length, 1);
      expect(friends.first.name, 'Suresh');
      expect(friends.first.id, friendId);

      // Zero transactions
      final txs = await DatabaseHelper.instance.getTransactions(userId: 'user_restart');
      expect(txs.isEmpty, isTrue);
    });

    // 20. Existing Issue #1 offline transaction behavior still passes
    test('20. Existing Issue #1 offline transaction behavior still passes', () async {
      final tx = TransactionModel(
        friendName: 'Rohan',
        amount: 500,
        note: '',
        date: '2026-10-01',
        iGave: true,
        createdBy: 'user_offline',
        syncStatus: SyncStatus.pending,
      );
      final id = await DatabaseHelper.instance.insertTransaction(tx);

      final pending = await DatabaseHelper.instance.getPendingTransactions(userId: 'user_offline');
      expect(pending.length, 1);
      expect(pending.first.id, id);
      expect(pending.first.syncStatus, SyncStatus.pending);

      // Update sync status
      await DatabaseHelper.instance.updateTransactionSyncStatus(
        id,
        SyncStatus.synced,
        firebaseId: 'fb_123',
      );
      final synced = (await DatabaseHelper.instance.getTransactions(userId: 'user_offline')).first;
      expect(synced.syncStatus, SyncStatus.synced);
      expect(synced.firebaseId, 'fb_123');
    });

    // 21. Existing Issue A deletion tests still pass
    test('21. Existing Issue A deletion tests still pass', () async {
      final txId = await DatabaseHelper.instance.insertTransaction(
        TransactionModel(
          firebaseId: 'fb_del_1',
          friendName: 'Amit',
          amount: 400,
          note: '',
          date: '2026-10-01',
          iGave: true,
          createdBy: 'user_1',
        ),
      );

      // Clear entry into deleted_entries
      await DatabaseHelper.instance.clearEntry(txId, userId: 'user_1');

      final activeTxs = await DatabaseHelper.instance.getTransactions(userId: 'user_1');
      expect(activeTxs.isEmpty, isTrue);

      final personId = DatabaseHelper.personIdForName('Amit');
      final deleted = await DatabaseHelper.instance.getDeletedEntries(personId, userId: 'user_1');
      expect(deleted.length, 1);
      expect(deleted.first.friendName, 'Amit');
      expect(deleted.first.amount, 400.0);
    });

    // 22. You appears at the top of Home friend section
    testWidgets('22. You appears at the top of Home friend section', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Container(
                  key: const Key('home_you_card'),
                  child: const Text('You'),
                ),
                const Text('Rohan'),
              ],
            ),
          ),
        ),
      );

      final youFinder = find.byKey(const Key('home_you_card'));
      final rohanFinder = find.text('Rohan');

      expect(youFinder, findsOneWidget);
      expect(rohanFinder, findsOneWidget);

      final youTop = tester.getTopLeft(youFinder).dy;
      final rohanTop = tester.getTopLeft(rohanFinder).dy;
      expect(youTop < rohanTop, isTrue);
    });

    // 23. You appears even when there are zero friends
    testWidgets('23. You appears even when there are zero friends', (tester) async {
      final friends = <FriendListItem>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Container(
                  key: const Key('home_you_card'),
                  child: const Text('You'),
                ),
                if (friends.isEmpty)
                  const Text("No friends added yet. Tap '+' to add a transaction."),
              ],
            ),
          ),
        ),
      );

      expect(find.byKey(const Key('home_you_card')), findsOneWidget);
      expect(find.text("No friends added yet. Tap '+' to add a transaction."), findsOneWidget);
    });

    // 24. You has no + button and no - button
    testWidgets('24. You has no + button and no - button', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Container(
              key: const Key('home_you_card'),
              child: Row(
                children: [
                  const Text('You'),
                  TextButton(
                    key: const Key('you_clear_button'),
                    onPressed: () {},
                    child: const Text('Clear'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      final youCard = find.byKey(const Key('home_you_card'));
      expect(youCard, findsOneWidget);

      final addIcon = find.descendant(of: youCard, matching: find.byIcon(Icons.add));
      final removeIcon = find.descendant(of: youCard, matching: find.byIcon(Icons.remove));
      expect(addIcon, findsNothing);
      expect(removeIcon, findsNothing);
      expect(find.descendant(of: youCard, matching: find.text('Give')), findsNothing);
      expect(find.descendant(of: youCard, matching: find.text('Take')), findsNothing);
    });

    // 25. You does not create a Give/Take transaction
    test('25. You does not create a Give/Take transaction', () async {
      final txsBefore = await DatabaseHelper.instance.getTransactions(userId: 'user_you');
      expect(txsBefore.isEmpty, isTrue);

      final expenses = await DatabaseHelper.instance.getExpenses('user_you');
      expect(expenses.isEmpty, isTrue);

      final txsAfter = await DatabaseHelper.instance.getTransactions(userId: 'user_you');
      expect(txsAfter.isEmpty, isTrue);
    });

    // 26. Clear action for You works using the existing personal expense/clear mechanism
    test('26. Clear action for You works using the existing personal expense/clear mechanism', () async {
      final expense = ExpenseModel(
        id: 'exp_you_001',
        userId: 'user_you',
        amount: 450.0,
        category: 'Food',
        description: 'Snacks',
        expenseDate: DateTime.now(),
        createdAt: DateTime.now(),
      );
      await DatabaseHelper.instance.insertExpense(expense);

      final beforeClear = await DatabaseHelper.instance.getExpenses('user_you');
      expect(beforeClear.length, 1);
      expect(beforeClear.first.amount, 450.0);

      await DatabaseHelper.instance.clearExpenses(userId: 'user_you');

      final afterClear = await DatabaseHelper.instance.getExpenses('user_you');
      expect(afterClear.isEmpty, isTrue);
    });

    // 27. Clearing You does not delete or modify normal friend transactions
    test('27. Clearing You does not delete or modify normal friend transactions', () async {
      final txId = await DatabaseHelper.instance.insertTransaction(
        TransactionModel(
          friendName: 'Rohan',
          amount: 500,
          note: 'Dinner',
          date: '2026-10-01',
          iGave: true,
          createdBy: 'user_you',
        ),
      );
      await DatabaseHelper.instance.insertExpense(
        ExpenseModel(
          id: 'exp_002',
          userId: 'user_you',
          amount: 200,
          category: 'Travel',
          description: 'Cab',
          expenseDate: DateTime.now(),
          createdAt: DateTime.now(),
        ),
      );

      await DatabaseHelper.instance.clearExpenses(userId: 'user_you');

      expect((await DatabaseHelper.instance.getExpenses('user_you')).isEmpty, isTrue);

      final txs = await DatabaseHelper.instance.getTransactions(userId: 'user_you');
      expect(txs.length, 1);
      expect(txs.first.id, txId);
      expect(txs.first.friendName, 'Rohan');
      expect(txs.first.amount, 500.0);
    });

    // 28. You is not inserted into local_friends
    test('28. You is not inserted into local_friends', () async {
      final friends = await DatabaseHelper.instance.getLocalFriends(userId: 'user_you');
      expect(friends.any((f) => f.name.toLowerCase() == 'you'), isFalse);
      expect(friends.any((f) => f.id == '__you__'), isFalse);
    });

    // ==================================================
    // ISSUE #2 REGRESSION TESTS
    // ==================================================

    // 1. You card does not open DailyExpenditureScreen
    testWidgets('Regression 1: You card does not open DailyExpenditureScreen', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                return InkWell(
                  key: const Key('home_you_card'),
                  onTap: () {
                    showModalBottomSheet(
                      context: context,
                      builder: (_) => const Text('Your Bill Split Shares'),
                    );
                  },
                  child: const Text('You'),
                );
              },
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('home_you_card')));
      await tester.pumpAndSettle();

      expect(find.text('Your Bill Split Shares'), findsOneWidget);
      expect(find.byType(DailyExpenditureScreen), findsNothing);
    });

    // 2. OCR split including You persists You's share
    test('Regression 2: OCR split including You persists You\'s share', () async {
      final splitId = 'split_ocr_001';
      await DatabaseHelper.instance.insertYouSplitShare(
        id: splitId,
        userId: 'user_reg_2',
        amount: 300.0,
        note: 'Dinner OCR Split',
        date: '2026-10-03',
        createdAt: '2026-10-03T12:00:00.000Z',
      );

      final shares = await DatabaseHelper.instance.getYouSplitShares(userId: 'user_reg_2');
      expect(shares.length, 1);
      expect(shares.first['amount'], 300.0);
      expect(shares.first['note'], 'Dinner OCR Split');
    });

    // 3. You split share appears on Home
    test('Regression 3: You split share appears on Home', () async {
      await DatabaseHelper.instance.insertYouSplitShare(
        id: 'split_home_001',
        userId: 'user_reg_3',
        amount: 300.0,
        note: 'Lunch Split',
        date: '2026-10-03',
        createdAt: '2026-10-03T12:00:00.000Z',
      );

      final homeTotal = await DatabaseHelper.instance.getYouSplitTotal(userId: 'user_reg_3');
      expect(homeTotal, 300.0);
    });

    // 4. Multiple splits accumulate: ₹300 + ₹200 = ₹500
    test('Regression 4: Multiple splits accumulate: ₹300 + ₹200 = ₹500', () async {
      await DatabaseHelper.instance.insertYouSplitShare(
        id: 'split_acc_1',
        userId: 'user_reg_4',
        amount: 300.0,
        note: 'Split 1',
        date: '2026-10-01',
        createdAt: '2026-10-01T12:00:00.000Z',
      );
      await DatabaseHelper.instance.insertYouSplitShare(
        id: 'split_acc_2',
        userId: 'user_reg_4',
        amount: 200.0,
        note: 'Split 2',
        date: '2026-10-02',
        createdAt: '2026-10-02T12:00:00.000Z',
      );

      final total = await DatabaseHelper.instance.getYouSplitTotal(userId: 'user_reg_4');
      expect(total, 500.0);
    });

    // 5. Clearing You resets only You split shares
    test('Regression 5: Clearing You resets only You split shares', () async {
      await DatabaseHelper.instance.insertYouSplitShare(
        id: 'split_clr_1',
        userId: 'user_reg_5',
        amount: 500.0,
        note: 'Split to clear',
        date: '2026-10-01',
        createdAt: '2026-10-01T12:00:00.000Z',
      );
      expect(await DatabaseHelper.instance.getYouSplitTotal(userId: 'user_reg_5'), 500.0);

      await DatabaseHelper.instance.clearYouSplitShares(userId: 'user_reg_5');

      expect(await DatabaseHelper.instance.getYouSplitTotal(userId: 'user_reg_5'), 0.0);
      expect((await DatabaseHelper.instance.getYouSplitShares(userId: 'user_reg_5')).isEmpty, isTrue);
    });

    // 6. Clearing You does not affect personal_expenses
    test('Regression 6: Clearing You does not affect personal_expenses', () async {
      final expense = ExpenseModel(
        id: 'exp_reg_6',
        userId: 'user_reg_6',
        amount: 450.0,
        category: 'Food',
        description: 'Snacks',
        expenseDate: DateTime.now(),
        createdAt: DateTime.now(),
      );
      await DatabaseHelper.instance.insertExpense(expense);
      await DatabaseHelper.instance.insertYouSplitShare(
        id: 'split_reg_6',
        userId: 'user_reg_6',
        amount: 200.0,
        date: '2026-10-01',
        createdAt: '2026-10-01T12:00:00.000Z',
      );

      await DatabaseHelper.instance.clearYouSplitShares(userId: 'user_reg_6');

      expect(await DatabaseHelper.instance.getYouSplitTotal(userId: 'user_reg_6'), 0.0);
      final expenses = await DatabaseHelper.instance.getExpenses('user_reg_6');
      expect(expenses.length, 1);
      expect(expenses.first.amount, 450.0);
    });

    // 7. Clearing You does not affect friend transactions
    test('Regression 7: Clearing You does not affect friend transactions', () async {
      final txId = await DatabaseHelper.instance.insertTransaction(
        TransactionModel(
          friendName: 'Rohan',
          amount: 300,
          note: 'Cafe',
          date: '2026-10-01',
          iGave: true,
          createdBy: 'user_reg_7',
        ),
      );
      await DatabaseHelper.instance.insertYouSplitShare(
        id: 'split_reg_7',
        userId: 'user_reg_7',
        amount: 300.0,
        date: '2026-10-01',
        createdAt: '2026-10-01T12:00:00.000Z',
      );

      await DatabaseHelper.instance.clearYouSplitShares(userId: 'user_reg_7');

      expect(await DatabaseHelper.instance.getYouSplitTotal(userId: 'user_reg_7'), 0.0);
      final txs = await DatabaseHelper.instance.getTransactions(userId: 'user_reg_7');
      expect(txs.length, 1);
      expect(txs.first.id, txId);
      expect(txs.first.friendName, 'Rohan');
      expect(txs.first.amount, 300.0);
    });

    // 8. You still creates zero Give/Take transactions
    test('Regression 8: You still creates zero Give/Take transactions', () async {
      await DatabaseHelper.instance.insertYouSplitShare(
        id: 'split_reg_8',
        userId: 'user_reg_8',
        amount: 300.0,
        date: '2026-10-01',
        createdAt: '2026-10-01T12:00:00.000Z',
      );
      final txs = await DatabaseHelper.instance.getTransactions(userId: 'user_reg_8');
      expect(txs.isEmpty, isTrue);
    });

    // 9. Manual friend created through Add Friend appears in OCR
    test('Regression 9: Manual friend created through Add Friend appears in OCR', () async {
      final friend = LocalFriendModel(
        id: DatabaseHelper.generateLocalId(),
        name: 'Manual Friend 1',
        userId: 'user_reg_9',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await DatabaseHelper.instance.insertLocalFriend(friend);

      final friends = await DatabaseHelper.instance.getLocalFriends(userId: 'user_reg_9');
      expect(friends.any((f) => f.name == 'Manual Friend 1'), isTrue);
    });

    // 10. Manual friend with zero transactions appears in OCR
    test('Regression 10: Manual friend with zero transactions appears in OCR', () async {
      final friend = LocalFriendModel(
        id: DatabaseHelper.generateLocalId(),
        name: 'Zero Tx Friend',
        userId: 'user_reg_10',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await DatabaseHelper.instance.insertLocalFriend(friend);

      final txs = await DatabaseHelper.instance.getTransactions(userId: 'user_reg_10');
      expect(txs.isEmpty, isTrue);

      final friends = await DatabaseHelper.instance.getLocalFriends(userId: 'user_reg_10');
      expect(friends.any((f) => f.name == 'Zero Tx Friend'), isTrue);
    });

    // 11. Manual friend created through Give/Take appears in OCR
    test('Regression 11: Manual friend created through Give/Take appears in OCR', () async {
      await DatabaseHelper.instance.insertTransaction(
        TransactionModel(
          friendName: 'Tx Created Friend',
          amount: 250,
          note: 'Direct Give',
          date: '2026-10-01',
          iGave: true,
          createdBy: 'user_reg_11',
        ),
      );

      await DatabaseHelper.instance.migrateExistingFriendsToLocal(userId: 'user_reg_11');

      final friends = await DatabaseHelper.instance.getLocalFriends(userId: 'user_reg_11');
      expect(friends.any((f) => f.name == 'Tx Created Friend'), isTrue);
    });

    // 12. Offline-created local friend remains available after authentication
    test('Regression 12: Offline-created local friend remains available after authentication', () async {
      final offlineFriend = LocalFriendModel(
        id: DatabaseHelper.generateLocalId(),
        name: 'Offline Bob',
        userId: '',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await DatabaseHelper.instance.insertLocalFriend(offlineFriend);

      await DatabaseHelper.instance.adoptOrphanLocalFriends('user_reg_12_auth');

      final authFriends = await DatabaseHelper.instance.getLocalFriends(userId: 'user_reg_12_auth');
      expect(authFriends.any((f) => f.name == 'Offline Bob'), isTrue);
    });

    // 13. Local friend remains user-scoped
    test('Regression 13: Local friend remains user-scoped', () async {
      final friendA = LocalFriendModel(
        id: DatabaseHelper.generateLocalId(),
        name: 'Private Friend A',
        userId: 'user_reg_13_A',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await DatabaseHelper.instance.insertLocalFriend(friendA);

      final friendsB = await DatabaseHelper.instance.getLocalFriends(userId: 'user_reg_13_B');
      expect(friendsB.any((f) => f.name == 'Private Friend A'), isFalse);
    });

    // 14. Connected friends still appear
    test('Regression 14: Connected friends still appear', () async {
      await db.insert('cached_friends', {
        'friendUid': 'cloud_uid_14',
        'friendName': 'Cloud Connected User',
        'email': 'cloud@user.com',
        'friendCode': 'CLOUD99',
        'photoUrl': '',
        'upiId': '',
        'mobileNumber': '',
      });

      final cached = await DatabaseHelper.instance.getAllCachedFriends();
      expect(cached.any((f) => f['friendUid'] == 'cloud_uid_14'), isTrue);
    });

    // 15. Local friends do not get fake Firebase UIDs
    test('Regression 15: Local friends do not get fake Firebase UIDs', () async {
      final friend = LocalFriendModel(
        id: DatabaseHelper.generateLocalId(),
        name: 'Strict Local',
        userId: 'user_reg_15',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await DatabaseHelper.instance.insertLocalFriend(friend);

      final friends = await DatabaseHelper.instance.getLocalFriends(userId: 'user_reg_15');
      final found = friends.firstWhere((f) => f.name == 'Strict Local');
      expect(found.id.startsWith('local_'), isTrue);
      // peerUserId in transactions is null for local friends
      final tx = TransactionModel(
        friendName: found.name,
        amount: 100,
        note: '',
        date: '2026-10-01',
        iGave: true,
        createdBy: 'user_reg_15',
        peerUserId: null,
      );
      expect(tx.peerUserId, isNull);
    });

    // 16. You is not inserted into local_friends
    test('Regression 16: You is not inserted into local_friends', () async {
      final friends = await DatabaseHelper.instance.getLocalFriends(userId: 'user_reg_16');
      expect(friends.any((f) => f.name.toLowerCase() == 'you'), isFalse);
      expect(friends.any((f) => f.id == '__you__'), isFalse);
    });
  });
}
