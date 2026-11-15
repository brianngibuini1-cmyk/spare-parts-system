import 'package:flutter/foundation.dart';

import '../../core/errors/api_exception.dart';
import 'supplier_models.dart';
import 'supplier_repository.dart';

class SupplierController extends ChangeNotifier {
  SupplierController(
    this.repository, {
    this.onSessionExpired,
    this.isOwner = false,
  });

  final SupplierRepository repository;
  final void Function(String message)? onSessionExpired;
  final bool isOwner;

  bool _disposed = false;

  List<SupplierItem> suppliers = const [];
  int total = 0;
  bool isLoading = false;
  bool isSaving = false;
  String? listError;
  String? actionMessage;
  String? actionError;
  String searchQuery = '';
  bool includeInactive = true;

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

  Future<void> loadSuppliers({
    String? query,
    bool? includeInactiveFilter,
  }) async {
    if (query != null) {
      searchQuery = query;
    }
    if (includeInactiveFilter != null) {
      includeInactive = includeInactiveFilter;
    }
    isLoading = true;
    listError = null;
    notifyListeners();

    try {
      final result = await repository.listSuppliers(
        query: searchQuery,
        includeInactive: isOwner ? includeInactive : false,
      );
      suppliers = result.items;
      total = result.total;
    } on ApiException catch (error) {
      if (error.statusCode == 401) {
        onSessionExpired?.call(error.message);
        return;
      }
      listError = error.message;
    } catch (_) {
      listError = 'Unable to load suppliers right now.';
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<SupplierItem?> createSupplier(SupplierCreateInput input) async {
    isSaving = true;
    actionError = null;
    actionMessage = null;
    notifyListeners();

    try {
      final created = await repository.createSupplier(input);
      actionMessage = 'Supplier "${created.name}" added.';
      await loadSuppliers();
      return created;
    } on ApiException catch (error) {
      if (error.statusCode == 401) {
        onSessionExpired?.call(error.message);
        return null;
      }
      actionError = error.message;
      return null;
    } catch (_) {
      actionError = 'Unable to save supplier.';
      return null;
    } finally {
      isSaving = false;
      notifyListeners();
    }
  }

  Future<SupplierItem?> updateSupplier(
    String supplierId,
    SupplierUpdateInput input,
  ) async {
    isSaving = true;
    actionError = null;
    actionMessage = null;
    notifyListeners();

    try {
      final updated = await repository.updateSupplier(supplierId, input);
      actionMessage = 'Supplier "${updated.name}" updated.';
      await loadSuppliers();
      return updated;
    } on ApiException catch (error) {
      if (error.statusCode == 401) {
        onSessionExpired?.call(error.message);
        return null;
      }
      actionError = error.message;
      return null;
    } catch (_) {
      actionError = 'Unable to update supplier.';
      return null;
    } finally {
      isSaving = false;
      notifyListeners();
    }
  }

  Future<bool> setSupplierActive(SupplierItem supplier, bool active) async {
    isSaving = true;
    actionError = null;
    actionMessage = null;
    notifyListeners();

    try {
      final updated = active
          ? await repository.activateSupplier(supplier.id)
          : await repository.deactivateSupplier(supplier.id);
      actionMessage = updated.isActive
          ? 'Supplier "${updated.name}" activated.'
          : 'Supplier "${updated.name}" deactivated.';
      await loadSuppliers();
      return true;
    } on ApiException catch (error) {
      if (error.statusCode == 401) {
        onSessionExpired?.call(error.message);
        return false;
      }
      actionError = error.message;
      return false;
    } catch (_) {
      actionError = 'Unable to update supplier status.';
      return false;
    } finally {
      isSaving = false;
      notifyListeners();
    }
  }
}
