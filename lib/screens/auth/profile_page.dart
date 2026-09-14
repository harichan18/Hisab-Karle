import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../services/sync_service.dart';
import '../../services/transaction_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/image/custom_cached_image.dart';
import 'auth_gate.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  bool _isUploading = false;
  Future<DocumentSnapshot<Map<String, dynamic>>>? _profileFuture;
  bool _isSavingUpi = false;
  final TextEditingController _upiController = TextEditingController();
  bool _upiInitialized = false;
  bool _isSavingMobile = false;
  final TextEditingController _mobileController = TextEditingController();
  bool _mobileInitialized = false;

  @override
  void dispose() {
    _upiController.dispose();
    _mobileController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _profileFuture = _loadProfile();
  }

  Future<DocumentSnapshot<Map<String, dynamic>>> _loadProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw FirebaseAuthException(
        code: 'no-current-user',
        message: 'No user is currently signed in.',
      );
    }

    debugPrint('[Profile] Loading profile for authenticated user');

    final userDoc = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid);
    final snapshot = await userDoc.get();

    debugPrint('[Profile] document exists: ${snapshot.exists}');

    if (snapshot.exists) {
      return snapshot;
    }

    final friendCode = await _generateUniqueFriendCode();
    await userDoc.set({
      'uid': user.uid,
      'email': user.email ?? '',
      'name': user.displayName ?? '',
      'friendCode': friendCode,
      'upiId': '',
      'mobileNumber': '',
      'createdAt': FieldValue.serverTimestamp(),
    });

    return userDoc.get();
  }

  Future<String> _generateUniqueFriendCode() async {
    final random = Random.secure();

    for (var attempt = 0; attempt < 20; attempt++) {
      final digits = random.nextInt(1000000).toString().padLeft(6, '0');
      final code = 'HK$digits';
      final existing = await FirebaseFirestore.instance
          .collection('users')
          .where('friendCode', isEqualTo: code)
          .limit(1)
          .get();

      if (existing.docs.isEmpty) {
        return code;
      }
    }

    throw FirebaseAuthException(
      code: 'friend-code-generation-failed',
      message: 'Could not generate a unique friend code. Please try again.',
    );
  }

  Future<void> _logout(BuildContext context) async {
    FirebaseDataService.clearCachedSessionData();
    SyncService.instance.reset();
    await GoogleSignIn().signOut();
    await FirebaseAuth.instance.signOut();

    if (context.mounted) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const AuthGate()),
        (route) => false,
      );
    }
  }

  Future<void> _pickAndUploadProfilePhoto() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    // 1. Pick image from gallery
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
    );
    if (picked == null || !mounted) return;

    setState(() => _isUploading = true);

    try {
      // 2. Compress the image
      final tempDir = await getTemporaryDirectory();
      final targetPath =
          '${tempDir.path}/profile_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final compressed = await FlutterImageCompress.compressAndGetFile(
        picked.path,
        targetPath,
        quality: 75,
      );
      final fileToUpload = compressed != null
          ? File(compressed.path)
          : File(picked.path);

      // 3. Upload to Cloudinary
      final uri = Uri.parse(
        'https://api.cloudinary.com/v1_1/dxwf10vjg/image/upload',
      );
      final request = http.MultipartRequest('POST', uri)
        ..fields['upload_preset'] = 'receipt_upload'
        ..files.add(
          await http.MultipartFile.fromPath('file', fileToUpload.path),
        );

      final streamedResponse = await request.send();
      final responseBody = await streamedResponse.stream.bytesToString();

      if (streamedResponse.statusCode != 200) {
        throw Exception(
          'Cloudinary upload failed: ${streamedResponse.statusCode}',
        );
      }

      final jsonResponse = jsonDecode(responseBody) as Map<String, dynamic>;
      final secureUrl = jsonResponse['secure_url'] as String?;

      if (secureUrl == null || secureUrl.isEmpty) {
        throw Exception('Cloudinary response missing secure_url');
      }

      // 4. Update Firestore
      await FirebaseFirestore.instance.collection('users').doc(user.uid).update(
        {'photoUrl': secureUrl},
      );

      // 5. Refresh profile UI
      if (mounted) {
        setState(() {
          _isUploading = false;
          _profileFuture = _loadProfile();
        });
      }
    } catch (e) {
      debugPrint('[Profile] Photo upload failed: $e');
      if (mounted) {
        setState(() => _isUploading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to update profile photo.')),
        );
      }
    }
  }

  Future<void> _saveUpi() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final upi = _upiController.text.trim();
    if (upi.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('UPI ID cannot be empty.')));
      return;
    }
    if (!upi.contains('@')) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('UPI ID must contain "@".')));
      return;
    }

    setState(() {
      _isSavingUpi = true;
    });

    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).update(
        {'upiId': upi},
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('UPI ID updated successfully.')),
        );
      }
    } catch (e) {
      debugPrint('[Profile] UPI update failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to update UPI ID. Please try again.'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSavingUpi = false;
        });
      }
    }
  }

  Future<void> _saveMobile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final mobile = _mobileController.text.trim();
    if (mobile.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Mobile number cannot be empty.')),
      );
      return;
    }
    final digitsCount = mobile.replaceAll(RegExp(r'\D'), '').length;
    if (digitsCount < 10) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Mobile number must contain at least 10 digits.'),
        ),
      );
      return;
    }

    setState(() {
      _isSavingMobile = true;
    });

    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).update(
        {'mobileNumber': mobile},
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Mobile number updated successfully.')),
        );
      }
    } catch (e) {
      debugPrint('[Profile] Mobile update failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to update mobile number. Please try again.'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSavingMobile = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? AppColors.backgroundDark : AppColors.background,
      appBar: AppBar(
        title: Text(
          "Profile",
          style: TextStyle(
            color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(
          color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimary,
        ),
      ),
      body: SafeArea(
        bottom: true,
        child: FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          future: _profileFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }

            if (snapshot.hasError) {
              return Center(
                child: Text(
                  "Unable to load profile.",
                  style: TextStyle(
                    color: isDark
                        ? AppColors.textSecondaryDark
                        : AppColors.textSecondary,
                  ),
                ),
              );
            }

            final data = snapshot.data?.data() ?? {};
            if (!_upiInitialized) {
              _upiController.text = data['upiId'] as String? ?? '';
              _upiInitialized = true;
            }
            if (!_mobileInitialized) {
              _mobileController.text = data['mobileNumber'] as String? ?? '';
              _mobileInitialized = true;
            }
            final name = data['name'] as String? ?? '';
            final email = data['email'] as String? ?? '';
            final photoUrl = data['photoUrl'] as String?;
            final friendCode = data['friendCode'] as String? ?? '';

            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 48),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 6),
                  // Profile Photo
                  Center(
                    child: GestureDetector(
                      onTap: _isUploading ? null : _pickAndUploadProfilePhoto,
                      child: Stack(
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: isDark
                                    ? AppColors.borderDark
                                    : AppColors.borderLight,
                                width: 2,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(
                                    alpha: isDark ? 0.2 : 0.06,
                                  ),
                                  blurRadius: 10,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: CircleAvatar(
                              radius: 44,
                              backgroundColor: isDark
                                  ? AppColors.surfaceVariantDark
                                  : AppColors.surfaceVariant,
                              child: photoUrl == null || photoUrl.isEmpty
                                  ? Icon(
                                      Icons.person,
                                      size: 44,
                                      color: isDark
                                          ? AppColors.textSecondaryDark
                                          : AppColors.textSecondary,
                                    )
                                  : ClipOval(
                                      child: CustomCachedImage(
                                        url: photoUrl,
                                        width: 88,
                                        height: 88,
                                        fit: BoxFit.cover,
                                      ),
                                    ),
                            ),
                          ),
                          Positioned(
                            bottom: 0,
                            right: 0,
                            child: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: isDark
                                    ? const Color(0xFF27272A)
                                    : AppColors.darkCard,
                                shape: BoxShape.circle,
                              ),
                              child: _isUploading
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.camera_alt_rounded,
                                      size: 14,
                                      color: Colors.white,
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),

                  // Name & Email
                  Center(
                    child: Text(
                      name,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: isDark
                            ? AppColors.textPrimaryDark
                            : AppColors.textPrimary,
                        letterSpacing: -0.3,
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Center(
                    child: Text(
                      email,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark
                            ? AppColors.textSecondaryDark
                            : AppColors.textSecondary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),

                  // 1. Friend Code Card (Full-width, Copy & Share on the right)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: isDark ? AppColors.surfaceDark : Colors.white,
                      borderRadius: BorderRadius.circular(16),
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
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                "Friend Code",
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: isDark
                                      ? AppColors.textSecondaryDark
                                      : AppColors.textSecondary,
                                ),
                              ),
                              const SizedBox(height: 4),
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  friendCode,
                                  style: TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w800,
                                    color: isDark
                                        ? AppColors.textPrimaryDark
                                        : AppColors.textPrimary,
                                    letterSpacing: 1.2,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        // Copy Button
                        InkWell(
                          onTap: () {
                            Clipboard.setData(ClipboardData(text: friendCode));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Friend code copied to clipboard!',
                                ),
                              ),
                            );
                          },
                          borderRadius: BorderRadius.circular(10),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 9,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: isDark
                                    ? const Color(0xFF3A4150)
                                    : const Color(0xFFE5E7EB),
                                width: 1.0,
                              ),
                              color: isDark
                                  ? const Color(0xFF1E222A)
                                  : const Color(0xFFF3F4F6),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.copy_rounded,
                                  size: 14,
                                  color: isDark
                                      ? Colors.white
                                      : AppColors.textPrimary,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  "Copy",
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: isDark
                                        ? Colors.white
                                        : AppColors.textPrimary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Share Button
                        InkWell(
                          onTap: () {
                            SharePlus.instance.share(
                              ShareParams(
                                text:
                                    "My Hisab Kitab Friend Code is: $friendCode",
                              ),
                            );
                          },
                          borderRadius: BorderRadius.circular(10),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 9,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: isDark
                                    ? const Color(0xFF3A4150)
                                    : const Color(0xFFE5E7EB),
                                width: 1.0,
                              ),
                              color: isDark
                                  ? const Color(0xFF1E222A)
                                  : const Color(0xFFF3F4F6),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.share_rounded,
                                  size: 14,
                                  color: isDark
                                      ? Colors.white
                                      : AppColors.textPrimary,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  "Share",
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: isDark
                                        ? Colors.white
                                        : AppColors.textPrimary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // 2. UPI ID Card (Full-width, field + Save button in one row)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: isDark ? AppColors.surfaceDark : Colors.white,
                      borderRadius: BorderRadius.circular(16),
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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "UPI ID",
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: isDark
                                ? AppColors.textSecondaryDark
                                : AppColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: Container(
                                decoration: BoxDecoration(
                                  color: isDark
                                      ? AppColors.surfaceVariantDark
                                      : AppColors.surfaceVariant.withValues(
                                          alpha: 0.5,
                                        ),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: isDark
                                        ? AppColors.borderDark
                                        : AppColors.borderLight,
                                    width: 0.8,
                                  ),
                                ),
                                child: TextFormField(
                                  controller: _upiController,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: isDark
                                        ? AppColors.textPrimaryDark
                                        : AppColors.textPrimary,
                                  ),
                                  decoration: InputDecoration(
                                    hintText:
                                        "Enter UPI ID (e.g., name@okbank)",
                                    hintStyle: TextStyle(
                                      fontSize: 12,
                                      color: isDark
                                          ? AppColors.textMutedDark
                                          : AppColors.textMuted,
                                    ),
                                    prefixIcon: Icon(
                                      Icons.account_balance_wallet_outlined,
                                      size: 16,
                                      color: isDark
                                          ? AppColors.textSecondaryDark
                                          : AppColors.textSecondary,
                                    ),
                                    border: InputBorder.none,
                                    isDense: true,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 10,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            SizedBox(
                              height: 42,
                              child: ElevatedButton(
                                onPressed: _isSavingUpi ? null : _saveUpi,
                                style: ElevatedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 18,
                                  ),
                                  backgroundColor: isDark
                                      ? Colors.white
                                      : const Color(0xFF111827),
                                  foregroundColor: isDark
                                      ? Colors.black87
                                      : Colors.white,
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                child: _isSavingUpi
                                    ? SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: isDark
                                              ? Colors.black87
                                              : Colors.white,
                                        ),
                                      )
                                    : const Text(
                                        "Save",
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 13,
                                        ),
                                      ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // 3. Mobile Number Card (Full-width, field + Save button in one row)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: isDark ? AppColors.surfaceDark : Colors.white,
                      borderRadius: BorderRadius.circular(16),
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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "Mobile Number",
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: isDark
                                ? AppColors.textSecondaryDark
                                : AppColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: Container(
                                decoration: BoxDecoration(
                                  color: isDark
                                      ? AppColors.surfaceVariantDark
                                      : AppColors.surfaceVariant.withValues(
                                          alpha: 0.5,
                                        ),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: isDark
                                        ? AppColors.borderDark
                                        : AppColors.borderLight,
                                    width: 0.8,
                                  ),
                                ),
                                child: TextFormField(
                                  controller: _mobileController,
                                  keyboardType: TextInputType.phone,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: isDark
                                        ? AppColors.textPrimaryDark
                                        : AppColors.textPrimary,
                                  ),
                                  decoration: InputDecoration(
                                    hintText:
                                        "Enter mobile number (e.g., 9876543210)",
                                    hintStyle: TextStyle(
                                      fontSize: 12,
                                      color: isDark
                                          ? AppColors.textMutedDark
                                          : AppColors.textMuted,
                                    ),
                                    prefixIcon: Icon(
                                      Icons.phone_outlined,
                                      size: 16,
                                      color: isDark
                                          ? AppColors.textSecondaryDark
                                          : AppColors.textSecondary,
                                    ),
                                    border: InputBorder.none,
                                    isDense: true,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 10,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            SizedBox(
                              height: 42,
                              child: ElevatedButton(
                                onPressed: _isSavingMobile ? null : _saveMobile,
                                style: ElevatedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 18,
                                  ),
                                  backgroundColor: isDark
                                      ? Colors.white
                                      : const Color(0xFF111827),
                                  foregroundColor: isDark
                                      ? Colors.black87
                                      : Colors.white,
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                child: _isSavingMobile
                                    ? SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: isDark
                                              ? Colors.black87
                                              : Colors.white,
                                        ),
                                      )
                                    : const Text(
                                        "Save",
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 13,
                                        ),
                                      ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),

                  // 4. Logout Button (Full width, semantic red)
                  SizedBox(
                    height: 50,
                    child: ElevatedButton.icon(
                      onPressed: () => _logout(context),
                      icon: const Icon(Icons.logout_rounded, size: 20),
                      label: const Text(
                        "Logout",
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFEF4444),
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(
                    height: 20,
                  ), // Ample bottom space so it never clips with system navigation
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
