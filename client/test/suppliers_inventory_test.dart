import 'package:bmm_auto_motors/core/errors/api_exception.dart';
import 'package:bmm_auto_motors/core/network/api_client.dart';
import 'package:bmm_auto_motors/core/network/api_transport.dart';
import 'package:bmm_auto_motors/core/security/credential_store.dart';
import 'package:bmm_auto_motors/features/catalogue/catalogue_models.dart';
import 'package:bmm_auto_motors/features/catalogue/catalogue_repository.dart';
import 'package:bmm_auto_motors/features/inventory/inventory_controller.dart';
import 'package:bmm_auto_motors/features/inventory/inventory_models.dart';
import 'package:bmm_auto_motors/features/inventory/inventory_repository.dart';
import 'package:bmm_auto_motors/features/inventory/inventory_screen.dart';
import 'package:bmm_auto_motors/features/inventory/product_movements_screen.dart';
import 'package:bmm_auto_motors/features/inventory/stock_receiving_screen.dart';
import 'package:bmm_auto_motors/features/navigation/app_shell.dart';
import 'package:bmm_auto_motors/features/suppliers/supplier_controller.dart';
import 'package:bmm_auto_motors/features/suppliers/supplier_models.dart';
import 'package:bmm_auto_motors/features/suppliers/supplier_repository.dart';
import 'package:bmm_auto_motors/features/suppliers/suppliers_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _NoopTransport implements ApiTransport {
  @override
  void close({bool force = false}) {}

  @override
  Future<ApiResponse> send(ApiRequest request) =>
      throw UnimplementedError('Unexpected network call in fake test.');
}

class _NoopCredentialStore implements CredentialStore {
  @override
  Future<void> clear() async {}

  @override
  Future<TokenPair?> read() async => null;

  @override
  Future<void> write(TokenPair pair) async {}
}

ApiClient _dummyApiClient() => ApiClient(
      baseUrl: Uri.parse('https://example.test'),
      transport: _NoopTransport(),
      credentials: _NoopCredentialStore(),
    );

class _FakeSupplierRepository extends SupplierRepository {
  _FakeSupplierRepository() : super(_dummyApiClient());

  final List<SupplierItem> items = <SupplierItem>[
    SupplierItem(
      id: 'sup-1',
      name: 'Nairobi Auto Spares',
      contactPerson: 'Jane Doe',
      phone: '+254700111222',
      email: 'sales@nairobiauto.example',
      notes: 'Filters and belts',
      isActive: true,
      createdAt: DateTime.utc(2026, 11, 1),
      updatedAt: DateTime.utc(2026, 11, 1),
    ),
    SupplierItem(
      id: 'sup-2',
      name: 'Old Inactive Vendor',
      contactPerson: null,
      phone: null,
      email: null,
      notes: null,
      isActive: false,
      createdAt: DateTime.utc(2026, 10, 1),
      updatedAt: DateTime.utc(2026, 10, 15),
    ),
  ];

  @override
  Future<SupplierListResult> listSuppliers({
    String? query,
    bool includeInactive = true,
    int limit = 50,
    int offset = 0,
  }) async {
    final q = query?.trim().toLowerCase() ?? '';
    final filtered = items.where((s) {
      if (!includeInactive && !s.isActive) return false;
      if (q.isEmpty) return true;
      return s.name.toLowerCase().contains(q) ||
          (s.contactPerson?.toLowerCase().contains(q) ?? false);
    }).toList(growable: false);
    return SupplierListResult(
      items: filtered,
      total: filtered.length,
      limit: limit,
      offset: offset,
    );
  }

  @override
  Future<SupplierItem> createSupplier(SupplierCreateInput input) async {
    final created = SupplierItem(
      id: 'sup-${items.length + 1}',
      name: input.name.trim(),
      contactPerson: input.contactPerson,
      phone: input.phone,
      email: input.email,
      notes: input.notes,
      isActive: true,
      createdAt: DateTime.utc(2026, 11, 12),
      updatedAt: DateTime.utc(2026, 11, 12),
    );
    items.add(created);
    return created;
  }

