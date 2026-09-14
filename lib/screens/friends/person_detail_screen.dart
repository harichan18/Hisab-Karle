import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/services.dart';
import '../../core/utils/transaction_display_helper.dart';
import '../../database/database_helper.dart';
import '../../models/transaction_model.dart';
import '../../services/transaction_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/image/custom_cached_image.dart';
import '../settlements/settlement_history_screen.dart';
import '../transactions/add_transaction_screen.dart';
import '../transactions/transaction_detail_screen.dart';

String _transactionDisplayFriendName(TransactionModel transaction) =>
    transactionDisplayFriendName(transaction);

bool _transactionDisplayIsGiven(TransactionModel transaction) =>
    transactionDisplayIsGiven(transaction);

class _TransactionGroup {
  final String dateLabel;
  final List<TransactionModel> transactions;
  _TransactionGroup(this.dateLabel, this.transactions);
}

class PersonDetailPage extends StatefulWidget {
  final String friendName;
  final String? peerUserId;

  const PersonDetailPage({
    super.key,
    required this.friendName,
    this.peerUserId,
  });

  @override
  State<PersonDetailPage> createState() => _PersonDetailPageState();
}

class _PersonDetailPageState extends State<PersonDetailPage> {
  List<TransactionModel> personTransactions = [];
  List<DeletedEntryModel> deletedTransactions = [];
  bool isLoading = true;
  bool _isClearingAccount = false;

  List<_TransactionGroup> _groupTransactions(
    List<TransactionModel> transactions,
  ) {
    final List<_TransactionGroup> groups = [];
    String? currentLabel;
    List<TransactionModel> currentGroupList = [];

    for (final t in transactions) {
      final label = _formatDateString(t.date);
      if (currentLabel == null) {
        currentLabel = label;
        currentGroupList.add(t);
      } else if (currentLabel == label) {
        currentGroupList.add(t);
      } else {
        groups.add(_TransactionGroup(currentLabel, currentGroupList));
        currentLabel = label;
        currentGroupList = [t];
      }
    }
    if (currentLabel != null) {
      groups.add(_TransactionGroup(currentLabel, currentGroupList));
    }
    return groups;
  }

  StreamSubscription<List<TransactionModel>>? _transactionsSubscription;
  StreamSubscription<List<DeletedEntryModel>>? _deletedSubscription;
  Future<Map<String, dynamic>?>? _friendProfileFuture;
  String? _cachedPhotoUrl;
  String? _cachedUpiId;
  String? _cachedMobileNumber;
  String? _localNickname;

  @override
  void initState() {
    super.initState();
    _loadNickname();
    if (FirebaseAuth.instance.currentUser == null) {
      loadPersonTransactions();
    } else {
      startRealtimeSync();
      _loadCachedProfile();
      _friendProfileFuture = _fetchFriendProfile();
    }
  }

  Future<void> _loadCachedProfile() async {
    final cached = await DatabaseHelper.instance.getCachedFriendByName(
      widget.friendName,
    );
    if (cached != null && mounted) {
      setState(() {
        _cachedPhotoUrl = cached['photoUrl'] as String?;
        _cachedUpiId = cached['upiId'] as String?;
        _cachedMobileNumber = cached['mobileNumber'] as String?;
      });
    }
  }

  Future<void> _loadNickname() async {
    final nick = await DatabaseHelper.instance.getFriendNickname(
      widget.friendName,
    );
    if (mounted) {
      setState(() {
        _localNickname = nick;
      });
    }
  }

  String get _displayName {
    if (_localNickname != null && _localNickname!.trim().isNotEmpty) {
      return _localNickname!.trim();
    }
    return widget.friendName;
  }

