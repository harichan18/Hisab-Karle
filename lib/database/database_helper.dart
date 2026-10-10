import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../models/transaction_model.dart';
import '../models/expense_model.dart';
import '../models/friend_model.dart';
import '../models/pending_deletion_model.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();

  static Database? _database;

  static void setTestDatabase(Database? db) {
    _database = db;
  }

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) {
      return _database!;
    }

    _database = await _initDB('hisab.db');

    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();

    final path = join(dbPath, filePath);

    return await openDatabase(
      path,

      version: 12,

      onCreate: _createDB,
      onUpgrade: _upgradeDB,
    );
  }

  Future<void> _createDB(Database db, int version) async {
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

    await _createSettingsTable(db);
    await _createDeletedEntriesTable(db);
    await _createMigrationMetaTable(db);
    await _createFriendNicknamesTable(db);
    await _createCachedFriendsTable(db);
    await _createPersonalExpensesTable(db);
    await _createLocalFriendsTable(db);
    await _createYouSplitSharesTable(db);
    await _createPendingDeletionsTable(db);
  }

  Future<void> _upgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _createSettingsTable(db);
    }
    if (oldVersion < 3) {
      await _createDeletedEntriesTable(db);
    }
    if (oldVersion < 4) {
      await _createMigrationMetaTable(db);
    }
    if (oldVersion < 5) {
      await db.execute('ALTER TABLE transactions ADD COLUMN receiptPath TEXT');
      if (oldVersion >= 3) {
        await db.execute(
          'ALTER TABLE deleted_entries ADD COLUMN receiptPath TEXT',
        );
      }
    }
    if (oldVersion < 6) {
      await _createFriendNicknamesTable(db);
    }
    if (oldVersion < 7) {
      await _createCachedFriendsTable(db);
    }
    if (oldVersion < 8) {
      await _createPersonalExpensesTable(db);
    }
    if (oldVersion < 9) {
      await db.execute('ALTER TABLE transactions ADD COLUMN firebaseId TEXT');
      await db.execute('ALTER TABLE transactions ADD COLUMN createdBy TEXT');
      await db.execute('ALTER TABLE transactions ADD COLUMN peerUserId TEXT');
      await db.execute('ALTER TABLE transactions ADD COLUMN receiptUrl TEXT');
      await db.execute(
        'ALTER TABLE transactions ADD COLUMN sync_status INTEGER DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE personal_expenses ADD COLUMN sync_status INTEGER DEFAULT 0',
      );
      await db.execute('ALTER TABLE deleted_entries ADD COLUMN userId TEXT');
      await db.execute(
        'ALTER TABLE deleted_entries ADD COLUMN receiptUrl TEXT',
      );
    }
    if (oldVersion < 10) {
      await _createLocalFriendsTable(db);
    }
    if (oldVersion < 11) {
      await _createYouSplitSharesTable(db);
    }
    if (oldVersion < 12) {
      await _createPendingDeletionsTable(db);
    }
  }

  Future<void> _createSettingsTable(Database db) async {
    await db.execute('''
CREATE TABLE IF NOT EXISTS settings(

id INTEGER PRIMARY KEY,

bankBalance REAL

)
''');
  }

  Future<void> _createDeletedEntriesTable(Database db) async {
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
)
''');
  }

  Future<void> _createMigrationMetaTable(Database db) async {
    await db.execute('''
