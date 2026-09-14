import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../../core/constants/app_constants.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  bool isLoading = false;

  Future<T> _runSignInStep<T>(String label, Future<T> Function() action) async {
    debugPrint('[GoogleSignIn] START $label');
    try {
      final result = await action();
      debugPrint('[GoogleSignIn] END $label');
      return result;
    } catch (error, stackTrace) {
      debugPrint('[GoogleSignIn] STOP $label: ${_debugAuthError(error)}');
      debugPrintStack(
        label: '[GoogleSignIn] STACK $label',
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> signInWithGoogle() async {
    debugPrint('[GoogleSignIn] Button pressed');
    setState(() {
      isLoading = true;
    });

    try {
      debugPrint(
        '[GoogleSignIn] serverClientId=${AppConstants.googleServerClientId}',
      );
      final GoogleSignIn googleSignIn = GoogleSignIn(
        serverClientId: AppConstants.googleServerClientId,
      );
      final googleUser = await _runSignInStep<GoogleSignInAccount?>(
        'GoogleSignIn.signIn()',
        googleSignIn.signIn,
      );

      if (googleUser == null) {
        debugPrint('[GoogleSignIn] User cancelled sign-in');
        return;
      }

      _debugGoogleAccount(googleUser);
      await _signInToFirebaseWithGoogle(googleUser);
      debugPrint('[GoogleSignIn] Completed successfully');
    } catch (error, stackTrace) {
      debugPrint('[GoogleSignIn] Handler caught: ${_debugAuthError(error)}');
      debugPrintStack(
        label: '[GoogleSignIn] Handler stack',
        stackTrace: stackTrace,
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_friendlyAuthError(error))));
      }
    } finally {
      debugPrint('[GoogleSignIn] Handler finally');
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  Future<void> _signInToFirebaseWithGoogle(
    GoogleSignInAccount googleUser,
  ) async {
    debugPrint('[GoogleSignIn] START GoogleSignInAccount.authentication');
    final googleAuth = await googleUser.authentication;
    debugPrint(
      '[GoogleSignIn] END GoogleSignInAccount.authentication '
      'idToken=${googleAuth.idToken == null ? 'missing' : 'present'} '
      'accessToken=${googleAuth.accessToken == null ? 'missing' : 'present'}',
    );
    _debugGoogleAuthentication(googleAuth);

    if (googleAuth.idToken == null) {
      throw FirebaseAuthException(
        code: 'missing-google-id-token',
        message: 'Google did not return an ID token.',
      );
    }

    final credential = GoogleAuthProvider.credential(
      idToken: googleAuth.idToken,
    );
    final userCredential = await _runSignInStep<UserCredential>(
      'FirebaseAuth.signInWithCredential()',
      () => FirebaseAuth.instance.signInWithCredential(credential),
    );
    final user = userCredential.user;

    if (user == null) {
      throw FirebaseAuthException(
        code: 'missing-firebase-user',
        message: 'Firebase did not return a signed-in user.',
      );
    }

    final friendCode = await _runSignInStep<String>(
      'Firestore users/${user.uid} friendCode',
      () => _getOrCreateFriendCode(user.uid),
    );

    await _runSignInStep<void>('Firestore users/${user.uid} upsert', () async {
      final userDocRef = FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid);
      final existingDoc = await userDocRef.get();
      final existingPhotoUrl = existingDoc.data()?['photoUrl'] as String?;
      final existingUpiId = existingDoc.data()?['upiId'] as String?;
      final existingMobileNumber =
          existingDoc.data()?['mobileNumber'] as String?;
      final photoUrl = (existingPhotoUrl != null && existingPhotoUrl.isNotEmpty)
          ? existingPhotoUrl
          : (user.photoURL ?? googleUser.photoUrl);
      await userDocRef.set({
        'uid': user.uid,
        'name': user.displayName ?? googleUser.displayName ?? '',
        'email': user.email ?? googleUser.email,
        'photoUrl': photoUrl,
        'friendCode': friendCode,
        'upiId': existingUpiId ?? '',
        'mobileNumber': existingMobileNumber ?? '',
        'provider': 'google',
        'updatedAt': FieldValue.serverTimestamp(),
        'createdAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    });
  }

  void _debugGoogleAccount(GoogleSignInAccount googleUser) {
    debugPrint(
      '[GoogleSignIn] Account connected: '
      'hasEmail=${googleUser.email.isNotEmpty}, '
      'hasDisplayName=${(googleUser.displayName ?? "").isNotEmpty}',
    );
  }

  void _debugGoogleAuthentication(GoogleSignInAuthentication googleAuth) {
    debugPrint(
      '[GoogleSignIn] Credentials status: '
      'idToken=${googleAuth.idToken != null ? "[PRESENT]" : "missing"}, '
      'accessToken=${googleAuth.accessToken != null ? "[PRESENT]" : "missing"}',
    );
  }

  Future<String> _getOrCreateFriendCode(String uid) async {
    final userRef = FirebaseFirestore.instance.collection('users').doc(uid);
    final snapshot = await userRef.get();
    final existingCode = snapshot.data()?['friendCode'];

    if (existingCode is String && existingCode.isNotEmpty) {
      return existingCode;
    }

    return _generateUniqueFriendCode();
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

  String _debugAuthError(Object error) {
    return '${error.runtimeType}: $error';
  }

  String _friendlyAuthError(Object error) {
    final message = error.toString();
    if (message.contains('serverClientId') ||
        message.contains('clientConfigurationError')) {
      return 'Google Sign-In needs a web OAuth client in google-services.json.';
    }
    if (message.contains('canceled')) {
      return 'Google Sign-In was cancelled.';
    }
    if (error is FirebaseAuthException && error.message != null) {
      return error.message ?? 'Authentication failed. Please try again.';
    }
    return 'Google Sign-In failed. Please try again.';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: Image.asset(
                    'assets/images/logo.png',
                    width: 120,
                    height: 120,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Hisab Karle',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Sign in to keep your account connected.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 36),
              SizedBox(
                height: 54,
                child: ElevatedButton.icon(
                  onPressed: isLoading ? null : signInWithGoogle,
                  icon: isLoading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.login),
                  label: const Text('Continue with Google'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