  Future<void> _renameFriend() async {
    final controller = TextEditingController(text: _localNickname ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Rename Friend'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Original Name: ${widget.friendName}',
                style: const TextStyle(color: Colors.grey, fontSize: 14),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                decoration: const InputDecoration(
                  labelText: 'Nickname',
                  hintText: 'Enter local nickname',
                  border: OutlineInputBorder(),
                ),
                autofocus: true,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );

    if (result != null) {
      await DatabaseHelper.instance.saveFriendNickname(
        widget.friendName,
        result,
      );
      await _loadNickname();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.isEmpty
                  ? 'Nickname cleared.'
                  : 'Nickname updated to "$result".',
            ),
          ),
        );
      }
    }
  }

  Future<Map<String, dynamic>?> _fetchFriendProfile() async {
    try {
      String? uid = widget.peerUserId;
      if (uid == null || uid.isEmpty) {
        uid = await FirebaseDataService.resolvePeerUserIdByFriendName(
          widget.friendName,
        );
      }
      if (uid == null || uid.isEmpty) {
        return null;
      }
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      final data = userDoc.data();
      if (data != null) {
        final name = data['name'] as String? ?? widget.friendName;
        final email = data['email'] as String? ?? '';
        final friendCode = data['friendCode'] as String? ?? '';
        final photoUrl = data['photoUrl'] as String? ?? '';
        final upiId = data['upiId'] as String? ?? '';
        final mobileNumber = data['mobileNumber'] as String? ?? '';

        await DatabaseHelper.instance.saveCachedFriend(
          friendUid: uid,
          friendName: name,
          email: email,
          friendCode: friendCode,
          photoUrl: photoUrl,
          upiId: upiId,
          mobileNumber: mobileNumber,
        );
      }
      return data;
    } catch (e) {
      debugPrint('Error fetching friend profile: $e');
      return null;
    }
  }

  String _normalizePhoneNumber(String rawPhone) {
    String digits = rawPhone.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 10) {
      return '91$digits';
    }
    return digits;
  }

  @override
  void dispose() {
    _transactionsSubscription?.cancel();
    _deletedSubscription?.cancel();
    super.dispose();
  }

  void startRealtimeSync() {
    _transactionsSubscription = FirebaseDataService.transactionsStream().listen(
      (all) {
        if (!mounted) {
          return;
        }
        setState(() {
          personTransactions = all
              .where(
                (t) =>
                    _transactionDisplayFriendName(t).trim().toLowerCase() ==
                    widget.friendName.trim().toLowerCase(),
              )
              .toList();
          isLoading = false;
        });
      },
    );

    _deletedSubscription =
        FirebaseDataService.deletedEntriesStream(widget.friendName).listen((
          deleted,
        ) {
          if (!mounted) {
            return;
          }
          setState(() {
            deletedTransactions = deleted;
            isLoading = false;
          });
        });
  }

  Future<void> loadPersonTransactions() async {
    setState(() {
      isLoading = true;
    });
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final all = await DatabaseHelper.instance.getTransactions(userId: uid);
    final deleted = await DatabaseHelper.instance.getDeletedEntries(
      DatabaseHelper.personIdForName(widget.friendName),
      userId: uid,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      personTransactions = all
          .where(
            (t) =>
                _transactionDisplayFriendName(t).trim().toLowerCase() ==
                widget.friendName.trim().toLowerCase(),
          )
          .toList()
          .reversed
          .toList();
      deletedTransactions = deleted;
      isLoading = false;
    });
  }

  double get totalGiven {
    double total = 0;
    for (var t in personTransactions) {
      if (_transactionDisplayIsGiven(t)) {
        total += t.amount;
      }
    }
    return total;
  }

  double get totalTaken {
    double total = 0;
    for (var t in personTransactions) {
      if (!_transactionDisplayIsGiven(t)) {
        total += t.amount;
      }
    }
    return total;
  }

  double get netBalance {
    return totalGiven - totalTaken;
  }

  Future<void> _executeSettleAccount() async {
    if (_isClearingAccount) return;
    setState(() => _isClearingAccount = true);
    try {
      final double amountToSettle = netBalance.abs();
      if (FirebaseAuth.instance.currentUser != null && amountToSettle != 0) {
        try {
          await FirebaseDataService.recordSettlement(
            friendName: widget.friendName,
            amount: amountToSettle,
          );
        } catch (e) {
          debugPrint('Error recording settlement: $e');
        }
      }

      final transactionsToProcess = List<TransactionModel>.from(
        personTransactions,
      );

      final uid = FirebaseAuth.instance.currentUser?.uid;
      for (final t in transactionsToProcess) {
        if (t.firebaseId != null) {
          await FirebaseDataService.clearTransaction(t);
        }
        if (t.id != null) {
          await DatabaseHelper.instance.clearEntry(t.id!, userId: uid);
        }
      }

      if (FirebaseAuth.instance.currentUser == null) {
        await loadPersonTransactions();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Account cleared successfully.')),
        );
      }
    } finally {
      if (mounted) setState(() => _isClearingAccount = false);
    }
  }

  Future<void> _clearAccount() async {
    if (_isClearingAccount) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Account?'),
        content: const Text(
          'This will move all active transactions with this friend to Deleted Transactions.\n'
          'You can restore them later from Deleted Transactions.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear Account'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    await _executeSettleAccount();
  }

  void _showTransactionOptions(BuildContext context, TransactionModel t) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    final isCreator = t.createdBy == currentUid;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final borderCol = isDark ? AppColors.borderDark : AppColors.borderLight;

    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? AppColors.surfaceDark : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 10, bottom: 6),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: borderCol,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              if (isCreator)
                ListTile(
                  leading: Icon(Icons.edit_outlined, color: textColor),
                  title: Text(
                    "Edit",
                    style: TextStyle(
                      color: textColor,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  onTap: () async {
                    Navigator.pop(context);
                    final result = await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => AddPage(transaction: t),
                      ),
                    );
                    if (result == true &&
                        FirebaseAuth.instance.currentUser == null) {
                      loadPersonTransactions();
                    }
                  },
                ),
              ListTile(
                leading: Icon(
                  Icons.cleaning_services_outlined,
                  color: textColor,
                ),
                title: Text(
                  "Clear Transaction",
                  style: TextStyle(
                    color: textColor,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                onTap: () async {
                  Navigator.pop(context);
                  if (t.firebaseId != null) {
                    await FirebaseDataService.clearTransaction(t);
                  }
                  if (t.id != null) {
                    await DatabaseHelper.instance.clearEntry(
                      t.id!,
                      userId: FirebaseAuth.instance.currentUser?.uid,
                    );
                  }
                  if (FirebaseAuth.instance.currentUser == null) {
                    loadPersonTransactions();
                  }
                },
              ),
              if (isCreator)
                ListTile(
                  leading: const Icon(
                    Icons.delete_outline,
                    color: AppColors.payText,
                  ),
                  title: const Text(
                    "Delete",
                    style: TextStyle(
                      color: AppColors.payText,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  onTap: () async {
                    Navigator.pop(context);
                    if (t.firebaseId != null) {
                      await FirebaseDataService.deleteTransaction(t);
                    }
                    if (t.id != null) {
                      await DatabaseHelper.instance.deleteTransaction(t.id!);
                    }
                    if (FirebaseAuth.instance.currentUser == null) {
                      loadPersonTransactions();
                    }
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  void _showDeletedTransactionOptions(
    BuildContext context,
    DeletedEntryModel entry,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final borderCol = isDark ? AppColors.borderDark : AppColors.borderLight;

    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? AppColors.surfaceDark : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 10, bottom: 6),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: borderCol,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              ListTile(
                leading: Icon(Icons.restore, color: textColor),
                title: Text(
                  "Restore Transaction",
                  style: TextStyle(
                    color: textColor,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                onTap: () async {
                  Navigator.pop(context);
                  if (entry.firebaseId != null) {
                    await FirebaseDataService.restoreDeletedEntry(entry);
                  }
                  if (entry.id != null) {
                    await DatabaseHelper.instance.restoreDeletedEntry(
                      entry.id!,
                    );
                  }
                  if (FirebaseAuth.instance.currentUser == null) {
                    loadPersonTransactions();
                  }
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.delete_forever_outlined,
                  color: AppColors.payText,
                ),
                title: const Text(
                  "Permanently Delete",
                  style: TextStyle(
                    color: AppColors.payText,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                onTap: () async {
                  Navigator.pop(context);
                  if (entry.firebaseId != null) {
                    await FirebaseDataService.permanentlyDeleteEntry(entry);
                  }
                  if (entry.id != null) {
                    await DatabaseHelper.instance.permanentlyDeleteEntry(
                      entry.id!,
                    );
                  }
                  if (FirebaseAuth.instance.currentUser == null) {
                    loadPersonTransactions();
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }

  String _formatDateString(String rawDate) {
    final regex = RegExp(r'^(\d{4})-(\d{2})-(\d{2})(.*)$');
    final match = regex.firstMatch(rawDate.trim());
    if (match == null) {
      return rawDate;
    }
    final monthStr = match.group(2)!;
    final dayStr = match.group(3)!;
    var suffix = match.group(4)!.trim();

    final monthVal = int.tryParse(monthStr);
    if (monthVal == null || monthVal < 1 || monthVal > 12) {
      return rawDate;
    }

    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final formattedDate = "$dayStr ${months[monthVal - 1]}";

    if (suffix.isNotEmpty) {
      while (suffix.startsWith('-') ||
          suffix.startsWith(':') ||
          suffix.startsWith(' ')) {
        suffix = suffix.substring(1).trim();
      }
      if (suffix.startsWith('(') && suffix.endsWith(')')) {
        if (suffix.length > 2) {
          final inside = suffix.substring(1, suffix.length - 1).trim();
          if (inside.isNotEmpty) {
            final capitalized = inside[0].toUpperCase() + inside.substring(1);
            return "$formattedDate ($capitalized)";
          }
        }
        return "$formattedDate $suffix";
      } else {
        final capitalized = suffix[0].toUpperCase() + suffix.substring(1);
        return "$formattedDate ($capitalized)";
      }
    }

    return formattedDate;
  }

  Widget _buildDateHeader(String formattedDate) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final subtextColor = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    final borderCol = isDark ? AppColors.borderDark : AppColors.borderLight;
    final variantBg = isDark
        ? AppColors.surfaceVariantDark
        : AppColors.surfaceVariant;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: [
          Expanded(
            child: Divider(color: borderCol, thickness: 1, endIndent: 12),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: variantBg,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              formattedDate,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: subtextColor,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(child: Divider(color: borderCol, thickness: 1, indent: 12)),
        ],
      ),
    );
  }

  Widget _buildTransactionsTable(List<TransactionModel> transactions) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final subtextColor = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    final cardBg = isDark ? AppColors.surfaceDark : Colors.white;
    final cardBorder = isDark ? AppColors.borderDark : AppColors.borderLight;
    final variantBg = isDark
        ? AppColors.surfaceVariantDark
        : AppColors.surfaceVariant;

    return Column(
      children: transactions.map((t) {
        final isGiven = _transactionDisplayIsGiven(t);
        final moneyColor = isGiven
            ? (isDark ? const Color(0xFF34D399) : AppColors.collectText)
            : (isDark ? const Color(0xFFF87171) : AppColors.payText);
        final badgeBg = isDark
            ? const Color(0xFF1E222A)
            : (isGiven ? AppColors.collectBg : AppColors.payBg);
        final badgeBorder = isDark
            ? const Color(0xFF2D323E)
            : (isGiven ? AppColors.collectBadge : AppColors.payBadge);
        final iconColor = isDark
            ? (isGiven ? const Color(0xFF34D399) : const Color(0xFFF87171))
            : (isGiven ? AppColors.collectText : AppColors.payText);
        final iconData = isGiven
            ? Icons.arrow_downward_rounded
            : Icons.arrow_upward_rounded;

        final hasLocal =
            t.receiptPath != null &&
            t.receiptPath!.isNotEmpty &&
            File(t.receiptPath!).existsSync();
        final hasRemote = t.receiptUrl != null && t.receiptUrl!.isNotEmpty;

        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: cardBorder),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.02),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () async {
                final result = await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => TransactionDetailPage(transaction: t),
                  ),
                );
                if (result == true &&
                    FirebaseAuth.instance.currentUser == null &&
                    context.mounted) {
                  loadPersonTransactions();
                }
              },
              onLongPress: () => _showTransactionOptions(context, t),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: badgeBg,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: badgeBorder, width: 0.8),
                      ),
                      child: Center(
                        child: Icon(iconData, color: iconColor, size: 18),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            t.note.isNotEmpty
                                ? t.note
                                : (isGiven ? "Given" : "Taken"),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: textColor,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              Text(
                                _formatDateString(t.date),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: subtextColor,
                                ),
                              ),
                              if (hasLocal || hasRemote) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 1.5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: variantBg,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.receipt_outlined,
                                        size: 11,
                                        color: subtextColor,
                                      ),
                                      const SizedBox(width: 2),
                                      Text(
                                        "Bill",
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: subtextColor,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          "${isGiven ? '+' : '-'}₹${t.amount.toStringAsFixed(0)}",
                          style: TextStyle(
                            color: moneyColor,
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          isGiven ? "Given" : "Taken",
                          style: TextStyle(
                            color: moneyColor.withValues(alpha: 0.8),
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildDeletedTransactionsSection() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final subtextColor = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    final cardBg = isDark ? AppColors.surfaceDark : Colors.white;
    final cardBorder = isDark ? AppColors.borderDark : AppColors.borderLight;
    final variantBg = isDark
        ? AppColors.surfaceVariantDark
        : AppColors.surfaceVariant;

    return Container(
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cardBorder),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          title: Row(
            children: [
              Icon(Icons.history_rounded, size: 20, color: subtextColor),
              const SizedBox(width: 8),
              Text(
                "Cleared Transactions",
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: textColor,
                ),
              ),
              if (deletedTransactions.isNotEmpty) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: variantBg,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    "${deletedTransactions.length}",
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: subtextColor,
                    ),
                  ),
                ),
              ],
            ],
          ),
          children: [
            if (deletedTransactions.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Center(
                  child: Text(
                    "No cleared transactions.",
                    style: TextStyle(color: subtextColor, fontSize: 13),
                  ),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Column(
                  children: deletedTransactions.map((entry) {
                    final moneyColor = entry.isGiven
                        ? AppColors.collectText
                        : AppColors.payText;
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onLongPress: () {
                        _showDeletedTransactionOptions(context, entry);
                      },
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: variantBg,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    entry.note.isNotEmpty
                                        ? entry.note
                                        : (entry.isGiven ? "Given" : "Taken"),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: textColor,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    "Date: ${_formatDateString(entry.date)} • Cleared: ${_formatDateString(entry.clearedDate)}",
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: subtextColor,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              "₹${entry.amount.toStringAsFixed(0)}",
                              style: TextStyle(
                                color: moneyColor,
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final subtextColor = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    final cardBg = isDark ? AppColors.surfaceDark : Colors.white;
    final cardBorder = isDark ? AppColors.borderDark : AppColors.borderLight;
    final variantBg = isDark
        ? AppColors.surfaceVariantDark
        : AppColors.surfaceVariant;

    return Scaffold(
      backgroundColor: isDark ? AppColors.backgroundDark : AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back_ios_new_rounded,
            color: textColor,
            size: 20,
          ),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          widget.friendName,
          style: TextStyle(
            color: textColor,
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
        ),
        centerTitle: true,
        actions: [
          PopupMenuButton<String>(
            color: cardBg,
            elevation: 4,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: cardBorder),
            ),
            onSelected: (value) {
              if (value == 'rename_friend') {
                _renameFriend();
              } else if (value == 'clear_account') {
                _clearAccount();
              } else if (value == 'settlement_history') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        SettlementHistoryPage(friendName: widget.friendName),
                  ),
                );
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem<String>(
                value: 'rename_friend',
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Icon(Icons.edit_outlined, color: textColor, size: 20),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Rename Friend',
                            style: TextStyle(
                              color: textColor,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Change display name',
                            style: TextStyle(color: subtextColor, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right, color: subtextColor, size: 18),
                  ],
                ),
              ),
              const PopupMenuDivider(height: 1),
              PopupMenuItem<String>(
                value: 'clear_account',
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.cleaning_services_outlined,
                      color: textColor,
                      size: 20,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Clear Account',
                            style: TextStyle(
                              color: textColor,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Set balance to zero',
                            style: TextStyle(color: subtextColor, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right, color: subtextColor, size: 18),
                  ],
                ),
              ),
              const PopupMenuDivider(height: 1),
              PopupMenuItem<String>(
                value: 'settlement_history',
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Icon(Icons.history_rounded, color: textColor, size: 20),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Settlement History',
                            style: TextStyle(
                              color: textColor,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'View past settlements',
                            style: TextStyle(color: subtextColor, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right, color: subtextColor, size: 18),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : personTransactions.isEmpty && deletedTransactions.isEmpty
          ? Center(
              child: Text(
                "No transactions found.",
                style: TextStyle(fontSize: 16, color: subtextColor),
              ),
            )
          : FutureBuilder<Map<String, dynamic>?>(
              future: _friendProfileFuture,
              builder: (context, snapshot) {
                final data =
                    (snapshot.connectionState == ConnectionState.done &&
                        snapshot.hasData)
                    ? snapshot.data
                    : null;

                final photoUrl =
                    data?['photoUrl'] as String? ?? _cachedPhotoUrl;
                final upiId = data?['upiId'] as String? ?? _cachedUpiId;
                final mobileNumber =
                    data?['mobileNumber'] as String? ?? _cachedMobileNumber;

                final grouped = _groupTransactions(personTransactions);

                return CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                        child: Column(
                          children: [
                            // Profile Avatar and Name (Screen 2 style)
                            CircleAvatar(
                              radius: 36,
                              backgroundColor: variantBg,
                              child: (photoUrl != null && photoUrl.isNotEmpty)
                                  ? ClipOval(
                                      child: CustomCachedImage(
                                        url: photoUrl,
                                        width: 72,
                                        height: 72,
                                        fit: BoxFit.cover,
                                      ),
                                    )
                                  : Text(
                                      _displayName.isNotEmpty
                                          ? _displayName[0].toUpperCase()
                                          : '?',
                                      style: TextStyle(
                                        fontSize: 26,
                                        fontWeight: FontWeight.bold,
                                        color: textColor,
                                      ),
                                    ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _displayName,
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: textColor,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              (mobileNumber != null && mobileNumber.isNotEmpty)
                                  ? mobileNumber
                                  : "Active Friend",
                              style: TextStyle(
                                fontSize: 13,
                                color: subtextColor,
                              ),
                            ),
                            const SizedBox(height: 16),
                            // Summary Card for this Person (Screen 2 style)
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(18),
                              decoration: BoxDecoration(
                                color: cardBg,
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: cardBorder),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(
                                      alpha: isDark ? 0.2 : 0.02,
                                    ),
                                    blurRadius: 8,
                                    offset: const Offset(0, 3),
                                  ),
                                ],
                              ),
                              child: Column(
                                children: [
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            "Given (+)",
                                            style: TextStyle(
                                              color: subtextColor,
                                              fontSize: 13,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            "\u20B9${totalGiven.toStringAsFixed(0)}",
                                            style: const TextStyle(
                                              color: AppColors.collectText,
                                              fontSize: 20,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ],
                                      ),
                                      Container(
                                        height: 34,
                                        width: 1,
                                        color: cardBorder,
                                      ),
                                      Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.end,
                                        children: [
                                          Text(
                                            "Taken (-)",
                                            style: TextStyle(
                                              color: subtextColor,
                                              fontSize: 13,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            "\u20B9${totalTaken.toStringAsFixed(0)}",
                                            style: const TextStyle(
                                              color: AppColors.payText,
                                              fontSize: 20,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                  Divider(
                                    height: 24,
                                    color: isDark
                                        ? AppColors.dividerDark
                                        : AppColors.borderLight,
                                  ),
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        "Net Balance",
                                        style: TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.bold,
                                          color: textColor,
                                        ),
                                      ),
                                      Text(
                                        "${netBalance >= 0 ? '' : '-'}\u20B9${netBalance.abs().toStringAsFixed(0)}",
                                        style: TextStyle(
                                          color: netBalance >= 0
                                              ? AppColors.collectText
                                              : AppColors.payText,
                                          fontSize: 20,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 14),
                            // Action Buttons Row (Screen 2: Send Reminder, Settle Up, Share)
                            Row(
                              children: [
                                // Send Reminder (Black pill button)
                                Expanded(
                                  flex: 5,
                                  child: ElevatedButton.icon(
                                    onPressed: () async {
                                      if (netBalance <= 0) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              "No dues pending to collect from this friend.",
                                            ),
                                            duration: Duration(seconds: 2),
                                          ),
                                        );
                                        return;
                                      }

                                      if (mobileNumber == null ||
                                          mobileNumber.trim().isEmpty) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              "Friend has not added a mobile number.",
                                            ),
                                          ),
                                        );
                                        return;
                                      }

                                      final normalizedMobile =
                                          _normalizePhoneNumber(
                                            mobileNumber.trim(),
                                          );
                                      if (normalizedMobile.isEmpty) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              "Friend has not added a mobile number.",
                                            ),
                                          ),
                                        );
                                        return;
                                      }

                                      final amountText = netBalance
                                          .toStringAsFixed(0);
                                      final message =
                                          'Hi $_displayName,\n\n'
                                          'According to Hisab Kitab, you currently owe ₹$amountText.\n\n'
                                          'You can settle it whenever convenient.\n\n'
                                          'Thanks 🙂';

                                      final whatsappUri = Uri.parse(
                                        'https://wa.me/$normalizedMobile?text=${Uri.encodeComponent(message)}',
                                      );

                                      try {
                                        final launched = await launchUrl(
                                          whatsappUri,
                                          mode: LaunchMode.externalApplication,
                                        );
                                        if (!launched && context.mounted) {
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            const SnackBar(
                                              content: Text(
                                                'Could not launch WhatsApp.',
                                              ),
                                            ),
                                          );
                                        }
                                      } catch (e) {
                                        debugPrint(
                                          '[WhatsApp] Launch failed: $e',
                                        );
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            const SnackBar(
                                              content: Text(
                                                'Could not launch WhatsApp. Please check if WhatsApp is installed.',
                                              ),
                                            ),
                                          );
                                        }
                                      }
                                    },
                                    icon: const Icon(
                                      Icons.notifications_active_outlined,
                                      size: 16,
                                    ),
                                    label: const Text(
                                      "Reminder",
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 13,
                                      ),
                                    ),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: isDark
                                          ? Colors.white
                                          : AppColors.darkCard,
                                      foregroundColor: isDark
                                          ? AppColors.darkCard
                                          : Colors.white,
                                      elevation: 0,
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 12,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(24),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                // Settle Up (Light pill button)
                                Expanded(
                                  flex: 5,
                                  child: OutlinedButton.icon(
                                    onPressed: _clearAccount,
                                    icon: const Icon(
                                      Icons.check_circle_outline_rounded,
                                      size: 16,
                                    ),
                                    label: const Text(
                                      "Settle Up",
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 13,
                                      ),
                                    ),
                                    style: OutlinedButton.styleFrom(
                                      backgroundColor: cardBg,
                                      foregroundColor: textColor,
                                      side: BorderSide(color: cardBorder),
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 12,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(24),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                // Share (Light pill button)
                                InkWell(
                                  onTap: () async {
                                    final summaryText =
                                        'Hisab summary with $_displayName:\n'
                                        'Given: ₹${totalGiven.toStringAsFixed(0)}\n'
                                        'Taken: ₹${totalTaken.toStringAsFixed(0)}\n'
                                        'Net Balance: ${netBalance >= 0 ? '' : '-'}₹${netBalance.abs().toStringAsFixed(0)}';
                                    await Clipboard.setData(
                                      ClipboardData(text: summaryText),
                                    );
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            'Hisab summary copied to clipboard!',
                                          ),
                                          duration: Duration(seconds: 2),
                                        ),
                                      );
                                    }
                                  },
                                  borderRadius: BorderRadius.circular(24),
                                  child: Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: cardBg,
                                      shape: BoxShape.circle,
                                      border: Border.all(color: cardBorder),
                                    ),
                                    child: Icon(
                                      Icons.share_outlined,
                                      size: 16,
                                      color: textColor,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            if (netBalance < 0) ...[
                              const SizedBox(height: 12),
                              (() {
                                final hasUpi =
                                    upiId != null && upiId.trim().isNotEmpty;
                                final upiBg = isDark
                                    ? const Color(0xFF181B22)
                                    : variantBg;
                                final upiBorder = isDark
                                    ? const Color(0xFF262B35)
                                    : AppColors.borderLight;
                                return Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 12,
                                  ),
                                  decoration: BoxDecoration(
                                    color: upiBg,
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: upiBorder,
                                      width: 0.8,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              hasUpi
                                                  ? "UPI: $upiId"
                                                  : "Friend has not set UPI ID",
                                              style: TextStyle(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w600,
                                                color: textColor,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            if (hasUpi)
                                              GestureDetector(
                                                onTap: () async {
                                                  await Clipboard.setData(
                                                    ClipboardData(
                                                      text: upiId.trim(),
                                                    ),
                                                  );
                                                  if (context.mounted) {
                                                    ScaffoldMessenger.of(
                                                      context,
                                                    ).showSnackBar(
                                                      const SnackBar(
                                                        content: Text(
                                                          'UPI ID copied to clipboard',
                                                        ),
                                                        duration: Duration(
                                                          seconds: 2,
                                                        ),
                                                      ),
                                                    );
                                                  }
                                                },
                                                child: Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                        top: 2,
                                                      ),
                                                  child: Text(
                                                    "Tap to copy UPI ID",
                                                    style: TextStyle(
                                                      fontSize: 11,
                                                      color: subtextColor,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      ElevatedButton.icon(
                                        onPressed: () async {
                                          const channel = MethodChannel(
                                            'hisab_kitab/upi_launcher',
                                          );
                                          try {
                                            final bool? success = await channel
                                                .invokeMethod<bool>(
                                                  'launchUpiPayment',
                                                );
                                            if (success != true &&
                                                context.mounted) {
                                              ScaffoldMessenger.of(
                                                context,
                                              ).showSnackBar(
                                                const SnackBar(
                                                  content: Text(
                                                    'No UPI app available.',
                                                  ),
                                                ),
                                              );
                                            }
                                          } catch (e) {
                                            debugPrint(
                                              '[UPI] Launch failed: $e',
                                            );
                                            if (context.mounted) {
                                              ScaffoldMessenger.of(
                                                context,
                                              ).showSnackBar(
                                                const SnackBar(
                                                  content: Text(
                                                    'Could not open UPI app. Please try again.',
                                                  ),
                                                ),
                                              );
                                            }
                                          }
                                        },
                                        icon: const Icon(
                                          Icons.payment,
                                          size: 16,
                                        ),
                                        label: const Text(
                                          "Pay UPI",
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: isDark
                                              ? const Color(0xFF2D323E)
                                              : AppColors.darkCard,
                                          foregroundColor: Colors.white,
                                          elevation: 0,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 14,
                                            vertical: 10,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              })(),
                            ],
                            const SizedBox(height: 18),
                            Row(
                              children: [
                                Text(
                                  "Transaction History",
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: textColor,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                          ],
                        ),
                      ),
                    ),
                    if (personTransactions.isEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 20,
                          ),
                          child: Center(
                            child: Text(
                              "No active transactions found.",
                              style: TextStyle(
                                fontSize: 15,
                                color: subtextColor,
                              ),
                            ),
                          ),
                        ),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        sliver: SliverList(
                          delegate: SliverChildBuilderDelegate((
                            context,
                            index,
                          ) {
                            final group = grouped[index];
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _buildDateHeader(group.dateLabel),
                                const SizedBox(height: 4),
                                _buildTransactionsTable(group.transactions),
                                const SizedBox(height: 8),
                              ],
                            );
                          }, childCount: grouped.length),
                        ),
                      ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                        child: _buildDeletedTransactionsSection(),
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}
