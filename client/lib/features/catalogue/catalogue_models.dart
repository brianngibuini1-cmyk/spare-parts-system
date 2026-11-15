import 'dart:typed_data';

import '../../core/errors/api_exception.dart';

enum ProductApprovalStatus {
  pending('pending', 'Pending approval'),
  approved('approved', 'Approved'),
  rejected('rejected', 'Rejected');

  const ProductApprovalStatus(this.wireValue, this.displayLabel);

  final String wireValue;
  final String displayLabel;

  static ProductApprovalStatus fromWire(Object? value) {
    return switch (value) {
      'pending' => ProductApprovalStatus.pending,
      'approved' => ProductApprovalStatus.approved,
      'rejected' => ProductApprovalStatus.rejected,
      _ => throw const ApiException(
          null,
          'The server returned an unsupported product approval status.',
        ),
    };
  }
}

final RegExp _decimalPricePattern = RegExp(r'^\d+(?:\.\d+)?$');
const int maxRejectionReasonLength = 2000;
const int _maxPriceIntegerDigits = 14;
const int _maxPriceFractionDigits = 4;

/// Validates a selling price string against the backend `ProductApproval`
/// schema (`Decimal`, finite, `>= 0`, `<= 99999999999999.9999`, at most 4
/// decimal places).
String? validateSellingPriceInput(String? rawValue) {
  final trimmed = rawValue?.trim() ?? '';
  if (trimmed.isEmpty) {
    return 'Enter a selling price.';
  }
  if (trimmed.startsWith('-')) {
    return 'Selling price must be zero or greater.';
  }
  if (!_decimalPricePattern.hasMatch(trimmed)) {
    return 'Enter a valid decimal selling price.';
  }
  final parts = trimmed.split('.');
  final integerPart = parts[0].replaceFirst(RegExp(r'^0+'), '');
  final fractionalPart = parts.length > 1 ? parts[1] : '';
  if (fractionalPart.length > _maxPriceFractionDigits) {
    return 'Selling price can have no more than four decimal places.';
  }
  if (integerPart.length > _maxPriceIntegerDigits) {
    return 'Selling price is outside the supported decimal range.';
  }
  return null;
}

/// Validates a rejection reason against the backend `ProductRejection` schema
/// (`str`, `min_length=1`, `max_length=2000` after whitespace stripping).
String? validateRejectionReasonInput(String? rawValue) {
  final trimmed = rawValue?.trim() ?? '';
  if (trimmed.isEmpty) {
    return 'Enter a rejection reason.';
  }
  if (trimmed.length > maxRejectionReasonLength) {
    return 'Rejection reason must not exceed 2,000 characters.';
  }
  return null;
}

class ProductItem {
  const ProductItem({
    required this.id,
    required this.internalReference,
    required this.name,
    required this.description,
    required this.category,
    required this.manufacturerPartNumber,
    required this.imageUrl,
    required this.sellingPrice,
    required this.approvalStatus,
    required this.submittedBy,
    required this.submittedByLogin,
    required this.submittedAt,
    required this.approvedBy,
    required this.approvedByLogin,
    required this.approvedAt,
    required this.rejectionReason,
    required this.canEdit,
  });

  final String id;
  final String internalReference;
  final String name;
  final String? description;
  final String? category;
  final String? manufacturerPartNumber;
  final String? imageUrl;
  final String? sellingPrice;
  final ProductApprovalStatus approvalStatus;
  final int submittedBy;
  final String submittedByLogin;
  final DateTime submittedAt;
  final int? approvedBy;
  final String? approvedByLogin;
  final DateTime? approvedAt;
  final String? rejectionReason;
  final bool canEdit;

  bool get isPending => approvalStatus == ProductApprovalStatus.pending;
  bool get isApproved => approvalStatus == ProductApprovalStatus.approved;
  bool get isRejected => approvalStatus == ProductApprovalStatus.rejected;

