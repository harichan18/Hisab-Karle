// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:open_file/open_file.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shimmer/shimmer.dart';

import '../../core/storage/app_prefs.dart';
import '../../core/storage/receipt_storage.dart';
import '../../core/utils/navigation_helper.dart';
import '../../core/utils/transaction_display_helper.dart';
import '../../database/database_helper.dart';
import '../../models/expense_model.dart';
import '../../models/friend_model.dart';
import '../../models/transaction_model.dart';
import '../../services/expense_service.dart';
import '../../services/share_receiver_service.dart';
import '../../services/transaction_service.dart';
import '../../services/update_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_drawer.dart';
import '../../widgets/buttons/glass_action_button.dart';
import '../../widgets/buttons/olive_premium_button.dart';
import '../../widgets/image/custom_cached_image.dart';
import '../../widgets/image/receipt_attachment_section.dart';
import '../auth/profile_page.dart';
import '../daily_expenditure_screen.dart';
import '../friends/add_friend_page.dart';
import '../friends/person_detail_screen.dart';
import '../reports_screen.dart';
import '../settings_screen.dart';
import '../share_payment_screen.dart';
import '../transactions/add_transaction_screen.dart';

void _receiptLog(String scope, String message) => receiptLog(scope, message);

Future<XFile?> _pickReceiptImage({
  required ImageSource source,
  required String scope,
}) => pickReceiptImage(source: source, scope: scope);

Future<XFile?> _compressReceiptImage(File file, {required String scope}) =>
    compressReceiptImage(file, scope: scope);

Future<String?> _saveReceiptLocally({
  required File sourceFile,
  required String firebaseId,
  required String scope,
}) => saveReceiptLocally(
  sourceFile: sourceFile,
  firebaseId: firebaseId,
  scope: scope,
);

String _transactionDisplayFriendName(TransactionModel transaction) =>
    transactionDisplayFriendName(transaction);

bool _transactionDisplayIsGiven(TransactionModel transaction) =>
    transactionDisplayIsGiven(transaction);

