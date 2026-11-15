import 'dart:async';

import 'package:bmm_auto_motors/core/errors/api_exception.dart';
import 'package:bmm_auto_motors/core/network/api_client.dart';
import 'package:bmm_auto_motors/core/network/api_transport.dart';
import 'package:bmm_auto_motors/core/security/credential_store.dart';
import 'package:bmm_auto_motors/features/navigation/app_shell.dart';
import 'package:bmm_auto_motors/features/reports/dashboard_screen.dart';
import 'package:bmm_auto_motors/features/reports/reports_controller.dart';
import 'package:bmm_auto_motors/features/reports/reports_models.dart';
import 'package:bmm_auto_motors/features/reports/reports_repository.dart';
import 'package:bmm_auto_motors/features/reports/reports_screen.dart';
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

class _FakeReportsRepository extends ReportsRepository {
  _FakeReportsRepository() : super(_dummyApiClient());

  ApiException? nextDashboardError;
  ApiException? nextReportsError;
  ApiException? nextBalancesError;
  ApiException? nextMovementsError;
  int dashboardFetches = 0;
  int salesFetches = 0;
  int balancesFetches = 0;
  int movementsFetches = 0;

  @override
  Future<DashboardSummary> fetchDashboard() async {
    dashboardFetches += 1;
    if (nextDashboardError != null) {
      final err = nextDashboardError!;
      nextDashboardError = null;
      throw err;
    }
    return const DashboardSummary(
      timezone: 'Africa/Nairobi',
      businessDate: '2026-11-13',
      todayCompletedSalesCount: 4,
      todaySalesTotal: '5250.5000',
      todayCashTotal: '3250.5000',
      todayMpesaTotal: '2000.0000',
      approvedProductsCount: 12,
      zeroStockProductsCount: 2,
    );
  }

  @override
  Future<SalesReportSummary> fetchSalesReport({
    String? fromDate,
    String? toDate,
  }) async {
    salesFetches += 1;
    if (nextReportsError != null) {
      final err = nextReportsError!;
      nextReportsError = null;
      throw err;
    }
    return SalesReportSummary(
      timezone: 'Africa/Nairobi',
      fromDate: fromDate ?? '2026-11-01',
      toDate: toDate ?? '2026-11-13',
      completedSalesCount: 18,
      totalSalesValue: '24500.0000',
      cashTotal: '14500.0000',
      mpesaTotal: '10000.0000',
      mpesaNote:
          'Manually recorded M-PESA amounts and references are not automatically verified.',
    );
  }

  @override
  Future<ReportInventoryBalanceListResult> fetchInventoryBalances({
    String? query,
    int limit = 50,
    int offset = 0,
  }) async {
    balancesFetches += 1;
    if (nextBalancesError != null) {
      final err = nextBalancesError!;
      nextBalancesError = null;
      throw err;
    }
    return ReportInventoryBalanceListResult(
      items: [
        ReportInventoryBalanceItem(
          productId: 'prod-1',
          internalReference: 'PRD-0001',
          name: 'Synthetic Oil 5W30',
          manufacturerPartNumber: 'SO-5W30',
          unitOfMeasure: null,
          sellingPrice: '850.2500',
          quantityOnHand: '7.0000',
          updatedAt: DateTime.utc(2026, 11, 13, 10),
        ),
      ],
      total: 1,
      limit: limit,
      offset: offset,
    );
  }

  @override
  Future<ReportStockMovementListResult> fetchInventoryMovements({
    String? fromDate,
    String? toDate,
    String? query,
    int limit = 50,
    int offset = 0,
  }) async {
    movementsFetches += 1;
    if (nextMovementsError != null) {
      final err = nextMovementsError!;
      nextMovementsError = null;
      throw err;
    }
    return ReportStockMovementListResult(
      timezone: 'Africa/Nairobi',
      items: [
        ReportStockMovementItem(
          id: 'mov-1',
          productId: 'prod-1',
          productInternalReference: 'PRD-0001',
          productName: 'Synthetic Oil 5W30',
          movementType: 'sale',
          quantityDelta: '-2.0000',
          sourceType: 'sale',
          sourceId: 'sale-1',
          sourceReference: 'RCPT-20261113-00000001',
          reason: null,
          actorId: 2,
          actorLogin: 'attendant@example.test',
          createdAt: DateTime.utc(2026, 11, 13, 10),
        ),
      ],
      total: 1,
      limit: limit,
      offset: offset,
    );
  }
}