  @override
  Future<SupplierItem> updateSupplier(
    String supplierId,
    SupplierUpdateInput input,
  ) async {
    final index = items.indexWhere((s) => s.id == supplierId);
    final current = items[index];
    final updated = SupplierItem(
      id: current.id,
      name: input.name ?? current.name,
      contactPerson: input.contactPerson,
      phone: input.phone,
      email: input.email,
      notes: input.notes,
      isActive: current.isActive,
      createdAt: current.createdAt,
      updatedAt: DateTime.utc(2026, 11, 12),
    );
    items[index] = updated;
    return updated;
  }

  @override
  Future<SupplierItem> deactivateSupplier(String supplierId) async {
    final index = items.indexWhere((s) => s.id == supplierId);
    final current = items[index];
    final updated = SupplierItem(
      id: current.id,
      name: current.name,
      contactPerson: current.contactPerson,
      phone: current.phone,
      email: current.email,
      notes: current.notes,
      isActive: false,
      createdAt: current.createdAt,
      updatedAt: DateTime.utc(2026, 11, 12),
    );
    items[index] = updated;
    return updated;
  }
}

class _FakeCatalogueRepository extends CatalogueRepository {
  _FakeCatalogueRepository() : super(_dummyApiClient());

  @override
  Future<ProductListResult> listProducts({
    String? query,
    ProductApprovalStatus? approvalStatus,
    int limit = 50,
  }) async {
    return ProductListResult(
      items: [
        ProductItem(
          id: 'prod-1',
          internalReference: 'PRD-0001',
          name: 'Oil Filter X100',
          description: null,
          category: 'Filters',
          manufacturerPartNumber: 'OF-100',
          imageUrl: null,
          sellingPrice: '1250.0000',
          approvalStatus: ProductApprovalStatus.approved,
          submittedBy: 2,
          submittedByLogin: 'attendant@example.test',
          submittedAt: DateTime.utc(2026, 11, 1),
          approvedBy: 1,
          approvedByLogin: 'owner@example.test',
          approvedAt: DateTime.utc(2026, 11, 1),
          rejectionReason: null,
          canEdit: false,
        ),
      ],
      limit: limit,
    );
  }
}

class _FakeInventoryRepository extends InventoryRepository {
  _FakeInventoryRepository() : super(_dummyApiClient());

  String balanceQty = '10.0000';
  final List<GoodsReceiptCreateInput> postedReceipts =
      <GoodsReceiptCreateInput>[];
  bool failNextReceipt = false;
  int receiptDelayMs = 0;

  final List<StockMovementItem> movements = <StockMovementItem>[
    StockMovementItem(
      id: 'mov-1',
      productId: 'prod-1',
      movementType: 'receipt',
      quantityDelta: '10.0000',
      sourceType: 'goods_receipt',
      sourceId: 'rcp-1',
      sourceReference: 'DN-100',
      supplierName: 'Nairobi Auto Spares',
      reason: null,
      actorId: 2,
      actorLogin: 'attendant@example.test',
      createdAt: DateTime.utc(2026, 11, 10, 9),
    ),
  ];

  @override
  Future<InventoryBalanceListResult> listBalances({
    String? query,
    int limit = 50,
    int offset = 0,
  }) async {
    final q = query?.trim().toLowerCase() ?? '';
    final all = [
      InventoryBalanceItem(
        productId: 'prod-1',
        internalReference: 'PRD-0001',
        name: 'Oil Filter X100',
        manufacturerPartNumber: 'OF-100',
        sellingPrice: '1250.0000',
        quantityOnHand: balanceQty,
        updatedAt: DateTime.utc(2026, 11, 10, 9),
      ),
    ];
    final filtered = all.where((item) {
      if (q.isEmpty) return true;
      return item.name.toLowerCase().contains(q) ||
          (item.manufacturerPartNumber?.toLowerCase().contains(q) ?? false);
    }).toList(growable: false);
    return InventoryBalanceListResult(
      items: filtered,
      total: filtered.length,
      limit: limit,
      offset: offset,
    );
  }

  @override
  Future<ProductMovementsResult> getProductMovements(
    String productId, {
    int limit = 50,
    int offset = 0,
  }) async {
    return ProductMovementsResult(
      productId: 'prod-1',
      internalReference: 'PRD-0001',
      name: 'Oil Filter X100',
      manufacturerPartNumber: 'OF-100',
      quantityOnHand: balanceQty,
      items: List<StockMovementItem>.unmodifiable(movements),
      total: movements.length,
      limit: limit,
      offset: offset,
    );
  }

