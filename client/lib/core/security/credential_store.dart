import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class TokenPair {
  const TokenPair({
    required this.accessToken,
    required this.refreshToken,
    required this.accessExpiresAt,
  });
  final String accessToken;
  final String refreshToken;
  final DateTime accessExpiresAt;

  Map<String, Object> toJson() => {
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'access_expires_at': accessExpiresAt.toIso8601String(),
      };

  static TokenPair fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['access_token'] is! String ||
        value['refresh_token'] is! String ||
        value['access_expires_at'] is! String) {
      throw const FormatException('Invalid saved session.');
    }
    return TokenPair(
      accessToken: value['access_token'] as String,
      refreshToken: value['refresh_token'] as String,
      accessExpiresAt: DateTime.parse(value['access_expires_at'] as String),
    );
  }
}

abstract interface class CredentialStore {
  Future<TokenPair?> read();
  Future<void> write(TokenPair pair);
  Future<void> clear();
}

class SecureCredentialStore implements CredentialStore {
  SecureCredentialStore({FlutterSecureStorage? storage})
      : _storage = storage ?? defaultSecureStorage;

  static const _key = 'bmm_native_session_v1';

  static const AndroidOptions defaultAndroidOptions = AndroidOptions(
    encryptedSharedPreferences: true,
    resetOnError: true,
  );

  static const IOSOptions defaultIosOptions = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
    synchronizable: false,
  );

  static const WindowsOptions defaultWindowsOptions = WindowsOptions(
    useBackwardCompatibility: false,
  );

  static const FlutterSecureStorage defaultSecureStorage = FlutterSecureStorage(
    aOptions: defaultAndroidOptions,
    iOptions: defaultIosOptions,
    wOptions: defaultWindowsOptions,
  );

  final FlutterSecureStorage _storage;

  @override
  Future<TokenPair?> read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return null;
    try {
      return TokenPair.fromJson(jsonDecode(raw));
    } on Object {
      await clear();
      return null;
    }
  }

  @override
  Future<void> write(TokenPair pair) =>
      _storage.write(key: _key, value: jsonEncode(pair.toJson()));

  @override
  Future<void> clear() => _storage.delete(key: _key);
}