void main() {
  testWidgets(
      'DashboardScreen renders metrics, handles error retry, and refreshes',
      (tester) async {
    final repo = _FakeReportsRepository()
      ..nextDashboardError =
          const ApiException(500, 'Dashboard temporarily unavailable.');
    final controller = DashboardController(repo);
    String? navigatedTo;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DashboardScreen(
            controller: controller,
            isOwner: true,
            onNavigateTo: (label) => navigatedTo = label,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Dashboard temporarily unavailable.'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('KES 5250.50'), findsOneWidget);
    expect(find.text('KES 3250.50'), findsOneWidget);
    expect(find.text('KES 2000.00'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);

    await tester.tap(find.byTooltip('Refresh dashboard'));
    await tester.pumpAndSettle();
    expect(repo.dashboardFetches, 3);

    await tester.tap(find.text('Open inventory'));
    expect(navigatedTo, 'Inventory');
    controller.dispose();
  });

  testWidgets('Attendant sees Dashboard but cannot access Reports',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = _FakeReportsRepository();
    final dashController = DashboardController(repo);
    final reportsController = ReportsController(repo, isOwner: false);

    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(
          user: const AuthenticatedUser(
            id: 2,
            loginName: 'attendant@example.test',
            role: 'SHOP_ATTENDANT',
          ),
          onLogout: () async {},
          dashboardController: dashController,
          reportsController: reportsController,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('KES 5250.50'), findsOneWidget);
    expect(find.text('Reports'), findsNothing);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReportsScreen(controller: reportsController),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Owner access is required to view operational reports.'),
      findsOneWidget,
    );
    dashController.dispose();
    reportsController.dispose();
  });

  testWidgets(
      'Owner opens Reports from AppShell, validates dates, and renders sales & inventory reports',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = _FakeReportsRepository();
    final dashController = DashboardController(repo);
    final reportsController = ReportsController(repo, isOwner: true);

    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(
          user: const AuthenticatedUser(
            id: 1,
            loginName: 'owner@example.test',
            role: 'OWNER',
          ),
          onLogout: () async {},
          dashboardController: dashController,
          reportsController: reportsController,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Reports'));
    await tester.pumpAndSettle();

    expect(
      find.text('Sales Summary (2026-11-01 to 2026-11-13)'),
      findsOneWidget,
    );
    expect(find.text('Total sales: KES 24500.00'), findsOneWidget);
    expect(find.text('Cash total: KES 14500.00'), findsOneWidget);
    expect(find.text('M-PESA (Manual) total: KES 10000.00'), findsOneWidget);
    expect(find.text('Synthetic Oil 5W30'), findsOneWidget);
    expect(find.text('Synthetic Oil 5W30 (SALE)'), findsOneWidget);

    // Invalid date range validation
    await tester.enterText(
      find.widgetWithText(TextField, 'From (YYYY-MM-DD)'),
      '2026-11-14',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'To (YYYY-MM-DD)'),
      '2026-11-10',
    );
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(find.text('Start date cannot be after end date.'), findsOneWidget);

    // Valid date range apply
    await tester.enterText(
      find.widgetWithText(TextField, 'From (YYYY-MM-DD)'),
      '2026-11-05',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'To (YYYY-MM-DD)'),
      '2026-11-13',
    );
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(
      find.text('Sales Summary (2026-11-05 to 2026-11-13)'),
      findsOneWidget,
    );

    dashController.dispose();
    reportsController.dispose();
  });

  test('DashboardController and ReportsController handle 401 expiry', () async {
    final repo = _FakeReportsRepository()
      ..nextDashboardError = const ApiException(401, 'Session expired.')
      ..nextReportsError = const ApiException(401, 'Session expired.');
    String? dashExpired;
    String? reportsExpired;

    final dashCtrl = DashboardController(
      repo,
      onSessionExpired: (m) => dashExpired = m,
    );
    final repCtrl = ReportsController(
      repo,
      isOwner: true,
      onSessionExpired: (m) => reportsExpired = m,
    );

    await dashCtrl.loadDashboard();
    await repCtrl.loadReports();

    expect(dashExpired, 'Session expired.');
    expect(reportsExpired, 'Session expired.');
    dashCtrl.dispose();
    repCtrl.dispose();
  });

  test(
      'validateReportDateRange rejects impossible calendar dates and checks leap years',
      () {
    expect(validateReportDateRange('2024-02-29', '2024-02-29'), isNull);
    expect(validateReportDateRange('2000-02-29', '2000-03-01'), isNull);
    expect(
      validateReportDateRange('2026-02-29', '2026-03-01'),
      'Enter valid calendar dates.',
    );
    expect(
      validateReportDateRange('1900-02-29', '1900-03-01'),
      'Enter valid calendar dates.',
    );
    expect(
      validateReportDateRange('2026-02-31', '2026-03-01'),
      'Enter valid calendar dates.',
    );
    expect(
      validateReportDateRange('2026-04-31', '2026-05-01'),
      'Enter valid calendar dates.',
    );
    expect(
      validateReportDateRange('2026-13-01', '2026-13-02'),
      'Enter valid calendar dates.',
    );
    expect(
      validateReportDateRange('2026-05-10', '2026-05-01'),
      'Start date cannot be after end date.',
    );
  });

  testWidgets(
      'ReportsScreen hides empty states on initial failure and recovers on Retry',
      (tester) async {
    final repo = _FakeReportsRepository()
      ..nextReportsError = const ApiException(500, 'Reports offline.');
    final controller = ReportsController(repo, isOwner: true);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReportsScreen(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Reports offline.'), findsOneWidget);
    expect(
      find.text('No approved products in inventory report.'),
      findsNothing,
    );
    expect(
      find.text('No stock movements found for this range.'),
      findsNothing,
    );

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('Synthetic Oil 5W30'), findsOneWidget);
    expect(find.text('Showing 1 of 1'), findsNWidgets(2));
    controller.dispose();
  });

  testWidgets(
      'ReportsScreen Load More appends without duplicates and handles pagination errors',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = _PagedReportsRepository();
    final controller = ReportsController(repo, isOwner: true);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReportsScreen(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Showing 1 of 2'), findsNWidgets(2));
    expect(find.text('Load more balances'), findsOneWidget);
    expect(find.text('Load more movements'), findsOneWidget);

    // Trigger balance pagination error; existing row stays visible
    repo.nextBalancePageError = const ApiException(500, 'Balance page error.');
    await tester.ensureVisible(find.text('Load more balances'));
    await tester.tap(find.text('Load more balances'));
    await tester.pumpAndSettle();
    expect(find.text('Balance page error.'), findsOneWidget);
    expect(find.text('Item A'), findsOneWidget);

    // Retry balance pagination cleanly (also ignores duplicate Item A)
    await tester.ensureVisible(find.text('Load more balances'));
    await tester.tap(find.text('Load more balances'));
    await tester.pumpAndSettle();
    expect(find.text('Showing 2 of 2'), findsOneWidget);
    expect(find.text('Item A'), findsOneWidget);
    expect(find.text('Item B'), findsOneWidget);
    expect(find.text('All balances loaded'), findsOneWidget);

    // Load more movements
    await tester.ensureVisible(find.text('Load more movements'));
    await tester.tap(find.text('Load more movements'));
    await tester.pumpAndSettle();
    expect(find.text('Showing 2 of 2'), findsNWidgets(2));
    expect(find.text('All movements loaded'), findsOneWidget);

    controller.dispose();
  });

  test(
      'ReportsController generation guard drops stale loadReports and pagination',
      () async {
    final repo = _ConcurrentReportsRepository();
    final controller = ReportsController(repo, isOwner: true);

    // First load populates page 1 (1 of 2)
    await controller.loadReports(
      nextFromDate: '2026-11-01',
      nextToDate: '2026-11-10',
    );
    expect(controller.balances.length, 1);

    // Start pagination, then supersede with a newer loadReports before page 2 resolves
    repo.holdNextBalancePage = true;
    final stalePagination = controller.loadMoreBalances();
    await controller.loadReports(
      nextFromDate: '2026-11-11',
      nextToDate: '2026-11-13',
    );
    repo.releaseBalancePage();
    await stalePagination;

    expect(controller.salesReport?.fromDate, '2026-11-11');
    expect(controller.balances.length, 1);
    controller.dispose();
  });

  testWidgets(
      'Sales failure does not block inventory or movements and retries independently',
      (tester) async {
    final repo = _FakeReportsRepository()
      ..nextReportsError = const ApiException(500, 'Sales service down.');
    final controller = ReportsController(repo, isOwner: true);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ReportsScreen(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sales service down.'), findsOneWidget);
    expect(find.text('Synthetic Oil 5W30'), findsOneWidget);
    expect(find.text('Synthetic Oil 5W30 (SALE)'), findsOneWidget);
    expect(repo.salesFetches, 1);
    expect(repo.balancesFetches, 1);
    expect(repo.movementsFetches, 1);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(
      find.text('Sales Summary (2026-11-01 to 2026-11-13)'),
      findsOneWidget,
    );
    expect(repo.salesFetches, 2);
    expect(repo.balancesFetches, 1);
    expect(repo.movementsFetches, 1);
    controller.dispose();
  });

  testWidgets(
      'Inventory failure does not block sales or movements and retries independently',
      (tester) async {
    final repo = _FakeReportsRepository()
      ..nextBalancesError = const ApiException(500, 'Balances service down.');
    final controller = ReportsController(repo, isOwner: true);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ReportsScreen(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Balances service down.'), findsOneWidget);
    expect(
      find.text('Sales Summary (2026-11-01 to 2026-11-13)'),
      findsOneWidget,
    );
    expect(find.text('Synthetic Oil 5W30 (SALE)'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('Synthetic Oil 5W30'), findsOneWidget);
    expect(repo.salesFetches, 1);
    expect(repo.balancesFetches, 2);
    expect(repo.movementsFetches, 1);
    controller.dispose();
  });

  testWidgets(
      'Movement failure does not block sales or inventory and retries independently',
      (tester) async {
    final repo = _FakeReportsRepository()
      ..nextMovementsError = const ApiException(500, 'Movements service down.');
    final controller = ReportsController(repo, isOwner: true);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ReportsScreen(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();

    expect(controller.movementsErrorMessage, 'Movements service down.');
    expect(
      find.text('Sales Summary (2026-11-01 to 2026-11-13)'),
      findsOneWidget,
    );
    expect(find.text('Synthetic Oil 5W30'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Movements service down.'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Movements service down.'), findsOneWidget);

    await tester.ensureVisible(find.text('Retry'));
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Synthetic Oil 5W30 (SALE)'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Synthetic Oil 5W30 (SALE)'), findsOneWidget);
    expect(repo.salesFetches, 1);
    expect(repo.balancesFetches, 1);
    expect(repo.movementsFetches, 2);
    controller.dispose();
  });

  test(
      'Invalid date submission invalidates in-flight report and pagination requests',
      () async {
    final repo = _ConcurrentReportsRepository();
    final controller = ReportsController(repo, isOwner: true);

    await controller.loadReports(
      nextFromDate: '2026-11-01',
      nextToDate: '2026-11-10',
    );
    expect(controller.balances.length, 1);

    repo.holdNextSales = true;
    repo.holdNextBalancePage = true;
    final staleLoad = controller.loadReports(
      nextFromDate: '2026-11-05',
      nextToDate: '2026-11-10',
    );
    final stalePage = controller.loadMoreBalances();

    await controller.loadReports(
      nextFromDate: '2026-02-31',
      nextToDate: '2026-03-01',
    );
    expect(controller.errorMessage, 'Enter valid calendar dates.');
    expect(controller.isLoading, isFalse);
    expect(controller.isLoadingMoreBalances, isFalse);

    repo.releaseSales();
    repo.releaseBalancePage();
    await Future.wait([staleLoad, stalePage]);

    expect(controller.errorMessage, 'Enter valid calendar dates.');
    expect(controller.salesReport?.fromDate, '2026-11-01');
    expect(controller.balances.length, 1);
    controller.dispose();
  });

  test('DashboardController drops out-of-order concurrent responses', () async {
    final repo = _OutOfOrderDashboardRepository();
    final controller = DashboardController(repo);

    final firstCompleter = Completer<DashboardSummary>();
    final secondCompleter = Completer<DashboardSummary>();
    repo.queue([firstCompleter.future, secondCompleter.future]);

    final firstCall = controller.loadDashboard();
    final secondCall = controller.loadDashboard();

    secondCompleter.complete(
      const DashboardSummary(
        timezone: 'Africa/Nairobi',
        businessDate: '2026-11-13',
        todayCompletedSalesCount: 9,
        todaySalesTotal: '9000.0000',
        todayCashTotal: '5000.0000',
        todayMpesaTotal: '4000.0000',
        approvedProductsCount: 15,
        zeroStockProductsCount: 1,
      ),
    );
    await secondCall;

    firstCompleter.complete(
      const DashboardSummary(
        timezone: 'Africa/Nairobi',
        businessDate: '2026-11-12',
        todayCompletedSalesCount: 1,
        todaySalesTotal: '100.0000',
        todayCashTotal: '100.0000',
        todayMpesaTotal: '0.0000',
        approvedProductsCount: 5,
        zeroStockProductsCount: 3,
      ),
    );
    await firstCall;

    expect(controller.summary?.todayCompletedSalesCount, 9);
    expect(controller.summary?.todaySalesTotal, '9000.0000');
    expect(controller.isLoading, isFalse);
    controller.dispose();
  });

  testWidgets(
      'Movement pagination handles errors cleanly and recovers on retry',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = _PagedReportsRepository();
    final controller = ReportsController(repo, isOwner: true);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ReportsScreen(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();

    repo.nextMovementPageError =
        const ApiException(500, 'Movement page error.');
    await tester.ensureVisible(find.text('Load more movements'));
    await tester.tap(find.text('Load more movements'));
    await tester.pumpAndSettle();

    expect(find.text('Movement page error.'), findsOneWidget);
    expect(find.text('Item A (RECEIPT)'), findsOneWidget);
    expect(find.text('Showing 1 of 2'), findsNWidgets(2));

    await tester.ensureVisible(find.text('Load more movements'));
    await tester.tap(find.text('Load more movements'));
    await tester.pumpAndSettle();

    expect(find.text('Movement page error.'), findsNothing);
    expect(find.text('Item B (SALE)'), findsOneWidget);
    expect(find.text('Showing 2 of 2'), findsOneWidget);
    expect(find.text('All movements loaded'), findsOneWidget);
    controller.dispose();
  });

  test('Session expiration during pagination invokes onSessionExpired',
      () async {
    final repo = _PagedReportsRepository();
    final expiredMessages = <String>[];
    final controller = ReportsController(
      repo,
      isOwner: true,
      onSessionExpired: expiredMessages.add,
    );

    await controller.loadReports();
    repo.nextBalancePageError = const ApiException(401, 'Token expired.');
    await controller.loadMoreBalances();

    repo.nextMovementPageError = const ApiException(401, 'Session timed out.');
    await controller.loadMoreMovements();

    // Session-expiration callbacks are deduplicated within a single report generation.
    expect(expiredMessages, ['Token expired.']);
    expect(controller.isLoadingMoreBalances, isFalse);
    expect(controller.isLoadingMoreMovements, isFalse);

    // A subsequent loadReports() generation can trigger a fresh callback.
    await controller.loadReports();
    repo.nextMovementPageError = const ApiException(401, 'Session timed out.');
    await controller.loadMoreMovements();

    expect(expiredMessages, ['Token expired.', 'Session timed out.']);
    expect(controller.isLoadingMoreMovements, isFalse);
    controller.dispose();
  });

  testWidgets('Stale date-validation error clears when refreshing reports',
      (tester) async {
    final repo = _FakeReportsRepository();
    final controller = ReportsController(repo, isOwner: true);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ReportsScreen(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'From (YYYY-MM-DD)'),
      '2026-02-31',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'To (YYYY-MM-DD)'),
      '2026-03-01',
    );
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(find.text('Enter valid calendar dates.'), findsOneWidget);

    await tester.tap(find.byTooltip('Refresh reports'));
    await tester.pumpAndSettle();
    expect(find.text('Enter valid calendar dates.'), findsNothing);
    controller.dispose();
  });

  testWidgets(
      'Date fields populate after successful sales retry without overwriting active edits',
      (tester) async {
    final repo = _FakeReportsRepository()
      ..nextReportsError = const ApiException(500, 'Sales service down.');
    final controller = ReportsController(repo, isOwner: true);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ReportsScreen(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();

    final fromField = tester.widget<TextField>(
      find.widgetWithText(TextField, 'From (YYYY-MM-DD)'),
    );
    final toField = tester.widget<TextField>(
      find.widgetWithText(TextField, 'To (YYYY-MM-DD)'),
    );
    expect(fromField.controller!.text, isEmpty);
    expect(toField.controller!.text, isEmpty);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(fromField.controller!.text, '2026-11-01');
    expect(toField.controller!.text, '2026-11-13');

    // User edits From field; a subsequent retry must not overwrite it.
    await tester.enterText(
      find.widgetWithText(TextField, 'From (YYYY-MM-DD)'),
      '2026-11-05',
    );
    await controller.retrySalesReport();
    await tester.pumpAndSettle();
    expect(fromField.controller!.text, '2026-11-05');
    controller.dispose();
  });
}

