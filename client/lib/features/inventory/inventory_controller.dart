import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../core/errors/api_exception.dart';
import '../catalogue/catalogue_models.dart';
import '../catalogue/catalogue_repository.dart';
import '../suppliers/supplier_models.dart';
import '../suppliers/supplier_repository.dart';
import 'inventory_models.dart';
import 'inventory_repository.dart';

class InventoryController extends ChangeNotifier {
  InventoryController(
    this.inventoryRepository, {
    this.catalogueRepository,
    this.supplierRepository,
    this.onSessionExpired,
    this.isOwner = false,
  });

  final InventoryRepository inventoryRepository;
  final CatalogueRepository? catalogueRepository;
  final SupplierRepository? supplierRepository;
  final void Function(String message)? onSessionExpired;
  final bool isOwner;

  bool _disposed = false;
  static final Random _random = Random();

  List<InventoryBalanceItem> balances = const [];
  int totalBalances = 0;
  bool isLoadingBalances = false;
  String? balancesError;
  String searchQuery = '';

  ProductMovementsResult? movementsResult;
  bool isLoadingMovements = false;
  String? movementsError;

  List<ProductItem> approvedProducts = const [];
  List<SupplierItem> activeSuppliers = const [];
  bool isLoadingReceivingLookups = false;
  String? receivingLookupsError;

  bool isSubmittingReceipt = false;
  bool isSubmittingAdjustment = false;
  String? actionMessage;
  String? actionError;

  String _pendingIdempotencyKey = _generateIdempotencyKey();
  String get pendingIdempotencyKey => _pendingIdempotencyKey;

  static String _generateIdempotencyKey() {
    final ts = DateTime.now().microsecondsSinceEpoch;
    final rand = _random.nextInt(0x7fffffff).toRadixString(16);
    return 'rcp-$ts-$rand';
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

  Future<void> loadBalances({String? query}) async {
    if (query != null) {
      searchQuery = query;
    }
    isLoadingBalances = true;
    balancesError = null;
    notifyListeners();

    try {
      final result = await inventoryRepository.listBalances(query: searchQuery);
      balances = result.items;
      totalBalances = result.total;
    } on ApiException catch (error) {
      if (error.statusCode == 401) {
        onSessionExpired?.call(error.message);
        return;
      }
      balancesError = error.message;
    } catch (_) {
      balancesError = 'Unable to load inventory balances.';
    } finally {
      isLoadingBalances = false;
      notifyListeners();
    }
  }

  Future<void> loadProductMovements(String productId) async {
    isLoadingMovements = true;
    movementsError = null;
    notifyListeners();

    try {
      movementsResult =
          await inventoryRepository.getProductMovements(productId);
    } on ApiException catch (error) {
      if (error.statusCode == 401) {
        onSessionExpired?.call(error.message);
        return;
      }
      movementsError = error.message;
    } catch (_) {
      movementsError = 'Unable to load movement history.';
    } finally {
      isLoadingMovements = false;
      notifyListeners();
    }
  }

  Future<void> loadReceivingLookups() async {
    isLoadingReceivingLookups = true;
    receivingLookupsError = null;
    notifyListeners();

    try {
      final productsFuture = catalogueRepository?.listProducts(
        approvalStatus: ProductApprovalStatus.approved,
        limit: 100,
      );
      final suppliersFuture = supplierRepository?.listSuppliers(
        includeInactive: false,
        limit: 100,
      );
      if (productsFuture != null) {
        approvedProducts = (await productsFuture).items;
      }
      if (suppliersFuture != null) {
        activeSuppliers = (await suppliersFuture).items;
      }
    } on ApiException catch (error) {
      if (error.statusCode == 401) {
        onSessionExpired?.call(error.message);
        return;
      }
      receivingLookupsError = error.message;
    } catch (_) {
      receivingLookupsError = 'Unable to load products and suppliers.';
    } finally {
      isLoadingReceivingLookups = false;
      notifyListeners();
    }
  }

  Future<GoodsReceiptItem?> submitGoodsReceipt({
    String? supplierId,
    String? unlistedSupplierName,
    String? deliveryNoteReference,
    String? notes,
    required List<GoodsReceiptLineInput> lines,
  }) async {
    if (isSubmittingReceipt) {
      return null;
    }
    isSubmittingReceipt = true;
    actionError = null;
    actionMessage = null;
    notifyListeners();

    try {
      final receipt = await inventoryRepository.createGoodsReceipt(
        GoodsReceiptCreateInput(
          idempotencyKey: _pendingIdempotencyKey,
          supplierId: supplierId,
          unlistedSupplierName: unlistedSupplierName,
          deliveryNoteReference: deliveryNoteReference,
          notes: notes,
          lines: lines,
        ),
      );
      rotateIdempotencyKey();
      actionMessage = receipt.replayed
          ? 'Receipt already recorded (idempotent replay).'
          : 'Stock receipt posted.';
      await loadBalances();
      return receipt;
    } on ApiException catch (error) {
      if (error.statusCode == 401) {
        onSessionExpired?.call(error.message);
        return null;
      }
      actionError = error.message;
      return null;
    } catch (_) {
      actionError = 'Unable to post goods receipt.';
      return null;
    } finally {
      isSubmittingReceipt = false;
      notifyListeners();
    }
  }

  Future<StockAdjustmentResult?> submitStockAdjustment({
    required String productId,
    required String quantityDelta,
    required String reason,
  }) async {
    if (isSubmittingAdjustment) {
      return null;
    }
    isSubmittingAdjustment = true;
    actionError = null;
    actionMessage = null;
    notifyListeners();

    try {
      final result = await inventoryRepository.createStockAdjustment(
        productId: productId,
        quantityDelta: quantityDelta,
        reason: reason,
      );
      actionMessage =
          'Stock adjusted to ${formatQuantityDisplay(result.quantityOnHand)}.';
      await Future.wait([
        loadBalances(),
        loadProductMovements(productId),
      ]);
      return result;
    } on ApiException catch (error) {
      if (error.statusCode == 401) {
        onSessionExpired?.call(error.message);
        return null;
      }
      actionError = error.message;
      return null;
    } catch (_) {
      actionError = 'Unable to post stock adjustment.';
      return null;
    } finally {
      isSubmittingAdjustment = false;
      notifyListeners();
    }
  }
}
