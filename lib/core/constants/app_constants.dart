class AppConstants {
  static const String googleServerClientId =
      '614565157950-q0vb676dva84bp5eg102ca1spv6nh0os.apps.googleusercontent.com';

  // Cloudinary
  static const String cloudinaryCloudName = 'dxwf10vjg';
  static const String cloudinaryUploadPreset = 'receipt_upload';
  static const String cloudinaryUploadUrl =
      'https://api.cloudinary.com/v1_1/$cloudinaryCloudName/image/upload';

  // Firestore Collection & Document keys
  static const String usersCollection = 'users';
  static const String transactionsSubcollection = 'transactions';
  static const String deletedTransactionsSubcollection = 'deletedTransactions';
  static const String friendsCollection = 'friends';
  static const String expensesCollection = 'expenses';
  static const String settlementsSubcollection = 'settlements';
  static const String summarySubcollection = 'summary';
  static const String appConfigCollection = 'app_config';
  static const String updatesDoc = 'updates';
}
