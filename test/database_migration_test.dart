import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:hisab_kitab/models/transaction_model.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('SQLite Database Schema Migration Tests (v8 -> v9)', () {
    const testDbPath = 'test_isolated_v8_to_v9_migration.db';

    tearDown(() async {
      await deleteDatabase(testDbPath);
    });

    test('1. Full migration from v8 schema creates all v9 columns without data loss', () async {
      await deleteDatabase(testDbPath);

      // Step 1: Initialize Database at Version 8 (pre-sync queue architecture)
      final v8Db = await openDatabase(
        testDbPath,
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
);
''');
          await db.execute('''
CREATE TABLE settings(
  id INTEGER PRIMARY KEY,
  bankBalance REAL
);
''');
          await db.execute('''
CREATE TABLE deleted_entries(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  originalEntryId INTEGER,
  personId INTEGER,
  friendName TEXT,
  date TEXT,
  note TEXT,
  amount REAL,
  isGiven INTEGER,
  clearedDate TEXT,
  receiptPath TEXT
);
''');
          await db.execute('''
CREATE TABLE personal_expenses(
  id TEXT PRIMARY KEY,
  userId TEXT,
  amount REAL,
  category TEXT,
  description TEXT,
  expenseDate TEXT,
  receiptUrl TEXT,
  createdAt TEXT
);
''');
        },
      );

      // Step 2: Seed v8 records
      final legacyTxId = await v8Db.insert('transactions', {
        'friendName': 'Harish',
        'amount': 450.0,
        'note': 'Chai and breakfast',
        'date': '2026-08-15',
        'iGave': 1,
        'receiptPath': '/data/user/0/receipts/harish_01.jpg',
      });
      expect(legacyTxId, isPositive);

      final legacyExpId = await v8Db.insert('personal_expenses', {
        'id': 'exp_v8_001',
        'userId': 'legacy_user_1',
        'amount': 150.0,
        'category': 'Food',
        'description': 'Evening snacks',
        'expenseDate': '2026-08-15T18:00:00.000',
        'receiptUrl': null,
        'createdAt': '2026-08-15T18:00:00.000',
      });
      expect(legacyExpId, isPositive);

      final legacyDeletedId = await v8Db.insert('deleted_entries', {
        'originalEntryId': 10,
        'personId': 101,
        'friendName': 'Ramesh',
        'date': '2026-08-10',
        'note': 'Settled debt',
        'amount': 200.0,
        'isGiven': 0,
        'clearedDate': '2026-08-11',
        'receiptPath': null,
      });
      expect(legacyDeletedId, isPositive);

      await v8Db.close();

      // Step 3: Upgrade to Version 9 using production migration logic
      final v9Db = await openDatabase(
        testDbPath,
        version: 9,
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 9) {
            await db.execute('ALTER TABLE transactions ADD COLUMN firebaseId TEXT');
            await db.execute('ALTER TABLE transactions ADD COLUMN createdBy TEXT');
            await db.execute('ALTER TABLE transactions ADD COLUMN peerUserId TEXT');
            await db.execute('ALTER TABLE transactions ADD COLUMN receiptUrl TEXT');
            await db.execute('ALTER TABLE transactions ADD COLUMN sync_status INTEGER DEFAULT 0');
            await db.execute('ALTER TABLE personal_expenses ADD COLUMN sync_status INTEGER DEFAULT 0');
            await db.execute('ALTER TABLE deleted_entries ADD COLUMN userId TEXT');
            await db.execute('ALTER TABLE deleted_entries ADD COLUMN receiptUrl TEXT');
          }
        },
      );

      // Step 4: Verify all new v9 columns exist and can be queried
      final txRows = await v9Db.query('transactions');
      expect(txRows.length, 1);
      final migratedTx = txRows.first;

      // Verify old columns preserved intact
      expect(migratedTx['id'], legacyTxId);
      expect(migratedTx['friendName'], 'Harish');
      expect(migratedTx['amount'], 450.0);
      expect(migratedTx['note'], 'Chai and breakfast');
      expect(migratedTx['date'], '2026-08-15');
      expect(migratedTx['iGave'], 1);
      expect(migratedTx['receiptPath'], '/data/user/0/receipts/harish_01.jpg');

      // Verify new columns defaulted cleanly
      expect(migratedTx['sync_status'], 0); // Synced by default
      expect(migratedTx['firebaseId'], isNull);
      expect(migratedTx['createdBy'], isNull);
      expect(migratedTx['peerUserId'], isNull);
      expect(migratedTx['receiptUrl'], isNull);

      // Verify personal expenses
      final expRows = await v9Db.query('personal_expenses');
      expect(expRows.length, 1);
      final migratedExp = expRows.first;
      expect(migratedExp['id'], 'exp_v8_001');
      expect(migratedExp['sync_status'], 0);

      // Verify deleted entries
      final delRows = await v9Db.query('deleted_entries');
      expect(delRows.length, 1);
      final migratedDel = delRows.first;
      expect(migratedDel['friendName'], 'Ramesh');
      expect(migratedDel['userId'], isNull);
      expect(migratedDel['receiptUrl'], isNull);

      // Step 5: Verify new records can be inserted with full v9 fields
      final newV9TxId = await v9Db.insert('transactions', {
        'firebaseId': 'tx_v9_brand_new',
        'createdBy': 'uid_v9_user',
        'peerUserId': 'uid_v9_peer',
        'friendName': 'V9 Friend',
        'amount': 1000.0,
        'note': 'New v9 transaction',
        'date': '2026-09-15',
        'iGave': 1,
        'receiptPath': '/path/receipt.jpg',
        'receiptUrl': 'https://cloudinary.com/v9.jpg',
        'sync_status': SyncStatus.pending,
      });
      expect(newV9TxId, isPositive);

      final newRows = await v9Db.query('transactions', where: 'id = ?', whereArgs: [newV9TxId]);
      final retrievedNew = TransactionModel.fromMap(newRows.first);
      expect(retrievedNew.firebaseId, 'tx_v9_brand_new');
      expect(retrievedNew.syncStatus, SyncStatus.pending);
      expect(retrievedNew.createdBy, 'uid_v9_user');

      await v9Db.close();
    });

    test('2. Legacy records without createdBy remain accessible under legacy fallback query', () async {
      await deleteDatabase(testDbPath);

      final db = await openDatabase(
        testDbPath,
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
        },
      );

      // Insert a legacy record (createdBy IS NULL)
      await db.insert('transactions', {
        'friendName': 'Old Friend',
        'amount': 250.0,
        'note': 'Old note',
        'date': '2026-01-01',
        'iGave': 1,
        'sync_status': 0,
        'createdBy': null,
      });

      // Query with legacy support: (createdBy IS NULL OR createdBy = ? OR peerUserId = ?)
      const currentUserId = 'first_logged_in_user';
      final rows = await db.query(
        'transactions',
        where: 'createdBy IS NULL OR createdBy = ? OR peerUserId = ?',
        whereArgs: [currentUserId, currentUserId],
      );

      expect(rows.length, 1);
      expect(rows.first['friendName'], 'Old Friend');

      await db.close();
    });
  });
}
