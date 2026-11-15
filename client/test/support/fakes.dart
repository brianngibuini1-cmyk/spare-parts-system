import 'package:bmm_auto_motors/core/network/api_transport.dart';
import 'package:bmm_auto_motors/core/security/credential_store.dart';

class MemoryCredentialStore implements CredentialStore {
  TokenPair? pair;
  @override
  Future<TokenPair?> read() async => pair;
  @override
  Future<void> write(TokenPair value) async => pair = value;
  @override
  Future<void> clear() async => pair = null;
}

class CallbackTransport implements ApiTransport {
  CallbackTransport(this.callback);
  final Future<ApiResponse> Function(ApiRequest request) callback;
  final List<ApiRequest> requests = [];
  bool isClosed = false;
  @override
  Future<ApiResponse> send(ApiRequest request) {
    if (isClosed) {
      throw StateError('Transport is closed.');
    }
    requests.add(request);
    return callback(request);
  }

  @override
  void close({bool force = false}) {
    isClosed = true;
  }
}

Map<String, Object> tokenResponse({
  String access = 'new-access',
  String refresh = 'new-refresh',
}) =>
    {
      'access_token': access,
      'token_type': 'Bearer',
      'expires_in': 600,
      'access_expires_at': DateTime.now()
          .toUtc()
          .add(const Duration(minutes: 10))
          .toIso8601String(),
      'refresh_token': refresh,
      'refresh_expires_at': DateTime.now()
          .toUtc()
          .add(const Duration(minutes: 30))
          .toIso8601String(),
      'session_expires_at': DateTime.now()
          .toUtc()
          .add(const Duration(hours: 12))
          .toIso8601String(),
      'user': {'id': 7, 'login_name': 'attendant1', 'role': 'SHOP_ATTENDANT'},
    };

Map<String, Object> meResponse({String role = 'SHOP_ATTENDANT'}) => {
      'id': 7,
      'login_name': 'attendant1',
      'role': role,
      'session_idle_expires_at': DateTime.now()
          .toUtc()
          .add(const Duration(minutes: 30))
          .toIso8601String(),
      'session_expires_at': DateTime.now()
          .toUtc()
          .add(const Duration(hours: 12))
          .toIso8601String(),
      'access_expires_at': DateTime.now()
          .toUtc()
          .add(const Duration(minutes: 10))
          .toIso8601String(),
    };
