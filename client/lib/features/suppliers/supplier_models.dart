import '../../core/errors/api_exception.dart';

class SupplierItem {
  const SupplierItem({
    required this.id,
    required this.name,
    required this.contactPerson,
    required this.phone,
    required this.email,
    required this.notes,
    required this.isActive,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String? contactPerson;
  final String? phone;
  final String? email;
  final String? notes;
  final bool isActive;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory SupplierItem.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const ApiException(
        null,
        'The server returned an invalid supplier record.',
      );
    }
    final id = value['id'];
    final name = value['name'];
    final isActive = value['is_active'];
    final createdAt = value['created_at'];
    final updatedAt = value['updated_at'];
    if (id is! String ||
        name is! String ||
        isActive is! bool ||
        createdAt is! String ||
        updatedAt is! String) {
      throw const ApiException(
        null,
        'The server returned an incomplete supplier record.',
      );
    }
    return SupplierItem(
      id: id,
      name: name,
      contactPerson: value['contact_person'] as String?,
      phone: value['phone'] as String?,
      email: value['email'] as String?,
      notes: value['notes'] as String?,
      isActive: isActive,
      createdAt: DateTime.parse(createdAt),
      updatedAt: DateTime.parse(updatedAt),
    );
  }
}

class SupplierListResult {
  const SupplierListResult({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
  });

  final List<SupplierItem> items;
  final int total;
  final int limit;
  final int offset;

  factory SupplierListResult.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['items'] is! List<dynamic> ||
        value['total'] is! int ||
        value['limit'] is! int ||
        value['offset'] is! int) {
      throw const ApiException(
        null,
        'The server returned an invalid supplier list response.',
      );
    }
    return SupplierListResult(
      items: List<SupplierItem>.unmodifiable(
        (value['items'] as List<dynamic>).map(SupplierItem.fromJson),
      ),
      total: value['total'] as int,
      limit: value['limit'] as int,
      offset: value['offset'] as int,
    );
  }
}

class SupplierCreateInput {
  const SupplierCreateInput({
    required this.name,
    this.contactPerson,
    this.phone,
    this.email,
    this.notes,
  });

  final String name;
  final String? contactPerson;
  final String? phone;
  final String? email;
  final String? notes;

  Map<String, Object?> toJson() => {
        'name': name.trim(),
        if (contactPerson != null && contactPerson!.trim().isNotEmpty)
          'contact_person': contactPerson!.trim(),
        if (phone != null && phone!.trim().isNotEmpty) 'phone': phone!.trim(),
        if (email != null && email!.trim().isNotEmpty) 'email': email!.trim(),
        if (notes != null && notes!.trim().isNotEmpty) 'notes': notes!.trim(),
      };
}

class SupplierUpdateInput {
  const SupplierUpdateInput({
    this.name,
    this.contactPerson,
    this.phone,
    this.email,
    this.notes,
  });

  final String? name;
  final String? contactPerson;
  final String? phone;
  final String? email;
  final String? notes;

  Map<String, Object?> toJson() => {
        if (name != null) 'name': name!.trim(),
        'contact_person': _cleanOptional(contactPerson),
        'phone': _cleanOptional(phone),
        'email': _cleanOptional(email),
        'notes': _cleanOptional(notes),
      };

  static String? _cleanOptional(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
