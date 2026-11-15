import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../core/errors/api_exception.dart';
import '../inventory/inventory_models.dart';
import '../inventory/inventory_repository.dart';
import 'sales_models.dart';
import 'sales_repository.dart';

class SalesController extends ChangeNotifier {
  SalesController(
    this.salesRepository, {
    required this.inventoryRepository,
    this.onSessionExpired,
  });

  final SalesRepository salesRepository;
  final InventoryRepository inventoryRepository;
  final void Function(String message)? onSessionExpired;

  bool _disposed = false;
  static final Random _random = Random();

  List<InventoryBalanceItem> availableProducts = const [];
  bool isLoadingProducts = false;
  String? productsError;

  List<SaleItem> sales = const [];
  int totalSales = 0;
  bool isLoadingSales = false;
  String? salesError;
  String searchQuery = '';

  bool isSubmittingSale = false;
  String? actionMessage;
  String? actionError;

  String _pendingIdempotencyKey = _generateIdempotencyKey();
  String get pendingIdempotencyKey => _pendingIdempotencyKey;

  static String _generateIdempotencyKey() {
    final ts = DateTime.now().microsecondsSinceEpoch;
    final rand = _random.nextInt(0x7fffffff).toRadixString(16);
    return 'sale-$ts-$rand';
  }

  void rotateIdempotencyKey() {
    _pendingIdempotencyKey = _generateIdempotencyKey();
  }

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

  void clearFeedback() {
    if (actionMessage == null && actionError == null) {
      return;
    }
    actionMessage = null;
    actionError = null;
    notifyListeners();
  }

  Future<void> loadAvailableProducts() async {
    isLoadingProducts = true;
    productsError = null;
    notifyListeners();

    try {
      final result = await inventoryRepository.listBalances(limit: 100);
      availableProducts = result.items;
    } on ApiException catch (error) {
      if (error.statusCode == 401) {
        onSessionExpired?.call(error.message);
        return;
      }
      productsError = error.message;
    } catch (_) {
      productsError = 'Unable to load products and stock.';
    } finally {
      isLoadingProducts = false;
      notifyListeners();
    }
  }

  Future<void> loadSales({String? query}) async {
    if (query != null) {
      searchQuery = query;
    }
    isLoadingSales = true;
    salesError = null;
    notifyListeners();

    try {
      final result = await salesRepository.listSales(query: searchQuery);
      sales = result.items;
      totalSales = result.total;
    } on ApiException catch (error) {
      if (error.statusCode == 401) {
        onSessionExpired?.call(error.message);
        return;
      }
      salesError = error.message;
    } catch (_) {
      salesError = 'Unable to load sales history.';
    } finally {
      isLoadingSales = false;
      notifyListeners();
    }
  }

  Future<SaleItem?> submitSale({
    required PaymentMethod paymentMethod,
    required String amountTendered,
    String? paymentReference,
    String? notes,
    required List<SaleLineInput> lines,
  }) async {
    if (isSubmittingSale) {
      return null;
    }
    isSubmittingSale = true;
    actionError = null;
    actionMessage = null;
    notifyListeners();

    try {
      final sale = await salesRepository.createSale(
        SaleCreateInput(
          idempotencyKey: _pendingIdempotencyKey,
          paymentMethod: paymentMethod,
          amountTendered: amountTendered,
          paymentReference: paymentReference,
          notes: notes,
          lines: lines,
        ),
      );
      rotateIdempotencyKey();
      actionMessage = sale.replayed
          ? 'Receipt ${sale.receiptNumber} already recorded.'
          : 'Sale completed: ${sale.receiptNumber}';
      await Future.wait([
        loadAvailableProducts(),
        loadSales(),
      ]);
      return sale;
    } on ApiException catch (error) {
      if (error.statusCode == 401) {
        onSessionExpired?.call(error.message);
        return null;
      }
      actionError = error.message;
      return null;
    } catch (_) {
      actionError = 'Unable to complete sale.';
      return null;
    } finally {
      isSubmittingSale = false;
      notifyListeners();
    }
  }
}
