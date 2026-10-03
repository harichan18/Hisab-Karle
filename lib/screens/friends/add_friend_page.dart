import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../../database/database_helper.dart';
import '../../models/friend_model.dart';
import '../../services/transaction_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/image/custom_cached_image.dart';

class AddFriendPage extends StatefulWidget {
  const AddFriendPage({super.key});

  @override
  State<AddFriendPage> createState() => _AddFriendPageState();
}

class _AddFriendPageState extends State<AddFriendPage> {
  // Manual friend controllers
  final nameController = TextEditingController();
  bool isSavingLocal = false;

  // Online friend code controllers
  final friendCodeController = TextEditingController();
  DocumentSnapshot<Map<String, dynamic>>? foundUser;
  bool isSearching = false;
  bool isAdding = false;

  FirebaseFirestore get _firestore => FirebaseFirestore.instance;

  String _friendDocumentId(String uid1, String uid2) {
    final ids = [uid1, uid2]..sort();
    return '${ids[0]}_${ids[1]}';
  }

  Future<void> addLocalFriend() async {
    if (isSavingLocal) return;
    final name = nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please enter a friend name.")),
      );
      return;
    }

    if (name.toLowerCase() == 'you') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Cannot use 'You' as a friend name.")),
      );
      return;
    }

    setState(() => isSavingLocal = true);
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      final existing = await DatabaseHelper.instance.getLocalFriendByName(
        name,
        userId: uid,
      );
      if (existing != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("'$name' is already in your friends list.")),
          );
        }
        return;
      }

      final now = DateTime.now();
      final friend = LocalFriendModel(
        id: DatabaseHelper.generateLocalId(),
        name: name,
        userId: uid,
        createdAt: now,
        updatedAt: now,
      );
      await DatabaseHelper.instance.insertLocalFriend(friend);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("'$name' added to friends.")),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      debugPrint('[AddFriend] Error adding local friend: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Failed to save friend locally.")),
        );
      }
    } finally {
      if (mounted) {
        setState(() => isSavingLocal = false);
      }
    }
  }

  Future<void> searchFriend() async {
    if (isSearching) return;
    final code = friendCodeController.text.trim();
    if (code.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please enter a friend code.")),
      );
      return;
    }

    setState(() {
      isSearching = true;
      foundUser = null;
    });

    try {
      final result = await _firestore
          .collection('users')
          .where('friendCode', isEqualTo: code)
          .limit(1)
          .get();

      if (!mounted) {
        return;
      }

      setState(() {
        foundUser = result.docs.isEmpty ? null : result.docs.first;
      });

      if (result.docs.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("No user found for this friend code.")),
        );
      }
    } catch (e) {
      debugPrint('[AddFriend] Search error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Unable to search friend. Please try again."),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          isSearching = false;
        });
      }
    }
  }

  Future<bool> _friendshipExists(
    String currentUserUid,
    String friendUid,
  ) async {
    final currentUserFriends = await _firestore
        .collection('friends')
        .where('user1', isEqualTo: currentUserUid)
        .get();
    final currentUserAsSecond = await _firestore
        .collection('friends')
        .where('user2', isEqualTo: currentUserUid)
        .get();

    final firstDirection = currentUserFriends.docs.any(
      (doc) => doc.data()['user2'] == friendUid,
    );
    final secondDirection = currentUserAsSecond.docs.any(
      (doc) => doc.data()['user1'] == friendUid,
    );

    return firstDirection || secondDirection;
  }

  Future<void> addFriend() async {
    if (isAdding) return;
    final currentUser = FirebaseAuth.instance.currentUser;
    final friend = foundUser;

    if (currentUser == null || friend == null) {
      return;
    }

    final friendUid = friend.id;
    if (friendUid == currentUser.uid) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("You cannot add yourself as a friend.")),
      );
      return;
    }

    setState(() {
      isAdding = true;
    });

    try {
      final exists = await _friendshipExists(currentUser.uid, friendUid);
      if (exists) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("This friend is already added.")),
          );
        }
        return;
      }

      final friendRef = _firestore
          .collection('friends')
          .doc(_friendDocumentId(currentUser.uid, friendUid));

      await _firestore.runTransaction((transaction) async {
        final snapshot = await transaction.get(friendRef);
        if (snapshot.exists) {
          throw StateError('duplicate-friend');
        }

        transaction.set(friendRef, {
          'user1': currentUser.uid,
          'user2': friendUid,
          'createdAt': FieldValue.serverTimestamp(),
        });
      });

      final friendData = friend.data() ?? {};
      await FirebaseDataService.saveFriendProfile(
        FirestoreFriendProfile(
          uid: friendUid,
          name: friendData['name'] as String? ?? '',
          email: friendData['email'] as String? ?? '',
          friendCode: friendData['friendCode'] as String? ?? '',
        ),
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Friend added successfully.")),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      debugPrint('[AddFriend] Add error: $e');
      if (mounted) {
        final message = e is StateError && e.message == 'duplicate-friend'
            ? "This friend is already added."
            : "Unable to add friend. Please check your connection and try again.";
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    } finally {
      if (mounted) {
        setState(() {
          isAdding = false;
        });
      }
    }
  }

  @override
  void dispose() {
    nameController.dispose();
    friendCodeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final data = foundUser?.data();
    final name = data?['name'] as String? ?? '';
    final email = data?['email'] as String? ?? '';
    final friendCode = data?['friendCode'] as String? ?? '';
    final photoUrl = data?['photoUrl'] as String?;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text("Add Friend"),
          centerTitle: true,
          bottom: TabBar(
            indicatorColor: isDark ? Colors.white : AppColors.darkCard,
            labelColor: isDark ? Colors.white : AppColors.textPrimary,
            unselectedLabelColor: isDark ? Colors.white54 : Colors.grey,
            tabs: const [
              Tab(icon: Icon(Icons.person_add_outlined), text: "By Name"),
              Tab(icon: Icon(Icons.badge_outlined), text: "Friend Code"),
            ],
          ),
        ),
        body: SafeArea(
          child: TabBarView(
            children: [
              // Tab 1: By Name (Offline, Manual, Instant)
              SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: isDark
                            ? AppColors.surfaceDark
                            : AppColors.surfaceVariant.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isDark
                              ? AppColors.borderDark
                              : AppColors.borderLight,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.info_outline_rounded,
                            size: 20,
                            color: isDark
                                ? AppColors.textSecondaryDark
                                : AppColors.textSecondary,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              "Add a friend by name. Works fully offline without requiring a friend code or internet connection.",
                              style: TextStyle(
                                fontSize: 12,
                                color: isDark
                                    ? AppColors.textSecondaryDark
                                    : AppColors.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: nameController,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: "Friend Name",
                        hintText: "e.g. Rohan",
                        prefixIcon: Icon(Icons.person),
                      ),
                      onSubmitted: (_) => addLocalFriend(),
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      height: 52,
                      child: ElevatedButton.icon(
                        onPressed: isSavingLocal ? null : addLocalFriend,
                        icon: isSavingLocal
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.check_rounded),
                        label: const Text("Add Friend"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: isDark
                              ? AppColors.darkCardDark
                              : AppColors.darkCard,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Tab 2: By Friend Code (Online connected friend)
              SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: friendCodeController,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(
                        labelText: "Friend Code",
                        prefixIcon: Icon(Icons.badge),
                      ),
                      onSubmitted: (_) => searchFriend(),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      height: 52,
                      child: ElevatedButton.icon(
                        onPressed: isSearching ? null : searchFriend,
                        icon: isSearching
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.search),
                        label: const Text("Search"),
                      ),
                    ),
                    const SizedBox(height: 24),
                    if (foundUser != null)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: CircleAvatar(
                                  backgroundColor: Colors.grey[800],
                                  child: photoUrl == null || photoUrl.isEmpty
                                      ? const Icon(Icons.person)
                                      : ClipOval(
                                          child: CustomCachedImage(
                                            url: photoUrl,
                                            width: 40,
                                            height: 40,
                                            fit: BoxFit.cover,
                                          ),
                                        ),
                                ),
                                title: Text(
                                  name.isEmpty ? "No name" : name,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                subtitle: Text(email),
                              ),
                              const Divider(),
                              const Text(
                                "Friend Code",
                                style: TextStyle(color: Colors.grey),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                friendCode,
                                style: const TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.2,
                                ),
                              ),
                              const SizedBox(height: 20),
                              SizedBox(
                                height: 52,
                                child: ElevatedButton.icon(
                                  onPressed: isAdding ? null : addFriend,
                                  icon: isAdding
                                      ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(Icons.person_add),
                                  label: const Text("Add Friend"),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.green,
                                    foregroundColor: Colors.white,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
