import 'package:bmm_auto_motors/core/errors/api_exception.dart';
import 'package:bmm_auto_motors/core/network/api_client.dart';
import 'package:bmm_auto_motors/core/network/api_transport.dart';
import 'package:bmm_auto_motors/core/security/credential_store.dart';
import 'package:bmm_auto_motors/features/inventory/inventory_models.dart';
import 'package:bmm_auto_motors/features/inventory/inventory_repository.dart';
import 'package:bmm_auto_motors/features/navigation/app_shell.dart';
import 'package:bmm_auto_motors/features/sales/sales_controller.dart';
import 'package:bmm_auto_motors/features/sales/sales_models.dart';
import 'package:bmm_auto_motors/features/sales/sales_repository.dart';
import 'package:bmm_auto_motors/features/sales/sales_screen.dart';
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

class _FakeInventoryRepository extends InventoryRepository {
  _FakeInventoryRepository() : super(_dummyApiClient());

  String oilStock = '10.0000';

  @override
  Future<InventoryBalanceListResult> listBalances({
    String? query,
    int limit = 50,
    int offset = 0,
  }) async {
    return InventoryBalanceListResult(
      items: [
        InventoryBalanceItem(
          productId: 'prod-1',
          internalReference: 'PRD-0001',
          name: 'Synthetic Oil 5W30',
          manufacturerPartNumber: 'SO-5W30',
          sellingPrice: '850.2500',
          quantityOnHand: oilStock,
          updatedAt: DateTime.utc(2026, 11, 12),
        ),
      ],
      total: 1,
      limit: limit,
      offset: offset,
    );
  }
}

class _FakeSalesRepository extends SalesRepository {
  _FakeSalesRepository(this.inventoryRepo) : super(_dummyApiClient());

  final _FakeInventoryRepository inventoryRepo;
  bool failNextSale = false;
  final List<SaleItem> sales = <SaleItem>[
    SaleItem(
      id: 'sale-0',
      receiptNumber: 'RCPT-20261112-00000001',
      idempotencyKey: 'seed-sale-0',
      status: 'completed',
      totalAmount: '850.2500',
      paymentMethod: PaymentMethod.cash,
      amountTendered: '1000.0000',
      changeGiven: '149.7500',
      paymentReference: null,
      notes: null,
      soldBy: 2,
      soldByLogin: 'attendant@example.test',
      soldAt: DateTime.utc(2026, 11, 12, 10),
      replayed: false,
      lines: const [
        SaleLineItem(
          id: 'line-0',
          lineNumber: 1,
          productId: 'prod-1',
          productInternalReference: 'PRD-0001',
          productName: 'Synthetic Oil 5W30',
          productDescription: '1L bottle',
          manufacturerPartNumber: 'SO-5W30',
          unitPrice: '850.2500',
          quantity: '1.0000',
          lineTotal: '850.2500',
        ),
      ],
    ),
  ];

  @override
  Future<SaleListResult> listSales({
    String? query,
    int limit = 50,
    int offset = 0,
  }) async {
    final q = query?.trim().toLowerCase() ?? '';
    final filtered = sales.where((s) {
      if (q.isEmpty) return true;
      return s.receiptNumber.toLowerCase().contains(q);
    }).toList(growable: false);
    return SaleListResult(
      items: filtered,
      total: filtered.length,
      limit: limit,
      offset: offset,
    );
  }

  @override
  Future<SaleItem> createSale(SaleCreateInput input) async {
    if (failNextSale) {
      failNextSale = false;
      throw const ApiException(409, 'Insufficient stock');
    }
    final qty = input.lines.first.quantity;
    final lineTotalScaled = computeLineTotalScaled4(qty, '850.2500');
    final tenderedScaled = parseScaled4(input.amountTendered);
    final changeScaled = tenderedScaled - lineTotalScaled;

    final nextStock = parseScaled4(inventoryRepo.oilStock) - parseScaled4(qty);
    inventoryRepo.oilStock = formatScaled4(nextStock);

    final item = SaleItem(
      id: 'sale-${sales.length}',
      receiptNumber: 'RCPT-20261113-AABBCCDD',
      idempotencyKey: input.idempotencyKey,
      status: 'completed',
      totalAmount: formatScaled4(lineTotalScaled),
      paymentMethod: input.paymentMethod,
      amountTendered: formatScaled4(tenderedScaled),
      changeGiven: formatScaled4(changeScaled),
      paymentReference: input.paymentReference,
      notes: input.notes,
      soldBy: 2,
      soldByLogin: 'attendant@example.test',
      soldAt: DateTime.utc(2026, 11, 13, 6),
      replayed: false,
      lines: [
        SaleLineItem(
          id: 'line-new',
          lineNumber: 1,
          productId: 'prod-1',
          productInternalReference: 'PRD-0001',
          productName: 'Synthetic Oil 5W30',
          productDescription: '1L bottle',
          manufacturerPartNumber: 'SO-5W30',
          unitPrice: '850.2500',
          quantity: qty,
          lineTotal: formatScaled4(lineTotalScaled),
        ),
      ],
    );
    sales.insert(0, item);
    return item;
  }
}

