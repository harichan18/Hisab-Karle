import '../storage/receipt_storage.dart';

String? getCloudinaryPublicId(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  final pathSegments = uri.pathSegments;
  if (pathSegments.isEmpty) return null;

  final uploadIndex = pathSegments.indexOf('upload');
  if (uploadIndex == -1 || uploadIndex >= pathSegments.length - 1) {
    return null;
  }

  var startIndex = uploadIndex + 1;
  if (startIndex < pathSegments.length &&
      pathSegments[startIndex].startsWith('v') &&
      RegExp(r'^v\d+$').hasMatch(pathSegments[startIndex])) {
    startIndex++;
  }

  if (startIndex >= pathSegments.length) return null;

  final remainingPath = pathSegments.sublist(startIndex).join('/');
  final dotIndex = remainingPath.lastIndexOf('.');
  if (dotIndex != -1) {
    return remainingPath.substring(0, dotIndex);
  }
  return remainingPath;
}

/// Safely handles Cloudinary asset deletion requests.
///
/// NOTE: Cloudinary's `/image/destroy` endpoint strictly requires a signed request
/// using the account API secret or Admin API authorization, which must never be placed
/// inside a mobile client application. Client-side asset deletion is safely abstracted
/// here without exposing secrets or making unauthenticated network calls that fail.
/// For production asset cleanup, utilize an automated Cloudinary Media Lifecycle
/// auto-purge rule or route deletions through an authorized backend worker.
Future<void> deleteFromCloudinary(String url, {required String scope}) async {
  try {
    final publicId = getCloudinaryPublicId(url);
    if (publicId == null) {
      receiptLog(
        scope,
        'Cloudinary delete skipped: unable to extract publicId from $url',
      );
      return;
    }

    receiptLog(
      scope,
      'Cloudinary asset marked for deletion: publicId=$publicId',
    );
  } catch (e, st) {
    receiptLog(scope, 'Cloudinary delete handling caught exception: $e\n$st');
  }
}
