import 'package:shared_preferences/shared_preferences.dart';

class AppPrefs {
  static SharedPreferences? _prefs;

  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // Dark mode persistence
  static bool isDarkMode() => _prefs?.getBool('is_dark_mode') ?? false;
  static Future<void> setDarkMode(bool value) async {
    await _prefs?.setBool('is_dark_mode', value);
  }

  // Bank balance
  static double getBankBalance() => _prefs?.getDouble('bank_balance') ?? 0.0;
  static Future<void> setBankBalance(double value) async {
    await _prefs?.setDouble('bank_balance', value);
  }

  // Profile completion
  static bool isProfileComplete() =>
      _prefs?.getBool('profile_complete') ?? false;
  static Future<void> setProfileComplete(bool value) async {
    await _prefs?.setBool('profile_complete', value);
  }

  // Cached User Name
  static String getUserName() => _prefs?.getString('cached_user_name') ?? '';
  static Future<void> setUserName(String value) async {
    if (value.trim().isNotEmpty) {
      await _prefs?.setString('cached_user_name', value.trim());
    }
  }
}
