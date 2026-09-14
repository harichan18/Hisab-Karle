import 'dart:convert';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import '../../core/constants/app_constants.dart';
import '../../core/network/cloudinary_client.dart';
import '../../core/storage/receipt_storage.dart';
import '../../database/database_helper.dart';
import '../../models/transaction_model.dart';
import '../../services/transaction_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/image/receipt_attachment_section.dart';
import '../share_payment_screen.dart';

class AddPage extends StatefulWidget {
  final TransactionModel? transaction;

  const AddPage({super.key, this.transaction});

  @override
  State<AddPage> createState() => _AddPageState();
}

class _AddPageState extends State<AddPage> {
  final friendController = TextEditingController();
  final amountController = TextEditingController();
  final noteController = TextEditingController();
  final dateController = TextEditingController();
  bool iGave = true;
  XFile? receiptImage;
  double receiptUploadProgress = 0;

  String? existingReceiptPath;
  String? existingReceiptUrl;
  bool isReceiptRemoved = false;
  bool _isSaving = false;

  String formatDate(DateTime date) {
    return "${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}";
  }

  @override
  void initState() {
    super.initState();
    if (widget.transaction != null) {
      friendController.text = widget.transaction!.friendName;
      amountController.text = widget.transaction!.amount.toString();
      noteController.text = widget.transaction!.note;
      dateController.text = widget.transaction!.date;
      iGave = widget.transaction!.iGave;
      existingReceiptPath = widget.transaction!.receiptPath;
      existingReceiptUrl = widget.transaction!.receiptUrl;
    } else {
      dateController.text = formatDate(DateTime.now());
    }
  }

  Future<void> pickDate() async {
    final currentDate =
        DateTime.tryParse(dateController.text) ?? DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: currentDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );

    if (selected != null) {
      setState(() {
        dateController.text = formatDate(selected);
      });
    }
  }

  Future<void> saveTransaction() async {
    const scope = 'AddPage.saveTransaction';
    if (_isSaving) return;

    final friendName = friendController.text.trim();
    if (friendName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a friend name.')),
      );
      return;
    }

    final rawAmount = amountController.text.trim();
    final parsedAmount = double.tryParse(rawAmount);
    if (parsedAmount == null ||
        parsedAmount <= 0 ||
        parsedAmount.isNaN ||
        parsedAmount.isInfinite) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid positive amount.')),
      );
      return;
    }
    if (parsedAmount > 100000000) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Amount is too large (maximum ₹10,00,00,000).'),
        ),
      );
      return;
    }

    setState(() => _isSaving = true);
    receiptLog(
      scope,
      'Save pressed. receiptSelected=${receiptImage != null} isReceiptRemoved=$isReceiptRemoved',
    );
    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      receiptLog(
        scope,
        'Current user=${currentUser?.uid ?? 'null'} existingFirebaseId=${widget.transaction?.firebaseId}',
      );

      String? firebaseId = widget.transaction?.firebaseId;
      String? receiptPath = widget.transaction?.receiptPath;
      String? receiptUrl = widget.transaction?.receiptUrl;

      if (isReceiptRemoved || receiptImage != null) {
        if (existingReceiptPath != null) {
          receiptLog(
            scope,
            'Deleting existing local receipt file: $existingReceiptPath',
          );
          await deleteLocalReceipt(existingReceiptPath, scope: scope);
        }
        if (existingReceiptUrl != null) {
          receiptLog(
            scope,
            'Deleting existing Cloudinary image: $existingReceiptUrl',
          );
          await deleteFromCloudinary(existingReceiptUrl!, scope: scope);
        }
        if (isReceiptRemoved && receiptImage == null) {
          receiptPath = null;
          receiptUrl = null;
        }
      }

      if (receiptImage != null) {
        if (currentUser == null) {
          receiptLog(
            scope,
            'No signed-in user; local receipt save will be skipped and transaction will still be saved.',
          );
        } else {
          firebaseId ??= FirebaseFirestore.instance
              .collection('users')
              .doc(currentUser.uid)
              .collection('transactions')
              .doc()
              .id;
          receiptLog(
            scope,
            'Using firebaseId=$firebaseId for local receipt save.',
          );

          final compressedImage = await compressReceiptImage(
            File(receiptImage!.path),
            scope: scope,
          );
          if (compressedImage != null) {
            final compressed = File(compressedImage.path);
            receiptPath = await saveReceiptLocally(
              sourceFile: compressed,
              firebaseId: firebaseId,
              scope: scope,
            );

            // Upload to Cloudinary
            try {
              final uri = Uri.parse(AppConstants.cloudinaryUploadUrl);
              final request = http.MultipartRequest('POST', uri)
                ..fields['upload_preset'] = AppConstants.cloudinaryUploadPreset
                ..files.add(
                  await http.MultipartFile.fromPath('file', compressed.path),
                );

              final streamedResponse = await request.send();
              final responseBody = await streamedResponse.stream
                  .bytesToString();

              if (streamedResponse.statusCode == 200) {
                final jsonResponse =
                    jsonDecode(responseBody) as Map<String, dynamic>;
                receiptUrl = jsonResponse['secure_url'] as String?;
                receiptLog(scope, 'Cloudinary upload succeeded: $receiptUrl');
              } else {
                receiptLog(
                  scope,
                  'Cloudinary upload failed: ${streamedResponse.statusCode}',
                );
              }
            } catch (cloudinaryError, cloudinarySt) {
              receiptLog(
                scope,
                'Cloudinary upload failed with exception: $cloudinaryError\n$cloudinarySt',
              );
            }
          } else {
            receiptLog(
              scope,
              'Compression returned null; continuing without local receipt path.',
            );
          }
        }
      }

      final transaction = TransactionModel(
        id: widget.transaction?.id,
        firebaseId: widget.transaction?.firebaseId ?? firebaseId,
        peerUserId: widget.transaction?.peerUserId,
        createdBy: widget.transaction?.createdBy ?? currentUser?.uid,
        receiptUrl: receiptUrl,
        receiptPath: receiptPath,
        friendName: friendName,
        amount: parsedAmount,
        note: noteController.text.trim(),
        date: dateController.text.trim(),
        iGave: iGave,
      );

      receiptLog(
        scope,
        'Built transaction payload: ${transaction.toFirestoreMap()}',
      );

      if (widget.transaction == null) {
        receiptLog(scope, 'Writing new transaction to local DB.');
        firebaseId ??= FirebaseFirestore.instance.collection('users').doc().id;
        final localTx = transaction.copyWith(
          firebaseId: firebaseId,
          createdBy: currentUser?.uid,
          syncStatus: currentUser != null
              ? SyncStatus.pending
              : SyncStatus.synced,
        );
        final localId = await DatabaseHelper.instance.insertTransaction(
          localTx,
        );

        if (currentUser != null) {
          receiptLog(scope, 'Writing new transaction to Firestore.');
          try {
            await FirebaseDataService.saveTransaction(
              localTx.copyWith(id: localId),
              firebaseId: firebaseId,
            );
            await DatabaseHelper.instance.updateTransactionSyncStatus(
              localId,
              SyncStatus.synced,
              firebaseId: firebaseId,
            );
          } catch (cloudErr) {
            receiptLog(
              scope,
              'Cloud save queued/failed: $cloudErr; safely stored in local SQLite.',
            );
          }
        }
      } else {
        if (transaction.id != null) {
          receiptLog(scope, 'Updating transaction in local DB.');
          final updatedTx = transaction.copyWith(
            syncStatus: currentUser != null
                ? SyncStatus.pending
                : SyncStatus.synced,
          );
          await DatabaseHelper.instance.updateTransaction(updatedTx);

          if (currentUser != null) {
            receiptLog(scope, 'Writing updated transaction to Firestore.');
            try {
              await FirebaseDataService.saveTransaction(
                updatedTx,
                firebaseId: transaction.firebaseId,
              );
              await DatabaseHelper.instance.updateTransactionSyncStatus(
                transaction.id!,
                SyncStatus.synced,
              );
            } catch (cloudErr) {
              receiptLog(
                scope,
                'Cloud update queued/failed: $cloudErr; safely stored in local SQLite.',
              );
            }
          }
        }
      }

      receiptLog(scope, 'Save finished successfully.');
      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (e, st) {
      receiptLog(scope, 'Save failed: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to save transaction. Please try again.'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  void dispose() {
    friendController.dispose();
    amountController.dispose();
    noteController.dispose();
    dateController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final hintColor = isDark ? AppColors.textMutedDark : AppColors.textMuted;
    final iconColor = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    final cardBg = isDark ? AppColors.surfaceDark : Colors.white;
    final cardBorder = isDark ? AppColors.borderDark : AppColors.borderLight;

    return Scaffold(
      backgroundColor: isDark ? AppColors.backgroundDark : AppColors.background,
      appBar: AppBar(
        title: Text(
          widget.transaction == null ? "Add Transaction" : "Edit Transaction",
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
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.transaction == null) ...[
              InkWell(
                onTap: () async {
                  final picker = ImagePicker();
                  final picked = await picker.pickImage(
                    source: ImageSource.gallery,
                  );
                  if (picked != null && context.mounted) {
                    final result = await Navigator.push<bool>(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            SharePaymentScreen(imagePath: picked.path),
                      ),
                    );
                    if (result == true && context.mounted) {
                      Navigator.pop(context, true);
                    }
                  }
                },
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF1E222A)
                        : const Color(0xFFF3F4F6),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: cardBorder, width: 0.8),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xFF272D37)
                              : Colors.white,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          Icons.document_scanner_rounded,
                          size: 20,
                          color: isDark
                              ? Colors.white
                              : const Color(0xFF111827),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "Auto-Extract from Payment Screenshot",
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: textColor,
                              ),
                            ),
                            Text(
                              "Scan GPay, PhonePe, Paytm screenshot & split",
                              style: TextStyle(fontSize: 11, color: hintColor),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.arrow_forward_ios_rounded,
                        size: 14,
                        color: hintColor,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            TextField(
              controller: friendController,
              style: TextStyle(color: textColor, fontWeight: FontWeight.w500),
              decoration: InputDecoration(
                hintText: "Friend Name",
                hintStyle: TextStyle(color: hintColor),
                prefixIcon: Icon(
                  Icons.person_outline_rounded,
                  size: 20,
                  color: iconColor,
                ),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: amountController,
              keyboardType: TextInputType.number,
              style: TextStyle(
                color: textColor,
                fontWeight: FontWeight.w700,
                fontSize: 16,
              ),
              decoration: InputDecoration(
                hintText: "Amount",
                hintStyle: TextStyle(color: hintColor),
                prefixIcon: Icon(
                  Icons.currency_rupee_rounded,
                  size: 20,
                  color: iconColor,
                ),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: noteController,
              style: TextStyle(color: textColor, fontWeight: FontWeight.w500),
              decoration: InputDecoration(
                hintText: "Note",
                hintStyle: TextStyle(color: hintColor),
                prefixIcon: Icon(
                  Icons.description_outlined,
                  size: 20,
                  color: iconColor,
                ),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: dateController,
              readOnly: true,
              onTap: pickDate,
              style: TextStyle(color: textColor, fontWeight: FontWeight.w500),
              decoration: InputDecoration(
                hintText: "Date",
                hintStyle: TextStyle(color: hintColor),
                prefixIcon: Icon(
                  Icons.calendar_today_outlined,
                  size: 18,
                  color: iconColor,
                ),
                suffixIcon: Icon(
                  Icons.calendar_month_rounded,
                  size: 20,
                  color: iconColor,
                ),
              ),
            ),
            const SizedBox(height: 20),
            ReceiptAttachmentSection(
              receiptImage: receiptImage,
              receiptUploadProgress: receiptUploadProgress,
              existingReceiptPath: existingReceiptPath,
              existingReceiptUrl: existingReceiptUrl,
              isReceiptRemoved: isReceiptRemoved,
              onRemoveExisting: () {
                receiptLog('AddPage.pickReceipt', 'Existing receipt removed.');
                setState(() {
                  isReceiptRemoved = true;
                });
              },
              onPick: (source) async {
                final result = await pickReceiptImage(
                  source: source,
                  scope: 'AddPage.pickReceipt',
                );
                if (result == null || !mounted) {
                  return;
                }
                setState(() {
                  receiptImage = result;
                  isReceiptRemoved = true;
                });
              },
              onClear: () {
                receiptLog('AddPage.pickReceipt', 'Receipt cleared.');
                setState(() {
                  receiptImage = null;
                  receiptUploadProgress = 0;
                });
              },
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: cardBorder, width: 0.8),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: iGave
                          ? (isDark
                                ? AppColors.collectBgDark
                                : AppColors.collectBg)
                          : (isDark ? AppColors.payBgDark : AppColors.payBg),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      iGave
                          ? Icons.arrow_upward_rounded
                          : Icons.arrow_downward_rounded,
                      color: iGave ? AppColors.collectText : AppColors.payText,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      iGave ? "I Gave Money" : "I Took Money",
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: textColor,
                      ),
                    ),
                  ),
                  Switch.adaptive(
                    value: iGave,
                    activeTrackColor: isDark
                        ? AppColors.collectText
                        : AppColors.darkCard,
                    activeThumbColor: Colors.white,
                    inactiveTrackColor: isDark
                        ? AppColors.surfaceVariantDark
                        : AppColors.borderLight,
                    onChanged: (value) {
                      setState(() {
                        iGave = value;
                      });
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),
            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton(
                onPressed: _isSaving ? null : saveTransaction,
                style: ElevatedButton.styleFrom(
                  backgroundColor: isDark ? Colors.white : AppColors.darkCard,
                  foregroundColor: isDark ? AppColors.darkCard : Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                  elevation: 0,
                ),
                child: _isSaving
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: isDark ? AppColors.darkCard : Colors.white,
                        ),
                      )
                    : Text(
                        widget.transaction == null
                            ? "Save Transaction"
                            : "Update Transaction",
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: isDark ? AppColors.darkCard : Colors.white,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}
