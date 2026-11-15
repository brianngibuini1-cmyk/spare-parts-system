import '../../core/errors/api_exception.dart';
import '../inventory/inventory_models.dart';

enum PaymentMethod {
  cash('cash', 'Cash'),
  mpesa('mpesa', 'M-PESA (Manual)');

  const PaymentMethod(this.wireValue, this.displayLabel);

  final String wireValue;
  final String displayLabel;

  static PaymentMethod fromWire(Object? value) {
    return switch (value) {
      'cash' => PaymentMethod.cash,
      'mpesa' => PaymentMethod.mpesa,
      _ => throw const ApiException(
          null,
          'The server returned an unsupported payment method.',
        ),
    };
  }
}

/// Parses a decimal string with up to 4 fractional digits into scaled integer
/// units (`1.0000` -> `10000`) for exact decimal arithmetic without floats.
BigInt parseScaled4(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return BigInt.zero;
  final negative = trimmed.startsWith('-');
  final unsigned =
      (negative || trimmed.startsWith('+')) ? trimmed.substring(1) : trimmed;
  final parts = unsigned.split('.');
  final whole = parts[0].isEmpty ? '0' : parts[0];
  final fracRaw = parts.length > 1 ? parts[1] : '';
  final fracPadded = fracRaw.padRight(4, '0').substring(0, 4);
  final magnitude = BigInt.parse('$whole$fracPadded');
  return negative ? -magnitude : magnitude;
}

String formatScaled4(BigInt scaled) {
  final negative = scaled < BigInt.zero;
  final absVal = negative ? -scaled : scaled;
  final whole = absVal ~/ BigInt.from(10000);
  final frac = (absVal % BigInt.from(10000)).toString().padLeft(4, '0');
  final raw = '$whole.$frac';
  final formatted = formatQuantityDisplay(raw);
  return negative ? '-$formatted' : formatted;
}

String formatMoneyDisplay(String raw) {
  final scaled = parseScaled4(raw);
  final negative = scaled < BigInt.zero;
  final absVal = negative ? -scaled : scaled;
  final whole = absVal ~/ BigInt.from(10000);
  final frac4 = (absVal % BigInt.from(10000)).toString().padLeft(4, '0');
  final fracDisplay = frac4.endsWith('00')
      ? frac4.substring(0, 2)
      : formatQuantityDisplay('0.$frac4').substring(2);
  return '${negative ? '-' : ''}$whole.$fracDisplay';
}

BigInt computeLineTotalScaled4(String quantity, String unitPrice) {
  final qtyScaled = parseScaled4(quantity);
  final priceScaled = parseScaled4(unitPrice);
  final product = qtyScaled * priceScaled;
  final scale = BigInt.from(10000);
  final half = BigInt.from(5000);
  return (product + half) ~/ scale;
}

class SaleLineInput {
  const SaleLineInput({
    required this.productId,
    required this.productName,
    required this.unitPrice,
    required this.quantity,
    required this.availableStock,
  });

  final String productId;
  final String productName;
  final String unitPrice;
  final String quantity;
  final String availableStock;

  Map<String, Object?> toJson() => {
        'product_id': productId,
        'quantity': quantity.trim(),
      };
}

class SaleCreateInput {
  const SaleCreateInput({
    required this.idempotencyKey,
    required this.paymentMethod,
    required this.amountTendered,
    this.paymentReference,
    this.notes,
    required this.lines,
  });

  final String idempotencyKey;
  final PaymentMethod paymentMethod;
  final String amountTendered;
  final String? paymentReference;
  final String? notes;
  final List<SaleLineInput> lines;

  Map<String, Object?> toJson() => {
        'idempotency_key': idempotencyKey,
        'payment_method': paymentMethod.wireValue,
        'amount_tendered': amountTendered.trim(),
        if (paymentReference != null && paymentReference!.trim().isNotEmpty)
          'payment_reference': paymentReference!.trim(),
        if (notes != null && notes!.trim().isNotEmpty) 'notes': notes!.trim(),
        'lines': lines.map((line) => line.toJson()).toList(growable: false),
      };
}

class SaleLineItem {
  const SaleLineItem({
    required this.id,
    required this.lineNumber,
    required this.productId,
    required this.productInternalReference,
    required this.productName,
    required this.productDescription,
    required this.manufacturerPartNumber,
    required this.unitPrice,
    required this.quantity,
    required this.lineTotal,
  });

