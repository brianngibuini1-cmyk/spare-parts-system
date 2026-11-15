import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/errors/api_exception.dart';
import 'catalogue_models.dart';
import 'catalogue_repository.dart';

class CatalogueController extends ChangeNotifier {
  CatalogueController(
    this.repository, {
    this.onSessionExpired,
    this.isOwner = false,
    ProductApprovalStatus? initialStatusFilter,
  }) : statusFilter = initialStatusFilter;

  final CatalogueRepository repository;
  final void Function(String message)? onSessionExpired;
  final bool isOwner;

  bool _disposed = false;

  List<ProductItem> products = const [];
  bool isLoadingList = false;
  String? listError;
  String searchQuery = '';
  ProductApprovalStatus? statusFilter;

  ProductItem? selectedProduct;
  bool isLoadingDetail = false;
  String? detailError;

  bool isSubmitting = false;
  bool isSavingEdit = false;
  bool isUploadingImage = false;
  bool isApproving = false;
  bool isRejecting = false;
  String? actionMessage;
  String? actionError;

  bool get isReviewActionInProgress => isApproving || isRejecting;

  final Map<String, Uint8List> _imageCache = <String, Uint8List>{};
  final Map<String, Future<void>> _inFlightImageLoads =
      <String, Future<void>>{};
  final Map<String, int> _imageLoadGeneration = <String, int>{};
  final Map<String, String> _imageErrors = <String, String>{};

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

  Uint8List? imageBytesFor(String? imageUrl) =>
      imageUrl == null ? null : _imageCache[imageUrl];

  bool isLoadingImageFor(String? imageUrl) =>
      imageUrl != null && _inFlightImageLoads.containsKey(imageUrl);

  String? imageErrorFor(String? imageUrl) =>
      imageUrl == null ? null : _imageErrors[imageUrl];

  void clearFeedback() {
    if (actionMessage == null && actionError == null && detailError == null) {
      return;
    }
    actionMessage = null;
    actionError = null;
    detailError = null;
    notifyListeners();
  }

  Future<void> loadProducts({
    String? query,
    ProductApprovalStatus? status,
    bool updateFilter = false,
  }) async {
    if (query != null) {
      searchQuery = query;
    }
    if (updateFilter) {
      statusFilter = status;
    }
    isLoadingList = true;
    listError = null;
    notifyListeners();

    try {
      final result = await repository.listProducts(
        query: searchQuery,
        approvalStatus: statusFilter,
      );
      if (_disposed) return;
      products = result.items;
      if (selectedProduct != null) {
        for (final item in products) {
          if (item.id == selectedProduct!.id) {
            selectedProduct = item;
            break;
          }
        }
      }
      for (final item in products) {
        if (item.imageUrl != null && !_imageCache.containsKey(item.imageUrl)) {
          unawaited(loadProductImage(item.imageUrl));
        }
      }
    } on ApiException catch (error) {
      if (_disposed) return;
      listError = error.message;
      _checkSessionExpired(error);
    } on Object {
      if (_disposed) return;
      listError =
          'Unable to load the product catalogue. Check the connection and try again.';
    } finally {
      isLoadingList = false;
      notifyListeners();
    }
  }

  Future<void> openProductDetail(
    String productId, {
    ProductItem? initial,
  }) async {
    if (initial != null) {
      selectedProduct = initial;
    }
    isLoadingDetail = true;
    detailError = null;
    actionError = null;
    actionMessage = null;
    notifyListeners();

    try {
      final fresh = await repository.getProduct(productId);
      if (_disposed) return;
      selectedProduct = fresh;
      _replaceProductInList(fresh);
      if (fresh.imageUrl != null) {
        unawaited(loadProductImage(fresh.imageUrl));
      }
    } on ApiException catch (error) {
      if (_disposed) return;
      detailError = error.message;
      _checkSessionExpired(error);
    } on Object {
      if (_disposed) return;
      detailError =
          'Unable to load product details. Check the connection and try again.';
    } finally {
      isLoadingDetail = false;
      notifyListeners();
    }
  }

  void closeProductDetail() {
    selectedProduct = null;
    isLoadingDetail = false;
    detailError = null;
    actionError = null;
    actionMessage = null;
    notifyListeners();
  }

