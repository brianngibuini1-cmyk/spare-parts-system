import '../../core/errors/api_exception.dart';

final RegExp _positiveDecimalPattern = RegExp(r'^\d+(?:\.\d+)?$');
final RegExp _signedDecimalPattern = RegExp(r'^[+-]?\d+(?:\.\d+)?$');
const int _maxDecimalFractionDigits = 4;
const int _maxDecimalIntegerDigits = 14;

String? validatePositiveDecimalInput(
  String? rawValue, {
  required String fieldLabel,
}) {
  final trimmed = rawValue?.trim() ?? '';
  if (trimmed.isEmpty) {
    return 'Enter $fieldLabel.';
  }
  if (trimmed.startsWith('-')) {
    return '$fieldLabel must be greater than zero.';
  }
  if (!_positiveDecimalPattern.hasMatch(trimmed)) {
    return 'Enter a valid decimal $fieldLabel.';
  }
  final parts = trimmed.split('.');
  final integerPart = parts[0].replaceFirst(RegExp(r'^0+'), '');
  final fractionalPart = parts.length > 1 ? parts[1] : '';
  if (fractionalPart.length > _maxDecimalFractionDigits) {
    return 'Use at most 4 decimal places.';
  }
  if (integerPart.length > _maxDecimalIntegerDigits) {
    return '$fieldLabel is too large.';
  }
  final parsed = double.tryParse(trimmed);
  if (parsed == null || parsed <= 0) {
    return '$fieldLabel must be greater than zero.';
  }
  return null;
}

String? validateNonNegativeDecimalInput(
  String? rawValue, {
  required String fieldLabel,
}) {
  final trimmed = rawValue?.trim() ?? '';
  if (trimmed.isEmpty) {
    return 'Enter $fieldLabel.';
  }
  if (trimmed.startsWith('-')) {
    return '$fieldLabel cannot be negative.';
  }
  if (!_positiveDecimalPattern.hasMatch(trimmed)) {
    return 'Enter a valid decimal $fieldLabel.';
  }
  final parts = trimmed.split('.');
  final integerPart = parts[0].replaceFirst(RegExp(r'^0+'), '');
  final fractionalPart = parts.length > 1 ? parts[1] : '';
  if (fractionalPart.length > _maxDecimalFractionDigits) {
    return 'Use at most 4 decimal places.';
  }
  if (integerPart.length > _maxDecimalIntegerDigits) {
    return '$fieldLabel is too large.';
  }
  return null;
}

String? validateSignedNonZeroDecimalInput(String? rawValue) {
  final trimmed = rawValue?.trim() ?? '';
  if (trimmed.isEmpty) {
    return 'Enter a quantity adjustment (e.g. -2 or 5).';
  }
  if (!_signedDecimalPattern.hasMatch(trimmed)) {
    return 'Enter a valid signed number (e.g. -2 or 5.5).';
  }
  final unsigned = trimmed.startsWith('-') || trimmed.startsWith('+')
      ? trimmed.substring(1)
      : trimmed;
  final parts = unsigned.split('.');
  final integerPart = parts[0].replaceFirst(RegExp(r'^0+'), '');
  final fractionalPart = parts.length > 1 ? parts[1] : '';
  if (fractionalPart.length > _maxDecimalFractionDigits) {
    return 'Use at most 4 decimal places.';
  }
  if (integerPart.length > _maxDecimalIntegerDigits) {
    return 'Quantity adjustment is too large.';
  }
  final parsed = double.tryParse(trimmed);
  if (parsed == null || parsed == 0) {
    return 'Quantity adjustment must be non-zero.';
  }
  return null;
}

String formatQuantityDisplay(String raw) {
  if (!raw.contains('.')) {
    return raw;
  }
  final trimmed = raw.replaceFirst(RegExp(r'\.?0+$'), '');
  return trimmed.isEmpty ? '0' : trimmed;
}

class InventoryBalanceItem {
  const InventoryBalanceItem({
    required this.productId,
    required this.internalReference,
    required this.name,
    required this.manufacturerPartNumber,
    required this.sellingPrice,
    required this.quantityOnHand,
    required this.updatedAt,
  });

  final String productId;
  final String internalReference;
  final String name;
  final String? manufacturerPartNumber;
  final String sellingPrice;
  final String quantityOnHand;
  final DateTime? updatedAt;

