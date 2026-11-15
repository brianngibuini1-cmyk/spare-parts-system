import '../../core/network/api_client.dart';
import 'supplier_models.dart';

class SupplierRepository {
  const SupplierRepository(this.api);

  final ApiClient api;

  Future<SupplierListResult> listSuppliers({
    String? query,
    bool includeInactive = true,
    int limit = 50,
    int offset = 0,
  }) async {
    final trimmed = query?.trim();
    final body = await api.get(
      '/api/v1/suppliers',
      queryParameters: <String, String>{
        'limit': '$limit',
        'offset': '$offset',
        'include_inactive': includeInactive ? 'true' : 'false',
        if (trimmed != null && trimmed.isNotEmpty) 'q': trimmed,
      },
    );
    return SupplierListResult.fromJson(body);
  }

  Future<SupplierItem> getSupplier(String supplierId) async {
    final body = await api.get('/api/v1/suppliers/$supplierId');
    return SupplierItem.fromJson(body);
  }

  Future<SupplierItem> createSupplier(SupplierCreateInput input) async {
    final body = await api.post('/api/v1/suppliers', body: input.toJson());
    return SupplierItem.fromJson(body);
  }

  Future<SupplierItem> updateSupplier(
    String supplierId,
    SupplierUpdateInput input,
  ) async {
    final body = await api.patch(
      '/api/v1/suppliers/$supplierId',
      body: input.toJson(),
    );
    return SupplierItem.fromJson(body);
  }

  Future<SupplierItem> activateSupplier(String supplierId) async {
    final body = await api.post('/api/v1/suppliers/$supplierId/activate');
    return SupplierItem.fromJson(body);
  }

  Future<SupplierItem> deactivateSupplier(String supplierId) async {
    final body = await api.post('/api/v1/suppliers/$supplierId/deactivate');
    return SupplierItem.fromJson(body);
  }
}
