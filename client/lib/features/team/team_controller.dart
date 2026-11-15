import 'package:flutter/foundation.dart';

import '../../core/errors/api_exception.dart';
import 'team_models.dart';
import 'team_repository.dart';

class TeamController extends ChangeNotifier {
  TeamController(
    this.repository, {
    this.onSessionExpired,
    this.isOwner = false,
  });

  final TeamRepository repository;
  final void Function(String message)? onSessionExpired;
  final bool isOwner;

  bool _disposed = false;

  List<AttendantAccount> attendants = const [];
  bool isLoading = false;
  bool isSaving = false;
  String? listError;
  String? actionMessage;
  String? actionError;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_disposed) {
      super.notifyListeners();
    }
  }

  void clearFeedback() {
    if (actionMessage == null && actionError == null) {
      return;
    }
    actionMessage = null;
    actionError = null;
    notifyListeners();
  }

  Future<void> loadAttendants() async {
    if (!isOwner) {
      listError = 'Owner access is required to manage attendant accounts.';
      notifyListeners();
      return;
    }
    isLoading = true;
    listError = null;
    notifyListeners();

    try {
      attendants = await repository.listAttendants();
    } on ApiException catch (error) {
      if (error.statusCode == 401) {
        onSessionExpired?.call(error.message);
        return;
      }
      listError = error.message;
    } catch (_) {
      listError = 'Unable to load attendant accounts right now.';
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<AttendantAccount?> createAttendant(AttendantCreateInput input) async {
    if (!isOwner) {
      actionError = 'Only the owner can create attendant accounts.';
      notifyListeners();
      return null;
    }
    if (isSaving) {
      return null;
    }
    isSaving = true;
    actionError = null;
    actionMessage = null;
    notifyListeners();

    try {
      final created = await repository.createAttendant(input);
      actionMessage = 'Created attendant account ${created.loginName}.';
      await loadAttendants();
      return created;
    } on ApiException catch (error) {
      if (error.statusCode == 401) {
        onSessionExpired?.call(error.message);
        return null;
      }
      actionError = error.message;
      return null;
    } catch (_) {
      actionError = 'Unable to create attendant account right now.';
      return null;
    } finally {
      isSaving = false;
      notifyListeners();
    }
  }

  Future<AttendantAccount?> setAttendantStatus(
    AttendantAccount attendant, {
    required bool isActive,
  }) async {
    if (!isOwner) {
      actionError = 'Only the owner can change attendant account status.';
      notifyListeners();
      return null;
    }
    if (isSaving) {
      return null;
    }
    isSaving = true;
    actionError = null;
    actionMessage = null;
    notifyListeners();

    try {
      final updated = await repository.setAttendantStatus(
        attendant.id,
        AttendantStatusInput(isActive: isActive),
      );
      actionMessage =
          '${updated.loginName} ${updated.isActive ? 'activated' : 'deactivated'}.';
      await loadAttendants();
      return updated;
    } on ApiException catch (error) {
      if (error.statusCode == 401) {
        onSessionExpired?.call(error.message);
        return null;
      }
      actionError = error.message;
      return null;
    } catch (_) {
      actionError = 'Unable to update attendant status right now.';
      return null;
    } finally {
      isSaving = false;
      notifyListeners();
    }
  }
}
