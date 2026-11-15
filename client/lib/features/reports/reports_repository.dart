import '../../core/network/api_client.dart';
import 'reports_models.dart';

class ReportsRepository {
  const ReportsRepository(this.api);

  final ApiClient api;

  Future<DashboardSummary> fetchDashboard() async {
    final body = await api.get('/api/v1/dashboard');
    return DashboardSummary.fromJson(body);
  }

  Future<SalesReportSummary> fetchSalesReport({
    String? fromDate,
    String? toDate,
  }) async {
    final body = await api.get(
      '/api/v1/reports/sales',
      queryParameters: <String, String>{
        if (fromDate != null && fromDate.trim().isNotEmpty)
          'from_date': fromDate.trim(),
        if (toDate != null && toDate.trim().isNotEmpty)
          'to_date': toDate.trim(),
      },
    );
    return SalesReportSummary.fromJson(body);
  }

  Future<ReportInventoryBalanceListResult> fetchInventoryBalances({
    String? query,
    int limit = 50,
    int offset = 0,
  }) async {
    final trimmed = query?.trim();
    final body = await api.get(
      '/api/v1/reports/inventory/balances',
      queryParameters: <String, String>{
        'limit': '$limit',
        'offset': '$offset',
        if (trimmed != null && trimmed.isNotEmpty) 'q': trimmed,
      },
    );
    return ReportInventoryBalanceListResult.fromJson(body);
  }

  Future<ReportStockMovementListResult> fetchInventoryMovements({
    String? fromDate,
    String? toDate,
    String? query,
    int limit = 50,
    int offset = 0,
  }) async {
    final trimmed = query?.trim();
    final body = await api.get(
      '/api/v1/reports/inventory/movements',
      queryParameters: <String, String>{
        'limit': '$limit',
        'offset': '$offset',
        if (fromDate != null && fromDate.trim().isNotEmpty)
          'from_date': fromDate.trim(),
        if (toDate != null && toDate.trim().isNotEmpty)
          'to_date': toDate.trim(),
        if (trimmed != null && trimmed.isNotEmpty) 'q': trimmed,
      },
    );
    return ReportStockMovementListResult.fromJson(body);
  }
}