CREATE TABLE IF NOT EXISTS migration_meta(

key TEXT PRIMARY KEY,

value TEXT

)
''');
  }

  static int personIdForName(String name) {
    final normalized = name.trim().toLowerCase();
    var hash = 0;
    for (final codeUnit in normalized.codeUnits) {
      hash = ((hash * 31) + codeUnit) & 0x7fffffff;
    }
    return hash;
  }

  String _formatDate(DateTime date) {
    return "${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}";
  }

  Future<int> insertTransaction(TransactionModel transaction) async {
    final db = await instance.database;

    return await db.insert('transactions', transaction.toMap());
  }

  Future<List<TransactionModel>> getTransactions({String? userId}) async {
    final db = await instance.database;

    if (userId == null || userId.isEmpty) {
      final result = await db.query('transactions');
      return result.map((json) => TransactionModel.fromMap(json)).toList();
    }

    final importedUid = await getMigrationMeta('legacy_sqlite_imported_uid');

    String whereClause;
    List<dynamic> whereArgs;

    if (importedUid == null || importedUid == userId) {
      whereClause = 'createdBy IS NULL OR createdBy = ? OR peerUserId = ?';
      whereArgs = [userId, userId];
    } else {
      whereClause = 'createdBy = ? OR peerUserId = ?';
      whereArgs = [userId, userId];
    }

    final result = await db.query(
      'transactions',
      where: whereClause,
      whereArgs: whereArgs,
    );

    return result.map((json) => TransactionModel.fromMap(json)).toList();
  }

  Future<TransactionModel?> getTransactionByFirebaseId(
    String firebaseId,
  ) async {
    if (firebaseId.trim().isEmpty) return null;
    final db = await instance.database;
    final rows = await db.query(
      'transactions',
      where: 'firebaseId = ?',
      whereArgs: [firebaseId.trim()],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return TransactionModel.fromMap(rows.first);
  }

  Future<int> updateTransaction(TransactionModel transaction) async {
    final db = await instance.database;

    if (transaction.id != null) {
      return await db.update(
        'transactions',
        transaction.toMap(),
        where: 'id = ?',
        whereArgs: [transaction.id],
      );
    } else if (transaction.firebaseId != null &&
        transaction.firebaseId!.trim().isNotEmpty) {
      return await db.update(
        'transactions',
        transaction.toMap(),
        where: 'firebaseId = ?',
        whereArgs: [transaction.firebaseId!.trim()],
      );
    }
    return 0;
  }

  static final Set<String> deletedFirebaseIds = {};

  Future<int> deleteTransaction(int id) async {
    final db = await instance.database;
    final rows = await db.query(
      'transactions',
      columns: ['firebaseId'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      final fid = rows.first['firebaseId'] as String?;
      if (fid != null && fid.isNotEmpty) {
        deletedFirebaseIds.add(fid);
      }
    }
    return await db.delete('transactions', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> deleteTransactionByFirebaseId(String firebaseId) async {
    deletedFirebaseIds.add(firebaseId);
    final db = await instance.database;
    return await db.delete(
      'transactions',
      where: 'firebaseId = ?',
      whereArgs: [firebaseId],
    );
  }

  Future<List<String>> getTransactionFirebaseIdsForFriend(
    String friendName, {
    String? userId,
    String? peerUserId,
    bool isManualFriend = false,
    bool hasConflictingConnectedFriend = false,
  }) async {
    // If a manual friend shares the name with a connected friend,
    // transactions without peerUserId are ambiguous and must NOT be deleted automatically.
    if (isManualFriend && hasConflictingConnectedFriend) {
      return [];
    }

    final db = await instance.database;
    final normalizedName = friendName.trim().toLowerCase();

    String whereClause = 'LOWER(TRIM(friendName)) = ?';
    List<dynamic> whereArgs = [normalizedName];
    if (userId != null && userId.isNotEmpty) {
      whereClause =
          '($whereClause) AND (createdBy IS NULL OR createdBy = ? OR peerUserId = ?)';
      whereArgs.addAll([userId, userId]);
    }
    if (peerUserId != null && peerUserId.isNotEmpty) {
      whereClause = '($whereClause) AND peerUserId = ?';
      whereArgs.add(peerUserId);
    } else if (isManualFriend) {
      whereClause =
          '($whereClause) AND (peerUserId IS NULL OR peerUserId = \'\')';
    }

    final rows = await db.query(
      'transactions',
      columns: ['firebaseId'],
      where: whereClause,
      whereArgs: whereArgs,
    );
    return rows
        .map((r) => r['firebaseId'] as String?)
        .where((id) => id != null && id.isNotEmpty)
        .cast<String>()
        .toList();
  }

  Future<int> deleteTransactionsForFriend(
    String friendName, {
    String? userId,
    String? peerUserId,
    bool isManualFriend = false,
    bool hasConflictingConnectedFriend = false,
  }) async {
    // Exclude ambiguous legacy transactions from automatic deletion if connected friend with same name exists
    if (isManualFriend && hasConflictingConnectedFriend) {
      return 0;
    }

    final db = await instance.database;
    final normalizedName = friendName.trim().toLowerCase();

    String whereClause = 'LOWER(TRIM(friendName)) = ?';
    List<dynamic> whereArgs = [normalizedName];
    if (userId != null && userId.isNotEmpty) {
      whereClause =
          '($whereClause) AND (createdBy IS NULL OR createdBy = ? OR peerUserId = ?)';
      whereArgs.addAll([userId, userId]);
    }
    if (peerUserId != null && peerUserId.isNotEmpty) {
      whereClause = '($whereClause) AND peerUserId = ?';
      whereArgs.add(peerUserId);
    } else if (isManualFriend) {
      whereClause =
          '($whereClause) AND (peerUserId IS NULL OR peerUserId = \'\')';
    }

    final rows = await db.query(
      'transactions',
      columns: ['firebaseId'],
      where: whereClause,
      whereArgs: whereArgs,
    );
    for (final r in rows) {
      final fid = r['firebaseId'] as String?;
      if (fid != null && fid.isNotEmpty) {
        deletedFirebaseIds.add(fid);
      }
    }

    return await db.delete(
      'transactions',
      where: whereClause,
      whereArgs: whereArgs,
    );
  }

  Future<void> clearEntryByFirebaseId(
    String firebaseId, {
    String? userId,
  }) async {
    deletedFirebaseIds.add(firebaseId);
    final db = await instance.database;
    final rows = await db.query(
      'transactions',
      columns: ['id'],
      where: 'firebaseId = ?',
      whereArgs: [firebaseId],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      final entryId = rows.first['id'] as int;
      await clearEntry(entryId, userId: userId);
    }
  }

  Future<void> clearEntry(int entryId, {String? userId}) async {
    final db = await instance.database;

    await db.transaction((txn) async {
      final rows = await txn.query(
        'transactions',
        where: 'id = ?',
        whereArgs: [entryId],
        limit: 1,
      );

      if (rows.isEmpty) {
        return;
      }

      final entry = rows.first;
      final friendName = entry['friendName'] as String;
      final creatorUid = userId ?? (entry['createdBy'] as String?);

      await txn.insert('deleted_entries', {
        'originalEntryId': entry['id'],
        'personId': personIdForName(friendName),
        'userId': creatorUid,
        'friendName': friendName,
        'date': entry['date'],
        'note': entry['note'],
        'amount': entry['amount'],
        'isGiven': entry['iGave'],
        'clearedDate': _formatDate(DateTime.now()),
        'receiptPath': entry['receiptPath'],
        'receiptUrl': entry['receiptUrl'],
      });

      await txn.delete('transactions', where: 'id = ?', whereArgs: [entryId]);
    });
  }

  Future<List<DeletedEntryModel>> getDeletedEntries(
    int personId, {
    String? userId,
  }) async {
    final db = await instance.database;

    String whereClause = 'personId = ?';
    List<dynamic> whereArgs = [personId];
    if (userId != null && userId.isNotEmpty) {
      whereClause = 'personId = ? AND (userId IS NULL OR userId = ?)';
      whereArgs = [personId, userId];
    }

    final result = await db.query(
      'deleted_entries',
      where: whereClause,
      whereArgs: whereArgs,
      orderBy: 'id DESC',
    );

    return result.map((json) => DeletedEntryModel.fromMap(json)).toList();
  }

  Future<List<DeletedEntryModel>> getAllDeletedEntries({String? userId}) async {
    final db = await instance.database;

    String? whereClause;
    List<dynamic>? whereArgs;
    if (userId != null && userId.isNotEmpty) {
      whereClause = 'userId IS NULL OR userId = ?';
      whereArgs = [userId];
    }

    final result = await db.query(
      'deleted_entries',
      where: whereClause,
      whereArgs: whereArgs,
      orderBy: 'id DESC',
    );

    return result.map((json) => DeletedEntryModel.fromMap(json)).toList();
  }

  Future<int> deleteDeletedEntriesForFriend(
    String friendName, {
    String? userId,
    bool hasConflictingConnectedFriend = false,
  }) async {
    if (hasConflictingConnectedFriend) {
      return 0;
    }
    final db = await instance.database;
    String whereClause = 'personId = ?';
    List<dynamic> whereArgs = [personIdForName(friendName)];
    if (userId != null && userId.isNotEmpty) {
      whereClause = '($whereClause) AND (userId IS NULL OR userId = ?)';
      whereArgs.add(userId);
    }

    return await db.delete(
      'deleted_entries',
      where: whereClause,
      whereArgs: whereArgs,
    );
  }

  Future<void> restoreDeletedEntry(int deletedEntryId) async {
    final db = await instance.database;

    await db.transaction((txn) async {
      final rows = await txn.query(
        'deleted_entries',
        where: 'id = ?',
        whereArgs: [deletedEntryId],
        limit: 1,
      );

      if (rows.isEmpty) {
        return;
      }

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

      await txn.delete(
        'deleted_entries',
        where: 'id = ?',
        whereArgs: [deletedEntryId],
      );
    });
  }

  Future<int> permanentlyDeleteEntry(int deletedEntryId) async {
    final db = await instance.database;

    return await db.delete(
      'deleted_entries',
      where: 'id = ?',
      whereArgs: [deletedEntryId],
    );
  }

  Future<int> saveBankBalance(double amount) async {
    final db = await instance.database;

    return await db.insert('settings', {
      'id': 1,
      'bankBalance': amount,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<double> getBankBalance() async {
    final db = await instance.database;

    final result = await db.query(
      'settings',

      columns: ['bankBalance'],

      where: 'id = ?',

      whereArgs: [1],

      limit: 1,
    );

    if (result.isEmpty) {
      return 0.0;
    }

    return (result.first['bankBalance'] as num?)?.toDouble() ?? 0.0;
  }

  Future<String?> getMigrationMeta(String key) async {
    final db = await instance.database;

    final result = await db.query(
      'migration_meta',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );

    if (result.isEmpty) {
      return null;
    }

    return result.first['value'] as String?;
  }

  Future<void> setMigrationMeta(String key, String value) async {
    final db = await instance.database;

    await db.insert('migration_meta', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> _createFriendNicknamesTable(Database db) async {
    await db.execute('''
