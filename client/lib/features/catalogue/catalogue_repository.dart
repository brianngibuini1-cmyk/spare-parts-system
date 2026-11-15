import 'dart:typed_data';

import '../../core/errors/api_exception.dart';
import '../../core/network/api_client.dart';
import 'catalogue_models.dart';

class CatalogueRepository {
  const CatalogueRepository(this.api);

  final ApiClient api;

  Future<ProductListResult> listProducts({
    String? query,
    ProductApprovalStatus? approvalStatus,
    int limit = 50,
  }) async {
    final trimmedQuery = query?.trim();
    final queryParameters = <String, String>{
      'limit': '$limit',
      if (trimmedQuery != null && trimmedQuery.isNotEmpty) 'q': trimmedQuery,
      if (approvalStatus != null) 'approval_status': approvalStatus.wireValue,
    };
    final body = await api.get(
      '/api/v1/products',
      queryParameters: queryParameters,
    );
    return ProductListResult.fromJson(body);
  }

  Future<List<ProductItem>> listPendingProducts() async {
    final body = await api.get('/api/v1/products/pending');
    if (body is! List<dynamic>) {
      throw const ApiException(
        null,
        'The server returned an invalid pending product list response.',
      );
    }
    return List<ProductItem>.unmodifiable(body.map(ProductItem.fromJson));
  }

  Future<ProductItem> getProduct(String productId) async {
    final body = await api.get('/api/v1/products/$productId');
    return ProductItem.fromJson(body);
  }

  Future<ProductItem> createProduct(ProductCreateInput input) async {
    final body = await api.post(
      '/api/v1/products',
      body: input.toJson(),
    );
    return ProductItem.fromJson(body);
  }

  Future<ProductItem> updateProduct(
    String productId,
    ProductUpdateInput input,
  ) async {
    final body = await api.patch(
      '/api/v1/products/$productId',
      body: input.toJson(),
    );
    return ProductItem.fromJson(body);
  }

  Future<ProductItem> approveProduct(
    String productId,
    ProductApproveInput input,
  ) async {
    final body = await api.post(
      '/api/v1/products/$productId/approve',
      body: input.toJson(),
    );
    return ProductItem.fromJson(body);
  }

  Future<ProductItem> rejectProduct(
    String productId,
    ProductRejectInput input,
  ) async {
    final body = await api.post(
      '/api/v1/products/$productId/reject',
      body: input.toJson(),
    );
    return ProductItem.fromJson(body);
  }

  Future<ProductItem> uploadProductImage(
    String productId,
    SelectedProductImage image,
  ) async {
    final body = await api.uploadMultipart(
      '/api/v1/products/$productId/image',
      bytes: image.bytes,
      filename: image.filename,
      contentType: image.contentType,
    );
    return ProductItem.fromJson(body);
  }

  Future<Uint8List> getProductImageBytes(String imageUrl) =>
      api.getImageBytes(imageUrl);
}