  factory InventoryBalanceItem.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const ApiException(
        null,
        'The server returned an invalid inventory balance record.',
      );
    }
    final productId = value['product_id'];
    final internalReference = value['internal_reference'];
    final name = value['name'];
    final sellingPrice = value['selling_price'];
    final quantityOnHand = value['quantity_on_hand'];
    if (productId is! String ||
        internalReference is! String ||
        name is! String ||
        sellingPrice is! String ||
        quantityOnHand is! String) {
      throw const ApiException(
        null,
        'The server returned an incomplete inventory balance record.',
      );
    }
    final updatedAtRaw = value['updated_at'];
    return InventoryBalanceItem(
      productId: productId,
      internalReference: internalReference,
      name: name,
      manufacturerPartNumber: value['manufacturer_part_number'] as String?,
      sellingPrice: sellingPrice,
      quantityOnHand: quantityOnHand,
      updatedAt: updatedAtRaw is String ? DateTime.parse(updatedAtRaw) : null,
    );
  }
}

class InventoryBalanceListResult {
  const InventoryBalanceListResult({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
  });

  final List<InventoryBalanceItem> items;
  final int total;
  final int limit;
  final int offset;

  factory InventoryBalanceListResult.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['items'] is! List<dynamic> ||
        value['total'] is! int ||
        value['limit'] is! int ||
        value['offset'] is! int) {
      throw const ApiException(
        null,
        'The server returned an invalid inventory balance list response.',
      );
    }
    return InventoryBalanceListResult(
      items: List<InventoryBalanceItem>.unmodifiable(
        (value['items'] as List<dynamic>).map(InventoryBalanceItem.fromJson),
      ),
      total: value['total'] as int,
      limit: value['limit'] as int,
      offset: value['offset'] as int,
    );
  }
}

class StockMovementItem {
  const StockMovementItem({
    required this.id,
    required this.productId,
    required this.movementType,
    required this.quantityDelta,
    required this.sourceType,
    required this.sourceId,
    required this.sourceReference,
    required this.supplierName,
    required this.reason,
    required this.actorId,
    required this.actorLogin,
    required this.createdAt,
  });

  final String id;
  final String productId;
  final String movementType;
  final String quantityDelta;
  final String sourceType;
  final String sourceId;
  final String? sourceReference;
  final String? supplierName;
  final String? reason;
  final int actorId;
  final String actorLogin;
  final DateTime createdAt;

  factory StockMovementItem.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const ApiException(
        null,
        'The server returned an invalid stock movement record.',
      );
    }
    final id = value['id'];
    final productId = value['product_id'];
    final movementType = value['movement_type'];
    final quantityDelta = value['quantity_delta'];
    final sourceType = value['source_type'];
    final sourceId = value['source_id'];
    final actorId = value['actor_id'];
    final actorLogin = value['actor_login'];
    final createdAt = value['created_at'];
    if (id is! String ||
        productId is! String ||
        movementType is! String ||
        quantityDelta is! String ||
        sourceType is! String ||
        sourceId is! String ||
        actorId is! int ||
        actorLogin is! String ||
        createdAt is! String) {
      throw const ApiException(
        null,
        'The server returned an incomplete stock movement record.',
      );
    }
    return StockMovementItem(
      id: id,
      productId: productId,
      movementType: movementType,
      quantityDelta: quantityDelta,
      sourceType: sourceType,
      sourceId: sourceId,
      sourceReference: value['source_reference'] as String?,
      supplierName: value['supplier_name'] as String?,
      reason: value['reason'] as String?,
      actorId: actorId,
      actorLogin: actorLogin,
      createdAt: DateTime.parse(createdAt),
    );
  }
}

class ProductMovementsResult {
  const ProductMovementsResult({
    required this.productId,
    required this.internalReference,
    required this.name,
    required this.manufacturerPartNumber,
    required this.quantityOnHand,
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
  });

  final String productId;
  final String internalReference;
  final String name;
  final String? manufacturerPartNumber;
  final String quantityOnHand;
  final List<StockMovementItem> items;
  final int total;
  final int limit;
  final int offset;

