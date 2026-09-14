import 'dart:io';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';
import '../../core/storage/custom_cache_manager.dart';
import '../../core/utils/transaction_display_helper.dart';
import '../../database/database_helper.dart';
import '../../models/transaction_model.dart';
import '../../services/transaction_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/image/custom_cached_image.dart';
import 'add_transaction_screen.dart';

class TransactionDetailPage extends StatelessWidget {
  const TransactionDetailPage({super.key, required this.transaction});

  final TransactionModel transaction;

  Widget? _buildReceiptWidget(BuildContext context) {
    final receiptPath = transaction.receiptPath;
    final receiptUrl = transaction.receiptUrl;

    if (receiptPath != null && receiptPath.isNotEmpty) {
      final file = File(receiptPath);
      if (file.existsSync()) {
        return GestureDetector(
          onTap: () {
            showDialog(
              context: context,
              builder: (_) {
                return Dialog(
                  insetPadding: const EdgeInsets.all(16),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: PhotoView(
                      imageProvider: FileImage(file),
                      backgroundDecoration: const BoxDecoration(
                        color: Colors.black,
                      ),
                    ),
                  ),
                );
              },
            );
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Image.file(file, fit: BoxFit.cover, width: double.infinity),
          ),
        );
      }
    }

    if (receiptUrl != null && receiptUrl.isNotEmpty) {
      return GestureDetector(
        onTap: () {
          showDialog(
            context: context,
            builder: (_) {
              return Dialog(
                insetPadding: const EdgeInsets.all(16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: FutureBuilder<File?>(
                    future: CustomCacheManager.instance.getFile(receiptUrl),
                    builder: (context, snapshot) {
                      final file = snapshot.data;
                      return PhotoView(
                        imageProvider: file != null
                            ? FileImage(file)
                            : NetworkImage(receiptUrl) as ImageProvider,
                        backgroundDecoration: const BoxDecoration(
                          color: Colors.black,
                        ),
                      );
                    },
                  ),
                ),
              );
            },
          );
        },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: CustomCachedImage(
            url: receiptUrl,
            fit: BoxFit.cover,
            width: double.infinity,
            errorBuilder: (_, _, _) => const SizedBox(
              height: 180,
              child: Center(
                child: Icon(Icons.broken_image, size: 48, color: Colors.grey),
              ),
            ),
          ),
        ),
      );
    }

    return null;
  }

  Widget _detailRow(BuildContext context, String label, String value) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: TextStyle(
                color: isDark
                    ? AppColors.textSecondaryDark
                    : AppColors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: isDark
                    ? AppColors.textPrimaryDark
                    : AppColors.textPrimary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final cardBg = isDark ? AppColors.surfaceDark : Colors.white;
    final cardBorder = isDark ? AppColors.borderDark : AppColors.borderLight;
    final dividerCol = isDark ? AppColors.dividerDark : AppColors.divider;

    final isGiven = transactionDisplayIsGiven(transaction);
    final amountColor = isGiven ? AppColors.collectText : AppColors.payText;
    final statusBg = isGiven
        ? (isDark ? AppColors.collectBgDark : AppColors.collectBg)
        : (isDark ? AppColors.payBgDark : AppColors.payBg);
    final receiptWidget = _buildReceiptWidget(context);
    final statusText = isGiven ? 'Collect' : 'Pay';
    final displayFriendName = transactionDisplayFriendName(transaction);
    final currentUser = FirebaseAuth.instance.currentUser?.uid;
    final isCreator = transaction.createdBy == currentUser;

    return Scaffold(
      backgroundColor: isDark ? AppColors.backgroundDark : AppColors.background,
      appBar: AppBar(
        title: Text(
          'Transaction Details',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 18,
            color: textColor,
          ),
        ),
        centerTitle: true,
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back_ios_new_rounded,
            color: textColor,
            size: 20,
          ),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          if (isCreator) ...[
            IconButton(
              icon: Icon(Icons.edit_outlined, color: textColor),
              tooltip: 'Edit',
              onPressed: () async {
                final result = await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => AddPage(transaction: transaction),
                  ),
                );
                if (result == true && context.mounted) {
                  Navigator.pop(context, true);
                }
              },
            ),
            IconButton(
              icon: const Icon(
                Icons.delete_outline_rounded,
                color: AppColors.payText,
              ),
              tooltip: 'Delete',
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                    title: const Text('Delete Transaction?'),
                    content: const Text(
                      'Are you sure you want to permanently delete this transaction?',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext, false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext, true),
                        child: const Text(
                          'Delete',
                          style: TextStyle(color: Colors.red),
                        ),
                      ),
                    ],
                  ),
                );
                if (confirmed == true && context.mounted) {
                  if (transaction.firebaseId != null) {
                    await FirebaseDataService.deleteTransaction(transaction);
                  }
                  if (transaction.id != null) {
                    await DatabaseHelper.instance.deleteTransaction(
                      transaction.id!,
                    );
                  }
                  if (context.mounted) {
                    Navigator.pop(context, true);
                  }
                }
              },
            ),
          ],
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: cardBorder, width: 0.8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.02),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    displayFriendName,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: textColor,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: statusBg,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'Status: $statusText',
                      style: TextStyle(
                        color: amountColor,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '₹${transaction.amount.toStringAsFixed(0)}',
                    style: TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w800,
                      color: amountColor,
                      letterSpacing: -0.5,
                    ),
                  ),
                ],
              ),
            ),
            if (receiptWidget != null) ...[
              const SizedBox(height: 16),
              receiptWidget,
              const SizedBox(height: 16),
            ],
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: cardBorder, width: 0.8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.02),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Transaction Info',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: textColor,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _detailRow(context, 'Date', transaction.date),
                  Divider(color: dividerCol, height: 16),
                  _detailRow(
                    context,
                    'Note',
                    transaction.note.isEmpty ? '-' : transaction.note,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
