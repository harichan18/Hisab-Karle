import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class InstallPermissionService {
  static const MethodChannel _channel = MethodChannel(
    'hisab_kitab/install_permission',
  );

  static Future<bool> canRequestPackageInstalls() async {
    try {
      final bool? result = await _channel.invokeMethod<bool>(
        'canRequestPackageInstalls',
      );
      return result ?? false;
    } on PlatformException catch (e) {
      debugPrint('Error checking canRequestPackageInstalls: $e');
      return false;
    }
  }

  static Future<bool> openInstallPermissionSettings() async {
    try {
      final bool? result = await _channel.invokeMethod<bool>(
        'openInstallPermissionSettings',
      );
      return result ?? false;
    } on PlatformException catch (e) {
      debugPrint('Error opening install permission settings: $e');
      return false;
    }
  }
}
