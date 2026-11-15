import '../../core/network/api_client.dart';

class AuthRepository {
  const AuthRepository(this.api);
  final ApiClient api;

  Future<AuthenticatedUser> signIn(String loginName, String password) async {
    await api.login(loginName.trim(), password);
    try {
      return await api.me();
    } on Object {
      await api.logout();
      rethrow;
    }
  }

  Future<AuthenticatedUser> restore() => api.me();
  Future<void> signOut() => api.logout();
}
