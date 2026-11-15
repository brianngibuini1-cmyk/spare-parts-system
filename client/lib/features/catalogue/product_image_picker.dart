import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/config/app_config.dart';
import 'catalogue_models.dart';

typedef ProductImagePicker = Future<SelectedProductImage?> Function(
  BuildContext context,
);

/// Default client-side image upload limit (5 MiB = 5,242,880 bytes), matching
/// `Settings.product_image_max_bytes` in `app/config.py`.
///
/// Override at build/run time with
/// `--dart-define=SPARE_PARTS_PRODUCT_IMAGE_MAX_BYTES=<bytes>` whenever the
/// backend `SPARE_PARTS_PRODUCT_IMAGE_MAX_BYTES` setting is customized.
const int defaultMaxProductImageBytes = AppConfig.defaultProductImageMaxBytes;

int get configuredMaxProductImageBytes =>
    AppConfig.configuredProductImageMaxBytes();

String? detectProductImageContentType(List<int> bytes, String filename) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0D &&
      bytes[5] == 0x0A &&
      bytes[6] == 0x1A &&
      bytes[7] == 0x0A) {
    return 'image/png';
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'image/webp';
  }

  final lower = filename.toLowerCase();
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
    return 'image/jpeg';
  }
  if (lower.endsWith('.png')) {
    return 'image/png';
  }
  if (lower.endsWith('.webp')) {
    return 'image/webp';
  }
  return null;
}

String _basename(String path) {
  final normalized = path.replaceAll(r'\', '/');
  final segments =
      normalized.split('/').where((segment) => segment.isNotEmpty).toList();
  return segments.isEmpty ? '' : segments.last;
}

/// Abstract contract for image picking to allow test decoupling.
abstract class ImagePickerService {
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool? requestFullMetadata,
  });
}

/// Production implementation backed by package:image_picker.
class DefaultImagePickerService implements ImagePickerService {
  DefaultImagePickerService([ImagePicker? picker])
      : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool? requestFullMetadata,
  }) =>
      _picker.pickImage(
        source: source,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
        imageQuality: imageQuality,
        preferredCameraDevice: preferredCameraDevice,
        requestFullMetadata: requestFullMetadata ?? true,
      );
}

/// Validates and converts an [XFile] into a [SelectedProductImage].
///
/// Enforces non-empty content, size bounds (<= [maxBytes], defaulting to
/// [configuredMaxProductImageBytes]), and format restrictions (JPEG, PNG, WebP).
Future<SelectedProductImage> processPickedXFile(
  XFile file, {
  int? maxBytes,
}) async {
  final effectiveMaxBytes = maxBytes ?? configuredMaxProductImageBytes;
  final bytes = await file.readAsBytes();
  if (bytes.isEmpty) {
    throw const FormatException('The selected image file is empty.');
  }
  if (bytes.length > effectiveMaxBytes) {
    throw const FormatException(
      'The selected image exceeds the upload size limit.',
    );
  }
  final rawName = file.name.isNotEmpty
      ? file.name
      : (file.path.isNotEmpty ? _basename(file.path) : '');
  final contentType = detectProductImageContentType(bytes, rawName);
  if (contentType == null) {
    throw const FormatException(
      'Only JPEG, PNG, and WebP images are accepted.',
    );
  }
  String filename = _basename(rawName);
  if (filename.isEmpty) {
    final ext = switch (contentType) {
      'image/png' => 'png',
      'image/webp' => 'webp',
      _ => 'jpg',
    };
    filename = 'product-image.$ext';
  }
  return SelectedProductImage(
    bytes: bytes,
    filename: filename,
    contentType: contentType,
  );
}