class _PagedReportsRepository extends _FakeReportsRepository {
  ApiException? nextBalancePageError;
  ApiException? nextMovementPageError;

  @override
  Future<ReportInventoryBalanceListResult> fetchInventoryBalances({
    String? query,
    int limit = 50,
    int offset = 0,
  }) async {
    if (offset > 0 && nextBalancePageError != null) {
      final err = nextBalancePageError!;
      nextBalancePageError = null;
      throw err;
    }
    if (offset == 0) {
      return const ReportInventoryBalanceListResult(
        items: [
          ReportInventoryBalanceItem(
            productId: 'p-1',
            internalReference: 'PRD-1',
            name: 'Item A',
            manufacturerPartNumber: null,
            unitOfMeasure: null,
            sellingPrice: '100.0000',
            quantityOnHand: '5.0000',
            updatedAt: null,
          ),
        ],
        total: 2,
        limit: 50,
        offset: 0,
      );
    }
    return const ReportInventoryBalanceListResult(
      items: [
        // Include duplicate p-1 to verify deduplication
        ReportInventoryBalanceItem(
          productId: 'p-1',
          internalReference: 'PRD-1',
          name: 'Item A',
          manufacturerPartNumber: null,
          unitOfMeasure: null,
          sellingPrice: '100.0000',
          quantityOnHand: '5.0000',
          updatedAt: null,
        ),
        ReportInventoryBalanceItem(
          productId: 'p-2',
          internalReference: 'PRD-2',
          name: 'Item B',
          manufacturerPartNumber: null,
          unitOfMeasure: null,
          sellingPrice: '200.0000',
          quantityOnHand: '3.0000',
          updatedAt: null,
        ),
      ],
      total: 2,
      limit: 50,
      offset: 1,
    );
  }

