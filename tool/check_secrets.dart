// Lightweight secret-safety scanner for Hisab Kitab.
// Run manually: dart run tool/check_secrets.dart
// Or integrate with git pre-commit hook.

import 'dart:io';

void main(List<String> args) {
  final checkAll = args.contains('--all');
  stdout.writeln(
    '🔒 Running Hisab Kitab secret scanner (${checkAll ? "all files" : "staged files"})...',
  );

  final filesToCheck = checkAll ? _getAllFiles() : _getStagedFiles();

  if (filesToCheck.isEmpty) {
    stdout.writeln('✅ No files to check.');
    exit(0);
  }

  var foundSecrets = 0;

  for (final path in filesToCheck) {
    final file = File(path);
    if (!file.existsSync()) continue;

    // Skip binary files or build/ephemeral directories
    if (_isIgnoredPath(path)) continue;

    // Check sensitive filenames
    if (_isSensitiveFilename(path)) {
      stderr.writeln('❌ [DANGER] Sensitive file detected: $path');
      foundSecrets++;
      continue;
    }

    try {
      final content = file.readAsStringSync();
      final violations = _scanContent(path, content);
      for (final v in violations) {
        stderr.writeln('❌ [DANGER] Potential secret in $path: $v');
        foundSecrets++;
      }
    } catch (_) {
      // Skip files that cannot be decoded as UTF-8 (binary)
    }
  }

  if (foundSecrets > 0) {
    stderr.writeln(
      '\n🚨 Secret scanner failed: $foundSecrets potential secret(s) found!',
    );
    stderr.writeln(
      'Please remove secrets before committing. Redact secrets or use secure configuration.',
    );
    exit(1);
  } else {
    stdout.writeln('✅ Secret scan clean! No exposed secrets detected.');
    exit(0);
  }
}

List<String> _getStagedFiles() {
  try {
    final res = Process.runSync('git', [
      'diff',
      '--cached',
      '--name-only',
      '--diff-filter=ACM',
    ]);
    if (res.exitCode != 0) return _getAllFiles();
    final out = (res.stdout as String).trim();
    if (out.isEmpty) return [];
    return out.split(RegExp(r'[\r\n]+')).where((p) => p.isNotEmpty).toList();
  } catch (_) {
    return _getAllFiles();
  }
}

List<String> _getAllFiles() {
  final files = <String>[];
  final root = Directory.current;
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    if (entity is File) {
      final relative = entity.path
          .replaceAll(root.path, '')
          .replaceAll(RegExp(r'^[\\/]'), '');
      files.add(relative);
    }
  }
  return files;
}

bool _isIgnoredPath(String path) {
  final normalized = path.replaceAll(r'\', '/');
  return normalized.contains('.git/') ||
      normalized.contains('.dart_tool/') ||
      normalized.contains('build/') ||
      normalized.contains('.idea/') ||
      normalized.contains('test/payment_screenshots/') ||
      normalized.endsWith('.png') ||
      normalized.endsWith('.jpg') ||
      normalized.endsWith('.jpeg') ||
      normalized.endsWith('.ico') ||
      normalized.endsWith('.jar');
}

bool _isSensitiveFilename(String path) {
  final name = path.split(RegExp(r'[\\/]')).last;
  if (name == '.env' ||
      (name.startsWith('.env.') && !name.endsWith('.example'))) {
    return true;
  }
  if (name.startsWith('service-account') && name.endsWith('.json')) return true;
  if (name == 'credentials.json' ||
      name == 'secrets.json' ||
      name == 'google-services-private.json') {
    return true;
  }
  if (name.endsWith('.jks') ||
      (name.endsWith('.keystore') && !name.contains('debug'))) {
    return true;
  }
  return false;
}

List<String> _scanContent(String path, String content) {
  final violations = <String>[];
  final normalizedPath = path.replaceAll(r'\', '/');
  if (normalizedPath.contains('tool/check_secrets.dart')) return violations;

  // Private keys
  if (content.contains('-----BEGIN PRIVATE KEY-----') ||
      content.contains('-----BEGIN RSA PRIVATE KEY-----') ||
      content.contains('-----BEGIN EC PRIVATE KEY-----')) {
    violations.add('Private key block detected');
  }

  // Google Service Account JSON
  if (content.contains('"type": "service_account"') &&
      content.contains('"private_key":')) {
    violations.add('Google Service Account private key JSON detected');
  }

  // Cloudinary API secret pattern
  if (RegExp(
    r'cloudinary.*api_secret\s*[:=]\s*["\x27][a-zA-Z0-9_-]{10,}["\x27]',
    caseSensitive: false,
  ).hasMatch(content)) {
    violations.add('Cloudinary API secret detected');
  }

  // AWS Access Key
  if (RegExp(r'AKIA[0-9A-Z]{16}').hasMatch(content)) {
    violations.add('AWS Access Key ID detected');
  }

  // GitHub Personal Access Token
  if (RegExp(
    r'gh[pousr]_[A-Za-z0-9_]{36}|github_pat_[A-Za-z0-9_]{82}',
  ).hasMatch(content)) {
    violations.add('GitHub Token detected');
  }

  // Note: Firebase client API key (AIzaSy...) in lib/firebase_options.dart and android/app/google-services.json
  // is expected client configuration and is intentionally not flagged.
  if (!normalizedPath.contains('firebase_options.dart') &&
      !normalizedPath.contains('google-services.json') &&
      !normalizedPath.contains('check_secrets.dart')) {
    if (RegExp(
      r'(?:secret|password|api_key|token)\s*[:=]\s*["\x27][a-zA-Z0-9_-]{20,}["\x27]',
      caseSensitive: false,
    ).hasMatch(content)) {
      violations.add('Suspicious hardcoded credential found');
    }
  }

  return violations;
}