  Future<ProductItem?> submitNewProduct(
    ProductCreateInput input, {
    SelectedProductImage? image,
  }) async {
    isSubmitting = true;
    actionError = null;
    actionMessage = null;
    notifyListeners();

    ProductItem? created;
    try {
      created = await repository.createProduct(input);
      if (_disposed) return null;
      var current = created;
      if (image != null) {
        try {
          current = await repository.uploadProductImage(created.id, image);
          if (_disposed) return null;
          if (current.imageUrl != null) {
            await loadProductImage(current.imageUrl, forceRefresh: true);
          }
          actionMessage =
              'Product and photograph submitted for owner approval.';
        } on ApiException catch (error) {
          if (_disposed) return null;
          selectedProduct = current;
          _upsertProductInList(current);
          actionError = error.message;
          _checkSessionExpired(error);
          return current;
        } on Object {
          if (_disposed) return null;
          selectedProduct = current;
          _upsertProductInList(current);
          actionError =
              'Product was submitted, but the photograph could not be uploaded.';
          return current;
        }
      } else {
        actionMessage = 'Product submitted for owner approval.';
      }
      selectedProduct = current;
      _upsertProductInList(current);
      return current;
    } on ApiException catch (error) {
      if (_disposed) return null;
      actionError = error.message;
      _checkSessionExpired(error);
      return null;
    } on Object {
      if (_disposed) return null;
      actionError =
          'Unable to submit the product. Check the connection and try again.';
      return null;
    } finally {
      isSubmitting = false;
      notifyListeners();
    }
  }

  Future<bool> updateSelectedProduct(ProductUpdateInput input) async {
    final current = selectedProduct;
    if (current == null) return false;
    if (!current.canEdit) {
      actionError = 'Only your pending submissions can be edited.';
      actionMessage = null;
      notifyListeners();
      return false;
    }

    isSavingEdit = true;
    actionError = null;
    actionMessage = null;
    notifyListeners();

    try {
      final updated = await repository.updateProduct(current.id, input);
      if (_disposed) return false;
      selectedProduct = updated;
      _replaceProductInList(updated);
      actionMessage = 'Product details updated.';
      return true;
    } on ApiException catch (error) {
      if (_disposed) return false;
      actionError = error.message;
      _checkSessionExpired(error);
      return false;
    } on Object {
      if (_disposed) return false;
      actionError =
          'Unable to save product changes. Check the connection and try again.';
      return false;
    } finally {
      isSavingEdit = false;
      notifyListeners();
    }
  }

  Future<bool> uploadImageForSelectedProduct(SelectedProductImage image) async {
    final current = selectedProduct;
    if (current == null) return false;
    if (!current.canEdit) {
      actionError = 'Only your pending submissions can be edited.';
      actionMessage = null;
      notifyListeners();
      return false;
    }

    isUploadingImage = true;
    actionError = null;
    actionMessage = null;
    notifyListeners();

    try {
      final updated = await repository.uploadProductImage(current.id, image);
      if (_disposed) return false;
      selectedProduct = updated;
      _replaceProductInList(updated);
      if (updated.imageUrl != null) {
        await loadProductImage(updated.imageUrl, forceRefresh: true);
      }
      actionMessage = 'Product photograph uploaded.';
      return true;
    } on ApiException catch (error) {
      if (_disposed) return false;
      actionError = error.message;
      _checkSessionExpired(error);
      return false;
    } on Object {
      if (_disposed) return false;
      actionError =
          'Unable to upload the photograph. Check the connection and try again.';
      return false;
    } finally {
      isUploadingImage = false;
      notifyListeners();
    }
  }

  Future<bool> approveProduct(
    String productId,
    String rawSellingPrice,
  ) async {
    if (isReviewActionInProgress) {
      return false;
    }
    if (!isOwner) {
      actionError = 'This account cannot perform that action.';
      actionMessage = null;
      notifyListeners();
      return false;
    }
    final current = selectedProduct?.id == productId ? selectedProduct : null;
    if (current != null && current.isRejected) {
      actionError = 'Rejected submissions cannot be approved.';
      actionMessage = null;
      notifyListeners();
      return false;
    }
    final validationError = validateSellingPriceInput(rawSellingPrice);
    if (validationError != null) {
      actionError = validationError;
      actionMessage = null;
      notifyListeners();
      return false;
    }

    isApproving = true;
    actionError = null;
    actionMessage = null;
    notifyListeners();

    try {
      final updated = await repository.approveProduct(
        productId,
        ProductApproveInput(sellingPrice: rawSellingPrice),
      );
      if (_disposed) return false;
      if (selectedProduct?.id == productId) {
        selectedProduct = updated;
      }
      await _refreshListAfterReviewDecision(updated);
      if (_disposed) return false;
      actionMessage = 'Product approved and selling price recorded.';
      return true;
    } on ApiException catch (error) {
      if (_disposed) return false;
      actionError = error.message;
      _checkSessionExpired(error);
      return false;
    } on Object {
      if (_disposed) return false;
      actionError =
          'Unable to approve the product. Check the connection and try again.';
      return false;
    } finally {
      isApproving = false;
      notifyListeners();
    }
  }