/// Presents a bottom sheet offering camera capture and gallery selection,
/// validates the selected image, and surfaces errors via SnackBar.
Future<SelectedProductImage?> showProductImagePickerSheet(
  BuildContext context, {
  ImagePickerService? service,
  int? maxBytes,
}) async {
  final effectiveService = service ?? DefaultImagePickerService();
  final source = await showModalBottomSheet<ImageSource>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const Key('pick-image-camera-tile'),
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Take photo'),
              subtitle: const Text('Use camera to take a product photograph'),
              onTap: () => Navigator.of(sheetContext).pop(ImageSource.camera),
            ),
            ListTile(
              key: const Key('pick-image-gallery-tile'),
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              subtitle: const Text('Select existing photo from storage'),
              onTap: () => Navigator.of(sheetContext).pop(ImageSource.gallery),
            ),
          ],
        ),
      ),
    ),
  );

  if (source == null) {
    return null;
  }

  try {
    final picked = await effectiveService.pickImage(source: source);
    if (picked == null) {
      return null;
    }
    return await processPickedXFile(picked, maxBytes: maxBytes);
  } on FormatException catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.message),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
    return null;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to select image: $e'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
    return null;
  }
}

Future<SelectedProductImage> loadSelectedImageFromFile(
  String rawPath, {
  int? maxBytes,
}) async {
  final effectiveMaxBytes = maxBytes ?? configuredMaxProductImageBytes;
  final trimmed = rawPath.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('Enter the path to an image file.');
  }
  final file = File(trimmed);
  if (!await file.exists()) {
    throw const FormatException('The selected image file does not exist.');
  }
  final length = await file.length();
  if (length <= 0) {
    throw const FormatException('The selected image file is empty.');
  }
  if (length > effectiveMaxBytes) {
    throw const FormatException(
      'The selected image exceeds the upload size limit.',
    );
  }
  final bytes = await file.readAsBytes();
  if (bytes.length > effectiveMaxBytes) {
    throw const FormatException(
      'The selected image exceeds the upload size limit.',
    );
  }
  final extracted = _basename(trimmed);
  final filename = extracted.isNotEmpty ? extracted : 'product-image.jpg';
  final contentType = detectProductImageContentType(bytes, filename);
  if (contentType == null) {
    throw const FormatException(
      'Only JPEG, PNG, and WebP images are accepted.',
    );
  }
  return SelectedProductImage(
    bytes: bytes,
    filename: filename,
    contentType: contentType,
  );
}

Future<SelectedProductImage?> showLocalFileImagePickerDialog(
  BuildContext context,
) =>
    showDialog<SelectedProductImage>(
      context: context,
      builder: (_) => const _LocalFileImagePickerDialog(),
    );

class _LocalFileImagePickerDialog extends StatefulWidget {
  const _LocalFileImagePickerDialog();

  @override
  State<_LocalFileImagePickerDialog> createState() =>
      _LocalFileImagePickerDialogState();
}

class _LocalFileImagePickerDialogState
    extends State<_LocalFileImagePickerDialog> {
  final _pathController = TextEditingController();
  String? _errorText;
  bool _loading = false;

  @override
  void dispose() {
    _pathController.dispose();
    super.dispose();
  }

  Future<void> _confirmSelection() async {
    setState(() {
      _errorText = null;
      _loading = true;
    });
    try {
      final selected = await loadSelectedImageFromFile(_pathController.text);
      if (!mounted) return;
      Navigator.of(context).pop(selected);
    } on FormatException catch (error) {
      if (!mounted) return;
      setState(() {
        _errorText = error.message;
        _loading = false;
      });
    } on FileSystemException {
      if (!mounted) return;
      setState(() {
        _errorText = 'Unable to read the selected image file.';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Select product photograph'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Enter the local file path to a JPEG, PNG, or WebP photograph.',
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('image-file-path-input'),
                controller: _pathController,
                enabled: !_loading,
                decoration: InputDecoration(
                  labelText: 'Image file path',
                  hintText: 'C:/photos/brake-pad.jpg',
                  errorText: _errorText,
                ),
                onSubmitted: (_) => _confirmSelection(),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _loading ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirm-image-file-button'),
            onPressed: _loading ? null : _confirmSelection,
            child: Text(_loading ? 'Reading...' : 'Select image'),
          ),
        ],
      );
}
