import 'package:flutter/foundation.dart';

import '../../core/errors/api_exception.dart';
import 'reports_models.dart';
import 'reports_repository.dart';

class DashboardController extends ChangeNotifier {
  DashboardController(
    this.repository, {
    this.onSessionExpired,
  });

  final ReportsRepository repository;
  final void Function(String message)? onSessionExpired;

  bool _disposed = false;
  int _requestGeneration = 0;
  DashboardSummary? summary;
  bool isLoading = false;
  String? errorMessage;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_disposed) {
      super.notifyListeners();
    }
  }

  Future<void> loadDashboard() async {
    final generation = ++_requestGeneration;
    isLoading = true;
    errorMessage = null;
    notifyListeners();

    try {
      final result = await repository.fetchDashboard();
      if (generation != _requestGeneration) {
        return;
      }
      summary = result;
    } on ApiException catch (error) {
      if (generation != _requestGeneration) {
        return;
      }
      if (error.statusCode == 401) {
        onSessionExpired?.call(error.message);
        return;
      }
      errorMessage = error.message;
    } catch (_) {
      if (generation != _requestGeneration) {
        return;
      }
      errorMessage = 'Unable to load dashboard right now.';
    } finally {
      if (generation == _requestGeneration) {
        isLoading = false;
        notifyListeners();
      }
    }
  }
}

class ReportsController extends ChangeNotifier {
  ReportsController(
    this.repository, {
    this.onSessionExpired,
    this.isOwner = false,
  });

  static const int pageSize = 50;

  final ReportsRepository repository;
  final void Function(String message)? onSessionExpired;
  final bool isOwner;

  bool _disposed = false;
  int _reportGeneration = 0;
  int _salesGeneration = 0;
  int _balancesGeneration = 0;
  int _movementsGeneration = 0;
  int? _sessionExpiredGeneration;

  String? errorMessage;

  bool isLoadingSales = false;
  String? salesErrorMessage;
  SalesReportSummary? salesReport;

  bool isLoadingBalances = false;
  String? balancesErrorMessage;
  List<ReportInventoryBalanceItem> balances = const [];
  int totalBalances = 0;
  bool isLoadingMoreBalances = false;
  String? balancesLoadMoreError;

  bool isLoadingMovements = false;
  String? movementsErrorMessage;
  List<ReportStockMovementItem> movements = const [];
  int totalMovements = 0;
  bool isLoadingMoreMovements = false;
  String? movementsLoadMoreError;

  String? fromDate;
  String? toDate;

