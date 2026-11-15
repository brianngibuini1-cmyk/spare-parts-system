import 'dart:async';

import 'package:flutter/foundation.dart';

import '../errors/api_exception.dart';
import '../security/credential_store.dart';
import 'api_transport.dart';

class AuthenticatedUser {
  const AuthenticatedUser({
    required this.id,
    required this.loginName,
    required this.role,
  });
  final int id;
  final String loginName;
  final String role;

  factory AuthenticatedUser.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['id'] is! int ||
        value['login_name'] is! String) {
      throw const ApiException(
        null,
        'The server returned an invalid account response.',
      );
    }
    final role = value['role'];
    if (role != 'OWNER' && role != 'SHOP_ATTENDANT') {
      throw const ApiException(
        null,
        'The server returned an unsupported account role.',
      );
    }
    return AuthenticatedUser(
      id: value['id'] as int,
      loginName: value['login_name'] as String,
      role: role as String,
    );
  }
}

class ApiClient {
  ApiClient({
    required Uri baseUrl,
    required ApiTransport transport,
    required CredentialStore credentials,
  })  : _baseUrl = baseUrl,
        _transport = transport,
        _credentials = credentials;

  final Uri _baseUrl;
  final ApiTransport _transport;
  final CredentialStore _credentials;
  Future<TokenPair>? _refreshing;
  Future<void> _storageSerial = Future<void>.value();
  int _authGeneration = 0;
  static const int maxConsumedRefreshTokens = 64;
  final Set<String> _consumedRefreshTokens = <String>{};

  @visibleForTesting
  Set<String> get consumedRefreshTokens =>
      Set<String>.unmodifiable(_consumedRefreshTokens);

  void close({bool force = false}) => _transport.close(force: force);

  void _markRefreshTokenConsumed(String refreshToken) {
    _consumedRefreshTokens
      ..remove(refreshToken)
      ..add(refreshToken);
    while (_consumedRefreshTokens.length > maxConsumedRefreshTokens) {
      _consumedRefreshTokens.remove(_consumedRefreshTokens.first);
    }
  }

  static bool _samePair(TokenPair? a, TokenPair? b) =>
      a != null &&
      b != null &&
      a.accessToken == b.accessToken &&
      a.refreshToken == b.refreshToken;

  Future<T> _withStorageLock<T>(Future<T> Function() action) {
    final previous = _storageSerial;
    final completer = Completer<void>();
    _storageSerial = completer.future;
    return previous.then((_) => action()).whenComplete(() {
      completer.complete();
    });
  }

  Future<TokenPair?> _readCredentials() =>
      _withStorageLock(() => _credentials.read());

  Future<void> _clearIfMatching(TokenPair expected) =>
      _withStorageLock(() async {
        final current = await _credentials.read();
        if (_samePair(current, expected)) {
          _markRefreshTokenConsumed(expected.refreshToken);
          await _credentials.clear();
        }
      });

  Uri _endpoint(String path, {Map<String, String>? queryParameters}) {
    final resolved = _baseUrl.resolve(path);
    if (queryParameters == null || queryParameters.isEmpty) {
      return resolved;
    }
    return resolved.replace(
      queryParameters: {
        ...resolved.queryParameters,
        ...queryParameters,
      },
    );
  }

  Future<void> login(String loginName, String password) async {
    final startGeneration = await _withStorageLock(
      () async => _authGeneration,
    );
    final response = await _send(
      'POST',
      '/api/v1/native/auth/login',
      body: {
        'login_name': loginName,
        'password': password,
      },
    );
    _ensureSuccess(response);
    final pair = _tokenPair(response.body);
    await _withStorageLock(() async {
      if (_authGeneration != startGeneration) {
        _markRefreshTokenConsumed(pair.refreshToken);
        throw const ApiException(
          401,
          'Your session has expired. Please sign in again.',
        );
      }
      _authGeneration++;
      _refreshing = null;
      _consumedRefreshTokens.remove(pair.refreshToken);
      await _credentials.write(pair);
    });
  }

  Future<AuthenticatedUser> me() async {
    final body = await get('/api/v1/native/auth/me');
    return AuthenticatedUser.fromJson(body);
  }

