import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:hisab_kitab/models/transaction_model.dart';
import 'package:hisab_kitab/models/expense_model.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Multi-User Isolation & Authentication Scoping Tests', () {
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
  createdAt TEXT,
  sync_status INTEGER DEFAULT 0
);
''');
          await db.execute('''
CREATE TABLE migration_meta(
  key TEXT PRIMARY KEY,
  value TEXT
);
''');
        },
      );
    });

    tearDown(() async {
      await db.close();
    });

    test('1. User A sees their own transactions and pending transactions', () async {
      final tx = TransactionModel(
        firebaseId: 'tx_a_1',
        friendName: 'Rohan',
        amount: 500.0,
        note: 'User A note',
        date: '2026-09-15',
        iGave: true,
        createdBy: 'user_a',
        syncStatus: SyncStatus.pending,
      );
      await db.insert('transactions', tx.toMap());

      final rows = await db.query(
        'transactions',
        where: 'createdBy = ? OR peerUserId = ?',
        whereArgs: ['user_a', 'user_a'],
      );

      expect(rows.length, 1);
      expect(rows.first['createdBy'], 'user_a');
      expect(rows.first['sync_status'], SyncStatus.pending);
    });

    test('2. User B CANNOT see User A local transactions', () async {
      final txA = TransactionModel(
        firebaseId: 'tx_a_secret',
        friendName: 'Private Friend',
        amount: 25000.0,
        note: 'Secret loan',
        date: '2026-09-15',
        iGave: true,
        createdBy: 'user_a',
        syncStatus: SyncStatus.synced,
      );
      await db.insert('transactions', txA.toMap());

      // User B query
      final rowsForB = await db.query(
        'transactions',
        where: 'createdBy = ? OR peerUserId = ?',
        whereArgs: ['user_b', 'user_b'],
      );

      expect(rowsForB, isEmpty);
    });

    test('3. User B CANNOT sync User A pending transactions', () async {
      // User A created an offline transaction that is still pending
      await db.insert('transactions', TransactionModel(
        firebaseId: 'tx_a_pending',
        friendName: 'Friend A',
        amount: 300.0,
        note: 'Pending tx',
        date: '2026-09-15',
        iGave: true,
        createdBy: 'user_a',
        syncStatus: SyncStatus.pending,
      ).toMap());

      // Sync queue query running while User B is logged in
      final pendingForUserB = await db.query(
        'transactions',
        where: 'createdBy = ? AND (sync_status != ?)',
        whereArgs: ['user_b', SyncStatus.synced],
      );

      expect(pendingForUserB, isEmpty, reason: "User B must never sync User A's pending records");
    });

    test('4. User B CANNOT see User A personal expenses', () async {
      await db.insert('personal_expenses', ExpenseModel(
        id: 'exp_a_secret',
        userId: 'user_a',
        amount: 1200.0,
        category: 'Health',
        description: 'Doctor consultation',
        expenseDate: DateTime.now(),
        createdAt: DateTime.now(),
      ).toLocalMap());

      // Query for User B
      final rowsForB = await db.query(
        'personal_expenses',
        where: 'userId = ?',
        whereArgs: ['user_b'],
      );

      expect(rowsForB, isEmpty);
    });

    test('5. User B CAN see legitimate peer transaction where peerUserId == User B', () async {
      // User A creates a transaction involving User B as the peer
      final peerTx = TransactionModel(
        firebaseId: 'tx_peer_ab',
        friendName: 'User B',
        amount: 900.0,
        note: 'Shared dinner',
        date: '2026-09-15',
        iGave: true,
        createdBy: 'user_a',
        peerUserId: 'user_b',
        syncStatus: SyncStatus.synced,
      );
      await db.insert('transactions', peerTx.toMap());

      // User B queries transactions
      final rowsForB = await db.query(
        'transactions',
        where: 'createdBy = ? OR peerUserId = ?',
        whereArgs: ['user_b', 'user_b'],
      );

      expect(rowsForB.length, 1);
      expect(rowsForB.first['firebaseId'], 'tx_peer_ab');
      expect(rowsForB.first['peerUserId'], 'user_b');
    });

    test('6. Null user handling: offline unauthenticated queries do not throw', () async {
      // When currentUser is null, app queries all local transactions or imported legacy
      final unauthenticatedRows = await db.query('transactions');
      expect(unauthenticatedRows, isNotNull);
    });

    test('7. Switching users (logout User A -> login User B) filters data strictly per user', () async {
      // User A records
      await db.insert('transactions', TransactionModel(
        firebaseId: 'tx_session_a',
        friendName: 'Friend A',
        amount: 100.0,
        note: 'Session A',
        date: '2026-09-15',
        iGave: true,
        createdBy: 'user_a',
      ).toMap());

      await db.insert('personal_expenses', ExpenseModel(
        id: 'exp_session_a',
        userId: 'user_a',
        amount: 50.0,
        category: 'Food',
        description: 'Session A food',
        expenseDate: DateTime.now(),
        createdAt: DateTime.now(),
      ).toLocalMap());

      // User B records
      await db.insert('transactions', TransactionModel(
        firebaseId: 'tx_session_b',
        friendName: 'Friend B',
        amount: 200.0,
        note: 'Session B',
        date: '2026-09-15',
        iGave: false,
        createdBy: 'user_b',
      ).toMap());

      await db.insert('personal_expenses', ExpenseModel(
        id: 'exp_session_b',
        userId: 'user_b',
        amount: 80.0,
        category: 'Travel',
        description: 'Session B travel',
        expenseDate: DateTime.now(),
        createdAt: DateTime.now(),
      ).toLocalMap());

      // Active session: User A
      final sessionATransactions = await db.query(
        'transactions',
        where: 'createdBy = ? OR peerUserId = ?',
        whereArgs: ['user_a', 'user_a'],
      );
      final sessionAExpenses = await db.query(
        'personal_expenses',
        where: 'userId = ?',
        whereArgs: ['user_a'],
      );
      expect(sessionATransactions.length, 1);
      expect(sessionATransactions.first['firebaseId'], 'tx_session_a');
      expect(sessionAExpenses.length, 1);
      expect(sessionAExpenses.first['id'], 'exp_session_a');

      // Logout User A, Login User B
      final sessionBTransactions = await db.query(
        'transactions',
        where: 'createdBy = ? OR peerUserId = ?',
        whereArgs: ['user_b', 'user_b'],
      );
      final sessionBExpenses = await db.query(
        'personal_expenses',
        where: 'userId = ?',
        whereArgs: ['user_b'],
      );
      expect(sessionBTransactions.length, 1);
      expect(sessionBTransactions.first['firebaseId'], 'tx_session_b');
      expect(sessionBExpenses.length, 1);
      expect(sessionBExpenses.first['id'], 'exp_session_b');
    });
  });
}
