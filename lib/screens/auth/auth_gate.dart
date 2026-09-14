import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../../core/storage/app_prefs.dart';
import '../../services/transaction_service.dart';
import 'complete_profile_page.dart';
import 'login_page.dart';
import 'splash_screen.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  // Validates session in the background — does NOT block UI
  static void _validateSessionBackground(User user) {
    Future<void>(() async {
      try {
        await user.reload();
        final stillValid = FirebaseAuth.instance.currentUser != null;
        if (!stillValid) {
          FirebaseDataService.clearCachedSessionData();
          await GoogleSignIn().signOut();
          await FirebaseAuth.instance.signOut();
        }
      } on FirebaseAuthException catch (e) {
        const invalidCodes = {
          'user-not-found',
          'user-disabled',
          'invalid-user-token',
          'user-token-expired',
        };
        if (invalidCodes.contains(e.code)) {
          FirebaseDataService.clearCachedSessionData();
          await GoogleSignIn().signOut();
          await FirebaseAuth.instance.signOut();
        }
      } catch (e) {
        // Non-fatal network error during background reload: keep user signed in offline
        debugPrint('[AuthGate] Background session reload skipped: $e');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        // While stream is initialising show the branded splash — no spinner
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SplashScreen();
        }

        if (snapshot.hasData) {
          // Kick off background session check without blocking UI
          _validateSessionBackground(snapshot.data!);
          return ProfileCompletionGate(child: const SplashScreen());
        }

        return const LoginPage();
      },
    );
  }
}

class ProfileCompletionGate extends StatelessWidget {
  final Widget child;
  const ProfileCompletionGate({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const LoginPage();
    }

    // If cache says profile is complete, show child immediately — no Firestore wait
    if (AppPrefs.isProfileComplete()) {
      // Still listen in background to catch profile becoming incomplete
      _listenProfileCompletionBackground(user.uid);
      return child;
    }

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .snapshots(),
      builder: (context, snapshot) {
        // Show child (SplashScreen) while waiting — no blocking spinner
        if (snapshot.connectionState == ConnectionState.waiting) {
          return child;
        }

        if (snapshot.hasError) {
          // On error, fall through to show child rather than blocking
          return child;
        }

        final data = snapshot.data?.data();
        if (data == null) {
          return child;
        }

        final upiId = data['upiId'] as String? ?? '';
        final mobileNumber = data['mobileNumber'] as String? ?? '';

        final isUpiValid = upiId.contains('@');
        final digitsCount = mobileNumber.replaceAll(RegExp(r'\D'), '').length;
        final isMobileValid = digitsCount >= 10;

        final isComplete =
            upiId.isNotEmpty &&
            mobileNumber.isNotEmpty &&
            isUpiValid &&
            isMobileValid;

        // Update cache for next launch
        AppPrefs.setProfileComplete(isComplete);

        if (!isComplete) {
          return CompleteProfilePage(
            currentUpiId: upiId,
            currentMobileNumber: mobileNumber,
          );
        }

        return child;
      },
    );
  }

  static void _listenProfileCompletionBackground(String uid) {
    FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .snapshots()
        .take(1)
        .listen((snap) {
          final data = snap.data();
          if (data == null) return;
          final upiId = data['upiId'] as String? ?? '';
          final mobile = data['mobileNumber'] as String? ?? '';
          final isComplete =
              upiId.contains('@') &&
              mobile.replaceAll(RegExp(r'\D'), '').length >= 10;
          AppPrefs.setProfileComplete(isComplete);
        });
  }
}
