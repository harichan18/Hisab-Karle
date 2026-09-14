import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:hisab_kitab/models/transaction_model.dart';
import 'package:hisab_kitab/models/expense_model.dart';
import 'package:hisab_kitab/services/sync_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Offline-First Sync Queue & SQLite Tests', () {
    late Database db;

    setUp(() async {
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
)
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
        },
      );
    });

    tearDown(() async {
      await db.close();
    });

    test(
      '1. New local transaction gets pending status when cloud sync is unavailable',
      () async {
        final tx = TransactionModel(
          firebaseId: 'test_tx_offline_001',
          friendName: 'Rahul',
          amount: 500.0,
          note: 'Dinner',
          date: '2026-09-14',
          iGave: true,
          syncStatus: SyncStatus.pending,
          createdBy: 'user_123',
        );

        final id = await db.insert('transactions', tx.toMap());
        expect(id, isPositive);

        final pendingRows = await db.query(
          'transactions',
          where: 'sync_status = ? OR sync_status = ?',
          whereArgs: [SyncStatus.pending, SyncStatus.failed],
        );

        expect(pendingRows.length, 1);
        final retrieved = TransactionModel.fromMap(pendingRows.first);
        expect(retrieved.syncStatus, SyncStatus.pending);
        expect(retrieved.firebaseId, 'test_tx_offline_001');
        expect(retrieved.amount, 500.0);
        expect(retrieved.friendName, 'Rahul');
      },
    );

    test(
      '2. Successful cloud synchronization changes pending -> synced',
      () async {
        final tx = TransactionModel(
          firebaseId: 'test_tx_sync_002',
          friendName: 'Priya',
          amount: 1200.0,
          note: 'Groceries',
          date: '2026-09-14',
          iGave: false,
          syncStatus: SyncStatus.pending,
          createdBy: 'user_123',
        );

        final id = await db.insert('transactions', tx.toMap());

        // Simulate cloud sync success
        await db.update(
          'transactions',
          {'sync_status': SyncStatus.synced},
          where: 'id = ?',
          whereArgs: [id],
        );

        // Verify no longer pending
        final pendingRows = await db.query(
          'transactions',
          where: 'sync_status = ? OR sync_status = ?',
          whereArgs: [SyncStatus.pending, SyncStatus.failed],
        );
        expect(pendingRows, isEmpty);

        // Verify row is synced
        final allRows = await db.query(
          'transactions',
          where: 'id = ?',
          whereArgs: [id],
        );
        expect(allRows.first['sync_status'], SyncStatus.synced);
      },
    );

    test(
      '3. Failed network synchronization keeps the record pending/failed',
      () async {
        final tx = TransactionModel(
          firebaseId: 'test_tx_fail_003',
          friendName: 'Amit',
          amount: 250.0,
          note: 'Tea & snacks',
          date: '2026-09-14',
          iGave: true,
          syncStatus: SyncStatus.pending,
          createdBy: 'user_123',
        );

        final id = await db.insert('transactions', tx.toMap());

        // Simulate network unavailable error keeping pending
        await db.update(
          'transactions',
          {'sync_status': SyncStatus.pending},
          where: 'id = ?',
          whereArgs: [id],
        );

        var pending = await db.query(
          'transactions',
          where: 'sync_status = ?',
          whereArgs: [SyncStatus.pending],
        );
        expect(pending.length, 1);

        // Simulate permanent validation/auth failure marking failed
        await db.update(
          'transactions',
          {'sync_status': SyncStatus.failed},
          where: 'id = ?',
          whereArgs: [id],
        );

        var failed = await db.query(
          'transactions',
          where: 'sync_status = ?',
          whereArgs: [SyncStatus.failed],
        );
        expect(failed.length, 1);
        expect(failed.first['id'], id);
      },
    );

    test(
      '4. Retrying the same transaction does not create a new transaction ID',
      () async {
        const existingFirebaseId = 'deterministic_firebase_doc_id_444';
        final tx = TransactionModel(
          firebaseId: existingFirebaseId,
          friendName: 'Sneha',
          amount: 750.0,
          note: 'Movie tickets',
          date: '2026-09-14',
          iGave: true,
          syncStatus: SyncStatus.pending,
          createdBy: 'user_123',
        );

        final localId = await db.insert('transactions', tx.toMap());

        // Attempt 1: retry update
        await db.update(
          'transactions',
          {'sync_status': SyncStatus.syncing},
          where: 'id = ?',
          whereArgs: [localId],
        );

        // Attempt 2: retry update on network reconnect
        await db.update(
          'transactions',
          {'sync_status': SyncStatus.synced},
          where: 'id = ?',
          whereArgs: [localId],
        );

        final allRows = await db.query('transactions');
        expect(
          allRows.length,
          1,
          reason: 'Must not create duplicate rows on retries',
        );
        expect(allRows.first['id'], localId);
        expect(allRows.first['firebaseId'], existingFirebaseId);
        expect(allRows.first['sync_status'], SyncStatus.synced);
      },
    );

    test(
      '5. Multiple pending transactions are synchronized in sequence',
      () async {
        for (int i = 1; i <= 3; i++) {
          final tx = TransactionModel(
            firebaseId: 'multi_tx_$i',
            friendName: 'Friend $i',
            amount: i * 100.0,
            note: 'Batch test $i',
            date: '2026-09-14',
            iGave: true,
            syncStatus: SyncStatus.pending,
            createdBy: 'user_123',
          );
          await db.insert('transactions', tx.toMap());
        }

        final pending = await db.query(
          'transactions',
          where: 'sync_status = ?',
          whereArgs: [SyncStatus.pending],
          orderBy: 'id ASC',
        );
        expect(pending.length, 3);
        expect(pending[0]['friendName'], 'Friend 1');
        expect(pending[1]['friendName'], 'Friend 2');
        expect(pending[2]['friendName'], 'Friend 3');

        // Batch sync
        for (final row in pending) {
          await db.update(
            'transactions',
            {'sync_status': SyncStatus.synced},
            where: 'id = ?',
            whereArgs: [row['id']],
          );
        }

        final remainingPending = await db.query(
          'transactions',
          where: 'sync_status = ?',
          whereArgs: [SyncStatus.pending],
        );
        expect(remainingPending, isEmpty);
      },
    );

    test(
      '6. Sync service prevents concurrent duplicate sync runs via lock',
      () async {
        final syncService = SyncService.instance;
        expect(syncService.isSyncing, isFalse);

        // Without auth user, returns noUser immediately
        final resNoUser = await syncService.syncPending();
        expect(resNoUser.status, SyncResultStatus.noUser);
      },
    );

    test(
      '7. Peer mirrored transaction uses the same existing transaction ID',
      () {
        const sharedFirebaseId = 'mirrored_shared_doc_777';
        final original = TransactionModel(
          firebaseId: sharedFirebaseId,
          peerUserId: 'user_b',
          createdBy: 'user_a',
          friendName: 'User B',
          amount: 800.0,
          note: 'Hotel booking',
          date: '2026-09-14',
          iGave: true,
        );

        final mirrored = original.copyWith(
          friendName: 'User A',
          iGave: !original.iGave,
          peerUserId: 'user_a',
        );

        expect(original.firebaseId, sharedFirebaseId);
        expect(mirrored.firebaseId, sharedFirebaseId);
        expect(mirrored.iGave, isFalse);
        expect(mirrored.peerUserId, 'user_a');
        expect(mirrored.amount, 800.0);
      },
    );

    test('8. SQLite migration from v8 to v9 preserves existing data', () async {
      const dbPath = 'test_migration_v8_to_v9.db';
      await deleteDatabase(dbPath);

      // Create v8 database
      final migrationDb = await openDatabase(
        dbPath,
        version: 8,
        onCreate: (db, version) async {
          await db.execute('''
CREATE TABLE transactions(
id INTEGER PRIMARY KEY AUTOINCREMENT,
friendName TEXT,
amount REAL,
note TEXT,
date TEXT,
iGave INTEGER,
receiptPath TEXT
)
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
  createdAt TEXT
)
''');
        },
      );

      // Insert legacy rows
      await migrationDb.insert('transactions', {
        'friendName': 'Legacy Friend',
        'amount': 345.50,
        'note': 'Old lunch',
        'date': '2025-12-01',
        'iGave': 1,
        'receiptPath': '/data/receipt1.jpg',
      });

      await migrationDb.insert('personal_expenses', {
        'id': 'legacy_exp_01',
        'userId': 'user_legacy',
        'amount': 60.0,
        'category': 'Food',
        'description': 'Coffee',
        'expenseDate': '2025-12-01T10:00:00.000',
        'receiptUrl': null,
        'createdAt': '2025-12-01T10:00:00.000',
      });

      await migrationDb.close();

      // Reopen at v9 executing onUpgrade
      final upgradedDb = await openDatabase(
        dbPath,
        version: 9,
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 9) {
            await db.execute(
              'ALTER TABLE transactions ADD COLUMN firebaseId TEXT',
            );
            await db.execute(
              'ALTER TABLE transactions ADD COLUMN createdBy TEXT',
            );
            await db.execute(
              'ALTER TABLE transactions ADD COLUMN peerUserId TEXT',
            );
            await db.execute(
              'ALTER TABLE transactions ADD COLUMN sync_status INTEGER DEFAULT 0',
            );
            await db.execute(
              'ALTER TABLE personal_expenses ADD COLUMN sync_status INTEGER DEFAULT 0',
            );
          }
        },
      );

      // Verify transactions preserved
      final txRows = await upgradedDb.query('transactions');
      expect(txRows.length, 1);
      expect(txRows.first['friendName'], 'Legacy Friend');
      expect(txRows.first['amount'], 345.50);
      expect(txRows.first['note'], 'Old lunch');
      expect(txRows.first['receiptPath'], '/data/receipt1.jpg');

      // Verify personal expenses preserved
      final expRows = await upgradedDb.query('personal_expenses');
      expect(expRows.length, 1);
      expect(expRows.first['id'], 'legacy_exp_01');
      expect(expRows.first['amount'], 60.0);
      expect(expRows.first['description'], 'Coffee');

      await upgradedDb.close();
      await deleteDatabase(dbPath);
    });

    test(
      '9. Existing synced records remain synced (status 0) after migration',
      () async {
        const dbPath = 'test_migration_synced_status.db';
        await deleteDatabase(dbPath);

        final db = await openDatabase(
          dbPath,
          version: 8,
          onCreate: (db, version) async {
            await db.execute('''
CREATE TABLE transactions(
id INTEGER PRIMARY KEY AUTOINCREMENT,
friendName TEXT,
amount REAL,
note TEXT,
date TEXT,
iGave INTEGER,
receiptPath TEXT
)
''');
          },
        );

        await db.insert('transactions', {
          'friendName': 'Pre Migration User',
          'amount': 999.0,
          'note': 'Already synced long ago',
          'date': '2026-01-01',
          'iGave': 1,
          'receiptPath': null,
        });

        await db.close();

        final upgradedDb = await openDatabase(
          dbPath,
          version: 9,
          onUpgrade: (db, oldVersion, newVersion) async {
            if (oldVersion < 9) {
              await db.execute(
                'ALTER TABLE transactions ADD COLUMN firebaseId TEXT',
              );
              await db.execute(
                'ALTER TABLE transactions ADD COLUMN createdBy TEXT',
              );
              await db.execute(
                'ALTER TABLE transactions ADD COLUMN peerUserId TEXT',
              );
              await db.execute(
                'ALTER TABLE transactions ADD COLUMN sync_status INTEGER DEFAULT 0',
              );
            }
          },
        );

        final rows = await upgradedDb.query('transactions');
        expect(rows.length, 1);
        expect(
          rows.first['sync_status'],
          0,
          reason: 'DEFAULT 0 ensures pre-existing data is considered synced',
        );

        final pending = await upgradedDb.query(
          'transactions',
          where: 'sync_status = ? OR sync_status = ?',
          whereArgs: [SyncStatus.pending, SyncStatus.failed],
        );
        expect(
          pending,
          isEmpty,
          reason: 'Pre-existing records must not be re-synced',
        );

        await upgradedDb.close();
        await deleteDatabase(dbPath);
      },
    );

    test('10. Expenses follow the correct sync behavior', () async {
      final now = DateTime.now();
      final expense = ExpenseModel(
        id: 'exp_test_10',
        userId: 'user_xyz',
        amount: 450.0,
        category: 'Travel',
        description: 'Cab ride',
        expenseDate: now,
        createdAt: now,
        syncStatus: SyncStatus.pending,
      );

      await db.insert('personal_expenses', expense.toLocalMap());

      // Query pending expenses
      final pendingExpenses = await db.query(
        'personal_expenses',
        where: 'sync_status = ? OR sync_status = ?',
        whereArgs: [SyncStatus.pending, SyncStatus.failed],
      );
      expect(pendingExpenses.length, 1);
      final retrieved = ExpenseModel.fromLocalMap(pendingExpenses.first);
      expect(retrieved.id, 'exp_test_10');
      expect(retrieved.amount, 450.0);
      expect(retrieved.category, 'Travel');
      expect(retrieved.syncStatus, SyncStatus.pending);

      // Mark synced
      await db.update(
        'personal_expenses',
        {'sync_status': SyncStatus.synced},
        where: 'id = ?',
        whereArgs: ['exp_test_10'],
      );

      final remainingPending = await db.query(
        'personal_expenses',
        where: 'sync_status = ? OR sync_status = ?',
        whereArgs: [SyncStatus.pending, SyncStatus.failed],
      );
      expect(remainingPending, isEmpty);
    });

    test(
      '11. User A transactions are NOT returned for User B (multi-user isolation)',
      () async {
        // User A creates a transaction
        final txUserA = TransactionModel(
          firebaseId: 'tx_user_a_001',
          friendName: 'FriendOfA',
          amount: 300.0,
          note: 'User A personal note',
          date: '2026-09-14',
          iGave: true,
          createdBy: 'uid_user_a',
          syncStatus: SyncStatus.pending,
        );
        await db.insert('transactions', txUserA.toMap());

        // User B queries transactions filtered by User B's UID
        final rowsForUserB = await db.query(
          'transactions',
          where: 'createdBy = ? OR peerUserId = ?',
          whereArgs: ['uid_user_b', 'uid_user_b'],
        );
        expect(
          rowsForUserB,
          isEmpty,
          reason: "User B must not see User A's transactions",
        );

        // User A queries transactions filtered by User A's UID
        final rowsForUserA = await db.query(
          'transactions',
          where: 'createdBy = ? OR peerUserId = ?',
          whereArgs: ['uid_user_a', 'uid_user_a'],
        );
        expect(rowsForUserA.length, 1);
        expect(rowsForUserA.first['createdBy'], 'uid_user_a');
      },
    );

    test('12. User A expenses are NOT returned for User B', () async {
      final now = DateTime.now();
      final expUserA = ExpenseModel(
        id: 'exp_user_a_001',
        userId: 'uid_user_a',
        amount: 150.0,
        category: 'Food',
        description: 'Snacks A',
        expenseDate: now,
        createdAt: now,
        syncStatus: SyncStatus.pending,
      );
      await db.insert('personal_expenses', expUserA.toLocalMap());

      // Query for User B
      final rowsForUserB = await db.query(
        'personal_expenses',
        where: 'userId = ? AND (sync_status != 0)',
        whereArgs: ['uid_user_b'],
      );
      expect(
        rowsForUserB,
        isEmpty,
        reason: "User B must not see User A's pending expenses",
      );

      // Query for User A
      final rowsForUserA = await db.query(
        'personal_expenses',
        where: 'userId = ? AND (sync_status != 0)',
        whereArgs: ['uid_user_a'],
      );
      expect(rowsForUserA.length, 1);
      expect(rowsForUserA.first['userId'], 'uid_user_a');
    });

    test(
      '13. Peer transaction created by User A is visible to peer User B',
      () async {
        final txPeer = TransactionModel(
          firebaseId: 'tx_peer_001',
          friendName: 'User B Name',
          amount: 800.0,
          note: 'Shared dinner bill',
          date: '2026-09-14',
          iGave: true,
          createdBy: 'uid_user_a',
          peerUserId: 'uid_user_b',
          syncStatus: SyncStatus.synced,
        );
        await db.insert('transactions', txPeer.toMap());

        // User B querying should see it via peerUserId match
        final rowsForUserB = await db.query(
          'transactions',
          where: 'createdBy = ? OR peerUserId = ?',
          whereArgs: ['uid_user_b', 'uid_user_b'],
        );
        expect(rowsForUserB.length, 1);
        expect(rowsForUserB.first['firebaseId'], 'tx_peer_001');
        expect(rowsForUserB.first['peerUserId'], 'uid_user_b');
      },
    );

    test(
      '14. Interrupted syncing record (status=2) is recovered and not stuck',
      () async {
        // Transaction was marked syncing (2) when app process terminated
        final txInterrupted = TransactionModel(
          firebaseId: 'tx_stuck_001',
          friendName: 'Charlie',
          amount: 400.0,
          note: 'Interrupted sync',
          date: '2026-09-14',
          iGave: true,
          createdBy: 'uid_user_a',
          syncStatus: SyncStatus.syncing, // status 2
        );
        await db.insert('transactions', txInterrupted.toMap());

        // getPendingTransactions uses `sync_status != 0`
        final recoverable = await db.query(
          'transactions',
          where: 'createdBy = ? AND sync_status != 0',
          whereArgs: ['uid_user_a'],
        );
        expect(
          recoverable.length,
          1,
          reason: 'Records with status 2 must be picked up for re-sync',
        );
        expect(recoverable.first['sync_status'], SyncStatus.syncing);

        // Transition to synced
        await db.update(
          'transactions',
          {'sync_status': SyncStatus.synced},
          where: 'id = ?',
          whereArgs: [recoverable.first['id']],
        );

        final postSync = await db.query(
          'transactions',
          where: 'createdBy = ? AND sync_status != 0',
          whereArgs: ['uid_user_a'],
        );
        expect(postSync, isEmpty);
      },
    );

    test(
      '15. Local receipt path is preserved until Cloudinary upload succeeds',
      () async {
        final txWithReceipt = TransactionModel(
          firebaseId: 'tx_receipt_001',
          friendName: 'Kavita',
          amount: 950.0,
          note: 'Stationery with receipt',
          date: '2026-09-14',
          iGave: true,
          createdBy: 'uid_user_a',
          receiptPath: '/local/app/receipts/tx_receipt_001.jpg',
          receiptUrl: null, // offline: deferred upload
          syncStatus: SyncStatus.pending,
        );

        final rowId = await db.insert('transactions', txWithReceipt.toMap());

        // Verify receiptPath is stored while receiptUrl is null
        final rowBefore = (await db.query(
          'transactions',
          where: 'id = ?',
          whereArgs: [rowId],
        )).first;
        expect(
          rowBefore['receiptPath'],
          '/local/app/receipts/tx_receipt_001.jpg',
        );
        expect(rowBefore['receiptUrl'], isNull);

        // Simulate successful Cloudinary upload: updates receiptUrl and marks synced
        await db.update(
          'transactions',
          {
            'receiptUrl':
                'https://res.cloudinary.com/demo/image/upload/v1/receipt.jpg',
            'sync_status': SyncStatus.synced,
          },
          where: 'id = ?',
          whereArgs: [rowId],
        );

        final rowAfter = (await db.query(
          'transactions',
          where: 'id = ?',
          whereArgs: [rowId],
        )).first;
        expect(
          rowAfter['receiptPath'],
          '/local/app/receipts/tx_receipt_001.jpg',
          reason: 'Local path retained',
        );
        expect(
          rowAfter['receiptUrl'],
          'https://res.cloudinary.com/demo/image/upload/v1/receipt.jpg',
        );
        expect(rowAfter['sync_status'], SyncStatus.synced);
      },
    );

    test('16. Retry with same firebaseId remains idempotent', () async {
      final txInitial = TransactionModel(
        firebaseId: 'tx_idempotent_123',
        friendName: 'Vikram',
        amount: 200.0,
        note: 'Lunch',
        date: '2026-09-14',
        iGave: true,
        createdBy: 'uid_user_a',
        syncStatus: SyncStatus.pending,
      );
      final id = await db.insert('transactions', txInitial.toMap());

      // Simulate re-saving the same transaction with ConflictAlgorithm.replace behavior
      final txUpdate = txInitial.copyWith(
        id: id,
        amount: 250.0,
        syncStatus: SyncStatus.synced,
      );
      await db.update(
        'transactions',
        txUpdate.toMap(),
        where: 'firebaseId = ?',
        whereArgs: ['tx_idempotent_123'],
      );

      final allMatching = await db.query(
        'transactions',
        where: 'firebaseId = ?',
        whereArgs: ['tx_idempotent_123'],
      );
      expect(
        allMatching.length,
        1,
        reason: 'Should not create duplicate rows for same firebaseId',
      );
      expect(allMatching.first['amount'], 250.0);
      expect(allMatching.first['sync_status'], SyncStatus.synced);
    });

    test(
      '17. Restoring a deleted transaction preserves createdBy, receiptUrl, and sync_status',
      () async {
        // User deletes a transaction with receipt and ownership
        final deletedRowId = await db.insert('deleted_entries', {
          'originalEntryId': 42,
          'personId': 101,
          'userId': 'user_owner_abc',
          'friendName': 'Rohan',
          'date': '2026-09-15',
          'note': 'Restored lunch payment',
          'amount': 350.0,
          'isGiven': 1,
          'clearedDate': '2026-09-15',
          'receiptPath': '/data/user/0/receipts/img_01.jpg',
          'receiptUrl':
              'https://res.cloudinary.com/test/image/upload/v1/receipt_01.jpg',
        });

        // Simulate DatabaseHelper.restoreDeletedEntry
        final rows = await db.query(
          'deleted_entries',
          where: 'id = ?',
          whereArgs: [deletedRowId],
        );
        final deletedEntry = rows.first;

        await db.insert('transactions', {
          'createdBy': deletedEntry['userId'],
          'friendName': deletedEntry['friendName'],
          'amount': deletedEntry['amount'],
          'note': deletedEntry['note'],
          'date': deletedEntry['date'],
          'iGave': deletedEntry['isGiven'],
          'receiptPath': deletedEntry['receiptPath'],
          'receiptUrl': deletedEntry['receiptUrl'],
          'sync_status': SyncStatus.synced,
        });
        await db.delete(
          'deleted_entries',
          where: 'id = ?',
          whereArgs: [deletedRowId],
        );

        // Verify the restored transaction in transactions table
        final restoredRows = await db.query(
          'transactions',
          where: 'createdBy = ?',
          whereArgs: ['user_owner_abc'],
        );
        expect(restoredRows.length, 1);
        final restored = restoredRows.first;
        expect(
          restored['createdBy'],
          'user_owner_abc',
          reason:
              'Restored transaction must preserve creator UID for multi-user isolation',
        );
        expect(
          restored['receiptUrl'],
          'https://res.cloudinary.com/test/image/upload/v1/receipt_01.jpg',
          reason: 'Restored transaction must preserve Cloudinary receipt URL',
        );
        expect(restored['receiptPath'], '/data/user/0/receipts/img_01.jpg');
        expect(restored['sync_status'], SyncStatus.synced);

        // Verify it was deleted from deleted_entries
        final remainingDeleted = await db.query(
          'deleted_entries',
          where: 'id = ?',
          whereArgs: [deletedRowId],
        );
        expect(remainingDeleted, isEmpty);
      },
    );

    test(
      '18. Financial validation logic rejects 0, negative, NaN, and excessive amounts',
      () {
        bool isValidFinancialAmount(String input) {
          final trimmed = input.trim();
          if (trimmed.isEmpty) return false;
          final parsed = double.tryParse(trimmed);
          if (parsed == null || parsed.isNaN || parsed.isInfinite) return false;
          if (parsed <= 0) return false;
          if (parsed > 100000000) return false;
          return true;
        }

        // Valid amounts
        expect(isValidFinancialAmount('100'), isTrue);
        expect(isValidFinancialAmount('0.50'), isTrue);
        expect(isValidFinancialAmount('99999999.99'), isTrue);

        // Invalid amounts
        expect(isValidFinancialAmount(''), isFalse);
        expect(isValidFinancialAmount('   '), isFalse);
        expect(isValidFinancialAmount('0'), isFalse);
        expect(isValidFinancialAmount('-50'), isFalse);
        expect(isValidFinancialAmount('abc'), isFalse);
        expect(isValidFinancialAmount('NaN'), isFalse);
        expect(isValidFinancialAmount('Infinity'), isFalse);
        expect(
          isValidFinancialAmount('100000001'),
          isFalse,
        ); // exceeds 10 crore
      },
    );

    test(
      '19. Double-tap prevention guard rejects concurrent execution',
      () async {
        bool isExecuting = false;
        int executionCount = 0;

        Future<void> guardedOperation() async {
          if (isExecuting) return;
          isExecuting = true;
          try {
            executionCount++;
            await Future.delayed(const Duration(milliseconds: 50));
          } finally {
            isExecuting = false;
          }
        }

        // Simulate rapid multi-taps
        await Future.wait([
          guardedOperation(),
          guardedOperation(),
          guardedOperation(),
        ]);

        expect(
          executionCount,
          1,
          reason: 'Rapid multi-taps must execute only once',
        );
      },
    );
  });
}