PageRouteBuilder<T> _smoothRoute<T>(WidgetBuilder builder) =>
    smoothRoute<T>(builder);

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  static bool _hasCheckedUpdate = false;
  List<TransactionModel> transactions = [];
  List<FirestoreFriendProfile> firestoreFriends = [];
  Map<String, String> localNicknames = {};
  Map<String, Map<String, dynamic>> cachedFriendProfiles = {};
  DateTime? _lastFriendsSyncTime;
  DateTime? _lastDashboardRefreshTime;
  bool _isSyncingFriends = false;
  String? _pendingApkPath;
  bool _isCheckingInstallPermission = false;
  String _selectedFilter = 'All';
  // True while the very first data load is in progress — shows shimmer
  bool _isInitialLoad = true;

  List<ExpenseModel> _homeExpenses = [];
  StreamSubscription<List<ExpenseModel>>? _homeExpensesSubscription;

  double get todayHomeSpending {
    final now = DateTime.now();
    return _homeExpenses
        .where(
          (e) =>
              e.expenseDate.year == now.year &&
              e.expenseDate.month == now.month &&
              e.expenseDate.day == now.day,
        )
        .fold(0.0, (acc, e) => acc + e.amount);
  }

  double get monthHomeSpending {
    final now = DateTime.now();
    return _homeExpenses
        .where(
          (e) =>
              e.expenseDate.year == now.year &&
              e.expenseDate.month == now.month,
        )
        .fold(0.0, (acc, e) => acc + e.amount);
  }

  Future<void> loadExpenses() async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? 'offline_user';
    final data = await ExpenseService.getExpensesOnce(uid);
    if (!mounted) return;
    debugPrint(
      '[Home] [SQLite Load] Reloaded personal expenses: ${data.length} items',
    );
    setState(() {
      _homeExpenses = data;
    });
  }

  Future<void> loadLocalNicknames() async {
    final nicks = await DatabaseHelper.instance.getAllNicknames();
    if (!mounted) return;
    setState(() {
      localNicknames = nicks;
    });
  }

  // Pre-load from cache for instant first render, SQLite will refine shortly after
  double bankBalance = AppPrefs.getBankBalance();
  bool isLoading = false;
  StreamSubscription<List<TransactionModel>>? _transactionsSubscription;
  StreamSubscription<double>? _bankBalanceSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _user1FriendsSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _user2FriendsSubscription;
  StreamSubscription<String>? _shareImageSubscription;
  bool _isHandlingShare = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    initializeHome();
    _shareImageSubscription = ShareReceiverService.instance.sharedImageStream
        .listen(_handleIncomingSharedImage);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkInitialSharedImage();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _shareImageSubscription?.cancel();
    _transactionsSubscription?.cancel();
    _bankBalanceSubscription?.cancel();
    _user1FriendsSubscription?.cancel();
    _user2FriendsSubscription?.cancel();
    _homeExpensesSubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkInitialSharedImage();
      if (_isCheckingInstallPermission && _pendingApkPath != null) {
        _isCheckingInstallPermission = false;
        _handleReturnFromInstallSettings();
      }
    }
  }

  Future<void> _checkInitialSharedImage() async {
    final path = await ShareReceiverService.instance.checkInitialSharedImage();
    if (path != null && path.isNotEmpty) {
      _handleIncomingSharedImage(path);
    }
  }

  Future<void> _handleIncomingSharedImage(String path) async {
    if (!mounted || _isHandlingShare) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      debugPrint(
        '[Home] User not logged in, share will wait until authenticated.',
      );
      return;
    }

    _isHandlingShare = true;
    ShareReceiverService.instance.clearPendingImage();

    try {
      final result = await Navigator.push<bool>(
        context,
        MaterialPageRoute(builder: (_) => SharePaymentScreen(imagePath: path)),
      );

      if (result == true && mounted) {
        await loadData();
        await loadExpenses();
        await loadFirestoreFriends();
      }
    } catch (e) {
      debugPrint('[Home] Error opening SharePaymentScreen: $e');
    } finally {
      _isHandlingShare = false;
    }
  }

  Future<void> _handleReturnFromInstallSettings() async {
    final hasPermission =
        await InstallPermissionService.canRequestPackageInstalls();
    if (!mounted) return;

    if (hasPermission) {
      final apkPath = _pendingApkPath;
      _pendingApkPath = null;
      if (apkPath != null) {
        await _installApk(apkPath);
      }
    } else {
      _pendingApkPath = null;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Install permission was denied. Cannot install update.',
          ),
        ),
      );
    }
  }

  Future<void> loadData() async {
    await loadLocalNicknames();
    await Future.wait([
      loadTransactions(),
      loadBankBalance(),
      loadCachedFriendProfiles(),
      loadExpenses(),
    ]);

    if (FirebaseAuth.instance.currentUser != null) {
      _loadDataFirestoreBackground();
    }
    debugPrint('[Home] total friends loaded: ${visibleFriends.length}');
  }

  Future<void> _loadDataFirestoreBackground() async {
    await FirebaseDataService.migrateSQLiteCacheToFirestoreIfNeeded();
    await loadFirestoreFriends();
  }

  Future<void> loadCachedFriendProfiles() async {
    final cached = await DatabaseHelper.instance.getAllCachedFriends();
    final map = {for (final row in cached) (row['friendUid'] as String): row};
    if (mounted) {
      setState(() {
        cachedFriendProfiles = map;
      });
    }
  }

  Future<void> _installApk(String apkPath) async {
    try {
      final apkFile = File(apkPath);
      final fileExists = await apkFile.exists();
      print('APK exists for install: $fileExists');
      if (!fileExists) {
        throw Exception('APK file does not exist.');
      }

      final fileSize = await apkFile.length();
      print('APK file size: $fileSize bytes');
      if (fileSize == 0) {
        throw Exception('APK file is empty.');
      }

      print('Launching installer: $apkPath');
      final result = await OpenFile.open(apkPath);
      print('OpenFile result: ${result.type}');
      print('OpenFile message: ${result.message}');

      if (result.type != ResultType.done) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Installation failed: ${result.message}')),
          );

          showDialog(
            context: context,
            builder: (errorContext) => AlertDialog(
              title: const Text('Installation Failed'),
              content: Text(
                'Could not launch APK installer.\n\n'
                'Error: ${result.type}\n'
                'Details: ${result.message}',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(errorContext),
                  child: const Text('OK'),
                ),
              ],
            ),
          );
        }
      }
    } catch (e) {
      print('APK install exception: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to install update: $e')));
      }
    }
  }

  Future<void> _downloadAndInstallApk(String url) async {
    if (url.isEmpty || url.toLowerCase() == 'pending') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Update URL is not available.')),
      );
      return;
    }

    double progress = 0.0;
    StateSetter? progressStateSetter;
    BuildContext? progressDialogContext;
    bool isProgressDialogClosed = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        progressDialogContext = dialogContext;
        return PopScope(
          canPop: false,
          child: StatefulBuilder(
            builder: (context, setState) {
              progressStateSetter = setState;
              return AlertDialog(
                title: const Text('Downloading Update'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LinearProgressIndicator(value: progress),
                    const SizedBox(height: 16),
                    Text('${(progress * 100).toStringAsFixed(0)}%'),
                    const SizedBox(height: 8),
                    const Text(
                      'Downloading APK...',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );

    String apkPath = '';
    try {
      print('APK download started');
      final tempDir = await getTemporaryDirectory();
      apkPath = '${tempDir.path}/hisab_kitab_update.apk';
      print('APK saved at: $apkPath');

      final apkFile = File(apkPath);
      if (await apkFile.exists()) {
        await apkFile.delete();
      }

      final dio = Dio();
      await dio.download(
        url,
        apkPath,
        onReceiveProgress: (received, total) {
          if (total != -1) {
            final currentProgress = received / total;
            if (progressStateSetter != null) {
              progressStateSetter!(() {
                progress = currentProgress;
              });
            }
          }
        },
      );
      print('APK download completed');

      if (progressDialogContext != null &&
          progressDialogContext!.mounted &&
          !isProgressDialogClosed) {
        isProgressDialogClosed = true;
        Navigator.pop(progressDialogContext!);
      }

      final fileExists = await apkFile.exists();
      print('APK exists: $fileExists');
      if (!fileExists) {
        throw Exception('Downloaded APK file does not exist.');
      }

      final fileSize = await apkFile.length();
      print('APK file size: $fileSize bytes');
      if (fileSize == 0) {
        throw Exception('Downloaded APK file is empty.');
      }

      final hasPermission =
          await InstallPermissionService.canRequestPackageInstalls();
      if (hasPermission) {
        await _installApk(apkPath);
      } else {
        if (mounted) {
          _pendingApkPath = apkPath;
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (dialogContext) {
              return AlertDialog(
                title: const Text('Permission Required'),
                content: const Text(
                  "Please allow 'Install unknown apps' for Hisab Kitab to continue the update.",
                ),
                actions: [
                  TextButton(
                    onPressed: () {
                      Navigator.pop(dialogContext);
                      _pendingApkPath = null;
                      _isCheckingInstallPermission = false;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Install permission was denied. Cannot install update.',
                          ),
                        ),
                      );
                    },
                    child: const Text('Cancel'),
                  ),
                  TextButton(
                    onPressed: () async {
                      Navigator.pop(dialogContext);
                      _isCheckingInstallPermission = true;
                      await InstallPermissionService.openInstallPermissionSettings();
                    },
                    child: const Text('Settings'),
                  ),
                ],
              );
            },
          );
        }
      }
    } catch (e) {
      if (progressDialogContext != null &&
          progressDialogContext!.mounted &&
          !isProgressDialogClosed) {
        isProgressDialogClosed = true;
        Navigator.pop(progressDialogContext!);
      }
      print('APK download/install exception: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to download or install update: $e')),
        );
      }
    }
  }

  Future<void> _checkAppUpdate() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('app_config')
          .doc('updates')
          .get();
      if (!doc.exists || doc.data() == null) return;
      final data = doc.data() ?? {};
      final latestVersion = data['latestVersion'] as int? ?? 0;
      final versionName = data['versionName'] as String? ?? '';
      final changelog = data['changelog'] as String? ?? '';
      final forceUpdate = data['forceUpdate'] as bool? ?? false;
      final apkUrl = data['apkUrl'] as String? ?? '';

      final packageInfo = await PackageInfo.fromPlatform();
      final currentBuildNumber = int.tryParse(packageInfo.buildNumber) ?? 0;

      if (latestVersion > currentBuildNumber) {
        if (!mounted) return;
        showDialog(
          context: context,
          barrierDismissible: !forceUpdate,
          builder: (dialogContext) {
            return PopScope(
              canPop: !forceUpdate,
              child: AlertDialog(
                title: const Text('Update Available'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Version: $versionName',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 12),
                    Text(changelog),
                  ],
                ),
                actions: [
                  if (!forceUpdate)
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('Later'),
                    ),
                  TextButton(
                    onPressed: () {
                      Navigator.pop(dialogContext);
                      _downloadAndInstallApk(apkUrl);
                    },
                    child: const Text('Update'),
                  ),
                ],
              ),
            );
          },
        );
      }
    } catch (e) {
      debugPrint('Error checking app update: $e');
    }
  }

  Future<void> initializeHome() async {
    await loadData();
    if (mounted) {
      setState(() => _isInitialLoad = false); // reveal real content
      startRealtimeSync();
      if (!_hasCheckedUpdate && FirebaseAuth.instance.currentUser != null) {
        _hasCheckedUpdate = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _checkAppUpdate();
        });
      }
    }
  }

  void startRealtimeSync() {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      return;
    }

    _homeExpensesSubscription = ExpenseService.expensesStream(currentUser.uid)
        .listen((data) {
          if (mounted) {
            setState(() {
              _homeExpenses = data;
            });
          }
        });

    _transactionsSubscription = FirebaseDataService.transactionsStream().listen((
      data,
    ) {
      if (!mounted) {
        return;
      }
      bool changed = transactions.length != data.length;
      if (!changed) {
        for (int i = 0; i < transactions.length; i++) {
          if (transactions[i].id != data[i].id ||
              transactions[i].firebaseId != data[i].firebaseId ||
              transactions[i].amount != data[i].amount ||
              transactions[i].note != data[i].note ||
              transactions[i].date != data[i].date ||
              transactions[i].iGave != data[i].iGave ||
              transactions[i].receiptPath != data[i].receiptPath ||
              transactions[i].receiptUrl != data[i].receiptUrl) {
            changed = true;
            break;
          }
        }
      }
      if (changed) {
        setState(() {
          transactions = data;
        });
        debugPrint(
          '[Home] [Firestore Stream] transactions snapshot loaded: ${data.length} items',
        );
        debugPrint('[Home] total friends loaded: ${visibleFriends.length}');
      }
    });

    _bankBalanceSubscription = FirebaseDataService.bankBalanceStream().listen((
      amount,
    ) {
      if (!mounted) {
        return;
      }
      if (bankBalance != amount) {
        setState(() {
          bankBalance = amount;
        });
        debugPrint(
          '[Home] [Firestore Stream] bank balance snapshot loaded: $amount',
        );
      }
    });

    final friendsCollection = FirebaseFirestore.instance.collection('friends');
    _user1FriendsSubscription = friendsCollection
        .where('user1', isEqualTo: currentUser.uid)
        .snapshots()
        .listen((_) => loadFirestoreFriends());
    _user2FriendsSubscription = friendsCollection
        .where('user2', isEqualTo: currentUser.uid)
        .snapshots()
        .listen((_) => loadFirestoreFriends());
  }

  Future<void> loadTransactions() async {
    final data = await DatabaseHelper.instance.getTransactions();
    if (!mounted) {
      return;
    }
    final reversedData = data.reversed.toList();
    bool changed = transactions.length != reversedData.length;
    if (!changed) {
      for (int i = 0; i < transactions.length; i++) {
        if (transactions[i].id != reversedData[i].id ||
            transactions[i].amount != reversedData[i].amount ||
            transactions[i].note != reversedData[i].note ||
            transactions[i].date != reversedData[i].date ||
            transactions[i].iGave != reversedData[i].iGave ||
            transactions[i].receiptPath != reversedData[i].receiptPath) {
          changed = true;
          break;
        }
      }
    }
    if (changed) {
      debugPrint(
        '[Home] [SQLite Load] Overwriting transactions list: ${reversedData.length} items',
      );
      setState(() {
        transactions = reversedData;
      });
    }
  }

  Future<void> loadBankBalance() async {
    final amount = await DatabaseHelper.instance.getBankBalance();
    if (!mounted) {
      return;
    }
    if (bankBalance != amount) {
      debugPrint('[Home] [SQLite Load] Overwriting bankBalance: $amount');
      setState(() {
        bankBalance = amount;
      });
    }
  }

  Future<void> refreshDashboard() async {
    final now = DateTime.now();
    if (_lastDashboardRefreshTime != null &&
        now.difference(_lastDashboardRefreshTime!) <
            const Duration(seconds: 1)) {
      debugPrint(
        '[Home] Dashboard refreshed very recently. Skipping duplicate reload.',
      );
      return;
    }
    _lastDashboardRefreshTime = now;

    await loadLocalNicknames();
    if (FirebaseAuth.instance.currentUser == null) {
      await Future.wait([loadTransactions(), loadBankBalance()]);
    } else {
      await loadFirestoreFriends();
    }
  }

  Future<void> loadFirestoreFriends() async {
    final cachedRows = await DatabaseHelper.instance.getAllCachedFriends();
    final cachedFriends = cachedRows.map((row) {
      return FirestoreFriendProfile(
        uid: row['friendUid'] as String,
        name: row['friendName'] as String? ?? '',
        email: row['email'] as String? ?? '',
        friendCode: row['friendCode'] as String? ?? '',
      );
    }).toList();

    if (cachedFriends.isNotEmpty && mounted) {
      setState(() {
        firestoreFriends = cachedFriends;
      });
    }

    _syncFirestoreFriendsBackground();
  }

  Future<void> _syncFirestoreFriendsBackground() async {
    if (_isSyncingFriends) {
      debugPrint('[Home] Already syncing friends. Skipping.');
      return;
    }

    final now = DateTime.now();
    if (_lastFriendsSyncTime != null &&
        now.difference(_lastFriendsSyncTime!) < const Duration(seconds: 2)) {
      debugPrint(
        '[Home] Friends synced very recently. Skipping duplicate reload.',
      );
      return;
    }
    _lastFriendsSyncTime = now;
    _isSyncingFriends = true;

    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser == null) return;
      final currentUid = currentUser.uid;

      final friendsCollection = FirebaseFirestore.instance.collection(
        'friends',
      );
      final user1Query = await friendsCollection
          .where('user1', isEqualTo: currentUid)
          .get();
      final user2Query = await friendsCollection
          .where('user2', isEqualTo: currentUid)
          .get();

      final friendshipDocs = {
        for (final doc in user1Query.docs) doc.id: doc,
        for (final doc in user2Query.docs) doc.id: doc,
      }.values.toList();

      final friendUids = <String>{};
      for (final doc in friendshipDocs) {
        final data = doc.data();
        final user1 = data['user1'] as String? ?? '';
        final user2 = data['user2'] as String? ?? '';
        final friendUid = user1 == currentUid ? user2 : user1;

        if (friendUid.isNotEmpty && friendUid != currentUid) {
          friendUids.add(friendUid);
        }
      }

      bool cacheChanged = false;

      final tasks = friendUids.map((friendUid) async {
        final cached = await DatabaseHelper.instance.getCachedFriendByUid(
          friendUid,
        );
        try {
          final userDoc = await FirebaseFirestore.instance
              .collection('users')
              .doc(friendUid)
              .get();
          final data = userDoc.data();
          if (userDoc.exists && data != null) {
            final friendProfile = FirestoreFriendProfile(
              uid: data['uid'] as String? ?? friendUid,
              name: data['name'] as String? ?? '',
              email: data['email'] as String? ?? '',
              friendCode: data['friendCode'] as String? ?? '',
            );

            final photoUrl = data['photoUrl'] as String? ?? '';
            final upiId = data['upiId'] as String? ?? '';
            final mobileNumber = data['mobileNumber'] as String? ?? '';

            if (cached == null ||
                cached['friendName'] != friendProfile.name ||
                cached['email'] != friendProfile.email ||
                cached['friendCode'] != friendProfile.friendCode ||
                cached['photoUrl'] != photoUrl ||
                cached['upiId'] != upiId ||
                cached['mobileNumber'] != mobileNumber) {
              await DatabaseHelper.instance.saveCachedFriend(
                friendUid: friendUid,
                friendName: friendProfile.name,
                email: friendProfile.email,
                friendCode: friendProfile.friendCode,
                photoUrl: photoUrl,
                upiId: upiId,
                mobileNumber: mobileNumber,
              );
              cacheChanged = true;
            }
            return friendProfile;
          }
        } catch (e) {
          debugPrint('Error syncing friend $friendUid: $e');
        }

        if (cached != null) {
          return FirestoreFriendProfile(
            uid: friendUid,
            name: cached['friendName'] as String? ?? '',
            email: cached['email'] as String? ?? '',
            friendCode: cached['friendCode'] as String? ?? '',
          );
        }
        return null;
      }).toList();

      final results = await Future.wait(tasks);
      final syncedFriends = results
          .whereType<FirestoreFriendProfile>()
          .toList();

      if (syncedFriends.isNotEmpty) {
        if (mounted) {
          bool listsDifferent = firestoreFriends.length != syncedFriends.length;
          if (!listsDifferent) {
            for (int i = 0; i < firestoreFriends.length; i++) {
              if (firestoreFriends[i].uid != syncedFriends[i].uid ||
                  firestoreFriends[i].name != syncedFriends[i].name) {
                listsDifferent = true;
                break;
              }
            }
          }
          if (listsDifferent || cacheChanged) {
            setState(() {
              firestoreFriends = syncedFriends;
            });
            if (cacheChanged) {
              await loadCachedFriendProfiles();
            }
          }
        }
      }
    } finally {
      _isSyncingFriends = false;
    }
  }

  double get totalToGet {
    double total = 0;
    for (var t in transactions) {
      if (t.iGave) {
        total += t.amount;
      }
    }
    return total;
  }

  double get totalToGive {
    double total = 0;
    for (var t in transactions) {
      if (!t.iGave) {
        total += t.amount;
      }
    }
    return total;
  }

  double get netWorth {
    return bankBalance + totalToGet - totalToGive;
  }

  Future<void> syncBankBalance() async {
    setState(() {
      isLoading = true;
    });
    try {
      if (FirebaseAuth.instance.currentUser == null) {
        await loadBankBalance();
      } else {
        await loadFirestoreFriends();
      }
    } catch (e) {
      debugPrint('Error loading bank balance: $e');
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  String formatAmount(double amount) {
    return amount
        .toStringAsFixed(0)
        .replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');
  }

  Future<void> showBankBalanceDialog() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final subtextColor = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    final borderCol = isDark ? AppColors.borderDark : AppColors.borderLight;
    final cardBg = isDark
        ? AppColors.surfaceVariantDark
        : const Color(0xFFF9FAFB);

    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? AppColors.surfaceDark : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (bottomSheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: borderCol,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  "Adjust Bank Balance",
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: textColor,
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: cardBg,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: borderCol),
                  ),
                  child: Column(
                    children: [
                      Text(
                        "CURRENT BANK BALANCE",
                        style: TextStyle(
                          fontSize: 12,
                          color: subtextColor,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.1,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        "₹${formatAmount(bankBalance)}",
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: textColor,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                OlivePremiumButton(
                  icon: Icons.add_rounded,
                  title: "Add Money",
                  description: "Increase your current bank balance manually",
                  onTap: () {
                    Navigator.pop(bottomSheetContext);
                    _showAdjustmentSheet(isDeduction: false);
                  },
                ),
                const SizedBox(height: 16),
                OlivePremiumButton(
                  icon: Icons.remove_rounded,
                  title: "Deduct Money",
                  description: "Decrease your current bank balance manually",
                  onTap: () {
                    Navigator.pop(bottomSheetContext);
                    _showAdjustmentSheet(isDeduction: true);
                  },
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showAdjustmentSheet({required bool isDeduction}) {
    final controller = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final subtextColor = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    final borderCol = isDark ? AppColors.borderDark : AppColors.borderLight;
    final inputBg = isDark
        ? AppColors.surfaceVariantDark
        : const Color(0xFFF9FAFB);

    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? AppColors.surfaceDark : Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sbContext, setSheetState) {
            final enteredText = controller.text.trim();
            final enteredAmount = double.tryParse(enteredText) ?? 0.0;
            final double previewBalance = isDeduction
                ? (bankBalance - enteredAmount)
                : (bankBalance + enteredAmount);

            return Padding(
              padding: EdgeInsets.only(
                left: 24,
                right: 24,
                top: 16,
                bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 24,
              ),
              child: SafeArea(
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: borderCol,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        isDeduction ? "Deduct Money" : "Add Money",
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: textColor,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: isDark
                                    ? AppColors.surfaceVariantDark
                                    : const Color(0xFFF3F4F6),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: borderCol),
                              ),
                              child: Column(
                                children: [
                                  Text(
                                    "Current Balance",
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: subtextColor,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    "₹${formatAmount(bankBalance)}",
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: textColor,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Icon(
                            Icons.arrow_forward_rounded,
                            color: isDark
                                ? AppColors.textMutedDark
                                : AppColors.textMuted,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: isDeduction && previewBalance < 0
                                    ? (isDark
                                          ? AppColors.payBgDark
                                          : AppColors.payBg)
                                    : (isDark
                                          ? AppColors.collectBgDark
                                          : AppColors.collectBg),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isDeduction && previewBalance < 0
                                      ? AppColors.payBadge
                                      : AppColors.collectBadge,
                                ),
                              ),
                              child: Column(
                                children: [
                                  Text(
                                    "New Balance Preview",
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: subtextColor,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    "₹${formatAmount(previewBalance)}",
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: isDeduction && previewBalance < 0
                                          ? AppColors.payText
                                          : AppColors.collectText,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      TextFormField(
                        controller: controller,
                        autofocus: true,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        style: TextStyle(
                          color: textColor,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                        cursorColor: isDark ? Colors.white : AppColors.darkCard,
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: inputBg,
                          labelText:
                              "Amount to ${isDeduction ? 'deduct' : 'add'}",
                          labelStyle: TextStyle(color: subtextColor),
                          hintText: "500",
                          hintStyle: TextStyle(
                            color: isDark
                                ? AppColors.textMutedDark
                                : AppColors.textMuted,
                          ),
                          prefixText: "\u20B9 ",
                          prefixStyle: TextStyle(
                            color: textColor,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: borderCol),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: isDark ? Colors.white : AppColors.darkCard,
                              width: 1.5,
                            ),
                          ),
                          errorBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                              color: AppColors.payText,
                            ),
                          ),
                          focusedErrorBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                              color: AppColors.payText,
                              width: 1.5,
                            ),
                          ),
                        ),
                        onChanged: (_) {
                          setSheetState(() {});
                        },
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return "Please enter an amount";
                          }
                          final parsed = double.tryParse(value.trim());
                          if (parsed == null || parsed <= 0) {
                            return "Please enter a valid positive amount";
                          }
                          if (isDeduction && bankBalance - parsed < 0) {
                            return "Deduction amount cannot exceed current balance";
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                side: BorderSide(color: borderCol),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              onPressed: () => Navigator.pop(sheetContext),
                              child: Text(
                                "Cancel",
                                style: TextStyle(
                                  color: subtextColor,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: isDark
                                    ? Colors.white
                                    : AppColors.darkCard,
                                foregroundColor: isDark
                                    ? AppColors.darkCard
                                    : Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                elevation: 0,
                              ),
                              onPressed: () async {
                                if (formKey.currentState?.validate() ?? false) {
                                  final amount = double.parse(
                                    controller.text.trim(),
                                  );
                                  final newBalance = isDeduction
                                      ? (bankBalance - amount)
                                      : (bankBalance + amount);

                                  await AppPrefs.setBankBalance(newBalance);
                                  await DatabaseHelper.instance.saveBankBalance(
                                    newBalance,
                                  );
                                  await FirebaseDataService.saveBankBalance(
                                    newBalance,
                                  );

                                  if (sheetContext.mounted) {
                                    Navigator.pop(sheetContext);
                                  }

                                  setState(() {
                                    bankBalance = newBalance;
                                  });

                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        backgroundColor: const Color(
                                          0xFF9EA98F,
                                        ),
                                        content: Text(
                                          isDeduction
                                              ? "Successfully deducted ₹${formatAmount(amount)} from Bank Balance"
                                              : "Successfully added ₹${formatAmount(amount)} to Bank Balance",
                                          style: const TextStyle(
                                            color: Colors.black,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    );
                                  }
                                }
                              },
                              child: Text(
                                isDeduction ? "Deduct" : "Add",
                                style: const TextStyle(
                                  color: Colors.black,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> openProfilePage() async {
    await Navigator.push(context, _smoothRoute((_) => const ProfilePage()));
  }

  Future<void> openAddFriendPage() async {
    final result = await Navigator.push(
      context,
      _smoothRoute((_) => const AddFriendPage()),
    );
    if (result == true) {
      await refreshDashboard();
      debugPrint('[Home] total friends loaded: ${visibleFriends.length}');
    }
  }

  // Group transactions by friendName (case-insensitive key, original case preserved)
  Map<String, List<TransactionModel>> get groupedTransactions {
    final Map<String, List<TransactionModel>> map = {};
    final Map<String, String> originalNames = {};
    for (var t in transactions) {
      final name = _transactionDisplayFriendName(t).trim();
      if (name.isEmpty) continue;
      final key = name.toLowerCase();
      if (!originalNames.containsKey(key)) {
        originalNames[key] = name;
      }
      map.putIfAbsent(originalNames[key] ?? name, () => []).add(t);
    }
    return map;
  }

  // Sorted list of unique friend names
  List<String> get uniqueFriends {
    final friends = groupedTransactions.keys.toList();
    friends.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return friends;
  }

  List<FriendListItem> get visibleFriends {
    final items = <FriendListItem>[];
    final existingNames = <String>{};

    for (final friendName in uniqueFriends) {
      final key = friendName.trim().toLowerCase();
      final nickname = localNicknames[key];
      items.add(FriendListItem(name: friendName, nickname: nickname));
      existingNames.add(key);
    }

    for (final firestoreFriend in firestoreFriends) {
      final displayName = firestoreFriend.displayName;
      final key = displayName.toLowerCase();
      final nickname = localNicknames[key];
      if (existingNames.contains(key)) {
        final index = items.indexWhere(
          (item) => item.name.trim().toLowerCase() == key,
        );
        if (index != -1) {
          items[index] = FriendListItem(
            name: items[index].name,
            uid: firestoreFriend.uid,
            email: firestoreFriend.email,
            friendCode: firestoreFriend.friendCode,
            fromFirestore: true,
            nickname: nickname,
          );
        }
        continue;
      }

      items.add(
        FriendListItem(
          name: displayName,
          uid: firestoreFriend.uid,
          email: firestoreFriend.email,
          friendCode: firestoreFriend.friendCode,
          fromFirestore: true,
          nickname: nickname,
        ),
      );
      existingNames.add(key);
    }

    items.sort(
      (a, b) =>
          a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
    );
    return items;
  }

  List<TransactionModel> transactionsForFriend(String friendName) {
    final normalizedName = friendName.trim().toLowerCase();
    return transactions
        .where(
          (t) =>
              _transactionDisplayFriendName(t).trim().toLowerCase() ==
              normalizedName,
        )
        .toList();
  }

  double totalGivenForFriend(String friendName) {
    double total = 0;
    for (final t in transactionsForFriend(friendName)) {
      if (_transactionDisplayIsGiven(t)) {
        total += t.amount;
      }
    }
    return total;
  }

  double totalTakenForFriend(String friendName) {
    double total = 0;
    for (final t in transactionsForFriend(friendName)) {
      if (!_transactionDisplayIsGiven(t)) {
        total += t.amount;
      }
    }
    return total;
  }

  // Matches PersonDetailPage: netBalance = totalGiven - totalTaken.
  double getFriendBalance(String friendName) {
    return totalGivenForFriend(friendName) - totalTakenForFriend(friendName);
  }

  Future<void> deleteEntireFriend(FriendListItem friend) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text("Delete friend and all transactions?"),
          content: Text(
            "This will delete ${friend.name}, all active transactions, and deleted transaction history.",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text("Cancel"),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              child: const Text("Delete"),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      return;
    }

    if (FirebaseAuth.instance.currentUser == null) {
      await DatabaseHelper.instance.deleteTransactionsForFriend(friend.name);
      await DatabaseHelper.instance.deleteDeletedEntriesForFriend(friend.name);
    } else {
      await FirebaseDataService.deleteFriendData(
        friendName: friend.name,
        friendUid: friend.uid,
      );
    }

    await refreshDashboard();
  }

  // Quick dialog to add a transaction for a friend when clicking + or -
  Future<void> quickAddTransaction(String friendName, bool isPlus) async {
    final amountController = TextEditingController();
    final noteController = TextEditingController();
    final today = DateTime.now();
    final dateController = TextEditingController(
      text:
          "${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}",
    );

    final formKey = GlobalKey<FormState>();
    XFile? receiptImage;
    double receiptUploadProgress = 0;
    bool isSaving = false;
    late StateSetter setDialogState;

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        Future<void> handlePick(ImageSource source) async {
          const scope = 'Home.quickAddTransaction.pickReceipt';
          final picked = await _pickReceiptImage(source: source, scope: scope);
          if (picked == null) {
            return;
          }
          if (!dialogContext.mounted) {
            return;
          }
          _receiptLog(scope, 'Applying picked image to quick-add dialog.');
          receiptImage = picked;
          receiptUploadProgress = 0;
          setDialogState(() {});
        }

        Future<void> handleSave() async {
          const scope = 'Home.quickAddTransaction.save';
          _receiptLog(
            scope,
            'Save pressed. receiptSelected=${receiptImage != null}',
          );
          if (!(formKey.currentState?.validate() ?? false)) {
            _receiptLog(scope, 'Form validation failed.');
            return;
          }

          try {
            isSaving = true;
            if (dialogContext.mounted) {
              setDialogState(() {});
            }

            final currentUser = FirebaseAuth.instance.currentUser;
            _receiptLog(
              scope,
              'Current user=${currentUser?.uid ?? 'null'} existingReceipt=${receiptImage != null}',
            );

            String? firebaseId;
            String? receiptPath;
            String? receiptUrl;

            if (receiptImage != null) {
              if (currentUser == null) {
                _receiptLog(
                  scope,
                  'No signed-in user; local receipt save skipped and transaction will still be saved.',
                );
              } else {
                firebaseId = FirebaseFirestore.instance
                    .collection('users')
                    .doc(currentUser.uid)
                    .collection('transactions')
                    .doc()
                    .id;
                _receiptLog(
                  scope,
                  'Generated firebaseId=$firebaseId for local receipt save.',
                );

                final compressedImage = await _compressReceiptImage(
                  File(receiptImage!.path),
                  scope: scope,
                );
                if (compressedImage != null) {
                  final compressedFile = File(compressedImage.path);
                  receiptPath = await _saveReceiptLocally(
                    sourceFile: compressedFile,
                    firebaseId: firebaseId,
                    scope: scope,
                  );

                  // Upload to Cloudinary
                  try {
                    final uri = Uri.parse(
                      'https://api.cloudinary.com/v1_1/dxwf10vjg/image/upload',
                    );
                    final request = http.MultipartRequest('POST', uri)
                      ..fields['upload_preset'] = 'receipt_upload'
                      ..files.add(
                        await http.MultipartFile.fromPath(
                          'file',
                          compressedFile.path,
                        ),
                      );

                    final streamedResponse = await request.send();
                    final responseBody = await streamedResponse.stream
                        .bytesToString();

                    if (streamedResponse.statusCode == 200) {
                      final jsonResponse =
                          jsonDecode(responseBody) as Map<String, dynamic>;
                      receiptUrl = jsonResponse['secure_url'] as String?;
                      _receiptLog(
                        scope,
                        'Cloudinary upload succeeded: $receiptUrl',
                      );
                    } else {
                      _receiptLog(
                        scope,
                        'Cloudinary upload failed: ${streamedResponse.statusCode}',
                      );
                    }
                  } catch (cloudinaryError, cloudinarySt) {
                    _receiptLog(
                      scope,
                      'Cloudinary upload failed with exception: $cloudinaryError\n$cloudinarySt',
                    );
                  }
                } else {
                  _receiptLog(
                    scope,
                    'Compression returned null; continuing without local receipt path.',
                  );
                }
              }
            }

            final transaction = TransactionModel(
              friendName: friendName,
              amount: double.parse(amountController.text.trim()),
              note: noteController.text.trim(),
              date: dateController.text.trim(),
              iGave: isPlus,
              firebaseId: firebaseId,
              createdBy: FirebaseAuth.instance.currentUser?.uid,
              receiptPath: receiptPath,
              receiptUrl: receiptUrl,
            );

            _receiptLog(
              scope,
              'Built transaction payload: ${transaction.toFirestoreMap()}',
            );

            _receiptLog(scope, 'Writing new transaction to local DB.');
            await DatabaseHelper.instance.insertTransaction(transaction);
            _receiptLog(scope, 'Writing new transaction to Firestore.');
            await FirebaseDataService.saveTransaction(
              transaction,
              firebaseId: firebaseId,
            );

            _receiptLog(scope, 'Save finished successfully.');
            if (dialogContext.mounted) {
              Navigator.pop(dialogContext, true);
            }
          } catch (e, st) {
            _receiptLog(scope, 'Save failed: $e\n$st');
            if (dialogContext.mounted) {
              ScaffoldMessenger.of(dialogContext).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Failed to save transaction. Please try again.',
                  ),
                ),
              );
            }
          } finally {
            isSaving = false;
            if (dialogContext.mounted) {
              setDialogState(() {});
            }
          }
        }

        return StatefulBuilder(
          builder: (context, stateSetter) {
            setDialogState = stateSetter;
            return AlertDialog(
              title: Text(
                isPlus
                    ? "Give Money to $friendName"
                    : "Take Money from $friendName",
                style: TextStyle(
                  color: isPlus ? Colors.green : Colors.red,
                  fontWeight: FontWeight.bold,
                ),
              ),
              content: Form(
                key: formKey,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextFormField(
                        controller: amountController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: "Money (Amount)",
                          prefixText: "\u20B9",
                        ),
                        validator: (val) {
                          if (val == null || val.isEmpty) {
                            return "Please enter amount";
                          }
                          if (double.tryParse(val) == null) {
                            return "Please enter a valid number";
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: noteController,
                        decoration: const InputDecoration(labelText: "Note"),
                        validator: (val) {
                          if (val == null || val.isEmpty) {
                            return "Please enter a note";
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: dateController,
                              decoration: const InputDecoration(
                                labelText: "Date",
                              ),
                              validator: (val) {
                                if (val == null || val.isEmpty) {
                                  return "Please enter date";
                                }
                                return null;
                              },
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.calendar_month),
                            onPressed: () async {
                              final selected = await showDatePicker(
                                context: dialogContext,
                                initialDate: DateTime.now(),
                                firstDate: DateTime(2000),
                                lastDate: DateTime(2100),
                              );
                              if (selected != null) {
                                dateController.text =
                                    "${selected.year}-${selected.month.toString().padLeft(2, '0')}-${selected.day.toString().padLeft(2, '0')}";
                                setDialogState(() {});
                              }
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      ReceiptAttachmentSection(
                        receiptImage: receiptImage,
                        receiptUploadProgress: receiptUploadProgress,
                        onPick: (source) async {
                          await handlePick(source);
                        },
                        onClear: () {
                          _receiptLog(
                            'Home.quickAddTransaction.clearReceipt',
                            'Clearing selected receipt image.',
                          );
                          receiptImage = null;
                          receiptUploadProgress = 0;
                          setDialogState(() {});
                        },
                      ),
                      if (isSaving) ...[
                        const SizedBox(height: 12),
                        const LinearProgressIndicator(),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: isSaving
                      ? null
                      : () => Navigator.pop(dialogContext, false),
                  child: const Text("Cancel"),
                ),
                ElevatedButton(
                  onPressed: isSaving ? null : handleSave,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isPlus ? Colors.green : Colors.red,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text("Save"),
                ),
              ],
            );
          },
        );
      },
    );

    if (saved == true) {
      await refreshDashboard();
    }
  }

  String _getGreeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good Morning,';
    if (hour < 17) return 'Good Afternoon,';
    return 'Good Evening,';
  }

  String _resolveHomeUserName(Map<String, dynamic>? userData) {
    final fromDoc = (userData?['name'] as String? ?? '').trim();
    if (fromDoc.isNotEmpty) {
      AppPrefs.setUserName(fromDoc);
      return fromDoc.split(' ').first;
    }
    final fromAuth = (FirebaseAuth.instance.currentUser?.displayName ?? '')
        .trim();
    if (fromAuth.isNotEmpty) {
      AppPrefs.setUserName(fromAuth);
      return fromAuth.split(' ').first;
    }
    final cached = AppPrefs.getUserName().trim();
    if (cached.isNotEmpty) {
      return cached.split(' ').first;
    }
    return 'User';
  }

  /// Shimmer skeleton shown while the first data load is in progress
  Widget _buildShimmerList() {
    return Column(
      children: List.generate(4, (_) {
        return Shimmer.fromColors(
          baseColor: const Color(0xFFE5E7EB),
          highlightColor: const Color(0xFFF3F4F6),
          child: Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: AppColors.borderLight, width: 0.8),
            ),
            child: Row(
              children: [
                const CircleAvatar(
                  radius: 20,
                  backgroundColor: Color(0xFFE5E7EB),
                ),
                const SizedBox(width: 14),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      height: 14,
                      width: 120,
                      decoration: BoxDecoration(
                        color: const Color(0xFFE5E7EB),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      height: 11,
                      width: 80,
                      decoration: BoxDecoration(
                        color: const Color(0xFFE5E7EB),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rawFriends = visibleFriends;
    final List<FriendListItem> friends;
    if (_selectedFilter == 'Collect') {
      friends = rawFriends.where((f) => getFriendBalance(f.name) > 0).toList();
      friends.sort(
        (a, b) => getFriendBalance(b.name).compareTo(getFriendBalance(a.name)),
      );
    } else if (_selectedFilter == 'Pay') {
      friends = rawFriends.where((f) => getFriendBalance(f.name) < 0).toList();
      friends.sort(
        (a, b) => getFriendBalance(a.name).compareTo(getFriendBalance(b.name)),
      );
    } else if (_selectedFilter == 'Settled') {
      friends = rawFriends.where((f) => getFriendBalance(f.name) == 0).toList();
      friends.sort(
        (a, b) =>
            a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
      );
    } else {
      friends = rawFriends;
    }

    final currentUser = FirebaseAuth.instance.currentUser;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? AppColors.backgroundDark : AppColors.background,
      resizeToAvoidBottomInset: false,
      drawer: const AppDrawer(currentRoute: 'dashboard'),
      bottomNavigationBar: SafeArea(
        child: Container(
          height: 62,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: isDark ? AppColors.surfaceDark : Colors.white,
            borderRadius: BorderRadius.circular(32),
            border: Border.all(
              color: isDark ? AppColors.borderDark : AppColors.borderLight,
              width: 0.8,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.06),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: Icon(
                  Icons.home_rounded,
                  color: isDark ? Colors.white : AppColors.textPrimary,
                  size: 24,
                ),
                onPressed: () {},
                tooltip: 'Home',
              ),
              IconButton(
                icon: Icon(
                  Icons.receipt_long_rounded,
                  color: isDark
                      ? AppColors.textSecondaryDark
                      : AppColors.textSecondary,
                  size: 24,
                ),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const DailyExpenditureScreen(),
                    ),
                  ).then((_) => loadExpenses());
                },
                tooltip: 'Daily Expenditure',
              ),
              // Center FAB
              GestureDetector(
                onTap: () async {
                  final result = await Navigator.push(
                    context,
                    _smoothRoute((_) => const AddPage()),
                  );
                  if (result == true) {
                    await refreshDashboard();
                  }
                },
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF27272A)
                        : AppColors.darkCard,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.add_rounded,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
              ),
              IconButton(
                icon: Icon(
                  Icons.bar_chart_rounded,
                  color: isDark
                      ? AppColors.textSecondaryDark
                      : AppColors.textSecondary,
                  size: 24,
                ),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ReportsScreen()),
                  );
                },
                tooltip: 'Reports',
              ),
              // 5. User Profile Photo (replaces Profile icon)
              GestureDetector(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ProfilePage()),
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.all(6.0),
                  child: currentUser != null
                      ? StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                          stream: FirebaseFirestore.instance
                              .collection('users')
                              .doc(currentUser.uid)
                              .snapshots(),
                          builder: (context, snapshot) {
                            final data = snapshot.hasData
                                ? snapshot.data!.data()
                                : null;
                            final photoUrl =
                                data?['photoUrl'] as String? ??
                                currentUser.photoURL ??
                                '';
                            return Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: isDark
                                      ? AppColors.borderDark
                                      : AppColors.borderLight,
                                  width: 1.0,
                                ),
                              ),
                              child: CircleAvatar(
                                radius: 13,
                                backgroundColor: isDark
                                    ? AppColors.surfaceVariantDark
                                    : AppColors.surfaceVariant,
                                child: photoUrl.isNotEmpty
                                    ? ClipOval(
                                        child: CustomCachedImage(
                                          url: photoUrl,
                                          width: 26,
                                          height: 26,
                                          fit: BoxFit.cover,
                                        ),
                                      )
                                    : Icon(
                                        Icons.person_outline_rounded,
                                        color: isDark
                                            ? AppColors.textSecondaryDark
                                            : AppColors.textSecondary,
                                        size: 17,
                                      ),
                              ),
                            );
                          },
                        )
                      : Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isDark
                                  ? AppColors.borderDark
                                  : AppColors.borderLight,
                              width: 1.0,
                            ),
                          ),
                          child: CircleAvatar(
                            radius: 13,
                            backgroundColor: isDark
                                ? AppColors.surfaceVariantDark
                                : AppColors.surfaceVariant,
                            child: Icon(
                              Icons.person_outline_rounded,
                              color: isDark
                                  ? AppColors.textSecondaryDark
                                  : AppColors.textSecondary,
                              size: 17,
                            ),
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: syncBankBalance,
          color: AppColors.darkCard,
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Top App Bar
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(
                      icon: Icon(
                        Icons.settings_outlined,
                        size: 24,
                        color: isDark
                            ? AppColors.textPrimaryDark
                            : AppColors.textPrimary,
                      ),
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const SettingsScreen(),
                          ),
                        );
                      },
                      tooltip: 'Settings',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                    InkWell(
                      onTap: openAddFriendPage,
                      borderRadius: BorderRadius.circular(20),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xFF27272A)
                              : AppColors.darkCard,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.08),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.person_add_rounded,
                              size: 18,
                              color: Colors.white,
                            ),
                            SizedBox(width: 6),
                            Text(
                              'Add Friend',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),

                // Greeting & Name Header
                StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                  stream: currentUser != null
                      ? FirebaseFirestore.instance
                            .collection('users')
                            .doc(currentUser.uid)
                            .snapshots()
                      : null,
                  builder: (context, snapshot) {
                    final data = snapshot.hasData
                        ? snapshot.data!.data()
                        : null;
                    final resolvedName = _resolveHomeUserName(data);

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _getGreeting(),
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: isDark
                                ? AppColors.textSecondaryDark
                                : AppColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Text(
                              resolvedName,
                              style: TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.w800,
                                color: isDark
                                    ? AppColors.textPrimaryDark
                                    : AppColors.textPrimary,
                                letterSpacing: -0.5,
                              ),
                            ),
                            const SizedBox(width: 6),
                            const Text("👋", style: TextStyle(fontSize: 22)),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          "Keep track. Stay sorted.",
                          style: TextStyle(
                            fontSize: 13,
                            color: isDark
                                ? AppColors.textSecondaryDark
                                : AppColors.textSecondary,
                          ),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 16),

                // Collect & Pay Cards
                Row(
                  children: [
                    // Collect Card
                    Expanded(
                      child: GestureDetector(
                        onTap: () {
                          setState(() {
                            _selectedFilter = _selectedFilter == 'Collect'
                                ? 'All'
                                : 'Collect';
                          });
                        },
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: isDark
                                ? const Color(0xFF0F1B14)
                                : AppColors.collectBg,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: _selectedFilter == 'Collect'
                                  ? (isDark
                                        ? const Color(0xFF10B981)
                                        : AppColors.collectText)
                                  : (isDark
                                        ? const Color(0xFF1B3624)
                                        : AppColors.collectBg),
                              width: 1.2,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(6),
                                    decoration: BoxDecoration(
                                      color: isDark
                                          ? const Color(0xFF1A3323)
                                          : AppColors.collectBadge,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      Icons.call_received_rounded,
                                      color: isDark
                                          ? const Color(0xFF34D399)
                                          : AppColors.collectText,
                                      size: 15,
                                    ),
                                  ),
                                  const Icon(
                                    Icons.chevron_right_rounded,
                                    color: AppColors.textMuted,
                                    size: 18,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Text(
                                "Collect",
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: isDark
                                      ? const Color(0xFF34D399)
                                      : AppColors.textSecondary,
                                ),
                              ),
                              const SizedBox(height: 2),
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  "₹${formatAmount(totalToGet)}",
                                  style: TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w800,
                                    color: isDark
                                        ? Colors.white
                                        : AppColors.textPrimary,
                                    letterSpacing: -0.4,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Pay Card
                    Expanded(
                      child: GestureDetector(
                        onTap: () {
                          setState(() {
                            _selectedFilter = _selectedFilter == 'Pay'
                                ? 'All'
                                : 'Pay';
                          });
                        },
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: isDark
                                ? const Color(0xFF1F1215)
                                : AppColors.payBg,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: _selectedFilter == 'Pay'
                                  ? (isDark
                                        ? const Color(0xFFEF4444)
                                        : AppColors.payText)
                                  : (isDark
                                        ? const Color(0xFF3B1E23)
                                        : AppColors.payBg),
                              width: 1.2,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(6),
                                    decoration: BoxDecoration(
                                      color: isDark
                                          ? const Color(0xFF3B1E23)
                                          : AppColors.payBadge,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      Icons.call_made_rounded,
                                      color: isDark
                                          ? const Color(0xFFF87171)
                                          : AppColors.payText,
                                      size: 15,
                                    ),
                                  ),
                                  const Icon(
                                    Icons.chevron_right_rounded,
                                    color: AppColors.textMuted,
                                    size: 18,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Text(
                                "Pay",
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: isDark
                                      ? const Color(0xFFF87171)
                                      : AppColors.textSecondary,
                                ),
                              ),
                              const SizedBox(height: 2),
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  "₹${formatAmount(totalToGive)}",
                                  style: TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w800,
                                    color: isDark
                                        ? Colors.white
                                        : AppColors.textPrimary,
                                    letterSpacing: -0.4,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // Net Balance Hero Card (Two balanced columns: Bank Balance Left, Net Balance Right)
                GestureDetector(
                  onTap: showBankBalanceDialog,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 16,
                    ),
                    decoration: BoxDecoration(
                      color: isDark
                          ? const Color(0xFF181B22)
                          : AppColors.darkCard,
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(
                        color: isDark
                            ? AppColors.borderDark
                            : Colors.transparent,
                        width: isDark ? 0.8 : 0,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(
                            alpha: isDark ? 0.3 : 0.12,
                          ),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        // LEFT: Bank Balance
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Row(
                                children: [
                                  Text(
                                    "Bank Balance",
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      color: Colors.white70,
                                    ),
                                  ),
                                  SizedBox(width: 4),
                                  Icon(
                                    Icons.edit_outlined,
                                    size: 12,
                                    color: Colors.white54,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  "₹${formatAmount(bankBalance)}",
                                  style: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w800,
                                    color: Colors.white,
                                    letterSpacing: -0.5,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 3),
                              const Text(
                                "Tap to edit",
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Colors.white54,
                                ),
                              ),
                            ],
                          ),
                        ),
                        // CENTER: Subtle vertical divider
                        Container(
                          width: 1,
                          height: 48,
                          margin: const EdgeInsets.symmetric(horizontal: 14),
                          color: Colors.white24,
                        ),
                        // RIGHT: Net Balance
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                "Net Balance",
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: Colors.white70,
                                ),
                              ),
                              const SizedBox(height: 4),
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  "₹${formatAmount(netWorth)}",
                                  style: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w800,
                                    color: Colors.white,
                                    letterSpacing: -0.5,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                netWorth >= 0
                                    ? "You're in plus"
                                    : "You owe overall",
                                style: TextStyle(
                                  fontSize: 10,
                                  color: netWorth >= 0
                                      ? const Color(0xFF6EE7B7)
                                      : const Color(0xFFFCA5A5),
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),

                // Filter Pills (Centered)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: ['All', 'Collect', 'Pay', 'Settled'].map((filter) {
                    final isSelected = _selectedFilter == filter;
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: GestureDetector(
                        onTap: () {
                          setState(() {
                            _selectedFilter = filter;
                          });
                        },
                        child: Container(
                          height: 32,
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? (isDark ? Colors.white : AppColors.darkCard)
                                : (isDark
                                      ? AppColors.surfaceDark
                                      : Colors.white),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: isSelected
                                  ? (isDark ? Colors.white : AppColors.darkCard)
                                  : (isDark
                                        ? AppColors.borderDark
                                        : AppColors.borderLight),
                              width: 0.8,
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            filter,
                            style: TextStyle(
                              color: isSelected
                                  ? (isDark ? Colors.black : Colors.white)
                                  : (isDark
                                        ? AppColors.textSecondaryDark
                                        : AppColors.textSecondary),
                              fontWeight: isSelected
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 12),

                // Friends List as part of the continuous vertical scroll!
                if (_isInitialLoad)
                  _buildShimmerList()
                else if (friends.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 40),
                    child: Center(
                      child: Text(
                        _selectedFilter == 'All'
                            ? "No friends added yet. Tap '+' to add a transaction."
                            : "No friends found under '$_selectedFilter'.",
                        style: TextStyle(
                          color: isDark
                              ? AppColors.textSecondaryDark
                              : AppColors.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  )
                else
                  ...friends.map((friend) {
                    final friendName = friend.name;
                    final balance = getFriendBalance(friendName);
                    final String status;
                    final Color statusColor;
                    if (balance > 0) {
                      status = "Collect";
                      statusColor = AppColors.collectText;
                    } else if (balance < 0) {
                      status = "Pay";
                      statusColor = AppColors.payText;
                    } else {
                      status = "Settled";
                      statusColor = isDark
                          ? AppColors.textSecondaryDark
                          : AppColors.settledText;
                    }

                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      decoration: BoxDecoration(
                        color: isDark ? AppColors.surfaceDark : Colors.white,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: isDark
                              ? AppColors.borderDark
                              : AppColors.borderLight,
                          width: 0.8,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(
                              alpha: isDark ? 0.2 : 0.02,
                            ),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(18),
                        onTap: () async {
                          await Navigator.push(
                            context,
                            _smoothRoute(
                              (_) => PersonDetailPage(
                                friendName: friendName,
                                peerUserId: friend.uid,
                              ),
                            ),
                          );
                          await refreshDashboard();
                        },
                        onLongPress: () {
                          deleteEntireFriend(friend);
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          child: Row(
                            children: [
                              (() {
                                final cached = cachedFriendProfiles[friend.uid];
                                final photoUrl = cached?['photoUrl'] as String?;
                                if (photoUrl != null && photoUrl.isNotEmpty) {
                                  return CircleAvatar(
                                    radius: 20,
                                    backgroundColor: Colors.transparent,
                                    child: ClipOval(
                                      child: CustomCachedImage(
                                        url: photoUrl,
                                        width: 40,
                                        height: 40,
                                        fit: BoxFit.cover,
                                      ),
                                    ),
                                  );
                                }
                                final Color placeholderColor;
                                final Color placeholderBg;
                                if (balance > 0) {
                                  placeholderColor = AppColors.collectText;
                                  placeholderBg = isDark
                                      ? const Color(
                                          0xFF064E3B,
                                        ).withValues(alpha: 0.3)
                                      : AppColors.collectBg;
                                } else if (balance < 0) {
                                  placeholderColor = AppColors.payText;
                                  placeholderBg = isDark
                                      ? const Color(
                                          0xFF7F1D1D,
                                        ).withValues(alpha: 0.3)
                                      : AppColors.payBg;
                                } else {
                                  placeholderColor = isDark
                                      ? AppColors.textSecondaryDark
                                      : AppColors.textSecondary;
                                  placeholderBg = isDark
                                      ? AppColors.surfaceVariantDark
                                      : AppColors.surfaceVariant;
                                }
                                return CircleAvatar(
                                  radius: 20,
                                  backgroundColor: placeholderBg,
                                  child: Text(
                                    friend.displayName.isNotEmpty
                                        ? friend.displayName[0].toUpperCase()
                                        : '?',
                                    style: TextStyle(
                                      color: placeholderColor,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 15,
                                    ),
                                  ),
                                );
                              })(),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      friend.displayName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 15,
                                        color: isDark
                                            ? AppColors.textPrimaryDark
                                            : AppColors.textPrimary,
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    Row(
                                      children: [
                                        Text(
                                          "Net: ₹${formatAmount(balance.abs())}",
                                          style: TextStyle(
                                            color: isDark
                                                ? AppColors.textSecondaryDark
                                                : AppColors.textSecondary,
                                            fontWeight: FontWeight.w500,
                                            fontSize: 12,
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          "• $status",
                                          style: TextStyle(
                                            color: statusColor,
                                            fontWeight: FontWeight.w600,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 10),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  GlassActionButton(
                                    icon: Icons.add,
                                    color: AppColors.collectText,
                                    tooltip: "Give Money (+)",
                                    onPressed: () {
                                      quickAddTransaction(friendName, true);
                                    },
                                  ),
                                  const SizedBox(width: 8),
                                  GlassActionButton(
                                    icon: Icons.remove,
                                    color: AppColors.payText,
                                    tooltip: "Take Money (-)",
                                    onPressed: () {
                                      quickAddTransaction(friendName, false);
                                    },
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
