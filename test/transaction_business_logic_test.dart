import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:hisab_kitab/models/transaction_model.dart';
import 'package:hisab_kitab/models/friend_model.dart';
import 'package:hisab_kitab/database/database_helper.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Transaction Business Logic & Lifecycle Tests', () {
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
CREATE TABLE deleted_entries(
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

    test('1. Money given increases positive balance (You Gave / Collect)', () async {
      final tx = TransactionModel(
        firebaseId: 'tx_give_1',
        friendName: 'Aman',
        amount: 500.0,
        note: 'Lunch payment',
        date: '2026-09-15',
        iGave: true,
        createdBy: 'user_1',
      );

      final id = await db.insert('transactions', tx.toMap());
      expect(id, isPositive);

      final rows = await db.query('transactions', where: 'id = ?', whereArgs: [id]);
      final inserted = TransactionModel.fromMap(rows.first);

      expect(inserted.iGave, isTrue);
      expect(inserted.amount, 500.0);
      expect(inserted.friendName, 'Aman');
    });

    test('2. Money received records as incoming (You Took / Pay)', () async {
      final tx = TransactionModel(
        firebaseId: 'tx_take_1',
        friendName: 'Aman',
        amount: 200.0,
        note: 'Coffee reimbursement',
        date: '2026-09-15',
        iGave: false,
        createdBy: 'user_1',
      );

      final id = await db.insert('transactions', tx.toMap());
      final rows = await db.query('transactions', where: 'id = ?', whereArgs: [id]);
      final inserted = TransactionModel.fromMap(rows.first);

      expect(inserted.iGave, isFalse);
      expect(inserted.amount, 200.0);
    });

    test('3. Net balance calculation: totalGiven - totalTaken', () async {
      // User gave 500, then gave 300, then took 200 from Aman
      final transactions = [
        TransactionModel(
          firebaseId: 'tx_1',
          friendName: 'Aman',
          amount: 500.0,
          note: 'Movie ticket',
          date: '2026-09-10',
          iGave: true,
          createdBy: 'user_1',
        ),
        TransactionModel(
          firebaseId: 'tx_2',
          friendName: 'Aman',
          amount: 300.0,
          note: 'Popcorn',
          date: '2026-09-11',
          iGave: true,
          createdBy: 'user_1',
        ),
        TransactionModel(
          firebaseId: 'tx_3',
          friendName: 'Aman',
          amount: 200.0,
          note: 'Cash back',
          date: '2026-09-12',
          iGave: false,
          createdBy: 'user_1',
        ),
      ];

      for (final tx in transactions) {
        await db.insert('transactions', tx.toMap());
      }

      final rows = await db.query(
        'transactions',
        where: 'friendName = ?',
        whereArgs: ['Aman'],
      );
      final list = rows.map((r) => TransactionModel.fromMap(r)).toList();

      final totalGiven = list.where((t) => t.iGave).fold<double>(0.0, (sum, t) => sum + t.amount);
      final totalTaken = list.where((t) => !t.iGave).fold<double>(0.0, (sum, t) => sum + t.amount);
      final netBalance = totalGiven - totalTaken;

      expect(totalGiven, 800.0);
      expect(totalTaken, 200.0);
      expect(netBalance, 600.0); // Aman owes user ₹600
    });

    test('4. Inverted net balance when user owes money to friend', () async {
      // User took 1000, gave 400
      final transactions = [
        TransactionModel(
          firebaseId: 'tx_borrow',
          friendName: 'Priya',
          amount: 1000.0,
          note: 'Borrowed for groceries',
          date: '2026-09-10',
          iGave: false,
          createdBy: 'user_1',
        ),
        TransactionModel(
          firebaseId: 'tx_repay',
          friendName: 'Priya',
          amount: 400.0,
          note: 'Partial repayment',
          date: '2026-09-11',
          iGave: true,
          createdBy: 'user_1',
        ),
      ];

      for (final tx in transactions) {
        await db.insert('transactions', tx.toMap());
      }

      final rows = await db.query(
        'transactions',
        where: 'friendName = ?',
        whereArgs: ['Priya'],
      );
      final list = rows.map((r) => TransactionModel.fromMap(r)).toList();

      final totalGiven = list.where((t) => t.iGave).fold<double>(0.0, (sum, t) => sum + t.amount);
      final totalTaken = list.where((t) => !t.iGave).fold<double>(0.0, (sum, t) => sum + t.amount);
      final netBalance = totalGiven - totalTaken;

      expect(totalGiven, 400.0);
      expect(totalTaken, 1000.0);
      expect(netBalance, -600.0); // User owes Priya ₹600
    });

    test('5. Editing a transaction updates amount, note, and direction in SQLite', () async {
      final initialTx = TransactionModel(
        firebaseId: 'tx_edit_me',
        friendName: 'Rahul',
        amount: 350.0,
        note: 'Taxi',
        date: '2026-09-12',
        iGave: true,
        createdBy: 'user_1',
      );
      final id = await db.insert('transactions', initialTx.toMap());

      // Update to ₹450 with new note and flipped direction
      final updatedTx = initialTx.copyWith(
        id: id,
        amount: 450.0,
        note: 'Taxi + Toll',
        iGave: false,
        syncStatus: SyncStatus.pending,
      );

      final count = await db.update(
        'transactions',
        updatedTx.toMap(),
        where: 'id = ?',
        whereArgs: [id],
      );
      expect(count, 1);

      final rows = await db.query('transactions', where: 'id = ?', whereArgs: [id]);
      final stored = TransactionModel.fromMap(rows.first);
      expect(stored.amount, 450.0);
      expect(stored.note, 'Taxi + Toll');
      expect(stored.iGave, isFalse);
      expect(stored.syncStatus, SyncStatus.pending);
    });

    test('6. Deleting transaction moves record to deleted_entries with metadata', () async {
      final tx = TransactionModel(
        firebaseId: 'tx_delete_me',
        friendName: 'Kunal',
        amount: 700.0,
        note: 'Dinner split',
        date: '2026-09-14',
        iGave: true,
        createdBy: 'user_1',
        receiptPath: '/local/receipts/kunal.jpg',
        receiptUrl: 'https://cloudinary.com/kunal.jpg',
      );
      final id = await db.insert('transactions', tx.toMap());

      // Simulate clearEntry / soft-delete
      await db.transaction((txn) async {
        final rows = await txn.query('transactions', where: 'id = ?', whereArgs: [id]);
        expect(rows.isNotEmpty, isTrue);
        final entry = rows.first;

        await txn.insert('deleted_entries', {
          'originalEntryId': entry['id'],
          'personId': DatabaseHelper.personIdForName(entry['friendName'] as String),
          'userId': entry['createdBy'],
          'friendName': entry['friendName'],
          'date': entry['date'],
          'note': entry['note'],
          'amount': entry['amount'],
          'isGiven': entry['iGave'],
          'clearedDate': '2026-09-15',
          'receiptPath': entry['receiptPath'],
          'receiptUrl': entry['receiptUrl'],
        });

        await txn.delete('transactions', where: 'id = ?', whereArgs: [id]);
      });

      // Confirm removed from active transactions
      final activeRows = await db.query('transactions', where: 'id = ?', whereArgs: [id]);
      expect(activeRows.isEmpty, isTrue);

      // Confirm present in deleted_entries
      final deletedRows = await db.query(
        'deleted_entries',
        where: 'originalEntryId = ?',
        whereArgs: [id],
      );
      expect(deletedRows.length, 1);
      final deleted = DeletedEntryModel.fromMap(deletedRows.first);
      expect(deleted.friendName, 'Kunal');
      expect(deleted.amount, 700.0);
      expect(deleted.isGiven, isTrue);
      expect(deleted.receiptPath, '/local/receipts/kunal.jpg');
      expect(deleted.receiptUrl, 'https://cloudinary.com/kunal.jpg');
    });

    test('7. Restoring transaction moves record back to transactions with sync_status=synced', () async {
      // Insert deleted entry
      final deletedId = await db.insert('deleted_entries', {
        'originalEntryId': 99,
        'personId': DatabaseHelper.personIdForName('Kunal'),
        'userId': 'user_1',
        'friendName': 'Kunal',
        'date': '2026-09-14',
        'note': 'Dinner split',
        'amount': 700.0,
        'isGiven': 1,
        'clearedDate': '2026-09-15',
        'receiptPath': '/local/receipts/kunal.jpg',
        'receiptUrl': 'https://cloudinary.com/kunal.jpg',
      });

      // Restore entry
      await db.transaction((txn) async {
        final rows = await txn.query(
          'deleted_entries',
          where: 'id = ?',
          whereArgs: [deletedId],
        );
        final deletedEntry = rows.first;

        await txn.insert('transactions', {
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

        await txn.delete('deleted_entries', where: 'id = ?', whereArgs: [deletedId]);
      });

      // Confirm deleted_entries is empty
      final deletedRows = await db.query('deleted_entries', where: 'id = ?', whereArgs: [deletedId]);
      expect(deletedRows.isEmpty, isTrue);

      // Confirm restored in transactions
      final restoredRows = await db.query(
        'transactions',
        where: 'friendName = ?',
        whereArgs: ['Kunal'],
      );
      expect(restoredRows.length, 1);
      final restored = TransactionModel.fromMap(restoredRows.first);
      expect(restored.amount, 700.0);
      expect(restored.iGave, isTrue);
      expect(restored.receiptUrl, 'https://cloudinary.com/kunal.jpg');
      expect(restored.syncStatus, SyncStatus.synced);
    });

    test('8. Peer transaction mirroring logic inverts iGave and swaps user perspective', () {
      final originalTx = TransactionModel(
        firebaseId: 'tx_shared_peer_123',
        createdBy: 'user_alice',
        peerUserId: 'user_bob',
        friendName: 'Bob',
        amount: 1500.0,
        note: 'Flight booking share',
        date: '2026-09-15',
        iGave: true, // Alice gave Bob ₹1500
      );

      // Mirrored model for Bob
      final mirroredTx = originalTx.copyWith(
        friendName: 'Alice',
        iGave: !originalTx.iGave, // Inverted: Bob received ₹1500
        peerUserId: originalTx.createdBy,
      );

      expect(mirroredTx.firebaseId, originalTx.firebaseId);
      expect(mirroredTx.amount, 1500.0);
      expect(mirroredTx.iGave, isFalse); // Bob took money
      expect(mirroredTx.friendName, 'Alice');
      expect(mirroredTx.peerUserId, 'user_alice');
    });

    test('9. Deterministic personIdForName generates identical non-negative hash', () {
      final id1 = DatabaseHelper.personIdForName('Aman Sharma');
      final id2 = DatabaseHelper.personIdForName('  aman sharma  ');
      final id3 = DatabaseHelper.personIdForName('AMAN SHARMA');
      final idDiff = DatabaseHelper.personIdForName('Rohit Verma');

      expect(id1, isPositive);
      expect(id1, equals(id2));
      expect(id1, equals(id3));
      expect(id1, isNot(equals(idDiff)));
    });

    test('10. Multi-person balance separation: transactions with different friends do not leak', () async {
      final txList = [
        TransactionModel(
          firebaseId: 't1',
          friendName: 'Aman',
          amount: 500.0,
          note: 'Aman lunch',
          date: '2026-09-10',
          iGave: true,
          createdBy: 'user_1',
        ),
        TransactionModel(
          firebaseId: 't2',
          friendName: 'Neha',
          amount: 300.0,
          note: 'Neha movie',
          date: '2026-09-11',
          iGave: false,
          createdBy: 'user_1',
        ),
      ];

      for (final tx in txList) {
        await db.insert('transactions', tx.toMap());
      }

      final amanRows = await db.query(
        'transactions',
        where: 'LOWER(TRIM(friendName)) = ?',
        whereArgs: ['aman'],
      );
      final nehaRows = await db.query(
        'transactions',
        where: 'LOWER(TRIM(friendName)) = ?',
        whereArgs: ['neha'],
      );

      expect(amanRows.length, 1);
      expect(nehaRows.length, 1);
      expect(TransactionModel.fromMap(amanRows.first).amount, 500.0);
      expect(TransactionModel.fromMap(nehaRows.first).amount, 300.0);
    });

    test('11. FriendListItem displayName precedence: nickname overrides name', () {
      const itemWithNick = FriendListItem(
        name: 'Chandan Kushwaha',
        nickname: 'Chandu',
      );
      expect(itemWithNick.displayName, 'Chandu');

      const itemWithoutNick = FriendListItem(
        name: 'Chandan Kushwaha',
        nickname: '',
      );
      expect(itemWithoutNick.displayName, 'Chandan Kushwaha');

      const itemNullNick = FriendListItem(
        name: 'Binay Kushwaha',
        nickname: null,
      );
      expect(itemNullNick.displayName, 'Binay Kushwaha');
    });

    test('12. FirestoreFriendProfile displayName fallback: name -> email -> friendCode -> uid', () {
      const p1 = FirestoreFriendProfile(
        uid: 'uid_1',
        name: 'Alice',
        email: 'alice@example.com',
        friendCode: 'ABC123',
      );
      expect(p1.displayName, 'Alice');

      const p2 = FirestoreFriendProfile(
        uid: 'uid_2',
        name: '',
        email: 'bob@example.com',
        friendCode: 'DEF456',
      );
      expect(p2.displayName, 'bob@example.com');

      const p3 = FirestoreFriendProfile(
        uid: 'uid_3',
        name: '',
        email: '',
        friendCode: 'GHI789',
      );
      expect(p3.displayName, 'GHI789');

      const p4 = FirestoreFriendProfile(
        uid: 'uid_4',
        name: '',
        email: '',
        friendCode: '',
      );
      expect(p4.displayName, 'uid_4');
    });

    test('13. TransactionModel toFirestoreMap and fromFirestore preserve all fields', () {
      final tx = TransactionModel(
        firebaseId: 'doc_123',
        peerUserId: 'peer_abc',
        createdBy: 'creator_xyz',
        receiptUrl: 'https://cloudinary.com/doc.jpg',
        receiptPath: '/local/doc.jpg',
        friendName: 'Samir',
        amount: 1250.0,
        note: 'Concert pass',
        date: '2026-09-15',
        iGave: true,
      );

      final firestoreMap = tx.toFirestoreMap();
      expect(firestoreMap['friendName'], 'Samir');
      expect(firestoreMap['amount'], 1250.0);
      expect(firestoreMap['iGave'], isTrue);
      expect(firestoreMap['peerUserId'], 'peer_abc');
      expect(firestoreMap['createdBy'], 'creator_xyz');
      expect(firestoreMap['receiptUrl'], 'https://cloudinary.com/doc.jpg');

      final fromFs = TransactionModel.fromFirestore('doc_123', firestoreMap);
      expect(fromFs.firebaseId, 'doc_123');
      expect(fromFs.friendName, 'Samir');
      expect(fromFs.amount, 1250.0);
      expect(fromFs.iGave, isTrue);
      expect(fromFs.peerUserId, 'peer_abc');
    });

    test('14. DeletedEntryModel toFirestoreMap and fromFirestore roundtrip', () {
      final del = DeletedEntryModel(
        firebaseId: 'del_doc_1',
        originalEntryId: 55,
        originalFirebaseId: 'tx_orig_55',
        personId: 101,
        friendName: 'Pooja',
        date: '2026-09-10',
        note: 'Book purchase',
        amount: 400.0,
        isGiven: false,
        clearedDate: '2026-09-15',
        receiptUrl: 'https://cloudinary.com/del.jpg',
        receiptPath: '/local/del.jpg',
        peerUserId: 'peer_pooja',
      );

      final fsMap = del.toFirestoreMap();
      expect(fsMap['originalEntryId'], 55);
      expect(fsMap['friendName'], 'Pooja');
      expect(fsMap['amount'], 400.0);
      expect(fsMap['isGiven'], isFalse);

      final reconstructed = DeletedEntryModel.fromFirestore('del_doc_1', fsMap);
      expect(reconstructed.firebaseId, 'del_doc_1');
      expect(reconstructed.friendName, 'Pooja');
      expect(reconstructed.amount, 400.0);
      expect(reconstructed.isGiven, isFalse);
    });
  });
}

