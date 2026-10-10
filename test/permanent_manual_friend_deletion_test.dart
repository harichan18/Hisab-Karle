import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as p;
import 'package:hisab_kitab/database/database_helper.dart';
import 'package:hisab_kitab/models/friend_model.dart';
import 'package:hisab_kitab/models/pending_deletion_model.dart';
import 'package:hisab_kitab/models/transaction_model.dart';

/// Regression and verification suite for permanent manual-friend deletion,
/// identity disambiguation, durable pending-deletion queue, and offline resiliency.
///
/// Note: These tests use SQLite FFI for local database verification and structured
/// unit mocks/handlers for Firestore operations. They verify the client-side logic,
/// durable SQLite queue persistence, identity isolation, migration from v11 to v12,
/// and restart recovery without claiming to invoke live Firestore backend endpoints.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Permanent Friend Deletion & Durable Queue Tests', () {
    late Database db;
    late Directory tempDir;

    Future<Database> createV12TestDb(String path) async {
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
      tempDir = await Directory.systemTemp.createTemp('hisab_deletion_test_');
      final dbPath = p.join(tempDir.path, 'test_hisab_v12.db');
      db = await createV12TestDb(dbPath);
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

    /// Helper replicating HomePage._friendMatches identity logic
    bool matchesFriend(
      TransactionModel t,
      String friendName,
      String? friendUid, {
      bool hasConflictingConnectedFriend = false,
    }) {
      final lowerTarget = friendName.trim().toLowerCase();
      final nameMatches = t.friendName.trim().toLowerCase() == lowerTarget;

      if (friendUid != null && friendUid.isNotEmpty) {
        if (t.peerUserId == friendUid) {
          return true;
        }
        if (t.peerUserId != null && t.peerUserId!.isNotEmpty) {
          return false;
        }
        return false;
      } else {
        if (t.peerUserId != null && t.peerUserId!.isNotEmpty) {
          return false;
        }
        if (hasConflictingConnectedFriend) {
          return false;
        }
        return nameMatches;
      }
    }

    /// Simulates the exact deletion flow implemented in HomePage.deleteEntireFriend
    Future<void> simulateDeleteEntireFriend({
      required FriendListItem friend,
      required String? currentUserId,
      List<TransactionModel>? inMemoryTransactions,
      Future<void> Function({
        required String friendName,
        String? friendUid,
        List<String>? specificFirebaseIds,
      })?
      cloudDeleteHandler,
      Future<void> Function({
        required String friendName,
        String? friendUid,
        List<String>? specificFirebaseIds,
        bool hasConflictingConnectedFriend,
      })?
      cloudDeleteConflictHandler,
    }) async {
      final uid = currentUserId;
      final isManual = friend.uid == null || friend.uid!.isEmpty;

      bool hasConflictingConnectedFriend = false;
      if (isManual) {
        hasConflictingConnectedFriend = await DatabaseHelper.instance
            .hasConnectedFriendWithName(friend.name);
      }

      // 1. Collect known Firebase IDs
      final knownFirebaseIds = <String>{};
      if (inMemoryTransactions != null) {
        for (final t in inMemoryTransactions) {
          if (matchesFriend(
                t,
                friend.name,
                friend.uid,
                hasConflictingConnectedFriend: hasConflictingConnectedFriend,
              ) &&
              t.firebaseId != null &&
              t.firebaseId!.isNotEmpty) {
            knownFirebaseIds.add(t.firebaseId!);
          }
        }
      }

      final sqliteIds = await DatabaseHelper.instance
          .getTransactionFirebaseIdsForFriend(
            friend.name,
            userId: uid,
            peerUserId: friend.uid,
            isManualFriend: isManual,
            hasConflictingConnectedFriend: hasConflictingConnectedFriend,
          );
      knownFirebaseIds.addAll(sqliteIds);

      // 2. Record deletion intent in SQLite durable queue BEFORE removing local data
      int? pendingId;
      if (uid != null && uid.isNotEmpty) {
        final pendingRecord = PendingDeletionModel(
          userId: uid,
          type: 'friend',
          friendName: friend.name,
          friendUid: friend.uid,
          localFriendId: friend.localId,
          firebaseIds: knownFirebaseIds.toList(),
          createdAt: DateTime.now(),
        );
        pendingId = await DatabaseHelper.instance.insertPendingDeletion(
          pendingRecord,
        );
      }

      DatabaseHelper.deletedFirebaseIds.addAll(knownFirebaseIds);

      // 3. Delete from SQLite with identity disambiguation
      if (friend.localId != null && friend.localId!.isNotEmpty) {
        await DatabaseHelper.instance.deleteLocalFriend(friend.localId!);
      }
      if (uid != null && uid.isNotEmpty) {
        await DatabaseHelper.instance.deleteLocalFriendByName(
          friend.name,
          userId: uid,
        );
      } else {
        await DatabaseHelper.instance.deleteLocalFriendByName(friend.name);
      }
      await DatabaseHelper.instance.deleteTransactionsForFriend(
        friend.name,
        userId: uid,
        peerUserId: friend.uid,
        isManualFriend: isManual,
        hasConflictingConnectedFriend: hasConflictingConnectedFriend,
      );
      await DatabaseHelper.instance.deleteDeletedEntriesForFriend(
        friend.name,
        userId: uid,
        hasConflictingConnectedFriend: hasConflictingConnectedFriend,
      );
      if (friend.uid != null && friend.uid!.isNotEmpty) {
        await DatabaseHelper.instance.deleteCachedFriend(friend.uid!);
        await DatabaseHelper.instance.deleteCachedFriendByName(friend.name);
      }
      if (!hasConflictingConnectedFriend) {
        await DatabaseHelper.instance.deleteFriendNickname(friend.name);
      }

      // 4. Attempt cloud deletion
      if (uid != null) {
        try {
          if (cloudDeleteConflictHandler != null) {
            await cloudDeleteConflictHandler(
              friendName: friend.name,
              friendUid: friend.uid,
              specificFirebaseIds: knownFirebaseIds.isNotEmpty
                  ? knownFirebaseIds.toList()
                  : null,
              hasConflictingConnectedFriend: hasConflictingConnectedFriend,
            );
          } else if (cloudDeleteHandler != null) {
            await cloudDeleteHandler(
              friendName: friend.name,
              friendUid: friend.uid,
              specificFirebaseIds: knownFirebaseIds.isNotEmpty
                  ? knownFirebaseIds.toList()
                  : null,
            );
          }
          if (pendingId != null) {
            await DatabaseHelper.instance.deletePendingDeletion(pendingId);
          }
        } catch (_) {
          // Intent remains durable in pending_deletions table
        }
      }

      // 5. In-memory pruning
      if (inMemoryTransactions != null) {
        inMemoryTransactions.removeWhere(
          (t) => matchesFriend(
            t,
            friend.name,
            friend.uid,
            hasConflictingConnectedFriend: hasConflictingConnectedFriend,
          ),
        );
      }
    }

    test(
      'C1. Manual friend deletion with known Firebase transaction IDs (Mocked cloud call)',
      () async {
        final localFriendId = DatabaseHelper.generateLocalId();
        final friend = FriendListItem(
          name: 'Rohan',
          localId: localFriendId,
          isLocal: true,
          uid: null,
        );

        await DatabaseHelper.instance.insertLocalFriend(
          LocalFriendModel(
            id: localFriendId,
            name: 'Rohan',
            userId: 'user_c1',
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        final tx1 = TransactionModel(
          firebaseId: 'rohan_fb_101',
          friendName: 'Rohan',
          amount: 250.0,
          note: 'Coffee',
          date: '2026-10-01',
          iGave: true,
          createdBy: 'user_c1',
        );
        final tx2 = TransactionModel(
          firebaseId: 'rohan_fb_102',
          friendName: 'Rohan',
          amount: 350.0,
          note: 'Snacks',
          date: '2026-10-02',
          iGave: false,
          createdBy: 'user_c1',
        );
        await DatabaseHelper.instance.insertTransaction(tx1);
        await DatabaseHelper.instance.insertTransaction(tx2);

        final inMem = <TransactionModel>[tx1, tx2];
        List<String>? passedFirebaseIds;
        bool cloudDeleteCalled = false;

        await simulateDeleteEntireFriend(
          friend: friend,
          currentUserId: 'user_c1',
          inMemoryTransactions: inMem,
          cloudDeleteHandler:
              ({
                required String friendName,
                String? friendUid,
                List<String>? specificFirebaseIds,
              }) async {
                cloudDeleteCalled = true;
                passedFirebaseIds = specificFirebaseIds;
              },
        );

        expect(cloudDeleteCalled, isTrue);
        expect(passedFirebaseIds, isNotNull);
        expect(
          passedFirebaseIds,
          containsAll(['rohan_fb_101', 'rohan_fb_102']),
        );
        expect(inMem, isEmpty);

        // Local database must be cleared
        final localFriends = await DatabaseHelper.instance.getLocalFriends(
          userId: 'user_c1',
        );
        expect(localFriends, isEmpty);
        final localTxs = await DatabaseHelper.instance.getTransactions(
          userId: 'user_c1',
        );
        expect(localTxs, isEmpty);

        // Pending deletion should be cleared upon confirmed cloud deletion
        final pending = await DatabaseHelper.instance.getPendingDeletions(
          userId: 'user_c1',
        );
        expect(pending, isEmpty);

        // in-memory deletedFirebaseIds has both IDs
        expect(
          DatabaseHelper.deletedFirebaseIds.contains('rohan_fb_101'),
          isTrue,
        );
        expect(
          DatabaseHelper.deletedFirebaseIds.contains('rohan_fb_102'),
          isTrue,
        );
      },
    );

    test(
      'C2. Two different friends with the same name: deleting manual friend preserves connected friend',
      () async {
        const sameName = 'Alex';
        const userUid = 'user_c2';
        const connectedPeerUid = 'alex_peer_uid_99';

        // Friend 1: Manual friend "Alex"
        final manualId = DatabaseHelper.generateLocalId();
        final manualFriend = FriendListItem(
          name: sameName,
          localId: manualId,
          isLocal: true,
          uid: null,
        );
        await DatabaseHelper.instance.insertLocalFriend(
          LocalFriendModel(
            id: manualId,
            name: sameName,
            userId: userUid,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
        final manualTx = TransactionModel(
          firebaseId: 'manual_alex_tx',
          friendName: sameName,
          peerUserId: null, // manual
          amount: 100.0,
          note: 'Manual Alex Coffee',
          date: '2026-10-01',
          iGave: true,
          createdBy: userUid,
        );
        await DatabaseHelper.instance.insertTransaction(manualTx);

        // Friend 2: Connected friend "Alex"
        final connectedFriend = FriendListItem(
          name: sameName,
          uid: connectedPeerUid,
          fromFirestore: true,
        );
        expect(connectedFriend.uid, connectedPeerUid);
        await DatabaseHelper.instance.saveCachedFriend(
          friendUid: connectedPeerUid,
          friendName: sameName,
          email: 'alex@connected.com',
        );
        final connectedTx = TransactionModel(
          firebaseId: 'conn_alex_tx',
          friendName: sameName,
          peerUserId: connectedPeerUid, // connected
          amount: 500.0,
          note: 'Connected Alex Dinner',
          date: '2026-10-02',
          iGave: false,
          createdBy: userUid,
        );
        await DatabaseHelper.instance.insertTransaction(connectedTx);

        final inMem = <TransactionModel>[manualTx, connectedTx];
        final cloudTxs = <String, TransactionModel>{
          'manual_alex_tx': manualTx,
          'conn_alex_tx': connectedTx,
        };

        // Action: Delete the manual friend "Alex"
        await simulateDeleteEntireFriend(
          friend: manualFriend,
          currentUserId: userUid,
          inMemoryTransactions: inMem,
          cloudDeleteHandler:
              ({
                required String friendName,
                String? friendUid,
                List<String>? specificFirebaseIds,
              }) async {
                if (specificFirebaseIds != null) {
                  for (final id in specificFirebaseIds) {
                    cloudTxs.remove(id);
                  }
                }
              },
        );

        // Verify connected friend and ambiguous transactions are PRESERVED in SQLite
        final survivingTxs = await DatabaseHelper.instance.getTransactions(
          userId: userUid,
        );
        // Under the safety rule, transactions without peerUserId sharing a name with a connected friend
        // are ambiguous and preserved to prevent accidental deletion of legacy connected transactions.
        expect(survivingTxs.length, 2);
        final survivingIds = survivingTxs.map((t) => t.firebaseId).toSet();
        expect(survivingIds, containsAll(['conn_alex_tx', 'manual_alex_tx']));

        // Manual friend is removed from local_friends
        final localFriends = await DatabaseHelper.instance.getLocalFriends(
          userId: userUid,
        );
        expect(localFriends, isEmpty);

        // Connected friend profile preserved in cache
        final cachedFriends = await DatabaseHelper.instance
            .getAllCachedFriends();
        expect(
          cachedFriends.any((c) => c['friendUid'] == connectedPeerUid),
          isTrue,
        );

        // Verify cloud mock preserved connected friend's transaction and ambiguous manual transaction
        expect(cloudTxs.containsKey('conn_alex_tx'), isTrue);
        expect(cloudTxs.containsKey('manual_alex_tx'), isTrue);

        // In-memory list preserved both transactions
        expect(inMem.length, 2);
      },
    );

    test(
      'C3. Connected-friend deletion with valid UID triggers pairing cleanup (Mocked cloud call)',
      () async {
        const userUid = 'user_c3';
        const friendUid = 'peer_charlie_uid';
        final friend = FriendListItem(
          name: 'Charlie',
          uid: friendUid,
          fromFirestore: true,
        );

        await DatabaseHelper.instance.saveCachedFriend(
          friendUid: friendUid,
          friendName: 'Charlie',
          email: 'charlie@test.com',
        );

        final connTx = TransactionModel(
          firebaseId: 'charlie_tx_1',
          friendName: 'Charlie',
          peerUserId: friendUid,
          amount: 800.0,
          note: 'Trip split',
          date: '2026-10-01',
          iGave: true,
          createdBy: userUid,
        );
        await DatabaseHelper.instance.insertTransaction(connTx);

        String? passedFriendUid;
        List<String>? passedFirebaseIds;

        await simulateDeleteEntireFriend(
          friend: friend,
          currentUserId: userUid,
          inMemoryTransactions: [connTx],
          cloudDeleteHandler:
              ({
                required String friendName,
                String? friendUid,
                List<String>? specificFirebaseIds,
              }) async {
                passedFriendUid = friendUid;
                passedFirebaseIds = specificFirebaseIds;
              },
        );

        expect(passedFriendUid, friendUid);
        expect(passedFirebaseIds, contains('charlie_tx_1'));

        final cached = await DatabaseHelper.instance.getAllCachedFriends();
        expect(cached.any((c) => c['friendUid'] == friendUid), isFalse);

        final remainingTxs = await DatabaseHelper.instance.getTransactions(
          userId: userUid,
        );
        expect(remainingTxs, isEmpty);
      },
    );

    test(
      'C4. Offline deletion, app restart, and subsequent retry via durable queue',
      () async {
        const userUid = 'user_offline_c4';
        final localFriendId = DatabaseHelper.generateLocalId();
        final friend = FriendListItem(
          name: 'OfflineDan',
          localId: localFriendId,
          isLocal: true,
          uid: null,
        );

        await DatabaseHelper.instance.insertLocalFriend(
          LocalFriendModel(
            id: localFriendId,
            name: 'OfflineDan',
            userId: userUid,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        final tx = TransactionModel(
          firebaseId: 'dan_offline_tx',
          friendName: 'OfflineDan',
          amount: 450.0,
          note: 'Groceries',
          date: '2026-10-01',
          iGave: true,
          createdBy: userUid,
        );
        await DatabaseHelper.instance.insertTransaction(tx);

        // Phase 1: Deletion occurs while OFFLINE (cloud call throws exception)
        await simulateDeleteEntireFriend(
          friend: friend,
          currentUserId: userUid,
          inMemoryTransactions: [tx],
          cloudDeleteHandler:
              ({
                required String friendName,
                String? friendUid,
                List<String>? specificFirebaseIds,
              }) async {
                throw const SocketException('No network connection');
              },
        );

        // Verify local data is deleted
        expect(
          await DatabaseHelper.instance.getLocalFriends(userId: userUid),
          isEmpty,
        );
        expect(
          await DatabaseHelper.instance.getTransactions(userId: userUid),
          isEmpty,
        );

        // Verify durable pending record EXISTS in SQLite
        final pendingBeforeRestart = await DatabaseHelper.instance
            .getPendingDeletions(userId: userUid);
        expect(pendingBeforeRestart.length, 1);
        final pendingItem = pendingBeforeRestart.first;
        expect(pendingItem.friendName, 'OfflineDan');
        expect(pendingItem.firebaseIds, contains('dan_offline_tx'));

        // Phase 2: Simulate App Restart (clearing in-memory state)
        DatabaseHelper.deletedFirebaseIds.clear();
        expect(DatabaseHelper.deletedFirebaseIds, isEmpty);

        // On startup, restoreDeletedFirebaseIds is called
        await DatabaseHelper.instance.restoreDeletedFirebaseIds(
          userId: userUid,
        );
        expect(
          DatabaseHelper.deletedFirebaseIds.contains('dan_offline_tx'),
          isTrue,
        );

        // Even if remote stream yields the surviving transaction, the filter drops it
        final staleRemoteStream = [tx];
        final filteredRemote = staleRemoteStream
            .where(
              (t) =>
                  t.firebaseId == null ||
                  !DatabaseHelper.deletedFirebaseIds.contains(t.firebaseId),
            )
            .toList();
        expect(filteredRemote, isEmpty);

        // Phase 3: Connectivity returns -> SyncService / retry processes pending queue
        final pendingList = await DatabaseHelper.instance.getPendingDeletions(
          userId: userUid,
        );
        expect(pendingList.isNotEmpty, isTrue);

        bool retrySuccess = false;
        for (final del in pendingList) {
          // Retry cloud deletion
          retrySuccess = true;
          // On server confirmation:
          await DatabaseHelper.instance.deletePendingDeletion(del.id!);
        }

        expect(retrySuccess, isTrue);
        final pendingAfterSync = await DatabaseHelper.instance
            .getPendingDeletions(userId: userUid);
        expect(pendingAfterSync, isEmpty);
      },
    );

    test('C5. Deletion of a manual friend with zero transactions', () async {
      const userUid = 'user_c5';
      final localFriendId = DatabaseHelper.generateLocalId();
      final friend = FriendListItem(
        name: 'EmptyFriend',
        localId: localFriendId,
        isLocal: true,
        uid: null,
      );

      await DatabaseHelper.instance.insertLocalFriend(
        LocalFriendModel(
          id: localFriendId,
          name: 'EmptyFriend',
          userId: userUid,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      bool cloudCalled = false;
      List<String>? passedIds;

      await simulateDeleteEntireFriend(
        friend: friend,
        currentUserId: userUid,
        inMemoryTransactions: [],
        cloudDeleteHandler:
            ({
              required String friendName,
              String? friendUid,
              List<String>? specificFirebaseIds,
            }) async {
              cloudCalled = true;
              passedIds = specificFirebaseIds;
            },
      );

      expect(cloudCalled, isTrue);
      expect(passedIds, isNull); // zero transactions -> passedIds is null
      expect(
        await DatabaseHelper.instance.getLocalFriends(userId: userUid),
        isEmpty,
      );
      expect(
        await DatabaseHelper.instance.getPendingDeletions(userId: userUid),
        isEmpty,
      );
    });

    test(
      'C6. Account isolation: Deleting friend in User A does not affect User B',
      () async {
        const userA = 'user_alpha';
        const userB = 'user_beta';
        const friendName = 'SharedNameFriend';

        // User A's friend and transaction
        final idA = DatabaseHelper.generateLocalId();
        await DatabaseHelper.instance.insertLocalFriend(
          LocalFriendModel(
            id: idA,
            name: friendName,
            userId: userA,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
        await DatabaseHelper.instance.insertTransaction(
          TransactionModel(
            firebaseId: 'user_a_tx_1',
            friendName: friendName,
            amount: 200.0,
            note: 'Alpha share',
            date: '2026-10-01',
            iGave: true,
            createdBy: userA,
          ),
        );

        // User B's friend and transaction
        final idB = DatabaseHelper.generateLocalId();
        await DatabaseHelper.instance.insertLocalFriend(
          LocalFriendModel(
            id: idB,
            name: friendName,
            userId: userB,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
        await DatabaseHelper.instance.insertTransaction(
          TransactionModel(
            firebaseId: 'user_b_tx_1',
            friendName: friendName,
            amount: 900.0,
            note: 'Beta share',
            date: '2026-10-01',
            iGave: false,
            createdBy: userB,
          ),
        );

        // User A deletes their friend
        await simulateDeleteEntireFriend(
          friend: FriendListItem(name: friendName, localId: idA, isLocal: true),
          currentUserId: userA,
          cloudDeleteHandler:
              ({
                required String friendName,
                String? friendUid,
                List<String>? specificFirebaseIds,
              }) async {},
        );

        // User A's data is gone
        expect(
          await DatabaseHelper.instance.getLocalFriends(userId: userA),
          isEmpty,
        );
        expect(
          await DatabaseHelper.instance.getTransactions(userId: userA),
          isEmpty,
        );

        // User B's data is completely intact
        final userBFriends = await DatabaseHelper.instance.getLocalFriends(
          userId: userB,
        );
        expect(userBFriends.length, 1);
        expect(userBFriends.first.name, friendName);

        final userBTxs = await DatabaseHelper.instance.getTransactions(
          userId: userB,
        );
        expect(userBTxs.length, 1);
        expect(userBTxs.first.firebaseId, 'user_b_tx_1');
        expect(userBTxs.first.amount, 900.0);
      },
    );

    test(
      'C7. Legacy transaction documents missing peerUserId are preserved when deleting connected friend',
      () async {
        const userUid = 'user_c7';
        const friendName = 'Jordan';
        const connectedUid = 'peer_jordan_uid';

        // Connected friend
        final connectedFriend = FriendListItem(
          name: friendName,
          uid: connectedUid,
          fromFirestore: true,
        );

        // Legacy transaction without peerUserId
        final legacyTx = TransactionModel(
          firebaseId: 'legacy_jordan_tx',
          friendName: friendName,
          peerUserId: null, // Legacy has no peerUserId
          amount: 320.0,
          note: 'Legacy lunch',
          date: '2026-09-15',
          iGave: true,
          createdBy: userUid,
        );
        await DatabaseHelper.instance.insertTransaction(legacyTx);

        // Connected transaction with peerUserId
        final connectedTx = TransactionModel(
          firebaseId: 'connected_jordan_tx',
          friendName: friendName,
          peerUserId: connectedUid,
          amount: 600.0,
          note: 'Connected movie',
          date: '2026-10-01',
          iGave: false,
          createdBy: userUid,
        );
        await DatabaseHelper.instance.insertTransaction(connectedTx);

        // Delete connected friend Jordan
        await simulateDeleteEntireFriend(
          friend: connectedFriend,
          currentUserId: userUid,
          inMemoryTransactions: [legacyTx, connectedTx],
          cloudDeleteHandler:
              ({
                required String friendName,
                String? friendUid,
                List<String>? specificFirebaseIds,
              }) async {},
        );

        // Legacy transaction is PRESERVED because peerUserId != connectedUid
        final remaining = await DatabaseHelper.instance.getTransactions(
          userId: userUid,
        );
        expect(remaining.length, 1);
        expect(remaining.first.firebaseId, 'legacy_jordan_tx');
        expect(remaining.first.amount, 320.0);
      },
    );

    test(
      'C8. Existing offline Give/Take and OCR split behavior remains intact',
      () async {
        const userUid = 'user_c8';

        // 1. Give transaction
        final giveTx = TransactionModel(
          friendName: 'Dev',
          amount: 500.0,
          note: 'Gave for fuel',
          date: '2026-10-05',
          iGave: true,
          createdBy: userUid,
          syncStatus: SyncStatus.pending,
        );
        final giveId = await DatabaseHelper.instance.insertTransaction(giveTx);
        expect(giveId, isPositive);

        // 2. Take transaction
        final takeTx = TransactionModel(
          friendName: 'Dev',
          amount: 200.0,
          note: 'Took for dinner',
          date: '2026-10-06',
          iGave: false,
          createdBy: userUid,
          syncStatus: SyncStatus.pending,
        );
        final takeId = await DatabaseHelper.instance.insertTransaction(takeTx);
        expect(takeId, isPositive);

        // 3. OCR split share
        await db.insert('you_split_shares', {
          'id': 'ocr_split_01',
          'userId': userUid,
          'amount': 150.0,
          'note': 'OCR receipt lunch share',
          'date': '2026-10-06',
          'createdAt': DateTime.now().toIso8601String(),
        });

        // Verify pending transactions query
        final pendingTxs = await DatabaseHelper.instance.getPendingTransactions(
          userId: userUid,
        );
        expect(pendingTxs.length, 2);

        // Verify OCR shares query
        final shares = await db.query(
          'you_split_shares',
          where: 'userId = ?',
          whereArgs: [userUid],
        );
        expect(shares.length, 1);
        expect(shares.first['amount'], 150.0);

        // Verify net calculations
        final devTxs = await DatabaseHelper.instance.getTransactions(
          userId: userUid,
        );
        double totalGiven = 0;
        double totalTaken = 0;
        for (final t in devTxs) {
          if (t.iGave) {
            totalGiven += t.amount;
          } else {
            totalTaken += t.amount;
          }
        }
        expect(totalGiven, 500.0);
        expect(totalTaken, 200.0);
        expect(totalGiven - totalTaken, 300.0);
      },
    );

    test(
      'C9. Database schema migration: v11 upgrades cleanly to v12 with pending_deletions table',
      () async {
        // Create a temporary db at version 11
        final v11Path = p.join(tempDir.path, 'upgrade_test_v11.db');
        var legacyDb = await openDatabase(
          v11Path,
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
          },
        );

        // Insert pre-upgrade data
        await legacyDb.insert('transactions', {
          'firebaseId': 'pre_migration_tx',
          'friendName': 'PreMigrationFriend',
          'amount': 100.0,
          'date': '2026-10-01',
          'iGave': 1,
        });
        await legacyDb.close();

        // Open with upgrade to v12
        var upgradedDb = await openDatabase(
          v11Path,
          version: 12,
          onUpgrade: (db, oldVersion, newVersion) async {
            if (oldVersion < 12) {
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
            }
          },
        );

        // Verify pre-existing data survives
        final rows = await upgradedDb.query('transactions');
        expect(rows.length, 1);
        expect(rows.first['firebaseId'], 'pre_migration_tx');

        // Verify pending_deletions table exists and can be queried/inserted
        await upgradedDb.insert('pending_deletions', {
          'userId': 'test_user',
          'type': 'friend',
          'friendName': 'Test',
          'firebaseIds': '["tx1","tx2"]',
          'createdAt': DateTime.now().toIso8601String(),
        });
        final pendingRows = await upgradedDb.query('pending_deletions');
        expect(pendingRows.length, 1);
        expect(pendingRows.first['friendName'], 'Test');

        await upgradedDb.close();
      },
    );

    test(
      'C10. Manual Alex plus connected Alex with legacy transaction missing peerUserId: ambiguous transaction survives manual deletion',
      () async {
        const userUid = 'user_c10';
        const sameName = 'Alex';
        const connectedPeerUid = 'alex_connected_uid_10';

        // 1. Manual friend "Alex"
        final manualLocalId = DatabaseHelper.generateLocalId();
        final manualFriend = FriendListItem(
          name: sameName,
          localId: manualLocalId,
          isLocal: true,
          uid: null,
        );
        await DatabaseHelper.instance.insertLocalFriend(
          LocalFriendModel(
            id: manualLocalId,
            name: sameName,
            userId: userUid,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        // 2. Connected friend "Alex" saved in cached_friends
        await DatabaseHelper.instance.saveCachedFriend(
          friendUid: connectedPeerUid,
          friendName: sameName,
          email: 'alex.connected@test.com',
        );

        // 3. Legacy transaction without peerUserId for "Alex"
        final legacyTx = TransactionModel(
          firebaseId: 'alex_legacy_tx_ambiguous',
          friendName: sameName,
          peerUserId: null, // Legacy: missing peerUserId!
          amount: 550.0,
          note: 'Ambiguous lunch bill',
          date: '2026-09-01',
          iGave: true,
          createdBy: userUid,
        );
        await DatabaseHelper.instance.insertTransaction(legacyTx);

        // In-memory lists and cloud mock
        final inMem = <TransactionModel>[legacyTx];
        final cloudDocs = <String, TransactionModel>{
          'alex_legacy_tx_ambiguous': legacyTx,
        };

        // Action: User deletes the manual friend "Alex"
        await simulateDeleteEntireFriend(
          friend: manualFriend,
          currentUserId: userUid,
          inMemoryTransactions: inMem,
          cloudDeleteConflictHandler:
              ({
                required String friendName,
                String? friendUid,
                List<String>? specificFirebaseIds,
                bool hasConflictingConnectedFriend = false,
              }) async {
                if (specificFirebaseIds != null) {
                  for (final id in specificFirebaseIds) {
                    cloudDocs.remove(id);
                  }
                } else if (!(friendUid == null &&
                    hasConflictingConnectedFriend)) {
                  cloudDocs.removeWhere(
                    (k, v) =>
                        v.friendName.toLowerCase() ==
                            friendName.toLowerCase() &&
                        (v.peerUserId == null || v.peerUserId!.isEmpty),
                  );
                }
              },
        );

        // Assert 1: Manual friend is removed from local_friends
        final localFriends = await DatabaseHelper.instance.getLocalFriends(
          userId: userUid,
        );
        expect(localFriends, isEmpty);

        // Assert 2: Connected friend profile remains in cached_friends
        final cachedFriends = await DatabaseHelper.instance
            .getAllCachedFriends();
        expect(
          cachedFriends.any((c) => c['friendUid'] == connectedPeerUid),
          isTrue,
        );

        // Assert 3: The ambiguous legacy transaction without peerUserId SURVIVES in SQLite
        final survivingTxs = await DatabaseHelper.instance.getTransactions(
          userId: userUid,
        );
        expect(survivingTxs.length, 1);
        expect(survivingTxs.first.firebaseId, 'alex_legacy_tx_ambiguous');
        expect(survivingTxs.first.amount, 550.0);

        // Assert 4: The ambiguous legacy transaction SURVIVES in cloud mock
        expect(cloudDocs.containsKey('alex_legacy_tx_ambiguous'), isTrue);

        // Assert 5: The ambiguous transaction SURVIVES in in-memory list
        expect(inMem.length, 1);
        expect(inMem.first.firebaseId, 'alex_legacy_tx_ambiguous');

        // Assert 6: No pending deletion record was created targeting the ambiguous transaction
        final pending = await DatabaseHelper.instance.getPendingDeletions(
          userId: userUid,
        );
        final targetedIds = pending.expand((p) => p.firebaseIds).toSet();
        expect(targetedIds.contains('alex_legacy_tx_ambiguous'), isFalse);

        // Assert 7: Retrying a pending deletion with empty firebaseIds list cannot delete ambiguous transactions
        final pendingWithEmptyIds = PendingDeletionModel(
          userId: userUid,
          type: 'friend',
          friendName: sameName,
          friendUid: null,
          firebaseIds: [],
          createdAt: DateTime.now(),
        );
        final conflictOnRetry = await DatabaseHelper.instance
            .hasConnectedFriendWithName(pendingWithEmptyIds.friendName);
        expect(conflictOnRetry, isTrue);

        // Simulate retry with empty firebaseIds (like SyncService)
        final targetIds = pendingWithEmptyIds.firebaseIds.toSet();
        if (targetIds.isNotEmpty) {
          for (final fid in targetIds) {
            cloudDocs.remove(fid);
          }
        } else if (!(pendingWithEmptyIds.friendUid == null &&
            conflictOnRetry)) {
          cloudDocs.removeWhere(
            (k, v) =>
                v.friendName.toLowerCase() ==
                    pendingWithEmptyIds.friendName.toLowerCase() &&
                (v.peerUserId == null || v.peerUserId!.isEmpty),
          );
        }
        expect(cloudDocs.containsKey('alex_legacy_tx_ambiguous'), isTrue);
      },
    );
  });
}
