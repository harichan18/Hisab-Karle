import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../core/constants/app_constants.dart';
import '../database/database_helper.dart';
import '../models/transaction_model.dart';
import 'transaction_service.dart';

enum SyncResultStatus {
  success,
  partial,
  noUser,
  alreadySyncing,
  networkUnavailable,
  error,
}

class SyncResult {
  final SyncResultStatus status;
  final int syncedTransactions;
  final int syncedExpenses;
  final int failedTransactions;
  final int failedExpenses;
  final String? message;

  const SyncResult({
    required this.status,
    this.syncedTransactions = 0,
    this.syncedExpenses = 0,
    this.failedTransactions = 0,
    this.failedExpenses = 0,
    this.message,
  });
}

class SyncService with WidgetsBindingObserver {
  static final SyncService instance = SyncService._();

  SyncService._();

  bool _isSyncing = false;
  bool get isSyncing => _isSyncing;

  final ValueNotifier<bool> isSyncingNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<int> pendingCountNotifier = ValueNotifier<int>(0);

  StreamSubscription<dynamic>? _connectivitySubscription;
  StreamSubscription<User?>? _authSubscription;
  bool _isListening = false;

  /// Starts listening to connectivity changes, lifecycle state, and auth changes.
  void startListening() {
    if (_isListening) return;
    _isListening = true;

    WidgetsBinding.instance.addObserver(this);

    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
      results,
    ) {
      final hasConnection = _hasNetworkConnection(results);
      if (hasConnection) {
        debugPrint(
          '[SyncService] Connectivity restored. Triggering pending sync.',
        );
        syncPending();
      }
    });

    _authSubscription = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (user != null) {
        debugPrint(
          '[SyncService] User authenticated. Triggering pending sync.',
        );
        syncPending();
      } else {
        pendingCountNotifier.value = 0;
      }
    });

    // Initial check
    syncPending();
  }

  /// Stops all listeners and lifecycle observers.
  void stopListening() {
    if (!_isListening) return;
    _isListening = false;

    WidgetsBinding.instance.removeObserver(this);
    _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
    _authSubscription?.cancel();
    _authSubscription = null;
  }

  /// Clears in-memory syncing state and pending counters (e.g. on logout).
  void reset() {
    _isSyncing = false;
    isSyncingNotifier.value = false;
    pendingCountNotifier.value = 0;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      debugPrint('[SyncService] App resumed. Triggering pending sync.');
      syncPending();
    }
  }

  bool _hasNetworkConnection(dynamic results) {
    if (results is List<ConnectivityResult>) {
      return results.any((r) => r != ConnectivityResult.none);
    } else if (results is ConnectivityResult) {
      return results != ConnectivityResult.none;
    }
    return false;
  }

  User? get _currentUser {
    try {
      return FirebaseAuth.instance.currentUser;
    } catch (_) {
      return null;
    }
  }

  /// Uploads any locally attached receipt image that hasn't been uploaded yet to Cloudinary.
  /// Never deletes the local file if upload fails.
  Future<String?> _uploadReceiptIfPending(TransactionModel tx) async {
    final path = tx.receiptPath;
    if (path == null || path.isEmpty) return null;
    try {
      final file = File(path);
      if (!await file.exists()) return null;

      final uri = Uri.parse(AppConstants.cloudinaryUploadUrl);
      final request = http.MultipartRequest('POST', uri)
        ..fields['upload_preset'] = AppConstants.cloudinaryUploadPreset
        ..files.add(await http.MultipartFile.fromPath('file', file.path));

      final streamedResponse = await request.send();
      if (streamedResponse.statusCode == 200) {
        final responseBody = await streamedResponse.stream.bytesToString();
        final jsonResponse = jsonDecode(responseBody) as Map<String, dynamic>;
        final url = jsonResponse['secure_url'] as String?;
        if (url != null && tx.id != null) {
          await DatabaseHelper.instance.updateTransactionReceipt(
            tx.id!,
            receiptUrl: url,
          );
        }
        return url;
      }
    } catch (e) {
      debugPrint(
        '[SyncService] Deferred Cloudinary upload deferred: $e. Preserving local file.',
      );
    }
    return null;
  }

  /// Updates the pending record count in SQLite for the current user.
  Future<int> refreshPendingCount() async {
    final user = _currentUser;
    if (user == null) {
      pendingCountNotifier.value = 0;
      return 0;
    }
    try {
      final pendingTx = await DatabaseHelper.instance.getPendingTransactions(
        userId: user.uid,
      );
      final pendingExp = await DatabaseHelper.instance.getPendingExpenses(
        userId: user.uid,
      );
      final total = pendingTx.length + pendingExp.length;
      pendingCountNotifier.value = total;
      return total;
    } catch (e) {
      debugPrint('[SyncService] Error refreshing pending count: $e');
      return 0;
    }
  }

  /// Synchronizes all pending local transactions and expenses to Firestore.
  ///
  /// Safe against concurrent runs via [_isSyncing] lock.
  /// Uses existing [FirebaseDataService.saveTransaction] for idempotent peer mirroring.
  Future<SyncResult> syncPending() async {
    if (_isSyncing) {
      debugPrint(
        '[SyncService] Sync already in progress. Skipping duplicate run.',
      );
      return const SyncResult(status: SyncResultStatus.alreadySyncing);
    }

    final user = _currentUser;
    if (user == null) {
      debugPrint('[SyncService] No authenticated user. Sync skipped.');
      return const SyncResult(status: SyncResultStatus.noUser);
    }

    _isSyncing = true;
    isSyncingNotifier.value = true;

    int syncedTx = 0;
    int failedTx = 0;
    int syncedExp = 0;
    int failedExp = 0;
    bool networkFailure = false;

    try {
      final currentUid = user.uid;

      // 1. Synchronize Pending Transactions
      final pendingTransactions = await DatabaseHelper.instance
          .getPendingTransactions(userId: currentUid);

      for (final tx in pendingTransactions) {
        if (tx.id == null) continue;

        // Mark in-memory/db state as syncing
        await DatabaseHelper.instance.updateTransactionSyncStatus(
          tx.id!,
          SyncStatus.syncing,
        );

        try {
          // Re-use existing firebaseId to guarantee idempotent writes
          final resolvedFirebaseId =
              tx.firebaseId ??
              FirebaseFirestore.instance.collection('users').doc().id;

          // Attempt deferred receipt upload if needed
          String? currentReceiptUrl = tx.receiptUrl;
          if (currentReceiptUrl == null || currentReceiptUrl.isEmpty) {
            final uploaded = await _uploadReceiptIfPending(tx);
            if (uploaded != null) {
              currentReceiptUrl = uploaded;
            }
          }

          await FirebaseDataService.saveTransaction(
            tx.copyWith(
              firebaseId: resolvedFirebaseId,
              createdBy: currentUid,
              receiptUrl: currentReceiptUrl,
            ),
            firebaseId: resolvedFirebaseId,
          );

          // Mark as successfully synced in SQLite
          await DatabaseHelper.instance.updateTransactionSyncStatus(
            tx.id!,
            SyncStatus.synced,
            firebaseId: resolvedFirebaseId,
          );
          syncedTx++;
        } on FirebaseException catch (fe) {
          if (fe.code == 'unavailable' || fe.code == 'network-request-failed') {
            networkFailure = true;
            await DatabaseHelper.instance.updateTransactionSyncStatus(
              tx.id!,
              SyncStatus.pending,
            );
            debugPrint(
              '[SyncService] Network unavailable for transaction ${tx.id}. Kept pending.',
            );
          } else if (fe.code == 'permission-denied' ||
              fe.code == 'unauthenticated') {
            await DatabaseHelper.instance.updateTransactionSyncStatus(
              tx.id!,
              SyncStatus.failed,
            );
            debugPrint(
              '[SyncService] Permission error syncing transaction ${tx.id}: ${fe.code}',
            );
            failedTx++;
          } else {
            await DatabaseHelper.instance.updateTransactionSyncStatus(
              tx.id!,
              SyncStatus.failed,
            );
            debugPrint(
              '[SyncService] Firestore error syncing transaction ${tx.id}: ${fe.code}',
            );
            failedTx++;
          }
        } catch (e) {
          networkFailure = true;
          await DatabaseHelper.instance.updateTransactionSyncStatus(
            tx.id!,
            SyncStatus.pending,
          );
          debugPrint(
            '[SyncService] General error syncing transaction ${tx.id}: $e',
          );
        }
      }

      // 2. Synchronize Pending Personal Expenses
      final pendingExpenses = await DatabaseHelper.instance.getPendingExpenses(
        userId: currentUid,
      );

      for (final exp in pendingExpenses) {
        if (exp.id == null) continue;

        await DatabaseHelper.instance.updateExpenseSyncStatus(
          exp.id!,
          SyncStatus.syncing,
        );

        try {
          await FirebaseFirestore.instance
              .collection('expenses')
              .doc(exp.id)
              .set(exp.toFirestoreMap(), SetOptions(merge: true));

          await DatabaseHelper.instance.updateExpenseSyncStatus(
            exp.id!,
            SyncStatus.synced,
          );
          syncedExp++;
        } on FirebaseException catch (fe) {
          if (fe.code == 'unavailable' || fe.code == 'network-request-failed') {
            networkFailure = true;
            await DatabaseHelper.instance.updateExpenseSyncStatus(
              exp.id!,
              SyncStatus.pending,
            );
            debugPrint(
              '[SyncService] Network unavailable for expense ${exp.id}. Kept pending.',
            );
          } else if (fe.code == 'permission-denied' ||
              fe.code == 'unauthenticated') {
            await DatabaseHelper.instance.updateExpenseSyncStatus(
              exp.id!,
              SyncStatus.failed,
            );
            failedExp++;
          } else {
            await DatabaseHelper.instance.updateExpenseSyncStatus(
              exp.id!,
              SyncStatus.failed,
            );
            failedExp++;
          }
        } catch (e) {
          networkFailure = true;
          await DatabaseHelper.instance.updateExpenseSyncStatus(
            exp.id!,
            SyncStatus.pending,
          );
          debugPrint(
            '[SyncService] General error syncing expense ${exp.id}: $e',
          );
        }
      }

      await refreshPendingCount();

      if (networkFailure && syncedTx == 0 && syncedExp == 0) {
        return SyncResult(
          status: SyncResultStatus.networkUnavailable,
          syncedTransactions: syncedTx,
          syncedExpenses: syncedExp,
          failedTransactions: failedTx,
          failedExpenses: failedExp,
        );
      } else if (failedTx > 0 || failedExp > 0 || networkFailure) {
        return SyncResult(
          status: SyncResultStatus.partial,
          syncedTransactions: syncedTx,
          syncedExpenses: syncedExp,
          failedTransactions: failedTx,
          failedExpenses: failedExp,
        );
      }

      return SyncResult(
        status: SyncResultStatus.success,
        syncedTransactions: syncedTx,
        syncedExpenses: syncedExp,
      );
    } finally {
      _isSyncing = false;
      isSyncingNotifier.value = false;
    }
  }
}
