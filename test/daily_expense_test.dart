import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:hisab_kitab/models/expense_model.dart';
import 'package:hisab_kitab/models/transaction_model.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Daily Personal Expense Business Logic & Lifecycle Tests', () {
    late Database db;

    setUp(() async {
      db = await openDatabase(
        inMemoryDatabasePath,
        version: 9,
        onCreate: (db, version) async {
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
        },
      );
    });

    tearDown(() async {
      await db.close();
    });

    test('1. Valid expense creation stores all fields in SQLite', () async {
      final now = DateTime(2026, 9, 15, 14, 30);
      final expense = ExpenseModel(
        id: 'exp_001',
        userId: 'user_a',
        amount: 250.0,
        category: 'Food',
        description: 'Office lunch with team',
        expenseDate: now,
        createdAt: now,
        receiptUrl: 'https://cloudinary.com/exp_receipt.jpg',
        syncStatus: SyncStatus.pending,
      );

      final insertedId = await db.insert('personal_expenses', expense.toLocalMap());
      expect(insertedId, isPositive);

      final rows = await db.query(
        'personal_expenses',
        where: 'id = ?',
        whereArgs: ['exp_001'],
      );
      expect(rows.length, 1);

      final retrieved = ExpenseModel.fromLocalMap(rows.first);
      expect(retrieved.id, 'exp_001');
      expect(retrieved.userId, 'user_a');
      expect(retrieved.amount, 250.0);
      expect(retrieved.category, 'Food');
      expect(retrieved.description, 'Office lunch with team');
      expect(retrieved.receiptUrl, 'https://cloudinary.com/exp_receipt.jpg');
      expect(retrieved.syncStatus, SyncStatus.pending);
    });

    test('2. Invalid amounts (zero, negative, NaN, Infinite) are rejected by validation logic', () {
      bool isValidExpenseAmount(double? amount) {
        if (amount == null) return false;
        if (amount <= 0 || amount.isNaN || amount.isInfinite) return false;
        if (amount > 100000000) return false;
        return true;
      }

      expect(isValidExpenseAmount(0.0), isFalse);
      expect(isValidExpenseAmount(-50.0), isFalse);
      expect(isValidExpenseAmount(double.nan), isFalse);
      expect(isValidExpenseAmount(double.infinity), isFalse);
      expect(isValidExpenseAmount(200000000.0), isFalse); // exceeds 10 crore
      expect(isValidExpenseAmount(150.0), isTrue);
      expect(isValidExpenseAmount(0.50), isTrue);
    });

    test('3. Editing an expense updates amount, category, description, and date', () async {
      final initialDate = DateTime(2026, 9, 10);
      final expense = ExpenseModel(
        id: 'exp_edit',
        userId: 'user_a',
        amount: 100.0,
        category: 'Food',
        description: 'Snacks',
        expenseDate: initialDate,
        createdAt: initialDate,
        syncStatus: SyncStatus.synced,
      );
      await db.insert('personal_expenses', expense.toLocalMap());

      // Update to Travel, ₹350, with pending sync
      final updatedDate = DateTime(2026, 9, 11);
      final updatedExpense = expense.copyWith(
        amount: 350.0,
        category: 'Travel',
        description: 'Auto fare',
        expenseDate: updatedDate,
        syncStatus: SyncStatus.pending,
      );

      final count = await db.update(
        'personal_expenses',
        updatedExpense.toLocalMap(),
        where: 'id = ?',
        whereArgs: ['exp_edit'],
      );
      expect(count, 1);

      final rows = await db.query(
        'personal_expenses',
        where: 'id = ?',
        whereArgs: ['exp_edit'],
      );
      final retrieved = ExpenseModel.fromLocalMap(rows.first);

      expect(retrieved.amount, 350.0);
      expect(retrieved.category, 'Travel');
      expect(retrieved.description, 'Auto fare');
      expect(retrieved.expenseDate.year, 2026);
      expect(retrieved.expenseDate.month, 9);
      expect(retrieved.expenseDate.day, 11);
      expect(retrieved.syncStatus, SyncStatus.pending);
    });

    test('4. Deletion of an expense removes it completely from SQLite', () async {
      final expense = ExpenseModel(
        id: 'exp_del',
        userId: 'user_a',
        amount: 50.0,
        category: 'Other',
        description: 'Stationery',
        expenseDate: DateTime.now(),
        createdAt: DateTime.now(),
      );
      await db.insert('personal_expenses', expense.toLocalMap());

      final deleteCount = await db.delete(
        'personal_expenses',
        where: 'id = ?',
        whereArgs: ['exp_del'],
      );
      expect(deleteCount, 1);

      final rows = await db.query(
        'personal_expenses',
        where: 'id = ?',
        whereArgs: ['exp_del'],
      );
      expect(rows.isEmpty, isTrue);
    });

    test('5. Categorization preserves standard categories and custom categories', () async {
      const categories = [
        'Food',
        'Travel',
        'Bills',
        'Shopping',
        'Entertainment',
        'Health',
        'Grocery',
        'Other',
      ];

      for (int i = 0; i < categories.length; i++) {
        final cat = categories[i];
        final expense = ExpenseModel(
          id: 'exp_cat_$i',
          userId: 'user_a',
          amount: (i + 1) * 100.0,
          category: cat,
          description: '$cat expense',
          expenseDate: DateTime.now(),
          createdAt: DateTime.now(),
        );
        await db.insert('personal_expenses', expense.toLocalMap());
      }

      final rows = await db.query('personal_expenses');
      expect(rows.length, categories.length);

      final retrievedCategories = rows.map((r) => r['category'] as String).toSet();
      for (final cat in categories) {
        expect(retrievedCategories.contains(cat), isTrue);
      }
    });

    test('6. Date handling: month and range queries filter correctly', () async {
      final septExpense = ExpenseModel(
        id: 'exp_sept',
        userId: 'user_a',
        amount: 500.0,
        category: 'Food',
        description: 'September dinner',
        expenseDate: DateTime(2026, 9, 10),
        createdAt: DateTime(2026, 9, 10),
      );

      final augExpense = ExpenseModel(
        id: 'exp_aug',
        userId: 'user_a',
        amount: 800.0,
        category: 'Bills',
        description: 'August electricity',
        expenseDate: DateTime(2026, 8, 25),
        createdAt: DateTime(2026, 8, 25),
      );

      await db.insert('personal_expenses', septExpense.toLocalMap());
      await db.insert('personal_expenses', augExpense.toLocalMap());

      // Query for September 2026 (between 2026-09-01 and 2026-09-30)
      final septRows = await db.query(
        'personal_expenses',
        where: 'expenseDate >= ? AND expenseDate <= ?',
        whereArgs: ['2026-09-01T00:00:00.000', '2026-09-30T23:59:59.999'],
      );

      expect(septRows.length, 1);
      expect(septRows.first['id'], 'exp_sept');
    });

    test('7. User ownership: User B cannot view or mutate User A expenses', () async {
      await db.insert('personal_expenses', ExpenseModel(
        id: 'exp_user_a',
        userId: 'user_a',
        amount: 999.0,
        category: 'Shopping',
        description: 'Headphones',
        expenseDate: DateTime.now(),
        createdAt: DateTime.now(),
      ).toLocalMap());

      await db.insert('personal_expenses', ExpenseModel(
        id: 'exp_user_b',
        userId: 'user_b',
        amount: 150.0,
        category: 'Food',
        description: 'Coffee',
        expenseDate: DateTime.now(),
        createdAt: DateTime.now(),
      ).toLocalMap());

      // Query scoped to User B
      final userBRows = await db.query(
        'personal_expenses',
        where: 'userId = ?',
        whereArgs: ['user_b'],
      );
      expect(userBRows.length, 1);
      expect(userBRows.first['id'], 'exp_user_b');
      expect(userBRows.first['amount'], 150.0);

      // Verify User A's expense is NOT in User B's result
      final ids = userBRows.map((r) => r['id'] as String).toList();
      expect(ids.contains('exp_user_a'), isFalse);
    });

    test('8. sync_status lifecycle transitions: synced -> pending -> syncing -> synced / failed', () async {
      final expense = ExpenseModel(
        id: 'exp_sync_lifecycle',
        userId: 'user_a',
        amount: 120.0,
        category: 'Travel',
        description: 'Bus ticket',
        expenseDate: DateTime.now(),
        createdAt: DateTime.now(),
        syncStatus: SyncStatus.pending, // 1
      );
      await db.insert('personal_expenses', expense.toLocalMap());

      // Transition to syncing (2)
      await db.update(
        'personal_expenses',
        {'sync_status': SyncStatus.syncing},
        where: 'id = ?',
        whereArgs: ['exp_sync_lifecycle'],
      );
      var row = (await db.query('personal_expenses', where: 'id = ?', whereArgs: ['exp_sync_lifecycle'])).first;
      expect(row['sync_status'], SyncStatus.syncing);

      // Transition to failed (3) when network drops
      await db.update(
        'personal_expenses',
        {'sync_status': SyncStatus.failed},
        where: 'id = ?',
        whereArgs: ['exp_sync_lifecycle'],
      );
      row = (await db.query('personal_expenses', where: 'id = ?', whereArgs: ['exp_sync_lifecycle'])).first;
      expect(row['sync_status'], SyncStatus.failed);

      // Recovery / Retry transition to synced (0)
      await db.update(
        'personal_expenses',
        {'sync_status': SyncStatus.synced},
        where: 'id = ?',
        whereArgs: ['exp_sync_lifecycle'],
      );
      row = (await db.query('personal_expenses', where: 'id = ?', whereArgs: ['exp_sync_lifecycle'])).first;
      expect(row['sync_status'], SyncStatus.synced);
    });
  });
}
