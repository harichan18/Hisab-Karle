import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class CustomCacheManager {
  static final CustomCacheManager instance = CustomCacheManager._();
  CustomCacheManager._();

  String _generateKey(String input) {
    int hash = 5381;
    for (int i = 0; i < input.length; i++) {
      hash = ((hash << 5) + hash) + input.codeUnitAt(i);
    }
    return hash.abs().toString();
  }

  Future<File?> getFile(String url) async {
    try {
      if (url.isEmpty) return null;
      final cacheDir = await getTemporaryDirectory();
      final key = _generateKey(url);
      final file = File('${cacheDir.path}/$key');
      if (await file.exists()) {
        return file;
      }
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        await file.writeAsBytes(response.bodyBytes);
        return file;
      }
    } catch (e) {
      debugPrint('Error caching image $url: $e');
    }
    return null;
  }
}