  @override
  Future<GoodsReceiptItem> createGoodsReceipt(
    GoodsReceiptCreateInput input,
  ) async {
    if (receiptDelayMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: receiptDelayMs));
    }
    if (failNextReceipt) {
      failNextReceipt = false;
      throw const ApiException(500, 'Simulated server error');
    }
    postedReceipts.add(input);
    final added = double.parse(input.lines.first.quantity);
    final next = double.parse(balanceQty) + added;
    balanceQty = next.toStringAsFixed(4);
    return GoodsReceiptItem(
      id: 'rcp-${postedReceipts.length + 1}',
      supplierId: input.supplierId,
      supplierName: input.supplierId != null ? 'Nairobi Auto Spares' : null,
      unlistedSupplierName: input.unlistedSupplierName,
      deliveryNoteReference: input.deliveryNoteReference,
      notes: input.notes,
      idempotencyKey: input.idempotencyKey,
      receivedByLogin: 'attendant@example.test',
      receivedAt: DateTime.utc(2026, 11, 12, 10),
      replayed: false,
    );
  }

  @override
  Future<StockAdjustmentResult> createStockAdjustment({
    required String productId,
    required String quantityDelta,
    required String reason,
  }) async {
    final delta = double.parse(quantityDelta);
    final next = double.parse(balanceQty) + delta;
    balanceQty = next.toStringAsFixed(4);
    final mov = StockMovementItem(
      id: 'mov-${movements.length + 1}',
      productId: productId,
      movementType: 'adjustment',
      quantityDelta: delta.toStringAsFixed(4),
      sourceType: 'stock_adjustment',
      sourceId: 'adj-1',
      sourceReference: 'ADJ-001',
      supplierName: null,
      reason: reason,
      actorId: 1,
      actorLogin: 'owner@example.test',
      createdAt: DateTime.utc(2026, 11, 12, 11),
    );
    movements.insert(0, mov);
    return StockAdjustmentResult(
      movement: mov,
      productId: productId,
      quantityOnHand: balanceQty,
    );
  }
}

