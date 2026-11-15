import '../../core/errors/api_exception.dart';

class DashboardSummary {
  const DashboardSummary({
    required this.timezone,
    required this.businessDate,
    required this.todayCompletedSalesCount,
    required this.todaySalesTotal,
    required this.todayCashTotal,
    required this.todayMpesaTotal,
    required this.approvedProductsCount,
    required this.zeroStockProductsCount,
  });

  final String timezone;
  final String businessDate;
  final int todayCompletedSalesCount;
  final String todaySalesTotal;
  final String todayCashTotal;
  final String todayMpesaTotal;
  final int approvedProductsCount;
  final int zeroStockProductsCount;

  factory DashboardSummary.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const ApiException(
        null,
        'The server returned an invalid dashboard summary.',
      );
    }
    final tz = value['timezone'];
    final businessDate = value['business_date'];
    final salesCount = value['today_completed_sales_count'];
    final salesTotal = value['today_sales_total'];
    final cashTotal = value['today_cash_total'];
    final mpesaTotal = value['today_mpesa_total'];
    final approvedCount = value['approved_products_count'];
    final zeroStockCount = value['zero_stock_products_count'];
    if (tz is! String ||
        businessDate is! String ||
        salesCount is! int ||
        salesTotal is! String ||
        cashTotal is! String ||
        mpesaTotal is! String ||
        approvedCount is! int ||
        zeroStockCount is! int) {
      throw const ApiException(
        null,
        'The server returned an incomplete dashboard summary.',
      );
    }
    return DashboardSummary(
      timezone: tz,
      businessDate: businessDate,
      todayCompletedSalesCount: salesCount,
      todaySalesTotal: salesTotal,
      todayCashTotal: cashTotal,
      todayMpesaTotal: mpesaTotal,
      approvedProductsCount: approvedCount,
      zeroStockProductsCount: zeroStockCount,
    );
  }
}

class SalesReportSummary {
  const SalesReportSummary({
    required this.timezone,
    required this.fromDate,
    required this.toDate,
    required this.completedSalesCount,
    required this.totalSalesValue,
    required this.cashTotal,
    required this.mpesaTotal,
    required this.mpesaNote,
  });

  final String timezone;
  final String fromDate;
  final String toDate;
  final int completedSalesCount;
  final String totalSalesValue;
  final String cashTotal;
  final String mpesaTotal;
  final String mpesaNote;

  factory SalesReportSummary.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const ApiException(
        null,
        'The server returned an invalid sales report.',
      );
    }
    final tz = value['timezone'];
    final fromDate = value['from_date'];
    final toDate = value['to_date'];
    final count = value['completed_sales_count'];
    final totalVal = value['total_sales_value'];
    final cashVal = value['cash_total'];
    final mpesaVal = value['mpesa_total'];
    final mpesaNote = value['mpesa_note'];
    if (tz is! String ||
        fromDate is! String ||
        toDate is! String ||
        count is! int ||
        totalVal is! String ||
        cashVal is! String ||
        mpesaVal is! String ||
        mpesaNote is! String) {
      throw const ApiException(
        null,
        'The server returned an incomplete sales report.',
      );
    }
    return SalesReportSummary(
      timezone: tz,
      fromDate: fromDate,
      toDate: toDate,
      completedSalesCount: count,
      totalSalesValue: totalVal,
      cashTotal: cashVal,
      mpesaTotal: mpesaVal,
      mpesaNote: mpesaNote,
    );
  }
}

class ReportInventoryBalanceItem {
  const ReportInventoryBalanceItem({
    required this.productId,
    required this.internalReference,
    required this.name,
    required this.manufacturerPartNumber,
    required this.unitOfMeasure,
    required this.sellingPrice,
    required this.quantityOnHand,
    required this.updatedAt,
  });

  final String productId;
  final String internalReference;
  final String name;
  final String? manufacturerPartNumber;
  final String? unitOfMeasure;
  final String sellingPrice;
  final String quantityOnHand;
  final DateTime? updatedAt;

  factory ReportInventoryBalanceItem.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const ApiException(
        null,
        'The server returned an invalid inventory report item.',
      );
    }
    final productId = value['product_id'];
    final ref = value['internal_reference'];
    final name = value['name'];
    final price = value['selling_price'];
    final qty = value['quantity_on_hand'];
    final updatedAtRaw = value['updated_at'];
    if (productId is! String ||
        ref is! String ||
        name is! String ||
        price is! String ||
        qty is! String) {
      throw const ApiException(
        null,
        'The server returned an incomplete inventory report item.',
      );
    }
    return ReportInventoryBalanceItem(
      productId: productId,
      internalReference: ref,
      name: name,
      manufacturerPartNumber: value['manufacturer_part_number'] as String?,
      unitOfMeasure: value['unit_of_measure'] as String?,
      sellingPrice: price,
      quantityOnHand: qty,
      updatedAt:
          updatedAtRaw is String ? DateTime.tryParse(updatedAtRaw) : null,
    );
  }
}

