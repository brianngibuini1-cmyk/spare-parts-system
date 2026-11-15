import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bmm_auto_motors/app/app.dart';
import 'package:bmm_auto_motors/app/theme.dart';
import 'package:bmm_auto_motors/core/network/api_client.dart';
import 'package:bmm_auto_motors/core/network/api_transport.dart';
import 'package:bmm_auto_motors/core/security/credential_store.dart';
import 'package:bmm_auto_motors/features/authentication/auth_controller.dart';
import 'package:bmm_auto_motors/features/authentication/auth_repository.dart';
import 'package:bmm_auto_motors/features/catalogue/catalogue_controller.dart';
import 'package:bmm_auto_motors/features/catalogue/catalogue_models.dart';
import 'package:bmm_auto_motors/features/catalogue/catalogue_repository.dart';
import 'package:bmm_auto_motors/features/catalogue/catalogue_screen.dart';
import 'package:bmm_auto_motors/features/catalogue/product_image_picker.dart';
import 'package:bmm_auto_motors/features/navigation/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

final Uint8List _validPngBytes = Uint8List.fromList(const <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
]);

TokenPair _activeTokenPair() => TokenPair(
      accessToken: 'attendant-access',
      refreshToken: 'attendant-refresh',
      accessExpiresAt: DateTime.now().toUtc().add(const Duration(minutes: 10)),
    );

Map<String, Object?> _productJson({
  required String id,
  required String name,
  String internalReference = 'SP-1001',
  String? description = 'Heavy-duty ceramic brake pad set',
  String? category = 'Brakes',
  String? manufacturerPartNumber = 'BP-4420',
  String? imageUrl,
  String? sellingPrice,
  String approvalStatus = 'pending',
  int submittedBy = 3,
  String submittedByLogin = 'attendant',
  int? approvedBy,
  String? approvedByLogin,
  String? approvedAt,
  String? rejectionReason,
  required bool canEdit,
}) =>
    <String, Object?>{
      'id': id,
      'internal_reference': internalReference,
      'name': name,
      'description': description,
      'category': category,
      'manufacturer_part_number': manufacturerPartNumber,
      'image_url': imageUrl,
      'selling_price': sellingPrice,
      'approval_status': approvalStatus,
      'submitted_by': submittedBy,
      'submitted_by_login': submittedByLogin,
      'submitted_at': '2026-04-18T10:00:00+00:00',
      'approved_by': approvedBy,
      'approved_by_login': approvedByLogin,
      'approved_at': approvedAt,
      'rejection_reason': rejectionReason,
      'can_edit': canEdit,
    };