  @override
  Future<ReportStockMovementListResult> fetchInventoryMovements({
    String? fromDate,
    String? toDate,
    String? query,
    int limit = 50,
    int offset = 0,
  }) async {
    if (offset > 0 && nextMovementPageError != null) {
      final err = nextMovementPageError!;
      nextMovementPageError = null;
      throw err;
    }
    if (offset == 0) {
      return ReportStockMovementListResult(
        timezone: 'Africa/Nairobi',
        items: [
          ReportStockMovementItem(
            id: 'm-1',
            productId: 'p-1',
            productInternalReference: 'PRD-1',
            productName: 'Item A',
            movementType: 'receipt',
            quantityDelta: '5.0000',
            sourceType: 'goods_receipt',
            sourceId: 'r-1',
            sourceReference: 'GR-1',
            reason: null,
            actorId: 1,
            actorLogin: 'owner@example.test',
            createdAt: DateTime.utc(2026, 11, 13, 9),
          ),
        ],
        total: 2,
        limit: 50,
        offset: 0,
      );
    }
    return ReportStockMovementListResult(
      timezone: 'Africa/Nairobi',
      items: [
        ReportStockMovementItem(
          id: 'm-2',
          productId: 'p-2',
          productInternalReference: 'PRD-2',
          productName: 'Item B',
          movementType: 'sale',
          quantityDelta: '-1.0000',
          sourceType: 'sale',
          sourceId: 's-1',
          sourceReference: 'RCPT-1',
          reason: null,
          actorId: 2,
          actorLogin: 'attendant@example.test',
          createdAt: DateTime.utc(2026, 11, 13, 10),
        ),
      ],
      total: 2,
      limit: 50,
      offset: 1,
    );
  }
}

