import 'dart:typed_data';

import 'package:bmm_auto_motors/features/catalogue/catalogue_models.dart';
import 'package:bmm_auto_motors/features/catalogue/product_image_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

class FakeImagePickerService implements ImagePickerService {
  FakeImagePickerService({this.onPickImage});

  final Future<XFile?> Function({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice,
    bool? requestFullMetadata,
  })? onPickImage;

  ImageSource? lastSource;
  int callCount = 0;

  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool? requestFullMetadata,
  }) async {
    callCount++;
    lastSource = source;
    if (onPickImage != null) {
      return onPickImage!(
        source: source,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
        imageQuality: imageQuality,
        preferredCameraDevice: preferredCameraDevice,
        requestFullMetadata: requestFullMetadata,
      );
    }
    return null;
  }
}

const List<int> _sampleJpegBytes = <int>[0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10];
const List<int> _samplePngBytes = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
];
const List<int> _sampleWebpBytes = <int>[
  0x52,
  0x49,
  0x46,
  0x46,
  0x00,
  0x00,
  0x00,
  0x00,
  0x57,
  0x45,
  0x42,
  0x50,
];
const List<int> _samplePdfBytes = <int>[0x25, 0x50, 0x44, 0x46, 0x2D, 0x31];

void main() {
  group('processPickedXFile validation', () {
    test('accepts valid JPEG file bytes', () async {
      final xfile = XFile.fromData(
        Uint8List.fromList(_sampleJpegBytes),
        path: 'brake_pad.jpg',
      );
      final selected = await processPickedXFile(xfile);
      expect(selected.filename, 'brake_pad.jpg');
      expect(selected.contentType, 'image/jpeg');
      expect(selected.bytes, _sampleJpegBytes);
    });

    test('accepts valid PNG file bytes', () async {
      final xfile = XFile.fromData(
        Uint8List.fromList(_samplePngBytes),
        path: 'oil_filter.png',
      );
      final selected = await processPickedXFile(xfile);
      expect(selected.filename, 'oil_filter.png');
      expect(selected.contentType, 'image/png');
      expect(selected.bytes, _samplePngBytes);
    });

    test('accepts valid WebP file bytes', () async {
      final xfile = XFile.fromData(
        Uint8List.fromList(_sampleWebpBytes),
        path: 'spark_plug.webp',
      );
      final selected = await processPickedXFile(xfile);
      expect(selected.filename, 'spark_plug.webp');
      expect(selected.contentType, 'image/webp');
      expect(selected.bytes, _sampleWebpBytes);
    });

    test('generates default filename when path and name are empty', () async {
      final xfile = XFile.fromData(
        Uint8List.fromList(_sampleJpegBytes),
      );
      final selected = await processPickedXFile(xfile);
      expect(selected.filename, 'product-image.jpg');
      expect(selected.contentType, 'image/jpeg');
    });

    test('throws FormatException when file is empty', () async {
      final xfile = XFile.fromData(
        Uint8List(0),
        path: 'empty.jpg',
      );
      expect(
        () => processPickedXFile(xfile),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('empty'),
          ),
        ),
      );
    });

    test('throws FormatException when file exceeds maxBytes', () async {
      final largeBytes = Uint8List(100);
      largeBytes[0] = 0xFF;
      largeBytes[1] = 0xD8;
      largeBytes[2] = 0xFF;
      final xfile = XFile.fromData(largeBytes, path: 'large.jpg');
      expect(
        () => processPickedXFile(xfile, maxBytes: 50),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('exceeds the upload size limit'),
          ),
        ),
      );
    });

    test('throws FormatException when format is unsupported', () async {
      final xfile = XFile.fromData(
        Uint8List.fromList(_samplePdfBytes),
        path: 'doc.pdf',
      );
      expect(
        () => processPickedXFile(xfile),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Only JPEG, PNG, and WebP images are accepted'),
          ),
        ),
      );
    });
  });

  group('showProductImagePickerSheet UI workflow', () {
    Widget buildTestHost({
      required Future<void> Function(BuildContext context) onTrigger,
    }) =>
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  key: const Key('trigger-picker-button'),
                  onPressed: () => onTrigger(context),
                  child: const Text('Pick Image'),
                ),
              ),
            ),
          ),
        );

    testWidgets('cancels and returns null when sheet is dismissed', (
      tester,
    ) async {
      SelectedProductImage? result;
      final fakeService = FakeImagePickerService();

      await tester.pumpWidget(
        buildTestHost(
          onTrigger: (context) async {
            result = await showProductImagePickerSheet(
              context,
              service: fakeService,
            );
          },
        ),
      );

      await tester.tap(find.byKey(const Key('trigger-picker-button')));
      await tester.pumpAndSettle();

      expect(find.text('Take photo'), findsOneWidget);
      expect(find.text('Choose from gallery'), findsOneWidget);

      // Tap outside the bottom sheet (at the top of the screen) to dismiss.
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();

      expect(find.text('Take photo'), findsNothing);
      expect(result, isNull);
      expect(fakeService.callCount, 0);
    });

    testWidgets('picks image from camera source', (tester) async {
      SelectedProductImage? result;
      final fakeService = FakeImagePickerService(
        onPickImage: ({
          required source,
          maxWidth,
          maxHeight,
          imageQuality,
          preferredCameraDevice = CameraDevice.rear,
          requestFullMetadata,
        }) async =>
            XFile.fromData(
          Uint8List.fromList(_sampleJpegBytes),
          path: 'camera_capture.jpg',
        ),
      );

      await tester.pumpWidget(
        buildTestHost(
          onTrigger: (context) async {
            result = await showProductImagePickerSheet(
              context,
              service: fakeService,
            );
          },
        ),
      );

      await tester.tap(find.byKey(const Key('trigger-picker-button')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('pick-image-camera-tile')));
      await tester.pumpAndSettle();

      expect(fakeService.callCount, 1);
      expect(fakeService.lastSource, ImageSource.camera);
      expect(result, isNotNull);
      expect(result!.filename, 'camera_capture.jpg');
      expect(result!.contentType, 'image/jpeg');
    });

    testWidgets('picks image from gallery source', (tester) async {
      SelectedProductImage? result;
      final fakeService = FakeImagePickerService(
        onPickImage: ({
          required source,
          maxWidth,
          maxHeight,
          imageQuality,
          preferredCameraDevice = CameraDevice.rear,
          requestFullMetadata,
        }) async =>
            XFile.fromData(
          Uint8List.fromList(_samplePngBytes),
          path: 'gallery_photo.png',
        ),
      );

      await tester.pumpWidget(
        buildTestHost(
          onTrigger: (context) async {
            result = await showProductImagePickerSheet(
              context,
              service: fakeService,
            );
          },
        ),
      );

      await tester.tap(find.byKey(const Key('trigger-picker-button')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('pick-image-gallery-tile')));
      await tester.pumpAndSettle();

      expect(fakeService.callCount, 1);
      expect(fakeService.lastSource, ImageSource.gallery);
      expect(result, isNotNull);
      expect(result!.filename, 'gallery_photo.png');
      expect(result!.contentType, 'image/png');
    });

    testWidgets('returns null when user cancels camera or gallery picker', (
      tester,
    ) async {
      SelectedProductImage? result;
      final fakeService = FakeImagePickerService(
        onPickImage: ({
          required source,
          maxWidth,
          maxHeight,
          imageQuality,
          preferredCameraDevice = CameraDevice.rear,
          requestFullMetadata,
        }) async =>
            null,
      );

      await tester.pumpWidget(
        buildTestHost(
          onTrigger: (context) async {
            result = await showProductImagePickerSheet(
              context,
              service: fakeService,
            );
          },
        ),
      );

      await tester.tap(find.byKey(const Key('trigger-picker-button')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('pick-image-gallery-tile')));
      await tester.pumpAndSettle();

      expect(fakeService.callCount, 1);
      expect(result, isNull);
    });

    testWidgets('surfaces SnackBar error on oversized file selection', (
      tester,
    ) async {
      SelectedProductImage? result;
      final fakeService = FakeImagePickerService(
        onPickImage: ({
          required source,
          maxWidth,
          maxHeight,
          imageQuality,
          preferredCameraDevice = CameraDevice.rear,
          requestFullMetadata,
        }) async =>
            XFile.fromData(
          Uint8List(50),
          path: 'oversized.jpg',
        ),
      );

      await tester.pumpWidget(
        buildTestHost(
          onTrigger: (context) async {
            result = await showProductImagePickerSheet(
              context,
              service: fakeService,
              maxBytes: 10,
            );
          },
        ),
      );

      await tester.tap(find.byKey(const Key('trigger-picker-button')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('pick-image-gallery-tile')));
      await tester.pumpAndSettle();

      expect(result, isNull);
      expect(
        find.text('The selected image exceeds the upload size limit.'),
        findsOneWidget,
      );
    });

    testWidgets('surfaces SnackBar error on unsupported file type', (
      tester,
    ) async {
      SelectedProductImage? result;
      final fakeService = FakeImagePickerService(
        onPickImage: ({
          required source,
          maxWidth,
          maxHeight,
          imageQuality,
          preferredCameraDevice = CameraDevice.rear,
          requestFullMetadata,
        }) async =>
            XFile.fromData(
          Uint8List.fromList(_samplePdfBytes),
          path: 'invoice.pdf',
        ),
      );

      await tester.pumpWidget(
        buildTestHost(
          onTrigger: (context) async {
            result = await showProductImagePickerSheet(
              context,
              service: fakeService,
            );
          },
        ),
      );

      await tester.tap(find.byKey(const Key('trigger-picker-button')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('pick-image-gallery-tile')));
      await tester.pumpAndSettle();

      expect(result, isNull);
      expect(
        find.text('Only JPEG, PNG, and WebP images are accepted.'),
        findsOneWidget,
      );
    });
  });
}