CREATE TABLE IF NOT EXISTS friend_nicknames(
friendName TEXT PRIMARY KEY,
nickname TEXT
)
''');
  }

  Future<int> saveFriendNickname(String friendName, String nickname) async {
    final db = await instance.database;
    return await db.insert('friend_nicknames', {
      'friendName': friendName.trim().toLowerCase(),
      'nickname': nickname,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> getFriendNickname(String friendName) async {
    final db = await instance.database;
    final result = await db.query(
      'friend_nicknames',
      columns: ['nickname'],
      where: 'friendName = ?',
      whereArgs: [friendName.trim().toLowerCase()],
      limit: 1,
    );
    if (result.isEmpty) {
      return null;
    }
    return result.first['nickname'] as String?;
  }

  Future<Map<String, String>> getAllNicknames() async {
    final db = await instance.database;
    final result = await db.query('friend_nicknames');
    return {
      for (final row in result)
        (row['friendName'] as String): (row['nickname'] as String),
    };
  }

  Future<int> deleteFriendNickname(String friendName) async {
    final db = await instance.database;
    return await db.delete(
      'friend_nicknames',
      where: 'friendName = ?',
      whereArgs: [friendName.trim().toLowerCase()],
    );
  }

  Future<void> _createCachedFriendsTable(Database db) async {
    await db.execute('''