void main() {
  test('exact decimal scaled-4 arithmetic avoids float rounding errors', () {
    expect(
      formatScaled4(computeLineTotalScaled4('1.5', '850.25')),
      '1275.375',
    );
    expect(
      formatScaled4(computeLineTotalScaled4('1.3333', '100.0005')),
      '133.3307',
    );
    expect(formatMoneyDisplay('1875.3750'), '1875.375');
    expect(formatMoneyDisplay('1000.0000'), '1000.00');
    expect(PaymentMethod.fromWire('cash'), PaymentMethod.cash);
    expect(PaymentMethod.fromWire('mpesa'), PaymentMethod.mpesa);
    expect(
      () => PaymentMethod.fromWire('card'),
      throwsA(isA<ApiException>()),
    );
  });

  test(
      'SalesController retains idempotency key on failure and rotates on success',
      () async {
    final invRepo = _FakeInventoryRepository();
    final salesRepo = _FakeSalesRepository(invRepo)..failNextSale = true;
    final controller = SalesController(
      salesRepo,
      inventoryRepository: invRepo,
    );
    final initialKey = controller.pendingIdempotencyKey;

    final failed = await controller.submitSale(
      paymentMethod: PaymentMethod.cash,
      amountTendered: '1000',
      lines: const [
        SaleLineInput(
          productId: 'prod-1',
          productName: 'Synthetic Oil 5W30',
          unitPrice: '850.2500',
          quantity: '1',
          availableStock: '10.0000',
        ),
      ],
    );
    expect(failed, isNull);
    expect(controller.pendingIdempotencyKey, initialKey);
    expect(controller.actionError, 'Insufficient stock');

    final ok = await controller.submitSale(
      paymentMethod: PaymentMethod.cash,
      amountTendered: '1000',
      lines: const [
        SaleLineInput(
          productId: 'prod-1',
          productName: 'Synthetic Oil 5W30',
          unitPrice: '850.2500',
          quantity: '1',
          availableStock: '10.0000',
        ),
      ],
    );
    expect(ok, isNotNull);
    expect(ok!.idempotencyKey, initialKey);
    expect(controller.pendingIdempotencyKey, isNot(initialKey));
    controller.dispose();
  });

  testWidgets(
      'SalesScreen adds item, completes sale, and opens digital receipt',
      (tester) async {
    final invRepo = _FakeInventoryRepository();
    final salesRepo = _FakeSalesRepository(invRepo);
    final controller = SalesController(
      salesRepo,
      inventoryRepository: invRepo,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SalesScreen(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add item'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Quantity *'),
      '1.5',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Add item'));
    await tester.pumpAndSettle();

    expect(find.text('Synthetic Oil 5W30'), findsOneWidget);
    expect(find.text('1275.375'), findsWidgets);

    await tester.enterText(
      find.widgetWithText(TextField, 'Amount tendered *'),
      '1500',
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Complete sale'));
    await tester.tap(find.text('Complete sale'));
    await tester.pumpAndSettle();

    expect(find.text('Receipt RCPT-20261113-AABBCCDD'), findsOneWidget);
    expect(
      find.text('Digital Receipt: RCPT-20261113-AABBCCDD'),
      findsOneWidget,
    );
    expect(invRepo.oilStock, '8.5');
    controller.dispose();
  });

  testWidgets('AppShell wires Sales and Receipts destinations', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final invRepo = _FakeInventoryRepository();
    final salesRepo = _FakeSalesRepository(invRepo);
    final controller = SalesController(
      salesRepo,
      inventoryRepository: invRepo,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(
          user: const AuthenticatedUser(
            id: 2,
            loginName: 'attendant@example.test',
            role: 'SHOP_ATTENDANT',
          ),
          onLogout: () async {},
          salesController: controller,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Sales'));
    await tester.pumpAndSettle();
    expect(find.text('Complete sale'), findsOneWidget);

    await tester.tap(find.text('Receipts').first);
    await tester.pumpAndSettle();
    expect(find.text('RCPT-20261112-00000001'), findsOneWidget);

    controller.dispose();
  });

  testWidgets(
      'SalesScreen supports manual M-PESA, rejects excess payment, and shows receipt note',
      (tester) async {
    final invRepo = _FakeInventoryRepository();
    final salesRepo = _FakeSalesRepository(invRepo);
    final controller = SalesController(
      salesRepo,
      inventoryRepository: invRepo,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SalesScreen(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add item'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Quantity *'),
      '1',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Add item'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cash'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('M-PESA (Manual)').last);
    await tester.pumpAndSettle();

    expect(find.text('M-PESA amount received *'), findsOneWidget);
    expect(find.text('M-PESA reference / code (optional)'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'M-PESA amount received *'),
      '1000',
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Complete sale'));
    await tester.tap(find.text('Complete sale'));
    await tester.pumpAndSettle();

    expect(
      find.text('Manual M-PESA payment amount must equal the sale total.'),
      findsOneWidget,
    );

    ScaffoldMessenger.of(tester.element(find.byType(SalesScreen)))
        .clearSnackBars();
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'M-PESA amount received *'),
      '850.25',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'M-PESA reference / code (optional)'),
      'QWE789MNO',
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Complete sale'));
    await tester.tap(find.text('Complete sale'));
    await tester.pumpAndSettle();

    expect(
      find.text('Recorded manually; not automatically verified.'),
      findsOneWidget,
    );
    expect(find.text('Payment ref: QWE789MNO'), findsOneWidget);
    controller.dispose();
  });
}
