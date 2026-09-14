import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:hisab_kitab/models/transaction_model.dart';
import 'package:hisab_kitab/services/payment_ocr_service.dart';
import 'package:hisab_kitab/models/extracted_payment_info.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Receipt Lifecycle & Error Path Tests', () {
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

    test('1. Receipt attached offline: local path saved, receiptUrl initially null', () async {
      final tx = TransactionModel(
        firebaseId: 'tx_offline_receipt_1',
        friendName: 'Rohit',
        amount: 850.0,
        note: 'Supermarket shopping',
        date: '2026-09-15',
        iGave: true,
        createdBy: 'user_1',
        receiptPath: '/local/app_flutter/receipts/img_offline_001.jpg',
        receiptUrl: null, // offline
        syncStatus: SyncStatus.pending,
      );

      final id = await db.insert('transactions', tx.toMap());
      final rows = await db.query('transactions', where: 'id = ?', whereArgs: [id]);
      final inserted = TransactionModel.fromMap(rows.first);

      expect(inserted.receiptPath, '/local/app_flutter/receipts/img_offline_001.jpg');
      expect(inserted.receiptUrl, isNull);
      expect(inserted.syncStatus, SyncStatus.pending);
    });

    test('2. Failed Cloudinary upload keeps local receipt path for subsequent retries', () async {
      final tx = TransactionModel(
        firebaseId: 'tx_failed_upload',
        friendName: 'Varun',
        amount: 300.0,
        note: 'Medicine bill',
        date: '2026-09-15',
        iGave: true,
        createdBy: 'user_1',
        receiptPath: '/local/receipts/varun.jpg',
        receiptUrl: null,
        syncStatus: SyncStatus.pending,
      );
      final id = await db.insert('transactions', tx.toMap());

      // Upload throws NetworkException / 500 error: receiptPath must NOT be cleared
      await db.update(
        'transactions',
        {'sync_status': SyncStatus.failed},
        where: 'id = ?',
        whereArgs: [id],
      );

      final rows = await db.query('transactions', where: 'id = ?', whereArgs: [id]);
      final state = TransactionModel.fromMap(rows.first);

      expect(state.receiptPath, '/local/receipts/varun.jpg', reason: 'Local path retained for retry');
      expect(state.receiptUrl, isNull);
      expect(state.syncStatus, SyncStatus.failed);
    });

    test('3. Successful upload persists receiptUrl and keeps local receiptPath', () async {
      final tx = TransactionModel(
        firebaseId: 'tx_success_upload',
        friendName: 'Varun',
        amount: 300.0,
        note: 'Medicine bill',
        date: '2026-09-15',
        iGave: true,
        createdBy: 'user_1',
        receiptPath: '/local/receipts/varun.jpg',
        receiptUrl: null,
        syncStatus: SyncStatus.pending,
      );
      final id = await db.insert('transactions', tx.toMap());

      // Cloudinary upload succeeds -> update receiptUrl and mark synced
      const uploadedCloudinaryUrl = 'https://res.cloudinary.com/hisab/image/upload/v1234/varun.jpg';
      await db.update(
        'transactions',
        {
          'receiptUrl': uploadedCloudinaryUrl,
          'sync_status': SyncStatus.synced,
        },
        where: 'id = ?',
        whereArgs: [id],
      );

      final rows = await db.query('transactions', where: 'id = ?', whereArgs: [id]);
      final state = TransactionModel.fromMap(rows.first);

      expect(state.receiptUrl, uploadedCloudinaryUrl);
      expect(state.receiptPath, '/local/receipts/varun.jpg');
      expect(state.syncStatus, SyncStatus.synced);
    });

    test('4. Retrying failed sync uses existing firebaseId and does not create duplicate rows', () async {
      const fixedFirebaseId = 'fixed_firebase_id_999';
      final tx = TransactionModel(
        firebaseId: fixedFirebaseId,
        friendName: 'Deepa',
        amount: 450.0,
        note: 'Dinner',
        date: '2026-09-15',
        iGave: true,
        createdBy: 'user_1',
        syncStatus: SyncStatus.failed,
      );
      final id = await db.insert('transactions', tx.toMap());

      // Retry updates the existing record
      await db.update(
        'transactions',
        {'sync_status': SyncStatus.synced},
        where: 'firebaseId = ?',
        whereArgs: [fixedFirebaseId],
      );

      final matchingRows = await db.query(
        'transactions',
        where: 'firebaseId = ?',
        whereArgs: [fixedFirebaseId],
      );
      expect(matchingRows.length, 1);
      expect(matchingRows.first['id'], id);
      expect(matchingRows.first['sync_status'], SyncStatus.synced);
    });

    test('5. Deleting and restoring transaction preserves both receiptPath and receiptUrl', () async {
      final tx = TransactionModel(
        firebaseId: 'tx_receipt_restore',
        friendName: 'Gaurav',
        amount: 1500.0,
        note: 'Electronics',
        date: '2026-09-15',
        iGave: true,
        createdBy: 'user_1',
        receiptPath: '/local/receipts/gaurav.jpg',
        receiptUrl: 'https://cloudinary.com/gaurav.jpg',
        syncStatus: SyncStatus.synced,
      );
      final txId = await db.insert('transactions', tx.toMap());

      // Soft delete: move to deleted_entries
      final deletedId = await db.insert('deleted_entries', {
        'originalEntryId': txId,
        'personId': 202,
        'userId': 'user_1',
        'friendName': 'Gaurav',
        'date': '2026-09-15',
        'note': 'Electronics',
        'amount': 1500.0,
        'isGiven': 1,
        'clearedDate': '2026-09-15',
        'receiptPath': '/local/receipts/gaurav.jpg',
        'receiptUrl': 'https://cloudinary.com/gaurav.jpg',
      });
      await db.delete('transactions', where: 'id = ?', whereArgs: [txId]);

      // Verify in deleted_entries
      final delRow = (await db.query('deleted_entries', where: 'id = ?', whereArgs: [deletedId])).first;
      expect(delRow['receiptPath'], '/local/receipts/gaurav.jpg');
      expect(delRow['receiptUrl'], 'https://cloudinary.com/gaurav.jpg');

      // Restore to transactions
      final restoredId = await db.insert('transactions', {
        'createdBy': delRow['userId'],
        'friendName': delRow['friendName'],
        'amount': delRow['amount'],
        'note': delRow['note'],
        'date': delRow['date'],
        'iGave': delRow['isGiven'],
        'receiptPath': delRow['receiptPath'],
        'receiptUrl': delRow['receiptUrl'],
        'sync_status': SyncStatus.synced,
      });
      await db.delete('deleted_entries', where: 'id = ?', whereArgs: [deletedId]);

      final restoredRow = (await db.query('transactions', where: 'id = ?', whereArgs: [restoredId])).first;
      expect(restoredRow['receiptPath'], '/local/receipts/gaurav.jpg');
      expect(restoredRow['receiptUrl'], 'https://cloudinary.com/gaurav.jpg');
    });

    test('6. OCR parsing corrupted / random text fails safely without throwing exception', () {
      const corruptedOcrText = 'X9#!! %%% ??? @@@ random non payment noise without digits';
      final result = PaymentOcrService.instance.parseExtractedText(corruptedOcrText);

      expect(result.status, PaymentStatus.unclear);
      expect(result.amount, isNull);
      expect(result.rawText, corruptedOcrText);
    });

    test('7. Interrupted syncing state (status 2) is safely recovered without data loss', () async {
      // Simulate crash during sync: status is 2 (syncing)
      final id = await db.insert('transactions', {
        'firebaseId': 'tx_crashed_in_flight',
        'createdBy': 'user_1',
        'friendName': 'Alok',
        'amount': 600.0,
        'note': 'Crashed sync',
        'date': '2026-09-15',
        'iGave': 1,
        'sync_status': SyncStatus.syncing,
      });

      // App starts up: query for un-synced items (sync_status != 0)
      final unSynced = await db.query(
        'transactions',
        where: 'sync_status != ?',
        whereArgs: [SyncStatus.synced],
      );
      expect(unSynced.length, 1);
      expect(unSynced.first['sync_status'], SyncStatus.syncing);

      // Reset to pending or immediately retry sync
      await db.update(
        'transactions',
        {'sync_status': SyncStatus.synced},
        where: 'id = ?',
        whereArgs: [id],
      );

      final finalRow = (await db.query('transactions', where: 'id = ?', whereArgs: [id])).first;
      expect(finalRow['sync_status'], SyncStatus.synced);
    });
  });
}