class _ConcurrentReportsRepository extends _PagedReportsRepository {
  bool holdNextSales = false;
  bool holdNextBalancePage = false;
  Completer<void>? _salesCompleter;
  Completer<void>? _balancePageCompleter;

  void releaseSales() {
    _salesCompleter?.complete();
    _salesCompleter = null;
  }

  void releaseBalancePage() {
    _balancePageCompleter?.complete();
    _balancePageCompleter = null;
  }

  @override
  Future<SalesReportSummary> fetchSalesReport({
    String? fromDate,
    String? toDate,
  }) async {
    if (holdNextSales) {
      holdNextSales = false;
      _salesCompleter = Completer<void>();
      await _salesCompleter!.future;
    }
    return super.fetchSalesReport(fromDate: fromDate, toDate: toDate);
  }

  @override
  Future<ReportInventoryBalanceListResult> fetchInventoryBalances({
    String? query,
    int limit = 50,
    int offset = 0,
  }) async {
    if (offset > 0 && holdNextBalancePage) {
      holdNextBalancePage = false;
      _balancePageCompleter = Completer<void>();
      await _balancePageCompleter!.future;
      return const ReportInventoryBalanceListResult(
        items: [
          ReportInventoryBalanceItem(
            productId: 'p-stale',
            internalReference: 'PRD-STALE',
            name: 'Stale Item',
            manufacturerPartNumber: null,
            unitOfMeasure: null,
            sellingPrice: '10.0000',
            quantityOnHand: '1.0000',
            updatedAt: null,
          ),
        ],
        total: 2,
        limit: 50,
        offset: 1,
      );
    }
    return super.fetchInventoryBalances(
      query: query,
      limit: limit,
      offset: offset,
    );
  }
}

class _OutOfOrderDashboardRepository extends _FakeReportsRepository {
  final List<Future<DashboardSummary>> _responses = [];

  void queue(List<Future<DashboardSummary>> futures) {
    _responses.addAll(futures);
  }

  @override
  Future<DashboardSummary> fetchDashboard() {
    return _responses.removeAt(0);
  }
}
