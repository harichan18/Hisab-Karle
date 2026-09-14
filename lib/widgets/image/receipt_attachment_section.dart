import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../theme/app_theme.dart';
import 'custom_cached_image.dart';

class ReceiptAttachmentSection extends StatelessWidget {
  const ReceiptAttachmentSection({
    super.key,
    required this.receiptImage,
    required this.receiptUploadProgress,
    required this.onPick,
    required this.onClear,
    this.existingReceiptPath,
    this.existingReceiptUrl,
    this.isReceiptRemoved = false,
    this.onRemoveExisting,
  });

  final XFile? receiptImage;
  final double receiptUploadProgress;
  final void Function(ImageSource source) onPick;
  final VoidCallback onClear;
  final String? existingReceiptPath;
  final String? existingReceiptUrl;
  final bool isReceiptRemoved;
  final VoidCallback? onRemoveExisting;

  Widget _buildPickButtons(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final btnBg = isDark ? AppColors.surfaceDark : Colors.white;
    final btnBorder = isDark ? AppColors.borderDark : AppColors.borderLight;
    final btnColor = isDark ? AppColors.textPrimaryDark : AppColors.textPrimary;

    return Row(
      children: [
        Expanded(
          child: Container(
            height: 46,
            decoration: BoxDecoration(
              color: btnBg,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: btnBorder, width: 1),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(24),
              onTap: () => onPick(ImageSource.camera),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.camera_alt_rounded, size: 18, color: btnColor),
                  const SizedBox(width: 8),
                  Text(
                    "Camera",
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: btnColor,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Container(
            height: 46,
            decoration: BoxDecoration(
              color: btnBg,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: btnBorder, width: 1),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(24),
              onTap: () => onPick(ImageSource.gallery),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.photo_library_rounded, size: 18, color: btnColor),
                  const SizedBox(width: 8),
                  Text(
                    "Gallery",
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: btnColor,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPreview() {
    if (receiptImage != null) {
      return SizedBox(
        height: 140,
        width: double.infinity,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Image.file(File(receiptImage!.path), fit: BoxFit.cover),
        ),
      );
    } else {
      final hasLocal =
          existingReceiptPath != null &&
          existingReceiptPath!.isNotEmpty &&
          File(existingReceiptPath!).existsSync();
      return SizedBox(
        height: 140,
        width: double.infinity,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: hasLocal
              ? Image.file(File(existingReceiptPath!), fit: BoxFit.cover)
              : CustomCachedImage(
                  url: existingReceiptUrl!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const Center(
                    child: Icon(
                      Icons.broken_image,
                      size: 40,
                      color: Colors.grey,
                    ),
                  ),
                ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;

    final hasReceipt =
        receiptImage != null ||
        (((existingReceiptPath != null && existingReceiptPath!.isNotEmpty) ||
                (existingReceiptUrl != null &&
                    existingReceiptUrl!.isNotEmpty)) &&
            !isReceiptRemoved);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "Receipt",
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            color: textColor,
          ),
        ),
        const SizedBox(height: 8),
        if (hasReceipt) ...[
          _buildPreview(),
          const SizedBox(height: 12),
          _buildPickButtons(context),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const ValueKey('remove_receipt_btn'),
            onPressed: () {
              if (receiptImage != null) {
                onClear();
              } else {
                onRemoveExisting?.call();
              }
            },
            icon: const Icon(
              Icons.delete_outline_rounded,
              color: AppColors.payText,
              size: 18,
            ),
            label: const Text(
              "Remove Receipt",
              style: TextStyle(
                color: AppColors.payText,
                fontWeight: FontWeight.w600,
              ),
            ),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: AppColors.payText),
              minimumSize: const Size(double.infinity, 44),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
        ] else ...[
          _buildPickButtons(context),
        ],
        if (receiptUploadProgress > 0 && receiptUploadProgress < 1)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: LinearProgressIndicator(
              value: receiptUploadProgress,
              color: isDark ? Colors.white : AppColors.darkCard,
              backgroundColor: isDark
                  ? AppColors.surfaceVariantDark
                  : AppColors.borderLight,
            ),
          ),
      ],
    );
  }
}
