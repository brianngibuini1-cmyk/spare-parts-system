import 'package:flutter/foundation.dart';

import '../../core/errors/api_exception.dart';
import '../../core/network/api_client.dart';
import 'auth_repository.dart';

enum AuthStatus { loading, signedOut, signedIn, error }

class AuthController extends ChangeNotifier {
  AuthController(this.repository);
  final AuthRepository repository;
  AuthStatus status = AuthStatus.loading;
  AuthenticatedUser? user;
  String? errorMessage;

  Future<void> restore() async {
    status = AuthStatus.loading;
    errorMessage = null;
    notifyListeners();
    try {
      user = await repository.restore();
      status = AuthStatus.signedIn;
    } on ApiException catch (error) {
      if (error.statusCode == 401) {
        status = AuthStatus.signedOut;
      } else {
        status = AuthStatus.error;
        errorMessage = error.message;
      }
    } on Object {
      status = AuthStatus.error;
      errorMessage =
          'Unable to restore your session. Check the connection and try again.';
    }
    notifyListeners();
  }

  Future<bool> signIn(String loginName, String password) async {
    errorMessage = null;
    status = AuthStatus.loading;
    notifyListeners();
    try {
      user = await repository.signIn(loginName, password);
      status = AuthStatus.signedIn;
      notifyListeners();
      return true;
    } on ApiException catch (error) {
      status = AuthStatus.signedOut;
      errorMessage = error.message;
    } on Object {
      status = AuthStatus.signedOut;
      errorMessage = 'Sign-in failed. Check your details and connection.';
    }
    notifyListeners();
    return false;
  }

  Future<void> signOut() async {
    try {
      await repository.signOut();
    } on Object {
      // Local credentials are cleared by the repository's logout path even if
      // the server cannot be reached. The user should still leave this device.
    } finally {
      user = null;
      errorMessage = null;
      status = AuthStatus.signedOut;
      notifyListeners();
    }
  }

  void handleSessionExpired([String? message]) {
    user = null;
    errorMessage = message ?? 'Your session has expired. Please sign in again.';
    status = AuthStatus.signedOut;
    notifyListeners();
  }

  Future<void>? _revalidating;

  /// Re-checks a signed-in session, for example when a phone app returns to
  /// the foreground after the server-side idle timeout may have elapsed.
  ///
  /// A rejected session returns the user to the login screen. Connectivity
  /// failures keep the current screen; the next API action reports them.
  Future<void> revalidate() {
    if (status != AuthStatus.signedIn || user == null) {
      return Future<void>.value();
    }
    return _revalidating ??= _performRevalidate().whenComplete(() {
      _revalidating = null;
    });
  }

  Future<void> _performRevalidate() async {
    final observedUser = user;
    try {
      final current = await repository.restore();
      if (status != AuthStatus.signedIn || !identical(user, observedUser)) {
        return;
      }
      if (current.id != observedUser?.id ||
          current.role != observedUser?.role ||
          current.loginName != observedUser?.loginName) {
        user = current;
        notifyListeners();
      }
    } on ApiException catch (error) {
      if (error.statusCode == 401 &&
          status == AuthStatus.signedIn &&
          identical(user, observedUser)) {
        handleSessionExpired();
      }
    } on Object {
      // Keep the current screen; transient connectivity loss is reported by
      // the next user-initiated request.
    }
  }
}