void main() {
  final baseUrl = Uri.parse('https://staging.example.test');

  testWidgets(
      'attendant opens catalogue after authentication, browses statuses, and searches with backend filters',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final storage = MemoryCredentialStore()..pair = _activeTokenPair();
    final productQueries = <Map<String, String>>[];
    final transport = CallbackTransport((request) async {
      if (request.uri.path == '/api/v1/native/auth/me') {
        return ApiResponse(
          statusCode: 200,
          body: meResponse(),
        );
      }
      if (request.method == 'GET' && request.uri.path == '/api/v1/products') {
        productQueries.add(request.uri.queryParameters);
        final status = request.uri.queryParameters['approval_status'];
        final query = request.uri.queryParameters['q'];
        if (status == 'rejected') {
          return ApiResponse(
            statusCode: 200,
            body: {
              'items': [
                _productJson(
                  id: 'prod-rejected',
                  internalReference: 'SP-REJ1',
                  name: 'Counterfeit Spark Plug',
                  approvalStatus: 'rejected',
                  rejectionReason: 'Incomplete supplier serial number',
                  canEdit: false,
                ),
              ],
              'limit': 50,
            },
          );
        }
        if (query == 'alternator') {
          return ApiResponse(
            statusCode: 200,
            body: {
              'items': [
                _productJson(
                  id: 'prod-alt',
                  internalReference: 'SP-ALT9',
                  name: 'Alternator Assembly',
                  category: 'Electrical',
                  approvalStatus: 'pending',
                  canEdit: true,
                ),
              ],
              'limit': 50,
            },
          );
        }
        return ApiResponse(
          statusCode: 200,
          body: {
            'items': [
              _productJson(
                id: 'prod-approved',
                internalReference: 'SP-APP1',
                name: 'Front Brake Disc',
                approvalStatus: 'approved',
                sellingPrice: '185000.0000',
                approvedBy: 1,
                approvedByLogin: 'owner',
                approvedAt: '2026-04-18T11:00:00+00:00',
                canEdit: false,
              ),
              _productJson(
                id: 'prod-pending',
                internalReference: 'SP-PEN2',
                name: 'Clutch Release Bearing',
                approvalStatus: 'pending',
                canEdit: true,
              ),
            ],
            'limit': 50,
          },
        );
      }
      throw StateError('Unexpected request ${request.method} ${request.uri}');
    });

    final api = ApiClient(
      baseUrl: baseUrl,
      transport: transport,
      credentials: storage,
    );
    final authController = AuthController(AuthRepository(api));

    await tester.pumpWidget(BmmApplication(controller: authController));
    await tester.pumpAndSettle();

    // Navigate to Products in NavigationRail.
    await tester.tap(find.text('Products'));
    await tester.pumpAndSettle();

    expect(find.text('Front Brake Disc'), findsOneWidget);
    expect(find.text('Selling price: 185000.0000'), findsOneWidget);
    expect(find.text('Clutch Release Bearing'), findsOneWidget);
    expect(find.text('Editable submission'), findsOneWidget);
    expect(productQueries.first, {'limit': '50'});

    // Filter by Rejected status.
    await tester.tap(find.byKey(const Key('filter-status-rejected')));
    await tester.pumpAndSettle();

    expect(find.text('Counterfeit Spark Plug'), findsOneWidget);
    expect(
      find.text('Rejection reason: Incomplete supplier serial number'),
      findsOneWidget,
    );
    expect(
      productQueries.last,
      {'limit': '50', 'approval_status': 'rejected'},
    );

    // Clear status filter and search by keyword.
    await tester.tap(find.byKey(const Key('filter-status-all')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('catalogue-search-input')),
      '  alternator  ',
    );
    await tester.tap(find.byKey(const Key('catalogue-search-button')));
    await tester.pumpAndSettle();

    expect(find.text('Alternator Assembly'), findsOneWidget);
    expect(productQueries.last, {'limit': '50', 'q': 'alternator'});
  });

  testWidgets(
      'attendant submits new product with optional photograph and validates required name',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final storage = MemoryCredentialStore()..pair = _activeTokenPair();
    var createCalls = 0;
    var uploadCalls = 0;
    var imageGetCalls = 0;

    final transport = CallbackTransport((request) async {
      if (request.method == 'POST' && request.uri.path == '/api/v1/products') {
        createCalls++;
        expect(request.body, {
          'name': 'Hydraulic Brake Hose',
          'description': 'Reinforced rubber line',
          'category': 'Brakes',
          'manufacturer_part_number': 'HBH-99',
        });
        return ApiResponse(
          statusCode: 201,
          body: _productJson(
            id: 'prod-new',
            internalReference: 'SP-NEW1',
            name: 'Hydraulic Brake Hose',
            description: 'Reinforced rubber line',
            category: 'Brakes',
            manufacturerPartNumber: 'HBH-99',
            approvalStatus: 'pending',
            canEdit: true,
          ),
        );
      }
      if (request.method == 'POST' &&
          request.uri.path == '/api/v1/products/prod-new/image') {
        uploadCalls++;
        final payload = request.body as MultipartFilePayload;
        expect(payload.filename, 'brake-hose.png');
        expect(payload.contentType, 'image/png');
        expect(payload.bytes, _validPngBytes);
        return ApiResponse(
          statusCode: 200,
          body: _productJson(
            id: 'prod-new',
            internalReference: 'SP-NEW1',
            name: 'Hydraulic Brake Hose',
            description: 'Reinforced rubber line',
            category: 'Brakes',
            manufacturerPartNumber: 'HBH-99',
            imageUrl: '/api/v1/products/prod-new/image',
            approvalStatus: 'pending',
            canEdit: true,
          ),
        );
      }
      if (request.method == 'GET' &&
          request.uri.path == '/api/v1/products/prod-new/image') {
        imageGetCalls++;
        return ApiResponse(statusCode: 200, body: _validPngBytes);
      }
      throw StateError('Unexpected request ${request.method} ${request.uri}');
    });

    final api = ApiClient(
      baseUrl: baseUrl,
      transport: transport,
      credentials: storage,
    );
    final controller = CatalogueController(CatalogueRepository(api));

    await tester.pumpWidget(
      MaterialApp(
        theme: BmmTheme.light,
        home: Scaffold(
          body: CatalogueScreen(
            controller: controller,
            initialSection: CatalogueSection.register,
            imagePicker: (_) async => SelectedProductImage(
              bytes: _validPngBytes,
              filename: 'brake-hose.png',
              contentType: 'image/png',
            ),
          ),
        ),
      ),
    );

    // Attempt submission with empty name -> client-side validation prevents API call.
    await tester.tap(find.byKey(const Key('submit-new-product-button')));
    await tester.pump();
    expect(find.text('Enter the product name.'), findsOneWidget);
    expect(createCalls, 0);

    // Fill out form and select image.
    await tester.enterText(
      find.byKey(const Key('create-product-name-input')),
      'Hydraulic Brake Hose',
    );
    await tester.enterText(
      find.byKey(const Key('create-product-category-input')),
      'Brakes',
    );
    await tester.enterText(
      find.byKey(const Key('create-product-part-number-input')),
      'HBH-99',
    );
    await tester.enterText(
      find.byKey(const Key('create-product-description-input')),
      'Reinforced rubber line',
    );
    await tester.tap(find.byKey(const Key('create-select-image-button')));
    await tester.pump();
    expect(find.text('brake-hose.png'), findsOneWidget);

    await tester.tap(find.byKey(const Key('submit-new-product-button')));
    await tester.pumpAndSettle();

    expect(createCalls, 1);
    expect(uploadCalls, 1);
    expect(imageGetCalls, 1);
    expect(
      find.text('Product and photograph submitted for owner approval.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('product-detail-image')), findsOneWidget);
  });

  testWidgets(
      'attendant can edit and upload photograph on own pending submission, with no owner approval controls',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 950);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final storage = MemoryCredentialStore()..pair = _activeTokenPair();
    var patchCalled = false;
    var imageUploaded = false;

    final transport = CallbackTransport((request) async {
      if (request.method == 'GET' && request.uri.path == '/api/v1/products') {
        return ApiResponse(
          statusCode: 200,
          body: {
            'items': [
              _productJson(
                id: 'prod-own',
                internalReference: 'SP-OWN1',
                name: 'Timing Belt Kit',
                category: 'Engine',
                manufacturerPartNumber: 'TBK-10',
                description: 'Initial belt description',
                approvalStatus: 'pending',
                canEdit: true,
              ),
            ],
            'limit': 50,
          },
        );
      }
      if (request.method == 'GET' &&
          request.uri.path == '/api/v1/products/prod-own') {
        return ApiResponse(
          statusCode: 200,
          body: _productJson(
            id: 'prod-own',
            internalReference: 'SP-OWN1',
            name: 'Timing Belt Kit',
            category: 'Engine',
            manufacturerPartNumber: 'TBK-10',
            description: 'Initial belt description',
            approvalStatus: 'pending',
            canEdit: true,
          ),
        );
      }
      if (request.method == 'PATCH' &&
          request.uri.path == '/api/v1/products/prod-own') {
        patchCalled = true;
        expect(request.body, {
          'name': 'Timing Belt Kit Pro',
          'description': 'Updated heavy-duty belt kit',
          'category': 'Engine',
          'manufacturer_part_number': 'TBK-10-PRO',
        });
        return ApiResponse(
          statusCode: 200,
          body: _productJson(
            id: 'prod-own',
            internalReference: 'SP-OWN1',
            name: 'Timing Belt Kit Pro',
            category: 'Engine',
            manufacturerPartNumber: 'TBK-10-PRO',
            description: 'Updated heavy-duty belt kit',
            approvalStatus: 'pending',
            canEdit: true,
          ),
        );
      }
      if (request.method == 'POST' &&
          request.uri.path == '/api/v1/products/prod-own/image') {
        imageUploaded = true;
        return ApiResponse(
          statusCode: 200,
          body: _productJson(
            id: 'prod-own',
            internalReference: 'SP-OWN1',
            name: 'Timing Belt Kit Pro',
            category: 'Engine',
            manufacturerPartNumber: 'TBK-10-PRO',
            description: 'Updated heavy-duty belt kit',
            imageUrl: '/api/v1/products/prod-own/image',
            approvalStatus: 'pending',
            canEdit: true,
          ),
        );
      }
      if (request.method == 'GET' &&
          request.uri.path == '/api/v1/products/prod-own/image') {
        return ApiResponse(statusCode: 200, body: _validPngBytes);
      }
      throw StateError('Unexpected request ${request.method} ${request.uri}');
    });

    final api = ApiClient(
      baseUrl: baseUrl,
      transport: transport,
      credentials: storage,
    );
    final controller = CatalogueController(CatalogueRepository(api));

    await tester.pumpWidget(
      MaterialApp(
        theme: BmmTheme.light,
        home: Scaffold(
          body: CatalogueScreen(
            controller: controller,
            imagePicker: (_) async => SelectedProductImage(
              bytes: _validPngBytes,
              filename: 'timing-belt.png',
              contentType: 'image/png',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Open product detail.
    await tester.tap(find.byKey(const Key('product-card-prod-own')));
    await tester.pumpAndSettle();

    // Verify attendant sees edit controls and upload button, but no owner approval/rejection buttons.
    expect(find.byKey(const Key('detail-edit-form-card')), findsOneWidget);
    expect(find.byKey(const Key('detail-upload-image-button')), findsOneWidget);
    expect(find.textContaining('Approve'), findsNothing);
    expect(find.textContaining('Reject product'), findsNothing);

    // Edit fields and save.
    await tester.enterText(
      find.byKey(const Key('edit-product-name-input')),
      'Timing Belt Kit Pro',
    );
    await tester.enterText(
      find.byKey(const Key('edit-product-part-number-input')),
      'TBK-10-PRO',
    );
    await tester.enterText(
      find.byKey(const Key('edit-product-description-input')),
      'Updated heavy-duty belt kit',
    );
    await tester.ensureVisible(
      find.byKey(const Key('save-product-edit-button')),
    );
    await tester.tap(find.byKey(const Key('save-product-edit-button')));
    await tester.pumpAndSettle();

    expect(patchCalled, isTrue);
    expect(find.text('Product details updated.'), findsOneWidget);
    expect(find.text('Timing Belt Kit Pro'), findsWidgets);

    // Upload photograph from detail view.
    await tester.ensureVisible(
      find.byKey(const Key('detail-upload-image-button')),
    );
    await tester.tap(find.byKey(const Key('detail-upload-image-button')));
    await tester.pumpAndSettle();

    expect(imageUploaded, isTrue);
    expect(find.text('Product photograph uploaded.'), findsOneWidget);
    expect(find.byKey(const Key('product-detail-image')), findsOneWidget);
  });

  testWidgets(
      'approved and rejected products are read-only for attendant and hide edit and image upload actions',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final storage = MemoryCredentialStore()..pair = _activeTokenPair();
    final transport = CallbackTransport((request) async {
      if (request.method == 'GET' && request.uri.path == '/api/v1/products') {
        return ApiResponse(
          statusCode: 200,
          body: {
            'items': [
              _productJson(
                id: 'prod-app',
                internalReference: 'SP-APP9',
                name: 'Approved Radiator',
                approvalStatus: 'approved',
                sellingPrice: '420000.0000',
                canEdit: false,
              ),
              _productJson(
                id: 'prod-rej',
                internalReference: 'SP-REJ9',
                name: 'Rejected Water Pump',
                approvalStatus: 'rejected',
                rejectionReason: 'Duplicate part number in system',
                canEdit: false,
              ),
            ],
            'limit': 50,
          },
        );
      }
      if (request.method == 'GET' &&
          request.uri.path == '/api/v1/products/prod-app') {
        return ApiResponse(
          statusCode: 200,
          body: _productJson(
            id: 'prod-app',
            internalReference: 'SP-APP9',
            name: 'Approved Radiator',
            approvalStatus: 'approved',
            sellingPrice: '420000.0000',
            canEdit: false,
          ),
        );
      }
      if (request.method == 'GET' &&
          request.uri.path == '/api/v1/products/prod-rej') {
        return ApiResponse(
          statusCode: 200,
          body: _productJson(
            id: 'prod-rej',
            internalReference: 'SP-REJ9',
            name: 'Rejected Water Pump',
            approvalStatus: 'rejected',
            rejectionReason: 'Duplicate part number in system',
            canEdit: false,
          ),
        );
      }
      throw StateError('Unexpected request ${request.method} ${request.uri}');
    });

    final api = ApiClient(
      baseUrl: baseUrl,
      transport: transport,
      credentials: storage,
    );
    final controller = CatalogueController(CatalogueRepository(api));

    await tester.pumpWidget(
      MaterialApp(
        theme: BmmTheme.light,
        home: Scaffold(body: CatalogueScreen(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();

    // Open approved product.
    await tester.tap(find.byKey(const Key('product-card-prod-app')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('detail-edit-form-card')), findsNothing);
    expect(find.byKey(const Key('detail-upload-image-button')), findsNothing);
    expect(find.byKey(const Key('product-readonly-notice')), findsOneWidget);
    expect(
      find.text(
        'Approved catalogue records are read-only for shop attendants.',
      ),
      findsOneWidget,
    );

    // Return to catalogue and open rejected product.
    await tester.tap(find.byKey(const Key('back-to-catalogue-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('product-card-prod-rej')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('detail-edit-form-card')), findsNothing);
    expect(find.byKey(const Key('detail-upload-image-button')), findsNothing);
    expect(
      find.byKey(const Key('detail-rejection-reason-box')),
      findsOneWidget,
    );
    expect(
      find.text('Rejection reason: Duplicate part number in system'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Rejected submissions are locked and cannot be edited or receive photograph updates.',
      ),
      findsOneWidget,
    );
  });

  testWidgets(
      'handles loading, empty, network error retry, and 401 session expiry redirection',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final storage = MemoryCredentialStore()..pair = _activeTokenPair();
    final firstLoadCompleter = Completer<ApiResponse>();
    var listAttempts = 0;

    final transport = CallbackTransport((request) async {
      if (request.uri.path == '/api/v1/native/auth/me') {
        return ApiResponse(
          statusCode: 200,
          body: meResponse(),
        );
      }
      if (request.method == 'GET' && request.uri.path == '/api/v1/products') {
        listAttempts++;
        if (listAttempts == 1) {
          return firstLoadCompleter.future;
        }
        if (listAttempts == 2) {
          throw const SocketException('Network down');
        }
        if (listAttempts == 3) {
          return const ApiResponse(statusCode: 401);
        }
      }
      if (request.uri.path == '/api/v1/native/auth/refresh') {
        return const ApiResponse(statusCode: 401);
      }
      throw StateError('Unexpected request ${request.method} ${request.uri}');
    });

    final api = ApiClient(
      baseUrl: baseUrl,
      transport: transport,
      credentials: storage,
    );
    final authController = AuthController(AuthRepository(api));

    await tester.pumpWidget(BmmApplication(controller: authController));
    await tester.pumpAndSettle();

    // Open Products destination.
    await tester.tap(find.text('Products'));
    await tester.pump();
    await tester.pump();

    // 1. Loading state is shown while request is in flight.
    expect(find.text('Loading spare parts catalogue...'), findsOneWidget);

    // 2. Empty state when server returns 0 items.
    firstLoadCompleter.complete(
      const ApiResponse(
        statusCode: 200,
        body: {'items': <Object?>[], 'limit': 50},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('catalogue-empty-card')), findsOneWidget);

    // 3. Network error state on refresh.
    await tester.tap(find.byKey(const Key('catalogue-refresh-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('catalogue-list-error-card')), findsOneWidget);
    expect(
      find.text(
        'Unable to reach BMM Auto Motors. Check the connection and try again.',
      ),
      findsOneWidget,
    );

    // 4. Retry receives 401 (and refresh fails with 401) -> redirects to LoginScreen.
    await tester.tap(find.byKey(const Key('catalogue-retry-button')));
    await tester.pumpAndSettle();
    expect(find.text('Sign in'), findsOneWidget);
    expect(
      find.text('Invalid sign-in or expired session.'),
      findsOneWidget,
    );
  });

  test(
      'local image file loader detects PNG, JPEG, and WebP, enforces 5 MiB boundary, and rejects unsupported files',
      () async {
    final tempDir = await Directory.systemTemp.createTemp('bmm_image_test_');
    addTearDown(() => tempDir.delete(recursive: true));

    expect(defaultMaxProductImageBytes, 5 * 1024 * 1024);
    expect(configuredMaxProductImageBytes, 5 * 1024 * 1024);

    final pngFile = File('${tempDir.path}/sample.png');
    await pngFile.writeAsBytes(_validPngBytes);
    final loadedPng = await loadSelectedImageFromFile(pngFile.path);
    expect(loadedPng.filename, 'sample.png');
    expect(loadedPng.contentType, 'image/png');
    expect(loadedPng.bytes, _validPngBytes);

    // Exact 5 MiB boundary accepted.
    final exactLimitBytes = Uint8List(defaultMaxProductImageBytes);
    exactLimitBytes.setRange(0, _validPngBytes.length, _validPngBytes);
    final exactLimitFile = File('${tempDir.path}/exact-5mib.png');
    await exactLimitFile.writeAsBytes(exactLimitBytes);
    final loadedAtLimit = await loadSelectedImageFromFile(exactLimitFile.path);
    expect(loadedAtLimit.bytes.length, defaultMaxProductImageBytes);

    // 5 MiB + 1 byte rejected before upload.
    final overLimitBytes = Uint8List(defaultMaxProductImageBytes + 1);
    overLimitBytes.setRange(0, _validPngBytes.length, _validPngBytes);
    final overLimitFile = File('${tempDir.path}/over-5mib.png');
    await overLimitFile.writeAsBytes(overLimitBytes);
    await expectLater(
      loadSelectedImageFromFile(overLimitFile.path),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'The selected image exceeds the upload size limit.',
        ),
      ),
    );

    final invalidFile = File('${tempDir.path}/notes.txt');
    await invalidFile.writeAsString('not an image');
    await expectLater(
      loadSelectedImageFromFile(invalidFile.path),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'Only JPEG, PNG, and WebP images are accepted.',
        ),
      ),
    );
  });

  test(
      'image loader deduplicates ordinary concurrent loads, lets forceRefresh bypass in-flight loads, and evicts stale bytes on failed forced refresh',
      () async {
    final storage = MemoryCredentialStore()..pair = _activeTokenPair();
    const imageUrl = '/api/v1/products/prod-img/image';
    final firstRequestStarted = Completer<void>();
    final secondRequestStarted = Completer<void>();
    final firstCompleter = Completer<ApiResponse>();
    final forcedCompleter = Completer<ApiResponse>();
    final staleBytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0x01]);
    final freshBytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0x02]);
    var imageGetCount = 0;

    final transport = CallbackTransport((request) async {
      if (request.method == 'GET' && request.uri.path == imageUrl) {
        imageGetCount++;
        if (imageGetCount == 1) {
          firstRequestStarted.complete();
          return firstCompleter.future;
        }
        if (imageGetCount == 2) {
          secondRequestStarted.complete();
          return forcedCompleter.future;
        }
        if (imageGetCount == 3) {
          return const ApiResponse(statusCode: 500);
        }
      }
      throw StateError('Unexpected request ${request.method} ${request.uri}');
    });

    final api = ApiClient(
      baseUrl: baseUrl,
      transport: transport,
      credentials: storage,
    );
    final controller = CatalogueController(CatalogueRepository(api));

    // 1. Two ordinary concurrent loads share one network request.
    final loadA = controller.loadProductImage(imageUrl);
    final loadB = controller.loadProductImage(imageUrl);
    await firstRequestStarted.future;
    expect(imageGetCount, 1);
    expect(controller.isLoadingImageFor(imageUrl), isTrue);

    // 2. While the first load is still in flight, forceRefresh: true is NOT
    // blocked and starts a new request immediately.
    final forcedLoad = controller.loadProductImage(
      imageUrl,
      forceRefresh: true,
    );
    await secondRequestStarted.future;
    expect(imageGetCount, 2);

    // Complete the older in-flight request first with stale bytes; it must not
    // populate the cache or clear the loading state of the newer forced refresh.
    firstCompleter.complete(ApiResponse(statusCode: 200, body: staleBytes));
    await Future.wait([loadA, loadB]);
    expect(controller.imageBytesFor(imageUrl), isNull);
    expect(controller.isLoadingImageFor(imageUrl), isTrue);

    // Complete the forced refresh with fresh bytes.
    forcedCompleter.complete(ApiResponse(statusCode: 200, body: freshBytes));
    await forcedLoad;
    expect(controller.imageBytesFor(imageUrl), freshBytes);
    expect(controller.isLoadingImageFor(imageUrl), isFalse);
    expect(controller.imageErrorFor(imageUrl), isNull);

    // 3. When a subsequent forced refresh fails, stale bytes are evicted
    // immediately and never remain cached.
    await controller.loadProductImage(imageUrl, forceRefresh: true);
    expect(imageGetCount, 3);
    expect(controller.imageBytesFor(imageUrl), isNull);
    expect(
      controller.imageErrorFor(imageUrl),
      'The service is temporarily unavailable. Try again later.',
    );
  });

  testWidgets(
      'AppShell resets selection and disposes owned controller on user or role change without disposing external controller',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final storage = MemoryCredentialStore()..pair = _activeTokenPair();
    var currentUserLabel = 'owner-item';
    final transport = CallbackTransport((request) async {
      if (request.method == 'GET' && request.uri.path == '/api/v1/products') {
        return ApiResponse(
          statusCode: 200,
          body: {
            'items': [
              _productJson(
                id: 'prod-$currentUserLabel',
                name: 'Part for $currentUserLabel',
                approvalStatus: 'approved',
                sellingPrice: '10000.0000',
                canEdit: false,
              ),
            ],
            'limit': 50,
          },
        );
      }
      throw StateError('Unexpected request ${request.method} ${request.uri}');
    });

    final api = ApiClient(
      baseUrl: baseUrl,
      transport: transport,
      credentials: storage,
    );

    const ownerUser = AuthenticatedUser(
      id: 1,
      loginName: 'owner',
      role: 'OWNER',
    );
    const attendant1 = AuthenticatedUser(
      id: 3,
      loginName: 'attendant1',
      role: 'SHOP_ATTENDANT',
    );
    const attendant2 = AuthenticatedUser(
      id: 4,
      loginName: 'attendant2',
      role: 'SHOP_ATTENDANT',
    );

    // Mount AppShell with owned controller as OWNER and select last destination
    // ('Team management', index 7, which is out of range for SHOP_ATTENDANT's 6 items).
    await tester.pumpWidget(
      MaterialApp(
        theme: BmmTheme.light,
        home: AppShell(
          user: ownerUser,
          onLogout: () async {},
          api: api,
        ),
      ),
    );
    await tester.tap(find.text('Team management'));
    await tester.pumpAndSettle();
    expect(find.text('Team management'), findsWidgets);

    // Switch in-place to attendant1 -> selection resets to 'Dashboard' (index 0)
    // without throwing RangeError.
    currentUserLabel = 'attendant1';
    await tester.pumpWidget(
      MaterialApp(
        theme: BmmTheme.light,
        home: AppShell(
          user: attendant1,
          onLogout: () async {},
          api: api,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Dashboard'), findsWidgets);

    // Open Products as attendant1 so the owned controller loads attendant1's catalogue.
    await tester.tap(find.text('Products'));
    await tester.pumpAndSettle();
    expect(find.text('Part for attendant1'), findsOneWidget);

    // Switch in-place to attendant2 -> owned controller is disposed/recreated and
    // selection resets to Dashboard; navigating to Products loads attendant2's data.
    currentUserLabel = 'attendant2';
    await tester.pumpWidget(
      MaterialApp(
        theme: BmmTheme.light,
        home: AppShell(
          user: attendant2,
          onLogout: () async {},
          api: api,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Part for attendant1'), findsNothing);

    await tester.tap(find.text('Products'));
    await tester.pumpAndSettle();
    expect(find.text('Part for attendant2'), findsOneWidget);

    // Verify an externally supplied CatalogueController is NOT disposed by AppShell
    // when the user changes.
    final externalController = CatalogueController(CatalogueRepository(api));
    addTearDown(externalController.dispose);
    var externalControllerNotified = false;
    externalController.addListener(() {
      externalControllerNotified = true;
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: BmmTheme.light,
        home: AppShell(
          user: attendant1,
          onLogout: () async {},
          catalogueController: externalController,
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: BmmTheme.light,
        home: AppShell(
          user: attendant2,
          onLogout: () async {},
          catalogueController: externalController,
        ),
      ),
    );
    // Calling clearFeedback/loadProducts on externalController must still work
    // because AppShell must not dispose an externally owned controller.
    await externalController.loadProducts();
    expect(externalControllerNotified, isTrue);
  });
}
