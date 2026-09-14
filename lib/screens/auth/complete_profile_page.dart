import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../../services/transaction_service.dart';

class CompleteProfilePage extends StatefulWidget {
  final String currentUpiId;
  final String currentMobileNumber;

  const CompleteProfilePage({
    super.key,
    required this.currentUpiId,
    required this.currentMobileNumber,
  });

  @override
  State<CompleteProfilePage> createState() => _CompleteProfilePageState();
}

class _CompleteProfilePageState extends State<CompleteProfilePage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _upiController;
  late final TextEditingController _mobileController;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _upiController = TextEditingController(text: widget.currentUpiId);
    _mobileController = TextEditingController(text: widget.currentMobileNumber);
  }

  @override
  void dispose() {
    _upiController.dispose();
    _mobileController.dispose();
    super.dispose();
  }

  Future<void> _saveProfile() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    setState(() {
      _isSaving = true;
    });

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .update({
            'upiId': _upiController.text.trim(),
            'mobileNumber': _mobileController.text.trim(),
          });
    } catch (e) {
      debugPrint('[CompleteProfile] Profile update failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Failed to update profile. Please check your connection.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<void> _logout() async {
    try {
      FirebaseDataService.clearCachedSessionData();
      await GoogleSignIn().signOut();
      await FirebaseAuth.instance.signOut();
    } catch (e) {
      debugPrint('[CompleteProfile] Logout failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Logout failed. Please try again.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(
          title: const Text("Complete Profile"),
          centerTitle: true,
          automaticallyImplyLeading: false,
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 16),
                  const Icon(
                    Icons.account_circle,
                    size: 96,
                    color: Colors.amber,
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    "Profile Setup Required",
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    "To use Hisab Karle, please complete your profile by providing your UPI ID and Mobile Number. This information is required for settlements and payment reminders.",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 32),
                  const Text(
                    "UPI ID",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    key: const ValueKey('complete_upi_field'),
                    controller: _upiController,
                    decoration: const InputDecoration(
                      hintText: "Enter UPI ID (e.g., name@okbank)",
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return "UPI ID is required";
                      }
                      if (!value.contains('@')) {
                        return "UPI ID must contain '@'";
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    "Mobile Number",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    key: const ValueKey('complete_mobile_field'),
                    controller: _mobileController,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      hintText: "Enter mobile number (e.g., 9876543210)",
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return "Mobile number is required";
                      }
                      final digitsCount = value
                          .replaceAll(RegExp(r'\D'), '')
                          .length;
                      if (digitsCount < 10) {
                        return "Mobile number must contain at least 10 digits";
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 40),
                  SizedBox(
                    height: 52,
                    child: ElevatedButton(
                      key: const ValueKey('complete_save_btn'),
                      onPressed: _isSaving ? null : _saveProfile,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.amber,
                        foregroundColor: Colors.black,
                      ),
                      child: _isSaving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.black,
                              ),
                            )
                          : const Text("Save & Continue"),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 52,
                    child: OutlinedButton.icon(
                      key: const ValueKey('complete_logout_btn'),
                      onPressed: _isSaving ? null : _logout,
                      icon: const Icon(Icons.logout),
                      label: const Text("Logout"),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.redAccent,
                        side: const BorderSide(color: Colors.redAccent),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
