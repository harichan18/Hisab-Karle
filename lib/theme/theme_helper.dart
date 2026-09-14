import 'package:flutter/material.dart';
import '../core/storage/app_prefs.dart';

final ValueNotifier<ThemeMode> themeModeNotifier = ValueNotifier<ThemeMode>(
  AppPrefs.isDarkMode() ? ThemeMode.dark : ThemeMode.light,
);