  Future<void> logout() async {
    late final int logoutGeneration;
    final pair = await _withStorageLock(() async {
      logoutGeneration = ++_authGeneration;
      _refreshing = null;
      final existing = await _credentials.read();
      if (existing != null) {
        _markRefreshTokenConsumed(existing.refreshToken);
      }
      await _credentials.clear();
      return existing;
    });
    try {
      if (pair != null) {
        final response = await _send(
          'POST',
          '/api/v1/native/auth/logout',
          body: {
            'refresh_token': pair.refreshToken,
          },
        );
        if (response.statusCode != 204 && response.statusCode != 401) {
          _ensureSuccess(response);
        }
      }
    } finally {
      await _withStorageLock(() async {
        if (_authGeneration == logoutGeneration) {
          await _credentials.clear();
        }
      });
    }
  }

  Future<Object?> get(
    String path, {
    Map<String, String>? queryParameters,
  }) async {
    final response = await _sendAuthorized(
      'GET',
      path,
      queryParameters: queryParameters,
    );
    return _ensureJsonBody(response);
  }

  Future<Object?> post(
    String path, {
    Object? body,
    Map<String, String>? queryParameters,
  }) async {
    final response = await _sendAuthorized(
      'POST',
      path,
      body: body,
      queryParameters: queryParameters,
    );
    return _ensureJsonBody(response);
  }

  Future<Object?> patch(
    String path, {
    Object? body,
    Map<String, String>? queryParameters,
  }) async {
    final response = await _sendAuthorized(
      'PATCH',
      path,
      body: body,
      queryParameters: queryParameters,
    );
    return _ensureJsonBody(response);
  }

  Future<Object?> uploadMultipart(
    String path, {
    required List<int> bytes,
    required String filename,
    required String contentType,
    String fieldName = 'file',
    Map<String, String> fields = const {},
    Map<String, String>? queryParameters,
  }) async {
    final payload = MultipartFilePayload(
      bytes: bytes,
      filename: filename,
      contentType: contentType,
      fieldName: fieldName,
      fields: fields,
    );
    final response = await _sendAuthorized(
      'POST',
      path,
      body: payload,
      queryParameters: queryParameters,
    );
    return _ensureJsonBody(response);
  }

  Future<Uint8List> getBytes(
    String path, {
    Map<String, String>? queryParameters,
  }) async {
    final response = await _sendAuthorized(
      'GET',
      path,
      queryParameters: queryParameters,
      responseType: ApiResponseType.bytes,
      acceptHeader:
          'image/jpeg, image/png, image/webp, application/octet-stream',
    );
    final body = response.body;
    if (body is Uint8List && body.isNotEmpty) {
      return body;
    }
    if (body is List<int> && body.isNotEmpty) {
      return Uint8List.fromList(body);
    }
    throw const ApiException(
      null,
      'The server returned an invalid image response.',
    );
  }

  Future<Uint8List> getImageBytes(
    String path, {
    Map<String, String>? queryParameters,
  }) =>
      getBytes(path, queryParameters: queryParameters);

  Future<ApiResponse> _sendAuthorized(
    String method,
    String path, {
    Object? body,
    Map<String, String>? queryParameters,
    ApiResponseType responseType = ApiResponseType.json,
    String acceptHeader = 'application/json',
  }) async {
    var pair = await _readCredentials();
    if (pair == null) {
      throw const ApiException(401, 'Please sign in to continue.');
    }
    var refreshed = false;
    if (!pair.accessExpiresAt
        .isAfter(DateTime.now().toUtc().add(const Duration(seconds: 30)))) {
      pair = await _refresh(pair);
      refreshed = true;
    }
    var response = await _send(
      method,
      path,
      body: body,
      bearer: pair.accessToken,
      queryParameters: queryParameters,
      responseType: responseType,
      acceptHeader: acceptHeader,
    );
    if (response.statusCode == 401) {
      if (refreshed) {
        await _clearIfMatching(pair);
        throw const ApiException(
          401,
          'Your session has expired. Please sign in again.',
        );
      }
      final latest = await _readCredentials();
      if (latest == null) {
        throw const ApiException(
          401,
          'Your session has expired. Please sign in again.',
        );
      }
      pair = latest.accessToken != pair.accessToken
          ? latest
          : await _refresh(latest);
      response = await _send(
        method,
        path,
        body: body,
        bearer: pair.accessToken,
        queryParameters: queryParameters,
        responseType: responseType,
        acceptHeader: acceptHeader,
      );
      if (response.statusCode == 401) {
        await _clearIfMatching(pair);
        throw const ApiException(
          401,
          'Your session has expired. Please sign in again.',
        );
      }
    }
    _ensureSuccess(response);
    return response;
  }