  bool get isLoading =>
      isLoadingSales || isLoadingBalances || isLoadingMovements;
  bool get hasMoreBalances => balances.length < totalBalances;
  bool get hasMoreMovements => movements.length < totalMovements;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_disposed) {
      super.notifyListeners();
    }
  }

  void _handleSessionExpired(int reportGen, String message) {
    if (_sessionExpiredGeneration == reportGen) {
      return;
    }
    _sessionExpiredGeneration = reportGen;
    onSessionExpired?.call(message);
  }

  Future<void> loadReports({
    String? nextFromDate,
    String? nextToDate,
  }) async {
    if (!isOwner) {
      errorMessage = 'Owner access is required to view operational reports.';
      notifyListeners();
      return;
    }

    final targetFrom = nextFromDate ?? fromDate;
    final targetTo = nextToDate ?? toDate;
    if (targetFrom != null && targetTo != null) {
      final rangeErr = validateReportDateRange(targetFrom, targetTo);
      if (rangeErr != null) {
        ++_reportGeneration;
        ++_salesGeneration;
        ++_balancesGeneration;
        ++_movementsGeneration;
        isLoadingSales = false;
        isLoadingBalances = false;
        isLoadingMovements = false;
        isLoadingMoreBalances = false;
        isLoadingMoreMovements = false;
        errorMessage = rangeErr;
        notifyListeners();
        return;
      }
      fromDate = targetFrom.trim();
      toDate = targetTo.trim();
    }

    final reportGen = ++_reportGeneration;
    final salesGen = ++_salesGeneration;
    final balGen = ++_balancesGeneration;
    final movGen = ++_movementsGeneration;
    errorMessage = null;
    isLoadingSales = true;
    salesErrorMessage = null;
    isLoadingBalances = true;
    balancesErrorMessage = null;
    isLoadingMoreBalances = false;
    balancesLoadMoreError = null;
    isLoadingMovements = true;
    movementsErrorMessage = null;
    isLoadingMoreMovements = false;
    movementsLoadMoreError = null;
    notifyListeners();

    await Future.wait([
      _loadSalesSection(reportGen, salesGen),
      _loadBalancesSection(reportGen, balGen),
      _loadMovementsSection(reportGen, movGen),
    ]);
  }

  Future<void> retrySalesReport() async {
    if (!isOwner || isLoadingSales) {
      return;
    }
    final reportGen = _reportGeneration;
    final salesGen = ++_salesGeneration;
    isLoadingSales = true;
    salesErrorMessage = null;
    notifyListeners();
    await _loadSalesSection(reportGen, salesGen);
  }

  Future<void> retryBalances() async {
    if (!isOwner || isLoadingBalances) {
      return;
    }
    final reportGen = _reportGeneration;
    final balGen = ++_balancesGeneration;
    isLoadingBalances = true;
    balancesErrorMessage = null;
    isLoadingMoreBalances = false;
    balancesLoadMoreError = null;
    notifyListeners();
    await _loadBalancesSection(reportGen, balGen);
  }

  Future<void> retryMovements() async {
    if (!isOwner || isLoadingMovements) {
      return;
    }
    final reportGen = _reportGeneration;
    final movGen = ++_movementsGeneration;
    isLoadingMovements = true;
    movementsErrorMessage = null;
    isLoadingMoreMovements = false;
    movementsLoadMoreError = null;
    notifyListeners();
    await _loadMovementsSection(reportGen, movGen);
  }

  Future<void> _loadSalesSection(int reportGen, int salesGen) async {
    bool isCurrent() =>
        reportGen == _reportGeneration && salesGen == _salesGeneration;
    try {
      final sales = await repository.fetchSalesReport(
        fromDate: fromDate,
        toDate: toDate,
      );
      if (!isCurrent()) {
        return;
      }
      salesReport = sales;
      fromDate ??= sales.fromDate;
      toDate ??= sales.toDate;
    } on ApiException catch (error) {
      if (!isCurrent()) {
        return;
      }
      if (error.statusCode == 401) {
        _handleSessionExpired(reportGen, error.message);
        return;
      }
      salesErrorMessage = error.message;
    } catch (_) {
      if (!isCurrent()) {
        return;
      }
      salesErrorMessage = 'Unable to load sales report right now.';
    } finally {
      if (isCurrent()) {
        isLoadingSales = false;
        notifyListeners();
      }
    }
  }

  Future<void> _loadBalancesSection(int reportGen, int balGen) async {
    bool isCurrent() =>
        reportGen == _reportGeneration && balGen == _balancesGeneration;
    try {
      final balResult = await repository.fetchInventoryBalances(
        limit: pageSize,
        offset: 0,
      );
      if (!isCurrent()) {
        return;
      }
      balances = balResult.items;
      totalBalances = balResult.total;
    } on ApiException catch (error) {
      if (!isCurrent()) {
        return;
      }
      if (error.statusCode == 401) {
        _handleSessionExpired(reportGen, error.message);
        return;
      }
      balancesErrorMessage = error.message;
    } catch (_) {
      if (!isCurrent()) {
        return;
      }
      balancesErrorMessage = 'Unable to load inventory balances right now.';
    } finally {
      if (isCurrent()) {
        isLoadingBalances = false;
        notifyListeners();
      }
    }
  }

  Future<void> _loadMovementsSection(int reportGen, int movGen) async {
    bool isCurrent() =>
        reportGen == _reportGeneration && movGen == _movementsGeneration;
    try {
      final movResult = await repository.fetchInventoryMovements(
        fromDate: fromDate,
        toDate: toDate,
        limit: pageSize,
        offset: 0,
      );
      if (!isCurrent()) {
        return;
      }
      movements = movResult.items;
      totalMovements = movResult.total;
    } on ApiException catch (error) {
      if (!isCurrent()) {
        return;
      }
      if (error.statusCode == 401) {
        _handleSessionExpired(reportGen, error.message);
        return;
      }
      movementsErrorMessage = error.message;
    } catch (_) {
      if (!isCurrent()) {
        return;
      }
      movementsErrorMessage = 'Unable to load stock movements right now.';
    } finally {
      if (isCurrent()) {
        isLoadingMovements = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadMoreBalances() async {
    if (!isOwner ||
        isLoadingBalances ||
        isLoadingMoreBalances ||
        !hasMoreBalances) {
      return;
    }
    final reportGen = _reportGeneration;
    final balGen = _balancesGeneration;
    bool isCurrent() =>
        reportGen == _reportGeneration && balGen == _balancesGeneration;

    final offset = balances.length;
    isLoadingMoreBalances = true;
    balancesLoadMoreError = null;
    notifyListeners();

    try {
      final page = await repository.fetchInventoryBalances(
        limit: pageSize,
        offset: offset,
      );
      if (!isCurrent()) {
        return;
      }
      final existingIds = balances.map((b) => b.productId).toSet();
      final merged = <ReportInventoryBalanceItem>[
        ...balances,
        ...page.items.where((b) => !existingIds.contains(b.productId)),
      ];
      balances = List<ReportInventoryBalanceItem>.unmodifiable(merged);
      totalBalances = page.total;
    } on ApiException catch (error) {
      if (!isCurrent()) {
        return;
      }
      if (error.statusCode == 401) {
        _handleSessionExpired(reportGen, error.message);
        return;
      }
      balancesLoadMoreError = error.message;
    } catch (_) {
      if (!isCurrent()) {
        return;
      }
      balancesLoadMoreError = 'Unable to load more inventory balances.';
    } finally {
      if (isCurrent()) {
        isLoadingMoreBalances = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadMoreMovements() async {
    if (!isOwner ||
        isLoadingMovements ||
        isLoadingMoreMovements ||
        !hasMoreMovements) {
      return;
    }
    final reportGen = _reportGeneration;
    final movGen = _movementsGeneration;
    bool isCurrent() =>
        reportGen == _reportGeneration && movGen == _movementsGeneration;

    final offset = movements.length;
    isLoadingMoreMovements = true;
    movementsLoadMoreError = null;
    notifyListeners();

    try {
      final page = await repository.fetchInventoryMovements(
        fromDate: fromDate,
        toDate: toDate,
        limit: pageSize,
        offset: offset,
      );
      if (!isCurrent()) {
        return;
      }
      final existingIds = movements.map((m) => m.id).toSet();
      final merged = <ReportStockMovementItem>[
        ...movements,
        ...page.items.where((m) => !existingIds.contains(m.id)),
      ];
      movements = List<ReportStockMovementItem>.unmodifiable(merged);
      totalMovements = page.total;
    } on ApiException catch (error) {
      if (!isCurrent()) {
        return;
      }
      if (error.statusCode == 401) {
        _handleSessionExpired(reportGen, error.message);
        return;
      }
      movementsLoadMoreError = error.message;
    } catch (_) {
      if (!isCurrent()) {
        return;
      }
      movementsLoadMoreError = 'Unable to load more stock movements.';
    } finally {
      if (isCurrent()) {
        isLoadingMoreMovements = false;
        notifyListeners();
      }
    }
  }
}
