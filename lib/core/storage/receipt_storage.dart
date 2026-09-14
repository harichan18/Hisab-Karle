import 'dart:io';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

void receiptLog(String scope, String message) {}

Future<XFile?> pickReceiptImage({
  required ImageSource source,
  required String scope,
}) async {
  receiptLog(scope, 'Opening image picker. source=$source');
  try {
    final result = await ImagePicker().pickImage(
      source: source,
      imageQuality: 80,
    );
    if (result == null) {
      receiptLog(scope, 'Image picker returned null.');
      return null;
    }

    receiptLog(scope, 'Image selected: path=${result.path}');
    return result;
  } catch (e, st) {
    receiptLog(scope, 'Image picker failed: $e\n$st');
    rethrow;
  }
}

Future<XFile?> compressReceiptImage(File file, {required String scope}) async {
  receiptLog(scope, 'Compressing image: path=${file.path}');
  try {
    final tempDir = await getTemporaryDirectory();
    final targetPath =
        '${tempDir.path}/${DateTime.now().millisecondsSinceEpoch}.jpg';
    final compressed = await FlutterImageCompress.compressAndGetFile(
      file.path,
      targetPath,
      quality: 75,
    );
    receiptLog(
      scope,
      compressed == null
          ? 'Compression returned null.'
          : 'Compression complete: path=${compressed.path}',
    );
    return compressed;
  } catch (e, st) {
    receiptLog(scope, 'Compression failed: $e\n$st');
    rethrow;
  }
}

Future<String?> saveReceiptLocally({
  required File sourceFile,
  required String firebaseId,
  required String scope,
}) async {
  receiptLog(scope, 'Saving receipt locally for firebaseId=$firebaseId');
  try {
    final directory = await getApplicationSupportDirectory();
    final receiptsDir = Directory(p.join(directory.path, 'receipts'));
    if (!await receiptsDir.exists()) {
      await receiptsDir.create(recursive: true);
    }

    final destinationPath = p.join(receiptsDir.path, '$firebaseId.jpg');
    await sourceFile.copy(destinationPath);
    receiptLog(scope, 'Receipt saved locally at $destinationPath');
    return destinationPath;
  } catch (e, st) {
    receiptLog(scope, 'Local receipt save failed: $e\n$st');
    return null;
  }
}

Future<void> deleteLocalReceipt(
  String? receiptPath, {
  required String scope,
}) async {
  if (receiptPath == null || receiptPath.isEmpty) {
    return;
  }

  try {
    final file = File(receiptPath);
    if (await file.exists()) {
      await file.delete();
      receiptLog(scope, 'Deleted local receipt file: $receiptPath');
    }
  } catch (e, st) {
    receiptLog(scope, 'Local receipt delete failed: $e\n$st');
  }
}
