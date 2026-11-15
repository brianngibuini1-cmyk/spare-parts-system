import '../../core/network/api_client.dart';
import 'sales_models.dart';

class SalesRepository {
  const SalesRepository(this.api);

  final ApiClient api;

  Future<SaleItem> createSale(SaleCreateInput input) async {
    final body = await api.post('/api/v1/sales', body: input.toJson());
    return SaleItem.fromJson(body);
  }

  Future<SaleListResult> listSales({
    String? query,
    int limit = 50,
    int offset = 0,
  }) async {
    final trimmed = query?.trim();
    final body = await api.get(
      '/api/v1/sales',
      queryParameters: <String, String>{
        'limit': '$limit',
        'offset': '$offset',
        if (trimmed != null && trimmed.isNotEmpty) 'q': trimmed,
      },
    );
    return SaleListResult.fromJson(body);
  }

  Future<SaleItem> getSale(String saleId) async {
    final body = await api.get('/api/v1/sales/$saleId');
    return SaleItem.fromJson(body);
  }
}