  factory ProductItem.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const ApiException(
        null,
        'The server returned an invalid product record.',
      );
    }
    final id = value['id'];
    final internalReference = value['internal_reference'];
    final name = value['name'];
    final submittedBy = value['submitted_by'];
    final submittedByLogin = value['submitted_by_login'];
    final submittedAtRaw = value['submitted_at'];
    final canEdit = value['can_edit'];

    if (id is! String ||
        id.isEmpty ||
        internalReference is! String ||
        internalReference.isEmpty ||
        name is! String ||
        name.isEmpty ||
        submittedBy is! int ||
        submittedByLogin is! String ||
        submittedByLogin.isEmpty ||
        submittedAtRaw is! String ||
        canEdit is! bool) {
      throw const ApiException(
        null,
        'The server returned an invalid product record.',
      );
    }

    final description = _optionalString(value['description']);
    final category = _optionalString(value['category']);
    final manufacturerPartNumber =
        _optionalString(value['manufacturer_part_number']);
    final imageUrl = _optionalString(value['image_url']);
    final sellingPrice = _optionalString(value['selling_price']);
    final approvedBy = value['approved_by'];
    if (approvedBy != null && approvedBy is! int) {
      throw const ApiException(
        null,
        'The server returned an invalid product record.',
      );
    }
    final approvedByLogin = _optionalString(value['approved_by_login']);
    final approvedAtRaw = _optionalString(value['approved_at']);
    final rejectionReason = _optionalString(value['rejection_reason']);

    try {
      return ProductItem(
        id: id,
        internalReference: internalReference,
        name: name,
        description: description,
        category: category,
        manufacturerPartNumber: manufacturerPartNumber,
        imageUrl: imageUrl,
        sellingPrice: sellingPrice,
        approvalStatus: ProductApprovalStatus.fromWire(
          value['approval_status'],
        ),
        submittedBy: submittedBy,
        submittedByLogin: submittedByLogin,
        submittedAt: DateTime.parse(submittedAtRaw).toUtc(),
        approvedBy: approvedBy as int?,
        approvedByLogin: approvedByLogin,
        approvedAt: approvedAtRaw != null
            ? DateTime.parse(approvedAtRaw).toUtc()
            : null,
        rejectionReason: rejectionReason,
        canEdit: canEdit,
      );
    } on FormatException {
      throw const ApiException(
        null,
        'The server returned an invalid product timestamp.',
      );
    }
  }

  static String? _optionalString(Object? value) {
    if (value == null) return null;
    if (value is String) return value;
    throw const ApiException(
      null,
      'The server returned an invalid product record.',
    );
  }
}

class ProductListResult {
  const ProductListResult({
    required this.items,
    required this.limit,
  });

  final List<ProductItem> items;
  final int limit;

  factory ProductListResult.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['items'] is! List<dynamic> ||
        value['limit'] is! int) {
      throw const ApiException(
        null,
        'The server returned an invalid product list response.',
      );
    }
    final rawItems = value['items'] as List<dynamic>;
    return ProductListResult(
      items: List<ProductItem>.unmodifiable(
        rawItems.map(ProductItem.fromJson),
      ),
      limit: value['limit'] as int,
    );
  }
}

class ProductCreateInput {
  const ProductCreateInput({
    required this.name,
    this.description,
    this.category,
    this.manufacturerPartNumber,
  });

  final String name;
  final String? description;
  final String? category;
  final String? manufacturerPartNumber;

  Map<String, Object?> toJson() {
    final trimmedDescription = description?.trim();
    final trimmedCategory = category?.trim();
    final trimmedPartNumber = manufacturerPartNumber?.trim();
    return <String, Object?>{
      'name': name.trim(),
      'description': (trimmedDescription == null || trimmedDescription.isEmpty)
          ? null
          : trimmedDescription,
      'category': (trimmedCategory == null || trimmedCategory.isEmpty)
          ? null
          : trimmedCategory,
      'manufacturer_part_number':
          (trimmedPartNumber == null || trimmedPartNumber.isEmpty)
              ? null
              : trimmedPartNumber,
    };
  }
}

class ProductUpdateInput {
  const ProductUpdateInput({
    required this.name,
    this.description,
    this.category,
    this.manufacturerPartNumber,
  });

  final String name;
  final String? description;
  final String? category;
  final String? manufacturerPartNumber;

  Map<String, Object?> toJson() {
    final trimmedDescription = description?.trim();
    final trimmedCategory = category?.trim();
    final trimmedPartNumber = manufacturerPartNumber?.trim();
    return <String, Object?>{
      'name': name.trim(),
      'description': (trimmedDescription == null || trimmedDescription.isEmpty)
          ? null
          : trimmedDescription,
      'category': (trimmedCategory == null || trimmedCategory.isEmpty)
          ? null
          : trimmedCategory,
      'manufacturer_part_number':
          (trimmedPartNumber == null || trimmedPartNumber.isEmpty)
              ? null
              : trimmedPartNumber,
    };
  }
}

class ProductApproveInput {
  const ProductApproveInput({required this.sellingPrice});

  final String sellingPrice;

  Map<String, Object?> toJson() => <String, Object?>{
        'selling_price': sellingPrice.trim(),
      };
}

class ProductRejectInput {
  const ProductRejectInput({required this.reason});

  final String reason;

  Map<String, Object?> toJson() => <String, Object?>{
        'reason': reason.trim(),
      };
}

class SelectedProductImage {
  SelectedProductImage({
    required List<int> bytes,
    required this.filename,
    required this.contentType,
  }) : _bytes = Uint8List.fromList(bytes);

  final Uint8List _bytes;
  final String filename;
  final String contentType;

  Uint8List get bytes => Uint8List.fromList(_bytes);
}