CREATE TABLE IF NOT EXISTS cached_friends(
  friendUid TEXT PRIMARY KEY,
  friendName TEXT,
  email TEXT,
  friendCode TEXT,
  photoUrl TEXT,
  upiId TEXT,
  mobileNumber TEXT
)
''');
  }

  Future<void> saveCachedFriend({
    required String friendUid,
    required String friendName,
    String? email,
    String? friendCode,
    String? photoUrl,
    String? upiId,
    String? mobileNumber,
  }) async {
    final db = await instance.database;
    await db.insert('cached_friends', {
      'friendUid': friendUid,
      'friendName': friendName,
      'email': email ?? '',
      'friendCode': friendCode ?? '',
      'photoUrl': photoUrl ?? '',
      'upiId': upiId ?? '',
      'mobileNumber': mobileNumber ?? '',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> getCachedFriendByUid(String friendUid) async {
    final db = await instance.database;
    final result = await db.query(
      'cached_friends',
      where: 'friendUid = ?',
      whereArgs: [friendUid],
      limit: 1,
    );
    if (result.isEmpty) {
      return null;
    }
    return result.first;
  }

  Future<Map<String, dynamic>?> getCachedFriendByName(String friendName) async {
    final db = await instance.database;
    final result = await db.query(
      'cached_friends',
      where: 'LOWER(TRIM(friendName)) = ?',
      whereArgs: [friendName.trim().toLowerCase()],
      limit: 1,
    );
    if (result.isEmpty) {
      return null;
    }
    return result.first;
  }

  Future<bool> hasConnectedFriendWithName(String friendName) async {
    final cached = await getCachedFriendByName(friendName);
    return cached != null;
  }

  Future<List<Map<String, dynamic>>> getAllCachedFriends() async {
    final db = await instance.database;
    return await db.query('cached_friends');
  }

  Future<int> deleteCachedFriend(String friendUid) async {
    final db = await instance.database;
    return await db.delete(
      'cached_friends',
      where: 'friendUid = ?',
      whereArgs: [friendUid],
    );
  }

  Future<int> deleteCachedFriendByName(String friendName) async {
    final db = await instance.database;
    return await db.delete(
      'cached_friends',
      where: 'LOWER(TRIM(friendName)) = ?',
      whereArgs: [friendName.trim().toLowerCase()],
    );
  }

  Future<List<TransactionModel>> getPendingTransactions({
    String? userId,
  }) async {
    final db = await instance.database;
    String whereClause = 'sync_status != ?';
    List<dynamic> whereArgs = [SyncStatus.synced];
    if (userId != null && userId.isNotEmpty) {
      whereClause = '($whereClause) AND (createdBy IS NULL OR createdBy = ?)';
      whereArgs.add(userId);
    }
    final result = await db.query(
      'transactions',
      where: whereClause,
      whereArgs: whereArgs,
      orderBy: 'id ASC',
    );
    return result.map((json) => TransactionModel.fromMap(json)).toList();
  }

  Future<int> updateTransactionSyncStatus(
    int? id,
    int status, {
    String? firebaseId,
  }) async {
    final db = await instance.database;
    final values = <String, dynamic>{
      'sync_status': status,
      if (firebaseId != null && firebaseId.isNotEmpty) 'firebaseId': firebaseId,
    };
    if (id != null) {
      return await db.update(
        'transactions',
        values,
        where: 'id = ?',
        whereArgs: [id],
      );
    } else if (firebaseId != null && firebaseId.isNotEmpty) {
      return await db.update(
        'transactions',
        values,
        where: 'firebaseId = ?',
        whereArgs: [firebaseId],
      );
    }
    return 0;
  }

  Future<int> updateTransactionReceipt(
    int id, {
    String? receiptPath,
    String? receiptUrl,
  }) async {
    final db = await instance.database;
    final values = <String, dynamic>{};
    if (receiptPath != null) values['receiptPath'] = receiptPath;
    if (receiptUrl != null) values['receiptUrl'] = receiptUrl;
    if (values.isEmpty) return 0;
    return await db.update(
      'transactions',
      values,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> _createPersonalExpensesTable(Database db) async {
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
)
''');
  }

  Future<int> insertExpense(ExpenseModel expense) async {
    final db = await instance.database;
    return await db.insert(
      'personal_expenses',
      expense.toLocalMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<ExpenseModel>> getExpenses(String userId) async {
    final db = await instance.database;
    final result = await db.query(
      'personal_expenses',
      where: 'userId = ?',
      whereArgs: [userId],
      orderBy: 'expenseDate DESC',
    );
    return result.map((json) => ExpenseModel.fromLocalMap(json)).toList();
  }

  Future<List<ExpenseModel>> getPendingExpenses({String? userId}) async {
    final db = await instance.database;
    String whereClause = 'sync_status != ?';
    List<dynamic> whereArgs = [SyncStatus.synced];
    if (userId != null && userId.isNotEmpty) {
      whereClause = '($whereClause) AND userId = ?';
      whereArgs.add(userId);
    }
    final result = await db.query(
      'personal_expenses',
      where: whereClause,
      whereArgs: whereArgs,
      orderBy: 'createdAt ASC',
    );
    return result.map((json) => ExpenseModel.fromLocalMap(json)).toList();
  }

  Future<int> updateExpense(ExpenseModel expense) async {
    final db = await instance.database;
    return await db.update(
      'personal_expenses',
      expense.toLocalMap(),
      where: 'id = ?',
      whereArgs: [expense.id],
    );
  }

  Future<int> updateExpenseSyncStatus(String id, int status) async {
    final db = await instance.database;
    return await db.update(
      'personal_expenses',
      {'sync_status': status},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> deleteExpense(String id) async {
    final db = await instance.database;
    return await db.delete(
      'personal_expenses',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> clearExpenses({String? userId}) async {
    final db = await instance.database;
    if (userId != null && userId.isNotEmpty && userId != 'offline_user') {
      return await db.delete(
        'personal_expenses',
        where: 'userId = ?',
        whereArgs: [userId],
      );
    } else {
      return await db.delete('personal_expenses');
    }
  }

  // --- Local Friends ---

  Future<void> _createLocalFriendsTable(Database db) async {
    await db.execute('''
CREATE TABLE IF NOT EXISTS local_friends(
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  userId TEXT NOT NULL,
  createdAt TEXT NOT NULL,
  updatedAt TEXT NOT NULL
)
''');
  }

  static String generateLocalId() {
    final now = DateTime.now().microsecondsSinceEpoch;
    final rand = Random.secure().nextInt(0x7fffffff).toRadixString(16);
    return 'local_${now}_$rand';
  }

  Future<int> insertLocalFriend(LocalFriendModel friend) async {
    final db = await instance.database;
    return await db.insert(
      'local_friends',
      friend.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<LocalFriendModel>> getLocalFriends({String? userId}) async {
    final db = await instance.database;
    final effectiveUserId = userId ?? '';
    final String whereClause;
    final List<dynamic> whereArgs;
    if (effectiveUserId.isEmpty) {
      whereClause = 'userId = ? OR userId IS NULL';
      whereArgs = [''];
    } else {
      whereClause = 'userId = ?';
      whereArgs = [effectiveUserId];
    }
    final result = await db.query(
      'local_friends',
      where: whereClause,
      whereArgs: whereArgs,
      orderBy: 'name COLLATE NOCASE ASC',
    );
    return result.map((m) => LocalFriendModel.fromMap(m)).toList();
  }

  Future<LocalFriendModel?> getLocalFriendByName(
    String name, {
    String? userId,
  }) async {
    final db = await instance.database;
    final effectiveUserId = userId ?? '';
    final String whereClause;
    final List<dynamic> whereArgs;
    if (effectiveUserId.isEmpty) {
      whereClause = 'LOWER(TRIM(name)) = ? AND (userId = ? OR userId IS NULL)';
      whereArgs = [name.trim().toLowerCase(), ''];
    } else {
      whereClause = 'LOWER(TRIM(name)) = ? AND userId = ?';
      whereArgs = [name.trim().toLowerCase(), effectiveUserId];
    }
    final result = await db.query(
      'local_friends',
      where: whereClause,
      whereArgs: whereArgs,
      limit: 1,
    );
    if (result.isEmpty) return null;
    return LocalFriendModel.fromMap(result.first);
  }

  Future<int> deleteLocalFriend(String id) async {
    final db = await instance.database;
    return await db.delete('local_friends', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> deleteLocalFriendByName(String name, {String? userId}) async {
    final db = await instance.database;
    final effectiveUserId = userId ?? '';
    final String whereClause;
    final List<dynamic> whereArgs;
    if (effectiveUserId.isEmpty) {
      whereClause = 'LOWER(TRIM(name)) = ? AND (userId = ? OR userId IS NULL)';
      whereArgs = [name.trim().toLowerCase(), ''];
    } else {
      whereClause = 'LOWER(TRIM(name)) = ? AND userId = ?';
      whereArgs = [name.trim().toLowerCase(), effectiveUserId];
    }
    return await db.delete(
      'local_friends',
      where: whereClause,
      whereArgs: whereArgs,
    );
  }

  Future<int> updateLocalFriend(LocalFriendModel friend) async {
    final db = await instance.database;
    return await db.update(
      'local_friends',
      friend.toMap(),
      where: 'id = ?',
      whereArgs: [friend.id],
    );
  }

  Future<void> adoptOrphanLocalFriends(String userId) async {
    if (userId.isEmpty) return;
    final db = await instance.database;
    await db.update(
      'local_friends',
      {'userId': userId},
      where: 'userId = ? OR userId IS NULL',
      whereArgs: [''],
    );
  }

  Future<void> migrateExistingFriendsToLocal({String? userId}) async {
    final effectiveUserId = userId ?? '';
    if (effectiveUserId.isNotEmpty) {
      await adoptOrphanLocalFriends(effectiveUserId);
    }
    final txs = await getTransactions(userId: effectiveUserId);
    final localFriends = await getLocalFriends(userId: effectiveUserId);
    final existingNames = localFriends
        .map((f) => f.name.trim().toLowerCase())
        .toSet();

    final cached = await getAllCachedFriends();
    final cachedNames = cached
        .map((c) => (c['friendName'] as String? ?? '').trim().toLowerCase())
        .toSet();

    final namesToMigrate = <String>{};
    for (final tx in txs) {
      final name = tx.friendName.trim();
      if (name.isNotEmpty && name.toLowerCase() != 'you') {
        namesToMigrate.add(name);
      }
    }

    for (final name in namesToMigrate) {
      final lower = name.toLowerCase();
      if (!cachedNames.contains(lower) && !existingNames.contains(lower)) {
        final now = DateTime.now();
        final newFriend = LocalFriendModel(
          id: generateLocalId(),
          name: name,
          userId: effectiveUserId,
          createdAt: now,
          updatedAt: now,
        );
        await insertLocalFriend(newFriend);
        existingNames.add(lower);
      }
    }
  }

  // --- You Split Shares ---

  Future<void> _createYouSplitSharesTable(Database db) async {
    await db.execute('''
CREATE TABLE IF NOT EXISTS you_split_shares(
  id TEXT PRIMARY KEY,
  userId TEXT NOT NULL,
  amount REAL NOT NULL,
  note TEXT,
  date TEXT NOT NULL,
  createdAt TEXT NOT NULL
)
''');
  }

  Future<int> insertYouSplitShare({
    required String id,
    required String userId,
    required double amount,
    String? note,
    required String date,
    required String createdAt,
  }) async {
    final db = await instance.database;
    return await db.insert('you_split_shares', {
      'id': id,
      'userId': userId,
      'amount': amount,
      'note': note,
      'date': date,
      'createdAt': createdAt,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> getYouSplitShares({String? userId}) async {
    final db = await instance.database;
    final effectiveUserId = userId ?? '';
    final String whereClause;
    final List<dynamic> whereArgs;
    if (effectiveUserId.isEmpty) {
      whereClause = 'userId = ? OR userId IS NULL';
      whereArgs = [''];
    } else {
      whereClause = 'userId = ?';
      whereArgs = [effectiveUserId];
    }
    return await db.query(
      'you_split_shares',
      where: whereClause,
      whereArgs: whereArgs,
      orderBy: 'createdAt DESC',
    );
  }

  Future<double> getYouSplitTotal({String? userId}) async {
    final shares = await getYouSplitShares(userId: userId);
    return shares.fold<double>(
      0.0,
      (sum, item) => sum + ((item['amount'] as num?)?.toDouble() ?? 0.0),
    );
  }

  Future<int> clearYouSplitShares({String? userId}) async {
    final db = await instance.database;
    final effectiveUserId = userId ?? '';
    if (effectiveUserId.isEmpty) {
      return await db.delete(
        'you_split_shares',
        where: 'userId = ? OR userId IS NULL',
        whereArgs: [''],
      );
    } else {
      return await db.delete(
        'you_split_shares',
        where: 'userId = ?',
        whereArgs: [effectiveUserId],
      );
    }
  }

  // --- Pending Deletions Queue ---

  Future<void> _createPendingDeletionsTable(Database db) async {
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
)
''');
  }

  Future<int> insertPendingDeletion(PendingDeletionModel deletion) async {
    final db = await instance.database;
    return await db.insert('pending_deletions', deletion.toMap());
  }

  Future<List<PendingDeletionModel>> getPendingDeletions({
    String? userId,
  }) async {
    final db = await instance.database;
    final List<Map<String, dynamic>> rows;
    if (userId != null && userId.isNotEmpty) {
      rows = await db.query(
        'pending_deletions',
        where: 'userId = ? OR userId = \'\'',
        whereArgs: [userId],
        orderBy: 'id ASC',
      );
    } else {
      rows = await db.query('pending_deletions', orderBy: 'id ASC');
    }
    return rows.map((r) => PendingDeletionModel.fromMap(r)).toList();
  }

  Future<int> deletePendingDeletion(int id) async {
    final db = await instance.database;
    return await db.delete(
      'pending_deletions',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> restoreDeletedFirebaseIds({String? userId}) async {
    try {
      final pending = await getPendingDeletions(userId: userId);
      for (final p in pending) {
        deletedFirebaseIds.addAll(p.firebaseIds);
      }
    } catch (e) {
      debugPrint('[DatabaseHelper] Error restoring deletedFirebaseIds: $e');
    }
  }
}