  Future<bool> rejectProduct(
    String productId,
    String rawReason,
  ) async {
    if (isReviewActionInProgress) {
      return false;
    }
    if (!isOwner) {
      actionError = 'This account cannot perform that action.';
      actionMessage = null;
      notifyListeners();
      return false;
    }
    final current = selectedProduct?.id == productId ? selectedProduct : null;
    if (current != null && !current.isPending) {
      actionError = 'Only pending submissions can be rejected.';
      actionMessage = null;
      notifyListeners();
      return false;
    }
    final validationError = validateRejectionReasonInput(rawReason);
    if (validationError != null) {
      actionError = validationError;
      actionMessage = null;
      notifyListeners();
      return false;
    }

    isRejecting = true;
    actionError = null;
    actionMessage = null;
    notifyListeners();

    try {
      final updated = await repository.rejectProduct(
        productId,
        ProductRejectInput(reason: rawReason),
      );
      if (_disposed) return false;
      if (selectedProduct?.id == productId) {
        selectedProduct = updated;
      }
      await _refreshListAfterReviewDecision(updated);
      if (_disposed) return false;
      actionMessage = 'Product submission rejected.';
      return true;
    } on ApiException catch (error) {
      if (_disposed) return false;
      actionError = error.message;
      _checkSessionExpired(error);
      return false;
    } on Object {
      if (_disposed) return false;
      actionError =
          'Unable to reject the product. Check the connection and try again.';
      return false;
    } finally {
      isRejecting = false;
      notifyListeners();
    }
  }

  Future<void> _refreshListAfterReviewDecision(ProductItem updated) async {
    _applyLocalStatusFilterUpdate(updated);
    try {
      final result = await repository.listProducts(
        query: searchQuery,
        approvalStatus: statusFilter,
      );
      if (_disposed) return;
      products = result.items;
      for (final item in products) {
        if (item.imageUrl != null && !_imageCache.containsKey(item.imageUrl)) {
          unawaited(loadProductImage(item.imageUrl));
        }
      }
    } on ApiException catch (error) {
      if (_disposed) return;
      _checkSessionExpired(error);
    } on Object {
      // Preserve the local list update if the secondary list refresh fails.
    }
  }

  void _applyLocalStatusFilterUpdate(ProductItem updated) {
    if (statusFilter != null && updated.approvalStatus != statusFilter) {
      products = List<ProductItem>.unmodifiable(
        products.where((item) => item.id != updated.id),
      );
      return;
    }
    _upsertProductInList(updated);
  }

  Future<void> loadProductImage(
    String? imageUrl, {
    bool forceRefresh = false,
  }) {
    if (imageUrl == null || imageUrl.isEmpty) {
      return Future<void>.value();
    }
    if (!forceRefresh) {
      if (_imageCache.containsKey(imageUrl)) {
        return Future<void>.value();
      }
      final existing = _inFlightImageLoads[imageUrl];
      if (existing != null) {
        return existing;
      }
    } else {
      // Evict stale bytes immediately so a forced reload after replacement
      // never displays the old photograph while loading or if the reload fails.
      _imageCache.remove(imageUrl);
    }

    final generation = (_imageLoadGeneration[imageUrl] ?? 0) + 1;
    _imageLoadGeneration[imageUrl] = generation;
    _imageErrors.remove(imageUrl);

    final operation = _performImageLoad(imageUrl, generation);
    _inFlightImageLoads[imageUrl] = operation;
    notifyListeners();
    return operation;
  }

  Future<void> _performImageLoad(String imageUrl, int generation) async {
    try {
      final bytes = await repository.getProductImageBytes(imageUrl);
      if (_disposed || _imageLoadGeneration[imageUrl] != generation) {
        return;
      }
      _imageCache[imageUrl] = bytes;
      _imageErrors.remove(imageUrl);
    } on ApiException catch (error) {
      if (_disposed) return;
      if (_imageLoadGeneration[imageUrl] == generation) {
        _imageCache.remove(imageUrl);
        _imageErrors[imageUrl] = error.message;
      }
      _checkSessionExpired(error);
    } on Object {
      if (_disposed) return;
      if (_imageLoadGeneration[imageUrl] == generation) {
        _imageCache.remove(imageUrl);
        _imageErrors[imageUrl] = 'Unable to load product photograph.';
      }
    } finally {
      if (!_disposed && _imageLoadGeneration[imageUrl] == generation) {
        _inFlightImageLoads.remove(imageUrl);
        notifyListeners();
      }
    }
  }

  void _replaceProductInList(ProductItem updated) {
    final index = products.indexWhere((item) => item.id == updated.id);
    if (index == -1) return;
    final copy = List<ProductItem>.of(products);
    copy[index] = updated;
    products = List<ProductItem>.unmodifiable(copy);
  }

  void _upsertProductInList(ProductItem item) {
    final index = products.indexWhere((existing) => existing.id == item.id);
    if (index == -1) {
      products = List<ProductItem>.unmodifiable([item, ...products]);
    } else {
      _replaceProductInList(item);
    }
  }

  void _checkSessionExpired(ApiException error) {
    if (error.statusCode == 401) {
      onSessionExpired?.call(error.message);
    }
  }
}