void main() {
  test('decimal validators and display formatter handle integers and fractions',
      () {
    expect(validatePositiveDecimalInput('5', fieldLabel: 'a quantity'), isNull);
    expect(
      validatePositiveDecimalInput('2.25', fieldLabel: 'a quantity'),
      isNull,
    );
    expect(
      validatePositiveDecimalInput('0', fieldLabel: 'a quantity'),
      isNotNull,
    );
    expect(
      validatePositiveDecimalInput('-1', fieldLabel: 'a quantity'),
      isNotNull,
    );
    expect(
      validateNonNegativeDecimalInput('0', fieldLabel: 'a unit cost'),
      isNull,
    );
    expect(
      validateNonNegativeDecimalInput('-0.01', fieldLabel: 'a unit cost'),
      isNotNull,
    );
    expect(validateSignedNonZeroDecimalInput('-2.5'), isNull);
    expect(validateSignedNonZeroDecimalInput('3'), isNull);
    expect(validateSignedNonZeroDecimalInput('0'), isNotNull);
    expect(formatQuantityDisplay('10.0000'), '10');
    expect(formatQuantityDisplay('12.5000'), '12.5');
    expect(formatQuantityDisplay('0.0000'), '0');
  });

  test(
      'InventoryController retains idempotency key on failure and rotates on success',
      () async {
    final invRepo = _FakeInventoryRepository()..failNextReceipt = true;
    final controller = InventoryController(invRepo);
    final initialKey = controller.pendingIdempotencyKey;

    final failed = await controller.submitGoodsReceipt(
      lines: const [
        GoodsReceiptLineInput(
          productId: 'prod-1',
          productName: 'Oil Filter X100',
          quantity: '2',
          unitCost: '100',
        ),
      ],
    );
    expect(failed, isNull);
    expect(controller.pendingIdempotencyKey, initialKey);
    expect(controller.actionError, 'Simulated server error');

    final succeeded = await controller.submitGoodsReceipt(
      lines: const [
        GoodsReceiptLineInput(
          productId: 'prod-1',
          productName: 'Oil Filter X100',
          quantity: '2',
          unitCost: '100',
        ),
      ],
    );
    expect(succeeded, isNotNull);
    expect(succeeded!.idempotencyKey, initialKey);
    expect(controller.pendingIdempotencyKey, isNot(initialKey));
    controller.dispose();
  });

  testWidgets('SuppliersScreen lists, filters, and creates suppliers',
      (tester) async {
    final repo = _FakeSupplierRepository();
    final controller = SupplierController(repo, isOwner: true);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SuppliersScreen(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Nairobi Auto Spares'), findsOneWidget);
    expect(find.text('Old Inactive Vendor'), findsOneWidget);

    await tester.tap(find.text('Add supplier'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Supplier name *'),
      'Mombasa Motors Supply',
    );
    await tester.tap(find.text('Save supplier'));
    await tester.pumpAndSettle();

    expect(find.text('Mombasa Motors Supply'), findsOneWidget);
    controller.dispose();
  });

  testWidgets('StockReceivingScreen adds line and submits receipt',
      (tester) async {
    final invRepo = _FakeInventoryRepository();
    final controller = InventoryController(
      invRepo,
      catalogueRepository: _FakeCatalogueRepository(),
      supplierRepository: _FakeSupplierRepository(),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StockReceivingScreen(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add product'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Quantity received *'),
      '3.5',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Purchase unit cost *'),
      '750',
    );
    await tester.tap(find.text('Add line'));
    await tester.pumpAndSettle();

    expect(find.text('Oil Filter X100'), findsOneWidget);

    await tester.tap(find.text('Submit stock receipt'));
    await tester.pumpAndSettle();

    expect(invRepo.postedReceipts.length, 1);
    expect(invRepo.postedReceipts.first.lines.first.quantity, '3.5');
    expect(invRepo.balanceQty, '13.5000');
    controller.dispose();
  });

  testWidgets(
      'InventoryScreen opens ProductMovementsScreen and enforces owner-only Adjust stock',
      (tester) async {
    final invRepo = _FakeInventoryRepository();
    final ownerController = InventoryController(invRepo, isOwner: true);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InventoryScreen(controller: ownerController),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Oil Filter X100'), findsOneWidget);
    expect(find.text('On hand: 10'), findsOneWidget);

    await tester.tap(find.text('Oil Filter X100'));
    await tester.pumpAndSettle();

    expect(find.text('Receipt'), findsOneWidget);
    expect(find.text('Adjust stock'), findsOneWidget);

    await tester.tap(find.text('Adjust stock'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Quantity delta (e.g. -2 or 5) *'),
      '-2',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Reason *'),
      'Shelf count variance',
    );
    await tester.tap(find.text('Post adjustment'));
    await tester.pumpAndSettle();

    expect(find.text('Adjustment'), findsOneWidget);
    expect(find.text('On hand: 8'), findsOneWidget);
    ownerController.dispose();

    // Attendant does not see Adjust stock button
    final attendantController = InventoryController(invRepo, isOwner: false);
    await tester.pumpWidget(
      MaterialApp(
        key: const ValueKey('attendant-movements-app'),
        home: ProductMovementsScreen(
          controller: attendantController,
          productId: 'prod-1',
          productName: 'Oil Filter X100',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Adjust stock'), findsNothing);
    attendantController.dispose();
  });

  testWidgets(
      'AppShell wires Suppliers, Inventory, and Stock receiving screens',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final supplierController =
        SupplierController(_FakeSupplierRepository(), isOwner: true);
    final inventoryController = InventoryController(
      _FakeInventoryRepository(),
      catalogueRepository: _FakeCatalogueRepository(),
      supplierRepository: _FakeSupplierRepository(),
      isOwner: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(
          user: const AuthenticatedUser(
            id: 1,
            loginName: 'owner@example.test',
            role: 'OWNER',
          ),
          onLogout: () async {},
          supplierController: supplierController,
          inventoryController: inventoryController,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Suppliers'));
    await tester.pumpAndSettle();
    expect(find.text('Nairobi Auto Spares'), findsOneWidget);

    await tester.tap(find.text('Inventory'));
    await tester.pumpAndSettle();
    expect(find.text('Oil Filter X100'), findsOneWidget);

    await tester.tap(find.text('Stock receiving'));
    await tester.pumpAndSettle();
    expect(find.text('Receive incoming stock'), findsOneWidget);

    supplierController.dispose();
    inventoryController.dispose();
  });
}