  final String id;
  final int lineNumber;
  final String productId;
  final String productInternalReference;
  final String productName;
  final String? productDescription;
  final String? manufacturerPartNumber;
  final String unitPrice;
  final String quantity;
  final String lineTotal;

  factory SaleLineItem.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const ApiException(
        null,
        'The server returned an invalid sale line.',
      );
    }
    final id = value['id'];
    final lineNumber = value['line_number'];
    final productId = value['product_id'];
    final ref = value['product_internal_reference'];
    final name = value['product_name'];
    final unitPrice = value['unit_price'];
    final quantity = value['quantity'];
    final lineTotal = value['line_total'];
    if (id is! String ||
        lineNumber is! int ||
        productId is! String ||
        ref is! String ||
        name is! String ||
        unitPrice is! String ||
        quantity is! String ||
        lineTotal is! String) {
      throw const ApiException(
        null,
        'The server returned an incomplete sale line.',
      );
    }
    return SaleLineItem(
      id: id,
      lineNumber: lineNumber,
      productId: productId,
      productInternalReference: ref,
      productName: name,
      productDescription: value['product_description'] as String?,
      manufacturerPartNumber: value['manufacturer_part_number'] as String?,
      unitPrice: unitPrice,
      quantity: quantity,
      lineTotal: lineTotal,
    );
  }
}

class SaleItem {
  const SaleItem({
    required this.id,
    required this.receiptNumber,
    required this.idempotencyKey,
    required this.status,
    required this.totalAmount,
    required this.paymentMethod,
    required this.amountTendered,
    required this.changeGiven,
    required this.paymentReference,
    required this.notes,
    required this.soldBy,
    required this.soldByLogin,
    required this.soldAt,
    required this.replayed,
    required this.lines,
  });

  final String id;
  final String receiptNumber;
  final String idempotencyKey;
  final String status;
  final String totalAmount;
  final PaymentMethod paymentMethod;
  final String amountTendered;
  final String changeGiven;
  final String? paymentReference;
  final String? notes;
  final int soldBy;
  final String soldByLogin;
  final DateTime soldAt;
  final bool replayed;
  final List<SaleLineItem> lines;

  factory SaleItem.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const ApiException(
        null,
        'The server returned an invalid sale record.',
      );
    }
    final id = value['id'];
    final receiptNumber = value['receipt_number'];
    final idempotencyKey = value['idempotency_key'];
    final status = value['status'];
    final totalAmount = value['total_amount'];
    final amountTendered = value['amount_tendered'];
    final changeGiven = value['change_given'];
    final soldBy = value['sold_by'];
    final soldByLogin = value['sold_by_login'];
    final soldAt = value['sold_at'];
    final linesRaw = value['lines'];
    if (id is! String ||
        receiptNumber is! String ||
        idempotencyKey is! String ||
        status is! String ||
        totalAmount is! String ||
        amountTendered is! String ||
        changeGiven is! String ||
        soldBy is! int ||
        soldByLogin is! String ||
        soldAt is! String ||
        linesRaw is! List<dynamic>) {
      throw const ApiException(
        null,
        'The server returned an incomplete sale record.',
      );
    }
    return SaleItem(
      id: id,
      receiptNumber: receiptNumber,
      idempotencyKey: idempotencyKey,
      status: status,
      totalAmount: totalAmount,
      paymentMethod: PaymentMethod.fromWire(value['payment_method']),
      amountTendered: amountTendered,
      changeGiven: changeGiven,
      paymentReference: value['payment_reference'] as String?,
      notes: value['notes'] as String?,
      soldBy: soldBy,
      soldByLogin: soldByLogin,
      soldAt: DateTime.parse(soldAt),
      replayed: value['replayed'] == true,
      lines: List<SaleLineItem>.unmodifiable(
        linesRaw.map(SaleLineItem.fromJson),
      ),
    );
  }
}

class SaleListResult {
  const SaleListResult({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
  });

  final List<SaleItem> items;
  final int total;
  final int limit;
  final int offset;

  factory SaleListResult.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['items'] is! List<dynamic> ||
        value['total'] is! int ||
        value['limit'] is! int ||
        value['offset'] is! int) {
      throw const ApiException(
        null,
        'The server returned an invalid sales list response.',
      );
    }
    return SaleListResult(
      items: List<SaleItem>.unmodifiable(
        (value['items'] as List<dynamic>).map(SaleItem.fromJson),
      ),
      total: value['total'] as int,
      limit: value['limit'] as int,
      offset: value['offset'] as int,
    );
  }
}
