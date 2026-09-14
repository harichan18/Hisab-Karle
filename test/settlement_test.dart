import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:hisab_kitab/models/transaction_model.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Settlement Calculation & Lifecycle Tests', () {
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
CREATE TABLE settlements(
  settlementId TEXT PRIMARY KEY,
  friendName TEXT,
  amount REAL,
  settledBy TEXT,
  settledAt TEXT,
  createdBy TEXT,
  userEmail TEXT
);
''');
        },
      );
    });

    tearDown(() async {
      await db.close();
    });

    double calculateNetBalance(List<TransactionModel> txs, String friendName) {
      final relevant = txs.where(
        (t) => t.friendName.trim().toLowerCase() == friendName.trim().toLowerCase(),
      );
      final given = relevant.where((t) => t.iGave).fold<double>(0.0, (sum, t) => sum + t.amount);
      final taken = relevant.where((t) => !t.iGave).fold<double>(0.0, (sum, t) => sum + t.amount);
      return given - taken;
    }

    test('1. Full settlement when friend owes user brings net balance to zero', () async {
      // Friend owes ₹1000 (User gave ₹1000)
      final initialTx = TransactionModel(
        firebaseId: 'tx_init',
        friendName: 'Vikas',
        amount: 1000.0,
        note: 'Loan',
        date: '2026-09-01',
        iGave: true,
        createdBy: 'user_1',
      );
      await db.insert('transactions', initialTx.toMap());

      var rows = await db.query('transactions');
      var list = rows.map((r) => TransactionModel.fromMap(r)).toList();
      expect(calculateNetBalance(list, 'Vikas'), 1000.0);

      // Full settlement: Vikas pays user ₹1000 (User receives -> iGave: false)
      final settlementTx = TransactionModel(
        firebaseId: 'tx_settle_full',
        friendName: 'Vikas',
        amount: 1000.0,
        note: 'Full settlement',
        date: '2026-09-15',
        iGave: false,
        createdBy: 'user_1',
      );
      await db.insert('transactions', settlementTx.toMap());

      rows = await db.query('transactions');
      list = rows.map((r) => TransactionModel.fromMap(r)).toList();
      final finalBalance = calculateNetBalance(list, 'Vikas');

      expect(finalBalance, 0.0);
    });

    test('2. Full settlement when user owes friend brings net balance to zero', () async {
      // User owes ₹500 (User took ₹500)
      final initialTx = TransactionModel(
        firebaseId: 'tx_borrow_500',
        friendName: 'Deepak',
        amount: 500.0,
        note: 'Borrowed for dinner',
        date: '2026-09-05',
        iGave: false,
        createdBy: 'user_1',
      );
      await db.insert('transactions', initialTx.toMap());

      var rows = await db.query('transactions');
      var list = rows.map((r) => TransactionModel.fromMap(r)).toList();
      expect(calculateNetBalance(list, 'Deepak'), -500.0);

      // Full settlement: User pays Deepak ₹500 (User gave -> iGave: true)
      final settlementTx = TransactionModel(
        firebaseId: 'tx_settle_deepak',
        friendName: 'Deepak',
        amount: 500.0,
        note: 'Full repayment',
        date: '2026-09-15',
        iGave: true,
        createdBy: 'user_1',
      );
      await db.insert('transactions', settlementTx.toMap());

      rows = await db.query('transactions');
      list = rows.map((r) => TransactionModel.fromMap(r)).toList();
      final finalBalance = calculateNetBalance(list, 'Deepak');

      expect(finalBalance, 0.0);
    });

    test('3. Partial settlement reduces outstanding balance proportionally', () async {
      // Friend owes ₹1500
      await db.insert('transactions', TransactionModel(
        firebaseId: 'tx_p1',
        friendName: 'Sanjay',
        amount: 1500.0,
        note: 'Event tickets',
        date: '2026-09-10',
        iGave: true,
        createdBy: 'user_1',
      ).toMap());

      // Sanjay pays partial ₹600
      await db.insert('transactions', TransactionModel(
        firebaseId: 'tx_p2',
        friendName: 'Sanjay',
        amount: 600.0,
        note: 'Partial settlement',
        date: '2026-09-12',
        iGave: false,
        createdBy: 'user_1',
      ).toMap());

      final rows = await db.query('transactions');
      final list = rows.map((r) => TransactionModel.fromMap(r)).toList();
      final netBalance = calculateNetBalance(list, 'Sanjay');

      expect(netBalance, 900.0); // ₹1500 - ₹600 = ₹900
    });

    test('4. Settlement direction determination logic based on current balance sign', () {
      bool determineSettlementDirection(double balance) {
        // If balance > 0 (Friend owes me), settlement means I took money (iGave: false).
        // If balance < 0 (I owe friend), settlement means I gave money (iGave: true).
        return balance < 0;
      }

      expect(determineSettlementDirection(500.0), isFalse); // Receive money
      expect(determineSettlementDirection(-250.0), isTrue); // Pay money
    });

    test('5. Zero balance returns zero required settlement amount', () {
      final txs = [
        TransactionModel(
          firebaseId: 't1',
          friendName: 'Ritu',
          amount: 400.0,
          note: 'Cab',
          date: '2026-09-01',
          iGave: true,
          createdBy: 'user_1',
        ),
        TransactionModel(
          firebaseId: 't2',
          friendName: 'Ritu',
          amount: 400.0,
          note: 'Cab share received',
          date: '2026-09-02',
          iGave: false,
          createdBy: 'user_1',
        ),
      ];

      final balance = calculateNetBalance(txs, 'Ritu');
      expect(balance, 0.0);

      // Settle action with 0 balance requires 0
      final requiredSettle = balance.abs();
      expect(requiredSettle, 0.0);
    });

    test('6. Over-settlement inverts net balance direction', () async {
      // Friend owes ₹300
      await db.insert('transactions', TransactionModel(
        firebaseId: 'tx_init_300',
        friendName: 'Tanmay',
        amount: 300.0,
        note: 'Snacks',
        date: '2026-09-10',
        iGave: true,
        createdBy: 'user_1',
      ).toMap());

      // Tanmay sends ₹500 (overpayment of ₹200)
      await db.insert('transactions', TransactionModel(
        firebaseId: 'tx_overpay_500',
        friendName: 'Tanmay',
        amount: 500.0,
        note: 'Overpayment settlement',
        date: '2026-09-15',
        iGave: false,
        createdBy: 'user_1',
      ).toMap());

      final rows = await db.query('transactions');
      final list = rows.map((r) => TransactionModel.fromMap(r)).toList();
      final netBalance = calculateNetBalance(list, 'Tanmay');

      // Now user owes Tanmay ₹200
      expect(netBalance, -200.0);
    });

    test('7. Repeated sequential partial settlements reconcile accurately to zero', () async {
      // Friend owes ₹1000
      await db.insert('transactions', TransactionModel(
        firebaseId: 'tx_seq_init',
        friendName: 'Ankit',
        amount: 1000.0,
        note: 'Trip expense',
        date: '2026-09-01',
        iGave: true,
        createdBy: 'user_1',
      ).toMap());

      final partialPayments = [300.0, 450.0, 250.0];
      for (int i = 0; i < partialPayments.length; i++) {
        await db.insert('transactions', TransactionModel(
          firebaseId: 'tx_partial_$i',
          friendName: 'Ankit',
          amount: partialPayments[i],
          note: 'Partial payment ${i + 1}',
          date: '2026-09-0${i + 2}',
          iGave: false,
          createdBy: 'user_1',
        ).toMap());
      }

      final rows = await db.query('transactions');
      final list = rows.map((r) => TransactionModel.fromMap(r)).toList();
      final netBalance = calculateNetBalance(list, 'Ankit');

      expect(netBalance, 0.0);
    });

    test('8. Settlement history record persists required fields and metadata', () async {
      await db.insert('settlements', {
        'settlementId': 'settle_doc_99',
        'friendName': 'Vikas',
        'amount': 1000.0,
        'settledBy': 'User Display',
        'settledAt': '2026-09-15T10:30:00Z',
        'createdBy': 'user_1',
        'userEmail': 'user1@example.com',
      });

      final rows = await db.query('settlements', where: 'settlementId = ?', whereArgs: ['settle_doc_99']);
      expect(rows.length, 1);
      final record = rows.first;

      expect(record['friendName'], 'Vikas');
      expect(record['amount'], 1000.0);
      expect(record['settledBy'], 'User Display');
      expect(record['createdBy'], 'user_1');
      expect(record['userEmail'], 'user1@example.com');
    });

    test('9. Settlements with Friend A do not mutate Friend B balance', () async {
      await db.insert('transactions', TransactionModel(
        firebaseId: 'tx_a',
        friendName: 'Friend A',
        amount: 500.0,
        note: 'Note A',
        date: '2026-09-10',
        iGave: true,
        createdBy: 'user_1',
      ).toMap());

      await db.insert('transactions', TransactionModel(
        firebaseId: 'tx_b',
        friendName: 'Friend B',
        amount: 800.0,
        note: 'Note B',
        date: '2026-09-10',
        iGave: true,
        createdBy: 'user_1',
      ).toMap());

      // Settle Friend A completely
      await db.insert('transactions', TransactionModel(
        firebaseId: 'tx_settle_a',
        friendName: 'Friend A',
        amount: 500.0,
        note: 'Settled A',
        date: '2026-09-15',
        iGave: false,
        createdBy: 'user_1',
      ).toMap());

      final rows = await db.query('transactions');
      final list = rows.map((r) => TransactionModel.fromMap(r)).toList();

      expect(calculateNetBalance(list, 'Friend A'), 0.0);
      expect(calculateNetBalance(list, 'Friend B'), 800.0);
    });
  });
}
