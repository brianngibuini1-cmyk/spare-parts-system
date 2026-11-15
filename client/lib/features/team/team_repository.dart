import '../../core/errors/api_exception.dart';
import '../../core/network/api_client.dart';
import 'team_models.dart';

class TeamRepository {
  const TeamRepository(this.api);

  final ApiClient api;

  Future<List<AttendantAccount>> listAttendants() async {
    final body = await api.get('/api/v1/attendants');
    if (body is! List<dynamic>) {
      throw const ApiException(
        null,
        'The server returned an invalid attendant list response.',
      );
    }
    return List<AttendantAccount>.unmodifiable(
      body.map(AttendantAccount.fromJson),
    );
  }

  Future<AttendantAccount> createAttendant(AttendantCreateInput input) async {
    final body = await api.post('/api/v1/attendants', body: input.toJson());
    return AttendantAccount.fromJson(body);
  }

  Future<AttendantAccount> setAttendantStatus(
    int userId,
    AttendantStatusInput input,
  ) async {
    final body = await api.patch(
      '/api/v1/attendants/$userId',
      body: input.toJson(),
    );
    return AttendantAccount.fromJson(body);
  }
}
