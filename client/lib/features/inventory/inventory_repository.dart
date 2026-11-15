import '../../core/network/api_client.dart';
import 'inventory_models.dart';

class InventoryRepository {
  const InventoryRepository(this.api);

  final ApiClient api;

  Future<InventoryBalanceListResult> listBalances({
    String? query,
    int limit = 50,
    int offset = 0,
  }) async {
    final trimmed = query?.trim();
    final body = await api.get(
      '/api/v1/inventory/balances',
      queryParameters: <String, String>{
        'limit': '$limit',
        'offset': '$offset',
        if (trimmed != null && trimmed.isNotEmpty) 'q': trimmed,
      },
    );
    return InventoryBalanceListResult.fromJson(body);
  }

  Future<ProductMovementsResult> getProductMovements(
    String productId, {
    int limit = 50,
    int offset = 0,
  }) async {
    final body = await api.get(
      '/api/v1/inventory/products/$productId/movements',
      queryParameters: <String, String>{
        'limit': '$limit',
        'offset': '$offset',
      },
    );
    return ProductMovementsResult.fromJson(body);
  }

  Future<GoodsReceiptItem> createGoodsReceipt(
    GoodsReceiptCreateInput input,
  ) async {
    final body = await api.post(
      '/api/v1/inventory/receipts',
      body: input.toJson(),
    );
    return GoodsReceiptItem.fromJson(body);
  }

  Future<StockAdjustmentResult> createStockAdjustment({
    required String productId,
    required String quantityDelta,
    required String reason,
  }) async {
    final body = await api.post(
      '/api/v1/inventory/adjustments',
      body: <String, Object?>{
        'product_id': productId,
        'quantity_delta': quantityDelta.trim(),
        'reason': reason.trim(),
      },
    );
    return StockAdjustmentResult.fromJson(body);
  }
}