class ReportInventoryBalanceListResult {
  const ReportInventoryBalanceListResult({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
  });

  final List<ReportInventoryBalanceItem> items;
  final int total;
  final int limit;
  final int offset;

  factory ReportInventoryBalanceListResult.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['items'] is! List<dynamic> ||
        value['total'] is! int ||
        value['limit'] is! int ||
        value['offset'] is! int) {
      throw const ApiException(
        null,
        'The server returned an invalid inventory balances report.',
      );
    }
    return ReportInventoryBalanceListResult(
      items: List<ReportInventoryBalanceItem>.unmodifiable(
        (value['items'] as List<dynamic>)
            .map(ReportInventoryBalanceItem.fromJson),
      ),
      total: value['total'] as int,
      limit: value['limit'] as int,
      offset: value['offset'] as int,
    );
  }
}

class ReportStockMovementItem {
  const ReportStockMovementItem({
    required this.id,
    required this.productId,
    required this.productInternalReference,
    required this.productName,
    required this.movementType,
    required this.quantityDelta,
    required this.sourceType,
    required this.sourceId,
    required this.sourceReference,
    required this.reason,
    required this.actorId,
    required this.actorLogin,
    required this.createdAt,
  });

  final String id;
  final String productId;
  final String productInternalReference;
  final String productName;
  final String movementType;
  final String quantityDelta;
  final String sourceType;
  final String sourceId;
  final String? sourceReference;
  final String? reason;
  final int actorId;
  final String actorLogin;
  final DateTime createdAt;

  factory ReportStockMovementItem.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const ApiException(
        null,
        'The server returned an invalid movement history record.',
      );
    }
    final id = value['id'];
    final productId = value['product_id'];
    final ref = value['product_internal_reference'];
    final name = value['product_name'];
    final type = value['movement_type'];
    final delta = value['quantity_delta'];
    final sourceType = value['source_type'];
    final sourceId = value['source_id'];
    final actorId = value['actor_id'];
    final actorLogin = value['actor_login'];
    final createdAt = value['created_at'];
    if (id is! String ||
        productId is! String ||
        ref is! String ||
        name is! String ||
        type is! String ||
        delta is! String ||
        sourceType is! String ||
        sourceId is! String ||
        actorId is! int ||
        actorLogin is! String ||
        createdAt is! String) {
      throw const ApiException(
        null,
        'The server returned an incomplete movement history record.',
      );
    }
    return ReportStockMovementItem(
      id: id,
      productId: productId,
      productInternalReference: ref,
      productName: name,
      movementType: type,
      quantityDelta: delta,
      sourceType: sourceType,
      sourceId: sourceId,
      sourceReference: value['source_reference'] as String?,
      reason: value['reason'] as String?,
      actorId: actorId,
      actorLogin: actorLogin,
      createdAt: DateTime.parse(createdAt),
    );
  }
}

class ReportStockMovementListResult {
  const ReportStockMovementListResult({
    required this.timezone,
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
  });

  final String timezone;
  final List<ReportStockMovementItem> items;
  final int total;
  final int limit;
  final int offset;

  factory ReportStockMovementListResult.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['timezone'] is! String ||
        value['items'] is! List<dynamic> ||
        value['total'] is! int ||
        value['limit'] is! int ||
        value['offset'] is! int) {
      throw const ApiException(
        null,
        'The server returned an invalid movement history report.',
      );
    }
    return ReportStockMovementListResult(
      timezone: value['timezone'] as String,
      items: List<ReportStockMovementItem>.unmodifiable(
        (value['items'] as List<dynamic>).map(ReportStockMovementItem.fromJson),
      ),
      total: value['total'] as int,
      limit: value['limit'] as int,
      offset: value['offset'] as int,
    );
  }
}

final RegExp _isoDatePattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

DateTime? _parseStrictIsoDate(String raw) {
  if (!_isoDatePattern.hasMatch(raw)) {
    return null;
  }
  final parts = raw.split('-');
  final year = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  final day = int.tryParse(parts[2]);
  if (year == null || month == null || day == null) {
    return null;
  }
  final parsed = DateTime(year, month, day);
  if (parsed.year != year || parsed.month != month || parsed.day != day) {
    return null;
  }
  return parsed;
}

String? validateReportDateRange(String fromRaw, String toRaw) {
  final from = fromRaw.trim();
  final to = toRaw.trim();
  if (!_isoDatePattern.hasMatch(from) || !_isoDatePattern.hasMatch(to)) {
    return 'Enter valid dates in YYYY-MM-DD format.';
  }
  final parsedFrom = _parseStrictIsoDate(from);
  final parsedTo = _parseStrictIsoDate(to);
  if (parsedFrom == null || parsedTo == null) {
    return 'Enter valid calendar dates.';
  }
  if (parsedFrom.isAfter(parsedTo)) {
    return 'Start date cannot be after end date.';
  }
  return null;
}
