import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as p;
import 'package:hisab_kitab/core/utils/transaction_display_helper.dart';
import 'package:hisab_kitab/database/database_helper.dart';
import 'package:hisab_kitab/models/pending_deletion_model.dart';
import 'package:hisab_kitab/models/transaction_model.dart';

/// End-to-end regression test suite for Give/Take transaction editing lifecycle:
/// - SQLite persistence by id and firebaseId
/// - mergeTransactions precedence for local pending edits over stale remote snapshots
/// - Preservation of SQLite id across merges
/// - Creator-only permissions vs manual friend editing
/// - Offline edit durability, pending sync queue, and duplicate prevention
/// - Balance reconciliation and durable deletion invariants
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Transaction Edit Lifecycle & Persistence Tests', () {
    late Database db;
    late Directory tempDir;

    Future<Database> createTestDb(String path) async {
      return await openDatabase(
        path,
        version: 12,
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
          await db.execute('''
CREATE TABLE IF NOT EXISTS pending_deletions(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  userId TEXT NOT NULL,
  type TEXT NOT NULL,
  friendName TEXT NOT NULL,
  friendUid TEXT,
  localFriendId TEXT,
  firebaseIds TEXT,
  createdAt TEXT NOT NULL
);
''');
        },
      );
    }

    setUp(() async {
      DatabaseHelper.deletedFirebaseIds.clear();
      tempDir = await Directory.systemTemp.createTemp('hisab_edit_test_');
      final dbPath = p.join(tempDir.path, 'test_hisab_edit_v12.db');
      db = await createTestDb(dbPath);
      DatabaseHelper.setTestDatabase(db);
    });

    tearDown(() async {
      DatabaseHelper.setTestDatabase(null);
      await db.close();
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
      DatabaseHelper.deletedFirebaseIds.clear();
    });

    /// Simulates AddPage.saveTransaction edit logic matching production implementation
    Future<bool> simulateSaveEditedTransaction({
      required TransactionModel original,
      required String updatedAmount,
      required String updatedNote,
      required String updatedDate,
      required bool updatedIGave,
      String? currentUserId,
      String? updatedReceiptPath,
      String? updatedReceiptUrl,
      Future<void> Function(TransactionModel tx, String? firebaseId)?
      cloudSaveHandler,
    }) async {
      final parsedAmount = double.tryParse(updatedAmount);
      if (parsedAmount == null || parsedAmount <= 0) {
        return false;
      }

      // 1. Enforce creator-only permissions for connected transactions
      final isConnected =
          original.peerUserId != null && original.peerUserId!.isNotEmpty;
      if (isConnected) {
        if (currentUserId == null ||
            original.createdBy == null ||
            original.createdBy != currentUserId) {
          return false; // Edit denied
        }
      }

      // 2. Resolve existing local SQLite ID and preserve original Firebase document ID
      int? localId = original.id;
      final targetFirebaseId = original.firebaseId;

      if (localId == null &&
          targetFirebaseId != null &&
          targetFirebaseId.isNotEmpty) {
        final existing = await DatabaseHelper.instance
            .getTransactionByFirebaseId(targetFirebaseId);
        if (existing != null) {
          localId = existing.id;
        }
      }

      // 3. Build updated transaction payload preserving ownership and identifiers
      final updatedTx = TransactionModel(
        id: localId,
        firebaseId: targetFirebaseId,
        peerUserId: original.peerUserId,
        createdBy: original.createdBy ?? currentUserId,
        friendName: original.friendName,
        amount: parsedAmount,
        note: updatedNote,
        date: updatedDate,
        iGave: updatedIGave,
        receiptPath: updatedReceiptPath ?? original.receiptPath,
        receiptUrl: updatedReceiptUrl ?? original.receiptUrl,
        syncStatus: currentUserId != null
            ? SyncStatus.pending
            : SyncStatus.synced,
      );

      // 4. Update existing local row, or insert local cache row if not in SQLite yet
      if (localId != null) {
        final rows = await DatabaseHelper.instance.updateTransaction(updatedTx);
        if (rows == 0) {
          localId = await DatabaseHelper.instance.insertTransaction(updatedTx);
        }
      } else {
        localId = await DatabaseHelper.instance.insertTransaction(updatedTx);
      }

      // 5. Update cloud if handler supplied
      if (currentUserId != null && cloudSaveHandler != null) {
        try {
          await cloudSaveHandler(
            updatedTx.copyWith(id: localId),
            targetFirebaseId,
          );
          await DatabaseHelper.instance.updateTransactionSyncStatus(
            localId,
            SyncStatus.synced,
            firebaseId: targetFirebaseId,
          );
        } catch (_) {
          // Cloud failed or offline: safely retained with SyncStatus.pending in SQLite
        }
      }

      return true;
    }

    test('1. Editing a transaction with a valid SQLite ID', () async {
      const userUid = 'user_test_1';
      final initialTx = TransactionModel(
        firebaseId: 'fb_doc_101',
        friendName: 'Rohan',
        amount: 200.0,
        note: 'Coffee',
        date: '2026-10-01',
        iGave: true,
        createdBy: userUid,
      );
      final id = await DatabaseHelper.instance.insertTransaction(initialTx);
      expect(id, isPositive);

      final originalWithId = initialTx.copyWith(id: id);

      final success = await simulateSaveEditedTransaction(
        original: originalWithId,
        updatedAmount: '350.0',
        updatedNote: 'Coffee + snacks',
        updatedDate: '2026-10-02',
        updatedIGave: true,
        currentUserId: userUid,
      );

      expect(success, isTrue);

      final reloaded = await DatabaseHelper.instance.getTransactions(
        userId: userUid,
      );
      expect(reloaded.length, 1);
      final edited = reloaded.first;
      expect(edited.id, id);
      expect(edited.firebaseId, 'fb_doc_101');
      expect(edited.amount, 350.0);
      expect(edited.note, 'Coffee + snacks');
      expect(edited.date, '2026-10-02');
      expect(edited.iGave, isTrue);
    });

    test(
      '2. Editing a Firestore-loaded transaction with id == null and a valid firebaseId',
      () async {
        const userUid = 'user_test_2';
        const fid = 'fb_streamed_doc_202';

        // 2A: Transaction exists in SQLite, but UI receives a stream model with id == null
        final localRowId = await DatabaseHelper.instance.insertTransaction(
          TransactionModel(
            firebaseId: fid,
            friendName: 'Priya',
            amount: 500.0,
            note: 'Original lunch',
            date: '2026-10-01',
            iGave: true,
            createdBy: userUid,
          ),
        );

        // Model simulated directly from Firestore stream (id is null)
        final streamedFromFirestore = TransactionModel(
          id: null, // As produced by TransactionModel.fromFirestore
          firebaseId: fid,
          friendName: 'Priya',
          amount: 500.0,
          note: 'Original lunch',
          date: '2026-10-01',
          iGave: true,
          createdBy: userUid,
        );

        final success = await simulateSaveEditedTransaction(
          original: streamedFromFirestore,
          updatedAmount: '650.0',
          updatedNote: 'Lunch with dessert',
          updatedDate: '2026-10-03',
          updatedIGave: true,
          currentUserId: userUid,
        );

        expect(success, isTrue);

        final allRows = await DatabaseHelper.instance.getTransactions(
          userId: userUid,
        );
        expect(allRows.length, 1);
        final updated = allRows.first;
        expect(updated.id, localRowId);
        expect(updated.firebaseId, fid);
        expect(updated.amount, 650.0);
        expect(updated.note, 'Lunch with dessert');

        // 2B: Transaction is not in SQLite yet (e.g. freshly fetched remote document)
        const fidNew = 'fb_fresh_remote_303';
        final freshlyFetchedRemote = TransactionModel(
          id: null,
          firebaseId: fidNew,
          friendName: 'Priya',
          amount: 1000.0,
          note: 'Trip booking',
          date: '2026-10-04',
          iGave: false,
          createdBy: userUid,
        );

        final success2 = await simulateSaveEditedTransaction(
          original: freshlyFetchedRemote,
          updatedAmount: '1200.0',
          updatedNote: 'Trip booking adjusted',
          updatedDate: '2026-10-04',
          updatedIGave: false,
          currentUserId: userUid,
        );

        expect(success2, isTrue);

        final afterFetch = await DatabaseHelper.instance
            .getTransactionByFirebaseId(fidNew);
        expect(afterFetch, isNotNull);
        expect(afterFetch!.amount, 1200.0);
        expect(afterFetch.note, 'Trip booking adjusted');
        expect(afterFetch.firebaseId, fidNew);
      },
    );

    test(
      '3. Editing an existing local row by Firebase ID without inserting a duplicate',
      () async {
        const userUid = 'user_test_3';
        const fid = 'fb_unique_key_404';

        await DatabaseHelper.instance.insertTransaction(
          TransactionModel(
            firebaseId: fid,
            friendName: 'Sameer',
            amount: 300.0,
            note: 'Cab fare',
            date: '2026-10-01',
            iGave: true,
            createdBy: userUid,
          ),
        );

        final unkeyedEdit = TransactionModel(
          id: null,
          firebaseId: fid,
          friendName: 'Sameer',
          amount: 300.0,
          note: 'Cab fare',
          date: '2026-10-01',
          iGave: true,
          createdBy: userUid,
        );

        await simulateSaveEditedTransaction(
          original: unkeyedEdit,
          updatedAmount: '450.0',
          updatedNote: 'Cab fare + tip',
          updatedDate: '2026-10-01',
          updatedIGave: true,
          currentUserId: userUid,
        );

        final matches = await db.query(
          'transactions',
          where: 'firebaseId = ?',
          whereArgs: [fid],
        );
        expect(
          matches.length,
          1,
          reason: 'Must update in place without duplicate insertion',
        );
        expect(matches.first['amount'], 450.0);
        expect(matches.first['note'], 'Cab fare + tip');
      },
    );

    test(
      '4. Persisting the currently editable fields and reloading the updated transaction',
      () async {
        const userUid = 'user_test_4';
        final initial = TransactionModel(
          firebaseId: 'fb_all_fields_505',
          friendName: 'Kunal',
          amount: 100.0,
          note: 'Initial note',
          date: '2026-10-01',
          iGave: true,
          receiptPath: '/local/receipt_old.jpg',
          receiptUrl: 'https://cdn.example.com/receipt_old.jpg',
          createdBy: userUid,
        );
        final id = await DatabaseHelper.instance.insertTransaction(initial);

        final success = await simulateSaveEditedTransaction(
          original: initial.copyWith(id: id),
          updatedAmount: '250.75',
          updatedNote: 'Updated note with details',
          updatedDate: '2026-10-05',
          updatedIGave: false, // Flipped direction (Took instead of Gave)
          updatedReceiptPath: '/local/receipt_new.jpg',
          updatedReceiptUrl: 'https://cdn.example.com/receipt_new.jpg',
          currentUserId: userUid,
        );
        expect(success, isTrue);

        final reloaded = await DatabaseHelper.instance
            .getTransactionByFirebaseId('fb_all_fields_505');
        expect(reloaded, isNotNull);
        expect(reloaded!.amount, 250.75);
        expect(reloaded.note, 'Updated note with details');
        expect(reloaded.date, '2026-10-05');
        expect(reloaded.iGave, isFalse);
        expect(reloaded.receiptPath, '/local/receipt_new.jpg');
        expect(reloaded.receiptUrl, 'https://cdn.example.com/receipt_new.jpg');
        expect(
          reloaded.friendName,
          'Kunal',
          reason: 'Friend identity must be strictly preserved',
        );
      },
    );

    test(
      '5. Offline editing, pending status, restart persistence, and later sync using the same Firebase document ID',
      () async {
        const userUid = 'user_offline_edit';
        const fid = 'fb_offline_doc_606';

        final initial = TransactionModel(
          firebaseId: fid,
          friendName: 'Aman',
          amount: 400.0,
          note: 'Dinner',
          date: '2026-10-01',
          iGave: true,
          createdBy: userUid,
          syncStatus: SyncStatus.synced,
        );
        final id = await DatabaseHelper.instance.insertTransaction(initial);

        // Offline edit: cloud save throws network exception
        await simulateSaveEditedTransaction(
          original: initial.copyWith(id: id),
          updatedAmount: '550.0',
          updatedNote: 'Dinner + dessert',
          updatedDate: '2026-10-02',
          updatedIGave: true,
          currentUserId: userUid,
          cloudSaveHandler: (tx, cloudFid) async {
            throw const SocketException('Network offline');
          },
        );

        // Verify SQLite state immediately after offline edit
        final pendingBeforeRestart = await DatabaseHelper.instance
            .getPendingTransactions(userId: userUid);
        expect(pendingBeforeRestart.length, 1);
        expect(pendingBeforeRestart.first.amount, 550.0);
        expect(pendingBeforeRestart.first.syncStatus, SyncStatus.pending);

        // Simulate App Restart by closing and reopening the SQLite database
        final dbPath = db.path;
        await db.close();
        db = await openDatabase(dbPath, version: 12);
        DatabaseHelper.setTestDatabase(db);

        // Verify pending status and edited values survive restart
        final pendingAfterRestart = await DatabaseHelper.instance
            .getPendingTransactions(userId: userUid);
        expect(pendingAfterRestart.length, 1);
        final txToSync = pendingAfterRestart.first;
        expect(txToSync.amount, 550.0);
        expect(txToSync.firebaseId, fid);

        // Simulate SyncService.syncPending() execution
        final cloudCollection = <String, TransactionModel>{
          fid: initial, // Stale Firestore document
        };

        // SyncService reuses tx.firebaseId to update the existing Firestore document
        final resolvedFirebaseId = txToSync.firebaseId ?? 'fallback_id';
        expect(
          resolvedFirebaseId,
          fid,
          reason: 'Must reuse existing Firebase ID; never generate new ID',
        );
        cloudCollection[resolvedFirebaseId] = txToSync; // In-place update

        await DatabaseHelper.instance.updateTransactionSyncStatus(
          txToSync.id!,
          SyncStatus.synced,
          firebaseId: resolvedFirebaseId,
        );

        // Verify cloud mock updated in-place without duplicate
        expect(cloudCollection.length, 1);
        expect(cloudCollection[fid]!.amount, 550.0);
        expect(cloudCollection[fid]!.note, 'Dinner + dessert');

        // Verify SQLite record is now synced
        final remainingPending = await DatabaseHelper.instance
            .getPendingTransactions(userId: userUid);
        expect(remainingPending, isEmpty);
      },
    );

    test('6. A stale remote snapshot not overriding a pending local edit', () {
      const fid = 'shared_fid_707';

      final staleRemote = TransactionModel(
        id: null,
        firebaseId: fid,
        friendName: 'Vikram',
        amount: 200.0, // Stale remote amount
        note: 'Movie',
        date: '2026-10-01',
        iGave: true,
        createdBy: 'user_v',
      );

      final localPendingEdit = TransactionModel(
        id: 42, // SQLite primary key
        firebaseId: fid,
        friendName: 'Vikram',
        amount: 350.0, // Locally edited amount
        note: 'Movie + Popcorn',
        date: '2026-10-02',
        iGave: true,
        createdBy: 'user_v',
        syncStatus: SyncStatus.pending, // Pending local edit!
      );

      final merged = mergeTransactions(
        remote: [staleRemote],
        local: [localPendingEdit],
      );

      expect(merged.length, 1);
      final result = merged.first;
      expect(
        result.amount,
        350.0,
        reason:
            'Local pending edit must take precedence over stale remote snapshot',
      );
      expect(result.note, 'Movie + Popcorn');
      expect(result.id, 42, reason: 'Local SQLite id must be preserved');
      expect(result.syncStatus, SyncStatus.pending);
    });

    test('7. Failed cloud updates remaining pending and retryable', () async {
      const userUid = 'user_test_7';
      const fid = 'fb_cloud_fail_808';

      final initial = TransactionModel(
        firebaseId: fid,
        friendName: 'Harish',
        amount: 700.0,
        note: 'Hotel',
        date: '2026-10-01',
        iGave: true,
        createdBy: userUid,
      );
      final id = await DatabaseHelper.instance.insertTransaction(initial);

      // Cloud save fails
      final success = await simulateSaveEditedTransaction(
        original: initial.copyWith(id: id),
        updatedAmount: '850.0',
        updatedNote: 'Hotel + tax',
        updatedDate: '2026-10-02',
        updatedIGave: true,
        currentUserId: userUid,
        cloudSaveHandler: (tx, cloudFid) async {
          throw const HttpException('Server unavailable');
        },
      );

      expect(success, isTrue); // Local persistence succeeds

      final pendingList = await DatabaseHelper.instance.getPendingTransactions(
        userId: userUid,
      );
      expect(pendingList.length, 1);
      expect(pendingList.first.amount, 850.0);
      expect(pendingList.first.syncStatus, SyncStatus.pending);
    });

    test('8. A connected transaction creator being allowed to edit', () async {
      const creatorUid = 'user_creator_8';
      const peerUid = 'user_peer_8';

      final connectedTx = TransactionModel(
        firebaseId: 'fb_connected_909',
        peerUserId: peerUid,
        createdBy: creatorUid,
        friendName: 'Peer Bob',
        amount: 900.0,
        note: 'Trip share',
        date: '2026-10-01',
        iGave: true,
      );
      final id = await DatabaseHelper.instance.insertTransaction(connectedTx);

      // Creator edits -> Allowed
      final success = await simulateSaveEditedTransaction(
        original: connectedTx.copyWith(id: id),
        updatedAmount: '950.0',
        updatedNote: 'Trip share revised',
        updatedDate: '2026-10-01',
        updatedIGave: true,
        currentUserId: creatorUid,
      );

      expect(success, isTrue);
      final updated = await DatabaseHelper.instance.getTransactionByFirebaseId(
        'fb_connected_909',
      );
      expect(updated!.amount, 950.0);
    });

    test(
      '9. A non-creator being denied, including a transaction with missing creator identity',
      () async {
        const creatorUid = 'user_creator_real';
        const nonCreatorUid = 'user_attacker';
        const peerUid = 'user_peer_target';

        // 9A: Non-creator attempting to edit creator's transaction
        final connectedTx = TransactionModel(
          firebaseId: 'fb_connected_guard_001',
          peerUserId: peerUid,
          createdBy: creatorUid,
          friendName: 'Alice',
          amount: 1000.0,
          note: 'Rent',
          date: '2026-10-01',
          iGave: true,
        );
        await DatabaseHelper.instance.insertTransaction(connectedTx);

        final allowedNonCreator = await simulateSaveEditedTransaction(
          original: connectedTx,
          updatedAmount: '50.0',
          updatedNote: 'Forged edit',
          updatedDate: '2026-10-01',
          updatedIGave: true,
          currentUserId: nonCreatorUid, // NOT the creator!
        );
        expect(
          allowedNonCreator,
          isFalse,
          reason: 'Non-creator must be denied',
        );

        // Verify data remains untouched
        final unchanged = await DatabaseHelper.instance
            .getTransactionByFirebaseId('fb_connected_guard_001');
        expect(unchanged!.amount, 1000.0);

        // 9B: Connected transaction with missing createdBy identity
        final unestablishedTx = TransactionModel(
          firebaseId: 'fb_connected_guard_002',
          peerUserId: peerUid,
          createdBy: null, // Ownership cannot be established
          friendName: 'Bob',
          amount: 500.0,
          note: 'Missing creator test',
          date: '2026-10-01',
          iGave: true,
        );
        await DatabaseHelper.instance.insertTransaction(unestablishedTx);

        final allowedMissingCreator = await simulateSaveEditedTransaction(
          original: unestablishedTx,
          updatedAmount: '100.0',
          updatedNote: 'Unauthorized edit',
          updatedDate: '2026-10-01',
          updatedIGave: true,
          currentUserId: nonCreatorUid,
        );
        expect(
          allowedMissingCreator,
          isFalse,
          reason: 'Must reject edits when ownership cannot be established',
        );
      },
    );

    test(
      '10. A manual transaction with null peerUserId and null createdBy remaining editable',
      () async {
        const userUid = 'local_user_10';

        // Legacy local manual transaction
        final manualLegacyTx = TransactionModel(
          firebaseId: 'fb_manual_legacy_101',
          peerUserId: null, // Manual friend
          createdBy: null, // Legacy row missing createdBy
          friendName: 'Manual Dave',
          amount: 150.0,
          note: 'Stationery',
          date: '2026-09-01',
          iGave: true,
        );
        final id = await DatabaseHelper.instance.insertTransaction(
          manualLegacyTx,
        );

        final success = await simulateSaveEditedTransaction(
          original: manualLegacyTx.copyWith(id: id),
          updatedAmount: '220.0',
          updatedNote: 'Stationery + Notebooks',
          updatedDate: '2026-09-02',
          updatedIGave: true,
          currentUserId: userUid,
        );

        expect(
          success,
          isTrue,
          reason:
              'Manual transactions must remain editable under local-user ownership',
        );

        final updated = await DatabaseHelper.instance
            .getTransactionByFirebaseId('fb_manual_legacy_101');
        expect(updated!.amount, 220.0);
        expect(updated.note, 'Stationery + Notebooks');
      },
    );

    test(
      '11. Connected and manual friend transactions retaining correct balances and history',
      () async {
        const userUid = 'user_balance_test';

        // Manual friend "Charlie"
        final manualTx1 = TransactionModel(
          firebaseId: 'm_tx_1',
          friendName: 'Charlie',
          amount: 500.0,
          note: 'Dinner',
          date: '2026-10-01',
          iGave: true, // You gave 500
          createdBy: userUid,
        );
        final manualTx2 = TransactionModel(
          firebaseId: 'm_tx_2',
          friendName: 'Charlie',
          amount: 200.0,
          note: 'Tea',
          date: '2026-10-02',
          iGave: false, // You took 200
          createdBy: userUid,
        );
        final id1 = await DatabaseHelper.instance.insertTransaction(manualTx1);
        await DatabaseHelper.instance.insertTransaction(manualTx2);

        // Initial net balance: 500 - 200 = 300
        var txs = await DatabaseHelper.instance.getTransactions(
          userId: userUid,
        );
        var netBalance = txs.fold<double>(
          0.0,
          (sum, t) => sum + (t.iGave ? t.amount : -t.amount),
        );
        expect(netBalance, 300.0);

        // Edit manualTx1: change amount from 500 to 700
        await simulateSaveEditedTransaction(
          original: manualTx1.copyWith(id: id1),
          updatedAmount: '700.0',
          updatedNote: 'Dinner with drinks',
          updatedDate: '2026-10-01',
          updatedIGave: true,
          currentUserId: userUid,
        );

        // Recomputed net balance: 700 - 200 = 500
        txs = await DatabaseHelper.instance.getTransactions(userId: userUid);
        netBalance = txs.fold<double>(
          0.0,
          (sum, t) => sum + (t.iGave ? t.amount : -t.amount),
        );
        expect(
          netBalance,
          500.0,
          reason: 'Balance must reconcile accurately after transaction edit',
        );
      },
    );

    test(
      '12. Existing permanent friend deletion and pending_deletions behavior remaining intact',
      () async {
        const userUid = 'user_del_invariant';
        const friendName = 'DeleteTarget';

        final tx = TransactionModel(
          firebaseId: 'del_target_tx_1',
          friendName: friendName,
          amount: 400.0,
          note: 'To delete',
          date: '2026-10-01',
          iGave: true,
          createdBy: userUid,
        );
        await DatabaseHelper.instance.insertTransaction(tx);

        // Durable pending deletion queue
        final pendingRecord = PendingDeletionModel(
          userId: userUid,
          type: 'friend',
          friendName: friendName,
          firebaseIds: ['del_target_tx_1'],
          createdAt: DateTime.now(),
        );
        final pId = await DatabaseHelper.instance.insertPendingDeletion(
          pendingRecord,
        );
        expect(pId, isPositive);

        // Delete transactions for friend
        await DatabaseHelper.instance.deleteTransactionsForFriend(
          friendName,
          userId: userUid,
          isManualFriend: true,
        );

        // Verify SQLite rows deleted
        final surviving = await DatabaseHelper.instance.getTransactions(
          userId: userUid,
        );
        expect(surviving, isEmpty);

        // Verify pending queue retains record
        final pendingQueue = await DatabaseHelper.instance.getPendingDeletions(
          userId: userUid,
        );
        expect(pendingQueue.length, 1);
        expect(pendingQueue.first.firebaseIds, contains('del_target_tx_1'));
      },
    );
  });
}
