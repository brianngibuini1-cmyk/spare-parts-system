import '../../core/errors/api_exception.dart';

class AttendantAccount {
  const AttendantAccount({
    required this.id,
    required this.loginName,
    required this.isActive,
    this.role = 'SHOP_ATTENDANT',
    this.createdAt,
  });

  final int id;
  final String loginName;
  final bool isActive;
  final String role;
  final DateTime? createdAt;

  factory AttendantAccount.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const ApiException(
        null,
        'The server returned an invalid attendant record.',
      );
    }
    final id = value['id'];
    final loginName = value['login_name'];
    final isActive = value['is_active'];
    final role = value['role'];
    final createdAtRaw = value['created_at'];
    if (id is! int || loginName is! String || isActive is! bool) {
      throw const ApiException(
        null,
        'The server returned an incomplete attendant record.',
      );
    }
    return AttendantAccount(
      id: id,
      loginName: loginName,
      isActive: isActive,
      role: role is String && role.isNotEmpty ? role : 'SHOP_ATTENDANT',
      createdAt:
          createdAtRaw is String ? DateTime.tryParse(createdAtRaw) : null,
    );
  }
}

class AttendantCreateInput {
  const AttendantCreateInput({
    required this.loginName,
    required this.password,
  });

  final String loginName;
  final String password;

  Map<String, Object?> toJson() => <String, Object?>{
        'login_name': loginName.trim(),
        'password': password,
      };
}

class AttendantStatusInput {
  const AttendantStatusInput({required this.isActive});

  final bool isActive;

  Map<String, Object?> toJson() => <String, Object?>{
        'is_active': isActive,
      };
}

String? validateAttendantLoginName(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return 'Enter a login name.';
  }
  if (trimmed.length > 254) {
    return 'Login name must not exceed 254 characters.';
  }
  return null;
}

String? validateAttendantPassword(String raw) {
  if (raw.length < 15) {
    return 'Password must contain at least 15 characters.';
  }
  if (raw.length > 1024) {
    return 'Password must not exceed 1024 characters.';
  }
  return null;
}
