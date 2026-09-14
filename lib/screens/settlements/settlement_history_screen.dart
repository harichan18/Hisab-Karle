import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';

class SettlementHistoryPage extends StatelessWidget {
  final String? friendName;

  const SettlementHistoryPage({super.key, this.friendName});

  String _formatSettlementDate(DateTime dt) {
    final months = [
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
    final day = dt.day.toString().padLeft(2, '0');
    final month = months[dt.month - 1];
    final year = dt.year;
    return "$day $month $year";
  }

  String _formatSettlementTime(DateTime dt) {
    final hour24 = dt.hour;
    final minute = dt.minute.toString().padLeft(2, '0');
    final amPm = hour24 >= 12 ? 'PM' : 'AM';
    var hour12 = hour24 % 12;
    if (hour12 == 0) hour12 = 12;
    return "$hour12:$minute $amPm";
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

    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      return Scaffold(
        backgroundColor: isDark
            ? AppColors.backgroundDark
            : AppColors.background,
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
            'Settlement History',
            style: TextStyle(
              color: textColor,
              fontWeight: FontWeight.bold,
              fontSize: 18,
            ),
          ),
          centerTitle: true,
        ),
        body: Center(
          child: Text(
            'Please log in to view settlement history.',
            style: TextStyle(color: subtextColor, fontSize: 15),
          ),
        ),
      );
    }

    final query = FirebaseFirestore.instance
        .collection('users')
        .doc(currentUser.uid)
        .collection('settlements')
        .orderBy('settledAt', descending: true);

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
          friendName != null ? '$friendName Settlements' : 'Settlement History',
          style: TextStyle(
            color: textColor,
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
        ),
        centerTitle: true,
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: query.snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Text(
                'Error loading settlements: ${snapshot.error}',
                style: const TextStyle(color: AppColors.payText),
              ),
            );
          }

          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final docs = snapshot.data?.docs ?? [];
          var settlements = docs.map((doc) => doc.data()).toList();

          if (friendName != null) {
            final filterName = (friendName ?? '').trim().toLowerCase();
            settlements = settlements.where((item) {
              final itemFriend = (item['friendName'] as String? ?? '')
                  .trim()
                  .toLowerCase();
              return itemFriend == filterName;
            }).toList();
          }

          if (settlements.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.history_rounded, size: 56, color: subtextColor),
                  const SizedBox(height: 12),
                  Text(
                    "No settlements recorded yet.",
                    style: TextStyle(color: subtextColor, fontSize: 15),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: settlements.length,
            itemBuilder: (context, index) {
              final item = settlements[index];
              final friend = item['friendName'] as String? ?? 'Unknown';
              final amount = (item['amount'] as num?)?.toDouble() ?? 0.0;
              final settledBy = item['settledBy'] as String? ?? '';
              final settledAtRaw = item['settledAt'];

              DateTime settledDateTime;
              if (settledAtRaw is Timestamp) {
                settledDateTime = settledAtRaw.toDate();
              } else if (settledAtRaw is String) {
                settledDateTime =
                    DateTime.tryParse(settledAtRaw) ?? DateTime.now();
              } else {
                settledDateTime = DateTime.now();
              }

              final dateStr = _formatSettlementDate(settledDateTime);
              final timeStr = _formatSettlementTime(settledDateTime);

              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: cardBorder),
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            friend,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: textColor,
                            ),
                          ),
                        ),
                        Text(
                          "Settled \u20B9${amount.toStringAsFixed(0)}",
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: AppColors.collectText,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Icon(
                          Icons.calendar_today_outlined,
                          size: 13,
                          color: subtextColor,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          dateStr,
                          style: TextStyle(color: subtextColor, fontSize: 13),
                        ),
                        const SizedBox(width: 16),
                        Icon(
                          Icons.access_time_rounded,
                          size: 13,
                          color: subtextColor,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          timeStr,
                          style: TextStyle(color: subtextColor, fontSize: 13),
                        ),
                      ],
                    ),
                    if (settledBy.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: variantBg,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          "Settled by $settledBy",
                          style: TextStyle(
                            color: subtextColor,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
