import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bmm_auto_motors/app/app.dart';
import 'package:bmm_auto_motors/app/theme.dart';
import 'package:bmm_auto_motors/core/errors/api_exception.dart';
import 'package:bmm_auto_motors/core/network/api_client.dart';
import 'package:bmm_auto_motors/core/network/api_transport.dart';
import 'package:bmm_auto_motors/core/security/credential_store.dart';
import 'package:bmm_auto_motors/features/authentication/auth_controller.dart';
import 'package:bmm_auto_motors/features/authentication/auth_repository.dart';
import 'package:bmm_auto_motors/features/catalogue/catalogue_controller.dart';
import 'package:bmm_auto_motors/features/catalogue/catalogue_models.dart';
import 'package:bmm_auto_motors/features/catalogue/catalogue_repository.dart';
import 'package:bmm_auto_motors/features/catalogue/catalogue_screen.dart';
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

TokenPair _ownerTokenPair() => TokenPair(
      accessToken: 'owner-access',
      refreshToken: 'owner-refresh',
      accessExpiresAt: DateTime.now().toUtc().add(const Duration(minutes: 10)),
    );

Map<String, Object?> _productJson({
  required String id,
  required String name,
  String internalReference = 'SP-2001',
  String? description = 'OEM specification part',
  String? category = 'Suspension',
  String? manufacturerPartNumber = 'SUS-881',
  String? imageUrl,
  String? sellingPrice,
  String approvalStatus = 'pending',
  int submittedBy = 3,
  String submittedByLogin = 'attendant@example.test',
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
      'submitted_at': '2026-04-18T09:30:00+00:00',
      'approved_by': approvedBy,
      'approved_by_login': approvedByLogin,
      'approved_at': approvedAt,
      'rejection_reason': rejectionReason,
      'can_edit': canEdit,
    };

void main() {
  final baseUrl = Uri.parse('https://staging.example.test');

  test(
      'selling price and rejection reason validators enforce backend constraints',
      () {
    expect(validateSellingPriceInput(null), 'Enter a selling price.');
    expect(validateSellingPriceInput('   '), 'Enter a selling price.');
    expect(
      validateSellingPriceInput('-0.01'),
      'Selling price must be zero or greater.',
    );
    expect(
      validateSellingPriceInput('NaN'),
      'Enter a valid decimal selling price.',
    );
    expect(
      validateSellingPriceInput('12.34.56'),
      'Enter a valid decimal selling price.',
    );
    expect(
      validateSellingPriceInput('100.00001'),
      'Selling price can have no more than four decimal places.',
    );
    expect(
      validateSellingPriceInput('100000000000000.0000'),
      'Selling price is outside the supported decimal range.',
    );
    expect(validateSellingPriceInput('0'), isNull);
    expect(validateSellingPriceInput('0.0000'), isNull);
    expect(validateSellingPriceInput('2450.1250'), isNull);
    expect(validateSellingPriceInput('99999999999999.9999'), isNull);

    expect(validateRejectionReasonInput(null), 'Enter a rejection reason.');
    expect(validateRejectionReasonInput('   '), 'Enter a rejection reason.');
    expect(
      validateRejectionReasonInput('x' * 2001),
      'Rejection reason must not exceed 2,000 characters.',
    );
    expect(validateRejectionReasonInput('x' * 2000), isNull);
    expect(
      validateRejectionReasonInput('Please verify the OEM part number.'),
      isNull,
    );
  });

  test(
      'repository sends documented approve, reject, and pending requests and maps backend errors',
      () async {
    final storage = MemoryCredentialStore()..pair = _ownerTokenPair();
    var mode = 'success';
    final transport = CallbackTransport((request) async {
      if (mode == 'network_error') {
        throw const SocketException('Connection reset');
      }
      if (mode == 'validation_error') {
        return const ApiResponse(
          statusCode: 422,
          body: {'detail': 'Selling price can have no more than four decimals'},
        );
      }
      if (mode == 'forbidden') {
        return const ApiResponse(
          statusCode: 403,
          body: {'detail': 'Owner access required.'},
        );
      }
      if (mode == 'conflict') {
        return const ApiResponse(
          statusCode: 409,
          body: {'detail': 'Only pending submissions can be rejected.'},
        );
      }
      if (request.method == 'GET' &&
          request.uri.path == '/api/v1/products/pending') {
        return ApiResponse(
          statusCode: 200,
          body: [
            _productJson(
              id: 'prod-1',
              name: 'Tie Rod End',
              approvalStatus: 'pending',
              canEdit: true,
            ),
          ],
        );
      }
      if (request.method == 'POST' &&
          request.uri.path == '/api/v1/products/prod-1/approve') {
        expect(request.body, {'selling_price': '2450.1250'});
        return ApiResponse(
          statusCode: 200,
          body: _productJson(
            id: 'prod-1',
            name: 'Tie Rod End',
            approvalStatus: 'approved',
            sellingPrice: '2450.1250',
            approvedBy: 1,
            approvedByLogin: 'owner@example.test',
            approvedAt: '2026-04-18T12:00:00+00:00',
            canEdit: true,
          ),
        );
      }
      if (request.method == 'POST' &&
          request.uri.path == '/api/v1/products/prod-2/reject') {
        expect(
          request.body,
          {'reason': 'Missing supplier verification markings.'},
        );
        return ApiResponse(
          statusCode: 200,
          body: _productJson(
            id: 'prod-2',
            name: 'Unverified Bearing',
            approvalStatus: 'rejected',
            rejectionReason: 'Missing supplier verification markings.',
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
    final repo = CatalogueRepository(api);

    final pendingList = await repo.listPendingProducts();
    expect(pendingList, hasLength(1));
    expect(pendingList.single.name, 'Tie Rod End');

    final approved = await repo.approveProduct(
      'prod-1',
      const ProductApproveInput(sellingPrice: '  2450.1250  '),
    );
    expect(approved.approvalStatus, ProductApprovalStatus.approved);
    expect(approved.sellingPrice, '2450.1250');
    expect(approved.approvedByLogin, 'owner@example.test');

    final rejected = await repo.rejectProduct(
      'prod-2',
      const ProductRejectInput(
        reason: '  Missing supplier verification markings.  ',
      ),
    );
    expect(rejected.approvalStatus, ProductApprovalStatus.rejected);
    expect(
      rejected.rejectionReason,
      'Missing supplier verification markings.',
    );

    mode = 'validation_error';
    await expectLater(
      repo.approveProduct(
        'prod-1',
        const ProductApproveInput(sellingPrice: '100.00001'),
      ),
      throwsA(
        isA<ApiException>().having((e) => e.statusCode, 'statusCode', 422),
      ),
    );

    mode = 'forbidden';
    await expectLater(
      repo.rejectProduct(
        'prod-1',
        const ProductRejectInput(reason: 'Not allowed'),
      ),
      throwsA(
        isA<ApiException>().having((e) => e.statusCode, 'statusCode', 403),
      ),
    );

    mode = 'conflict';
    await expectLater(
      repo.rejectProduct(
        'prod-1',
        const ProductRejectInput(reason: 'Already approved'),
      ),
      throwsA(
        isA<ApiException>().having((e) => e.statusCode, 'statusCode', 409),
      ),
    );

    mode = 'network_error';
    await expectLater(
      repo.approveProduct(
        'prod-1',
        const ProductApproveInput(sellingPrice: '50.0000'),
      ),
      throwsA(
        isA<ApiException>().having((e) => e.statusCode, 'statusCode', isNull),
      ),
    );
  });

  test(
      'controller manages owner review state, refreshes list after approval/rejection, blocks duplicate submissions, and preserves state on failure',
      () async {
    final storage = MemoryCredentialStore()..pair = _ownerTokenPair();
    final approveRequestStarted = Completer<void>();
    final approveResponseCompleter = Completer<ApiResponse>();
    var approveCalls = 0;
    var rejectCalls = 0;
    var listCalls = 0;
    var failNextReject = false;
    var expireNextApprove = false;
    String? expiredMessage;

    final pendingItemA = _productJson(
      id: 'pend-a',
      internalReference: 'SP-PENDA',
      name: 'Shock Absorber Front',
      approvalStatus: 'pending',
      canEdit: true,
    );
    final pendingItemB = _productJson(
      id: 'pend-b',
      internalReference: 'SP-PENDB',
      name: 'Ball Joint Lower',
      approvalStatus: 'pending',
      canEdit: true,
    );
    var serverPendingItems = <Map<String, Object?>>[pendingItemA, pendingItemB];

    final transport = CallbackTransport((request) async {
      if (request.method == 'GET' && request.uri.path == '/api/v1/products') {
        listCalls++;
        expect(request.uri.queryParameters['approval_status'], 'pending');
        return ApiResponse(
          statusCode: 200,
          body: {'items': serverPendingItems, 'limit': 50},
        );
      }
      if (request.method == 'POST' &&
          request.uri.path == '/api/v1/products/pend-a/approve') {
        approveCalls++;
        if (expireNextApprove) {
          return const ApiResponse(statusCode: 401);
        }
        if (!approveRequestStarted.isCompleted) {
          approveRequestStarted.complete();
        }
        return approveResponseCompleter.future;
      }
      if (request.method == 'POST' &&
          request.uri.path == '/api/v1/products/pend-b/reject') {
        rejectCalls++;
        if (failNextReject) {
          return const ApiResponse(
            statusCode: 409,
            body: {'detail': 'Only pending submissions can be rejected.'},
          );
        }
        serverPendingItems = const [];
        return ApiResponse(
          statusCode: 200,
          body: _productJson(
            id: 'pend-b',
            internalReference: 'SP-PENDB',
            name: 'Ball Joint Lower',
            approvalStatus: 'rejected',
            rejectionReason: 'Damaged boot in photograph.',
            canEdit: false,
          ),
        );
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
    final controller = CatalogueController(
      CatalogueRepository(api),
      isOwner: true,
      initialStatusFilter: ProductApprovalStatus.pending,
      onSessionExpired: (msg) => expiredMessage = msg,
    );
    addTearDown(controller.dispose);

    expect(controller.statusFilter, ProductApprovalStatus.pending);
    await controller.loadProducts();
    expect(controller.products.map((p) => p.id), ['pend-a', 'pend-b']);
    expect(listCalls, 1);

    controller.selectedProduct = controller.products.first;

    // Start approval of pend-a and verify duplicate approve/reject calls are blocked while in flight.
    final firstApprove = controller.approveProduct('pend-a', '125000.5000');
    expect(controller.isApproving, isTrue);
    expect(controller.isReviewActionInProgress, isTrue);

    final duplicateApprove = controller.approveProduct('pend-a', '125000.5000');
    final concurrentReject =
        controller.rejectProduct('pend-a', 'Should be blocked');
    expect(await duplicateApprove, isFalse);
    expect(await concurrentReject, isFalse);

    await approveRequestStarted.future;
    expect(approveCalls, 1);

    // Server removes pend-a from pending list after approval.
    serverPendingItems = [pendingItemB];
    approveResponseCompleter.complete(
      ApiResponse(
        statusCode: 200,
        body: _productJson(
          id: 'pend-a',
          internalReference: 'SP-PENDA',
          name: 'Shock Absorber Front',
          approvalStatus: 'approved',
          sellingPrice: '125000.5000',
          approvedBy: 1,
          approvedByLogin: 'owner@example.test',
          approvedAt: '2026-04-18T13:00:00+00:00',
          canEdit: true,
        ),
      ),
    );

    expect(await firstApprove, isTrue);
    expect(controller.isApproving, isFalse);
    expect(
      controller.selectedProduct?.approvalStatus,
      ProductApprovalStatus.approved,
    );
    expect(controller.selectedProduct?.sellingPrice, '125000.5000');
    expect(
      controller.actionMessage,
      'Product approved and selling price recorded.',
    );
    // Review list refreshed and now contains only pend-b.
    expect(listCalls, 2);
    expect(controller.products.map((p) => p.id), ['pend-b']);

    // Select pend-b and test failed rejection preserving usable review state.
    controller.selectedProduct = controller.products.single;
    failNextReject = true;
    final failedReject = controller.rejectProduct(
      'pend-b',
      'Damaged boot in photograph.',
    );
    expect(await failedReject, isFalse);
    expect(rejectCalls, 1);
    expect(
      controller.actionError,
      'This action conflicts with the current record state.',
    );
    expect(controller.selectedProduct?.id, 'pend-b');
    expect(
      controller.selectedProduct?.approvalStatus,
      ProductApprovalStatus.pending,
    );
    expect(controller.products.map((p) => p.id), ['pend-b']);

    // Retry rejection when backend succeeds -> updates selectedProduct and refreshes list to empty.
    failNextReject = false;
    expect(
      await controller.rejectProduct('pend-b', 'Damaged boot in photograph.'),
      isTrue,
    );
    expect(rejectCalls, 2);
    expect(
      controller.selectedProduct?.approvalStatus,
      ProductApprovalStatus.rejected,
    );
    expect(
      controller.selectedProduct?.rejectionReason,
      'Damaged boot in photograph.',
    );
    expect(controller.actionMessage, 'Product submission rejected.');
    expect(controller.products, isEmpty);

    // Session expiry during approval invokes onSessionExpired.
    expireNextApprove = true;
    controller.selectedProduct = ProductItem.fromJson(pendingItemA);
    expect(await controller.approveProduct('pend-a', '50000.0000'), isFalse);
    expect(expiredMessage, 'Invalid sign-in or expired session.');
  });

  testWidgets(
      'owner opens Product approvals queue, views pending details and image, validates inputs, approves and rejects products',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final storage = MemoryCredentialStore()..pair = _ownerTokenPair();
    final productQueries = <Map<String, String>>[];
    var itemAStatus = 'pending';
    String? itemAPrice;
    var itemBStatus = 'pending';
    String? itemBReason;

    Map<String, Object?> buildItemA() => _productJson(
          id: 'rev-1',
          internalReference: 'SP-REV1',
          name: 'Turbocharger Wastegate Actuator',
          description: 'Calibrated actuator for 2.4L diesel',
          category: 'Engine',
          manufacturerPartNumber: 'TWA-204',
          imageUrl: '/api/v1/products/rev-1/image',
          approvalStatus: itemAStatus,
          sellingPrice: itemAPrice,
          submittedBy: 7,
          submittedByLogin: 'attendant1',
          approvedBy: itemAStatus == 'approved' ? 1 : null,
          approvedByLogin: itemAStatus == 'approved' ? 'owner' : null,
          approvedAt:
              itemAStatus == 'approved' ? '2026-04-18T14:00:00+00:00' : null,
          canEdit: true,
        );

    Map<String, Object?> buildItemB() => _productJson(
          id: 'rev-2',
          internalReference: 'SP-REV2',
          name: 'Unlabelled Fuel Injector',
          description: 'No manufacturer markings',
          category: 'Fuel System',
          manufacturerPartNumber: 'UFI-00',
          approvalStatus: itemBStatus,
          rejectionReason: itemBReason,
          submittedBy: 7,
          submittedByLogin: 'attendant1',
          canEdit: itemBStatus != 'rejected',
        );

    final transport = CallbackTransport((request) async {
      if (request.uri.path == '/api/v1/native/auth/me') {
        return ApiResponse(
          statusCode: 200,
          body: meResponse(role: 'OWNER'),
        );
      }
      if (request.method == 'GET' && request.uri.path == '/api/v1/products') {
        productQueries.add(request.uri.queryParameters);
        final filter = request.uri.queryParameters['approval_status'];
        final all = [buildItemA(), buildItemB()];
        final filtered = filter == null
            ? all
            : all.where((item) => item['approval_status'] == filter).toList();
        return ApiResponse(
          statusCode: 200,
          body: {'items': filtered, 'limit': 50},
        );
      }
      if (request.method == 'GET' &&
          request.uri.path == '/api/v1/products/rev-1') {
        return ApiResponse(statusCode: 200, body: buildItemA());
      }
      if (request.method == 'GET' &&
          request.uri.path == '/api/v1/products/rev-2') {
        return ApiResponse(statusCode: 200, body: buildItemB());
      }
      if (request.method == 'GET' &&
          request.uri.path == '/api/v1/products/rev-1/image') {
        return ApiResponse(statusCode: 200, body: _validPngBytes);
      }
      if (request.method == 'POST' &&
          request.uri.path == '/api/v1/products/rev-1/approve') {
        expect(request.body, {'selling_price': '340000.0000'});
        itemAStatus = 'approved';
        itemAPrice = '340000.0000';
        return ApiResponse(statusCode: 200, body: buildItemA());
      }
      if (request.method == 'POST' &&
          request.uri.path == '/api/v1/products/rev-2/reject') {
        expect(
          request.body,
          {'reason': 'Part lacks verifiable serial number.'},
        );
        itemBStatus = 'rejected';
        itemBReason = 'Part lacks verifiable serial number.';
        return ApiResponse(statusCode: 200, body: buildItemB());
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

    // Navigate to 'Product approvals' in NavigationRail.
    await tester.tap(find.text('Product approvals'));
    await tester.pumpAndSettle();

    expect(find.text('Product approval queue'), findsOneWidget);
    expect(
      productQueries.last,
      {'limit': '50', 'approval_status': 'pending'},
    );
    expect(find.text('Turbocharger Wastegate Actuator'), findsOneWidget);
    expect(find.text('Unlabelled Fuel Injector'), findsOneWidget);
    expect(find.text('Awaiting owner review'), findsNWidgets(2));

    // Open first pending product detail view.
    await tester.tap(find.byKey(const Key('product-card-rev-1')));
    await tester.pumpAndSettle();

    expect(find.text('Submitted by: attendant1'), findsOneWidget);
    expect(find.byKey(const Key('product-detail-image')), findsOneWidget);
    expect(find.byKey(const Key('owner-approval-card')), findsOneWidget);
    expect(find.byKey(const Key('owner-rejection-card')), findsOneWidget);

    // Attempt approval without price -> client-side validation error.
    await tester.ensureVisible(
      find.byKey(const Key('owner-approve-product-button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('owner-approve-product-button')));
    await tester.pumpAndSettle();
    expect(find.text('Enter a selling price.'), findsOneWidget);

    // Enter invalid price with 5 decimal places -> client-side validation error.
    await tester.ensureVisible(
      find.byKey(const Key('owner-selling-price-input')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('owner-selling-price-input')),
      '340000.12345',
    );
    await tester.ensureVisible(
      find.byKey(const Key('owner-approve-product-button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('owner-approve-product-button')));
    await tester.pumpAndSettle();
    expect(
      find.text('Selling price can have no more than four decimal places.'),
      findsOneWidget,
    );

    // Enter valid price and approve.
    await tester.ensureVisible(
      find.byKey(const Key('owner-selling-price-input')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('owner-selling-price-input')),
      '340000.0000',
    );
    await tester.ensureVisible(
      find.byKey(const Key('owner-approve-product-button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('owner-approve-product-button')));
    await tester.pumpAndSettle();

    expect(
      find.text('Product approved and selling price recorded.'),
      findsOneWidget,
    );
    expect(find.text('Selling price: 340000.0000'), findsOneWidget);
    expect(find.text('Approved by: owner'), findsOneWidget);
    // Once approved, rejection card is hidden for non-pending product.
    expect(find.byKey(const Key('owner-rejection-card')), findsNothing);

    // Return to pending review list -> rev-1 is no longer in pending queue; rev-2 remains.
    await tester.ensureVisible(
      find.byKey(const Key('back-to-catalogue-button')),
    );
    await tester.tap(find.byKey(const Key('back-to-catalogue-button')));
    await tester.pumpAndSettle();

    expect(find.text('Turbocharger Wastegate Actuator'), findsNothing);
    expect(find.text('Unlabelled Fuel Injector'), findsOneWidget);

    // Open rev-2 and reject it.
    await tester.tap(find.byKey(const Key('product-card-rev-2')));
    await tester.pumpAndSettle();

    // Attempt rejection without reason -> validation error.
    await tester.ensureVisible(
      find.byKey(const Key('owner-reject-product-button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('owner-reject-product-button')));
    await tester.pumpAndSettle();
    expect(find.text('Enter a rejection reason.'), findsOneWidget);

    await tester.ensureVisible(
      find.byKey(const Key('owner-rejection-reason-input')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('owner-rejection-reason-input')),
      'Part lacks verifiable serial number.',
    );
    await tester.ensureVisible(
      find.byKey(const Key('owner-reject-product-button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('owner-reject-product-button')));
    await tester.pumpAndSettle();

    expect(find.text('Product submission rejected.'), findsOneWidget);
    expect(
      find.text('Rejection reason: Part lacks verifiable serial number.'),
      findsOneWidget,
    );
    // Rejected product locks out both approval and rejection cards and shows read-only notice.
    expect(find.byKey(const Key('owner-approval-card')), findsNothing);
    expect(find.byKey(const Key('owner-rejection-card')), findsNothing);
    expect(find.byKey(const Key('product-readonly-notice')), findsOneWidget);

    // Return to pending review queue -> empty pending queue state is shown without error.
    await tester.ensureVisible(
      find.byKey(const Key('back-to-catalogue-button')),
    );
    await tester.tap(find.byKey(const Key('back-to-catalogue-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('catalogue-empty-card')), findsOneWidget);
    expect(
      find.text('No pending products awaiting review.'),
      findsOneWidget,
    );
  });

  testWidgets('attendant never sees owner approval or rejection cards',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final storage = MemoryCredentialStore()..pair = _ownerTokenPair();
    final transport = CallbackTransport((request) async {
      if (request.method == 'GET' && request.uri.path == '/api/v1/products') {
        return ApiResponse(
          statusCode: 200,
          body: {
            'items': [
              _productJson(
                id: 'att-pend',
                name: 'Attendant Pending Part',
                approvalStatus: 'pending',
                canEdit: true,
              ),
            ],
            'limit': 50,
          },
        );
      }
      if (request.method == 'GET' &&
          request.uri.path == '/api/v1/products/att-pend') {
        return ApiResponse(
          statusCode: 200,
          body: _productJson(
            id: 'att-pend',
            name: 'Attendant Pending Part',
            approvalStatus: 'pending',
            canEdit: true,
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
    final controller = CatalogueController(
      CatalogueRepository(api),
      isOwner: false,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: BmmTheme.light,
        home: Scaffold(
          body: CatalogueScreen(
            controller: controller,
            isOwner: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('product-card-att-pend')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('owner-approval-card')), findsNothing);
    expect(find.byKey(const Key('owner-rejection-card')), findsNothing);
    expect(find.byKey(const Key('detail-edit-form-card')), findsOneWidget);
  });
}