  factory ProductMovementsResult.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['items'] is! List<dynamic> ||
        value['product_id'] is! String ||
        value['internal_reference'] is! String ||
        value['name'] is! String ||
        value['quantity_on_hand'] is! String ||
        value['total'] is! int ||
        value['limit'] is! int ||
        value['offset'] is! int) {
      throw const ApiException(
        null,
        'The server returned an invalid product movement history response.',
      );
    }
    return ProductMovementsResult(
      productId: value['product_id'] as String,
      internalReference: value['internal_reference'] as String,
      name: value['name'] as String,
      manufacturerPartNumber: value['manufacturer_part_number'] as String?,
      quantityOnHand: value['quantity_on_hand'] as String,
      items: List<StockMovementItem>.unmodifiable(
        (value['items'] as List<dynamic>).map(StockMovementItem.fromJson),
      ),
      total: value['total'] as int,
      limit: value['limit'] as int,
      offset: value['offset'] as int,
    );
  }
}

class GoodsReceiptLineInput {
  const GoodsReceiptLineInput({
    required this.productId,
    required this.productName,
    required this.quantity,
    required this.unitCost,
  });

  final String productId;
  final String productName;
  final String quantity;
  final String unitCost;

  Map<String, Object?> toJson() => {
        'product_id': productId,
        'quantity': quantity.trim(),
        'unit_cost': unitCost.trim(),
      };
}

class GoodsReceiptCreateInput {
  const GoodsReceiptCreateInput({
    required this.idempotencyKey,
    this.supplierId,
    this.unlistedSupplierName,
    this.deliveryNoteReference,
    this.notes,
    required this.lines,
  });

  final String idempotencyKey;
  final String? supplierId;
  final String? unlistedSupplierName;
  final String? deliveryNoteReference;
  final String? notes;
  final List<GoodsReceiptLineInput> lines;

  Map<String, Object?> toJson() => {
        'idempotency_key': idempotencyKey,
        if (supplierId != null) 'supplier_id': supplierId,
        if (unlistedSupplierName != null &&
            unlistedSupplierName!.trim().isNotEmpty)
          'unlisted_supplier_name': unlistedSupplierName!.trim(),
        if (deliveryNoteReference != null &&
            deliveryNoteReference!.trim().isNotEmpty)
          'delivery_note_reference': deliveryNoteReference!.trim(),
        if (notes != null && notes!.trim().isNotEmpty) 'notes': notes!.trim(),
        'lines': lines.map((line) => line.toJson()).toList(growable: false),
      };
}

class GoodsReceiptItem {
  const GoodsReceiptItem({
    required this.id,
    required this.supplierId,
    required this.supplierName,
    required this.unlistedSupplierName,
    required this.deliveryNoteReference,
    required this.notes,
    required this.idempotencyKey,
    required this.receivedByLogin,
    required this.receivedAt,
    required this.replayed,
  });

  final String id;
  final String? supplierId;
  final String? supplierName;
  final String? unlistedSupplierName;
  final String? deliveryNoteReference;
  final String? notes;
  final String idempotencyKey;
  final String receivedByLogin;
  final DateTime receivedAt;
  final bool replayed;

  factory GoodsReceiptItem.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['id'] is! String ||
        value['idempotency_key'] is! String ||
        value['received_by_login'] is! String ||
        value['received_at'] is! String) {
      throw const ApiException(
        null,
        'The server returned an invalid goods receipt response.',
      );
    }
    return GoodsReceiptItem(
      id: value['id'] as String,
      supplierId: value['supplier_id'] as String?,
      supplierName: value['supplier_name'] as String?,
      unlistedSupplierName: value['unlisted_supplier_name'] as String?,
      deliveryNoteReference: value['delivery_note_reference'] as String?,
      notes: value['notes'] as String?,
      idempotencyKey: value['idempotency_key'] as String,
      receivedByLogin: value['received_by_login'] as String,
      receivedAt: DateTime.parse(value['received_at'] as String),
      replayed: value['replayed'] == true,
    );
  }
}

class StockAdjustmentResult {
  const StockAdjustmentResult({
    required this.movement,
    required this.productId,
    required this.quantityOnHand,
  });

  final StockMovementItem movement;
  final String productId;
  final String quantityOnHand;

  factory StockAdjustmentResult.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['product_id'] is! String ||
        value['quantity_on_hand'] is! String) {
      throw const ApiException(
        null,
        'The server returned an invalid stock adjustment response.',
      );
    }
    return StockAdjustmentResult(
      movement: StockMovementItem.fromJson(value['movement']),
      productId: value['product_id'] as String,
      quantityOnHand: value['quantity_on_hand'] as String,
    );
  }
}