  Future<TokenPair> _refresh(TokenPair observed) {
    final inFlight = _refreshing;
    if (inFlight != null) return inFlight;
    final operation = _performRefresh(observed);
    _refreshing = operation;
    return operation.whenComplete(() {
      if (identical(_refreshing, operation)) _refreshing = null;
    });
  }

  Future<TokenPair> _performRefresh(TokenPair observed) async {
    late final int startGeneration;
    final preflightPair = await _withStorageLock(() async {
      final current = await _credentials.read();
      if (current == null) {
        throw const ApiException(
          401,
          'Your session has expired. Please sign in again.',
        );
      }
      if (!_samePair(current, observed)) {
        return current;
      }
      if (_consumedRefreshTokens.contains(observed.refreshToken)) {
        await _credentials.clear();
        throw const ApiException(
          401,
          'Your session has expired. Please sign in again.',
        );
      }
      startGeneration = _authGeneration;
      _markRefreshTokenConsumed(observed.refreshToken);
      return null;
    });
    if (preflightPair != null) {
      return preflightPair;
    }

    try {
      final response = await _send(
        'POST',
        '/api/v1/native/auth/refresh',
        body: {
          'refresh_token': observed.refreshToken,
        },
      );
      _ensureSuccess(response);
      final replacement = _tokenPair(response.body);
      return await _withStorageLock(() async {
        final current = await _credentials.read();
        if (_authGeneration != startGeneration) {
          if (current != null && !_samePair(current, observed)) {
            return current;
          }
          throw const ApiException(
            401,
            'Your session has expired. Please sign in again.',
          );
        }
        if (current == null) {
          throw const ApiException(
            401,
            'Your session has expired. Please sign in again.',
          );
        }
        if (!_samePair(current, observed)) {
          return current;
        }
        // The rotated pair is persisted as one secure record before it is used.
        _consumedRefreshTokens.remove(replacement.refreshToken);
        await _credentials.write(replacement);
        return replacement;
      });
    } on Object {
      // A refresh request may have consumed the token even if its response was
      // lost. Never replay it; clear only if the failed pair is still current.
      await _clearIfMatching(observed);
      rethrow;
    }
  }

  Future<ApiResponse> _send(
    String method,
    String path, {
    Object? body,
    String? bearer,
    Map<String, String>? queryParameters,
    ApiResponseType responseType = ApiResponseType.json,
    String acceptHeader = 'application/json',
  }) async {
    try {
      return await _transport.send(
        ApiRequest(
          method: method,
          uri: _endpoint(path, queryParameters: queryParameters),
          headers: {
            'Accept': acceptHeader,
            if (bearer != null) 'Authorization': 'Bearer $bearer',
          },
          body: body,
          responseType: responseType,
        ),
      );
    } on ApiException {
      rethrow;
    } on Object {
      throw const ApiException(
        null,
        'Unable to reach BMM Auto Motors. Check the connection and try again.',
      );
    }
  }

  Object? _ensureJsonBody(ApiResponse response) {
    if (response.statusCode == 204) return null;
    final body = response.body;
    if (body is Map<String, dynamic> || body is List<dynamic>) {
      return body;
    }
    throw const ApiException(
      null,
      'The server returned an invalid response.',
    );
  }

  TokenPair _tokenPair(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['access_token'] is! String ||
        value['refresh_token'] is! String ||
        value['access_expires_at'] is! String ||
        value['token_type'] != 'Bearer') {
      throw const ApiException(
        null,
        'The server returned an invalid session response.',
      );
    }
    try {
      return TokenPair(
        accessToken: value['access_token'] as String,
        refreshToken: value['refresh_token'] as String,
        accessExpiresAt:
            DateTime.parse(value['access_expires_at'] as String).toUtc(),
      );
    } on FormatException {
      throw const ApiException(
        null,
        'The server returned an invalid session response.',
      );
    }
  }

  void _ensureSuccess(ApiResponse response) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    final message = switch (response.statusCode) {
      401 => 'Invalid sign-in or expired session.',
      403 => 'This account cannot perform that action.',
      404 => 'The requested item could not be found.',
      409 => 'This action conflicts with the current record state.',
      413 => 'The selected image exceeds the upload size limit.',
      415 => 'Only JPEG, PNG, and WebP images are accepted.',
      422 => 'Check the entered information and try again.',
      429 => 'Sign-in is temporarily unavailable. Try again later.',
      >= 500 => 'The service is temporarily unavailable. Try again later.',
      _ =>
        'The request could not be completed. Check the information and try again.',
    };
    throw ApiException(response.statusCode, message);
  }
}
