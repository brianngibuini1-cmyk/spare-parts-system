import 'package:bmm_auto_motors/app/app.dart';
import 'package:bmm_auto_motors/core/network/api_client.dart';
import 'package:bmm_auto_motors/core/network/api_transport.dart';
import 'package:bmm_auto_motors/core/security/credential_store.dart';
import 'package:bmm_auto_motors/features/authentication/auth_controller.dart';
import 'package:bmm_auto_motors/features/authentication/auth_repository.dart';
import 'package:bmm_auto_motors/features/authentication/login_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

TokenPair _validPair() => TokenPair(
      accessToken: 'saved-access',
      refreshToken: 'saved-refresh',
      accessExpiresAt: DateTime.now().toUtc().add(const Duration(minutes: 10)),
    );

void main() {
  testWidgets(
      'resuming the app revalidates the session and returns to login when the '
      'server rejects it', (tester) async {
    tester.view.physicalSize = const Size(400, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final storage = MemoryCredentialStore()..pair = _validPair();
    var sessionRevoked = false;
    final transport = CallbackTransport((request) async {
      final path = request.uri.path;
      if (path == '/api/v1/native/auth/me') {
        return sessionRevoked
            ? const ApiResponse(statusCode: 401, body: {'detail': 'expired'})
            : ApiResponse(statusCode: 200, body: meResponse());
      }
      if (path == '/api/v1/native/auth/refresh') {
        return const ApiResponse(statusCode: 401, body: {'detail': 'expired'});
      }
      if (path == '/api/v1/products') {
        return const ApiResponse(statusCode: 200, body: {'items': []});
      }
      return const ApiResponse(statusCode: 404);
    });
    final api = ApiClient(
      baseUrl: Uri.parse('https://staging.example.test'),
      transport: transport,
      credentials: storage,
    );
    final controller = AuthController(AuthRepository(api));

    await tester.pumpWidget(BmmApplication(controller: controller));
    await tester.pumpAndSettle();
    expect(controller.status, AuthStatus.signedIn);

    // Phone goes to the background; the server-side session expires.
    sessionRevoked = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(controller.status, AuthStatus.signedOut);
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(storage.pair, isNull, reason: 'rejected credentials are cleared');
  });

  testWidgets('resuming while offline keeps the signed-in screen',
      (tester) async {
    tester.view.physicalSize = const Size(400, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final storage = MemoryCredentialStore()..pair = _validPair();
    var offline = false;
    final transport = CallbackTransport((request) async {
      if (offline) throw Exception('network down');
      final path = request.uri.path;
      if (path == '/api/v1/native/auth/me') {
        return ApiResponse(statusCode: 200, body: meResponse());
      }
      if (path == '/api/v1/products') {
        return const ApiResponse(statusCode: 200, body: {'items': []});
      }
      return const ApiResponse(statusCode: 404);
    });
    final controller = AuthController(
      AuthRepository(
        ApiClient(
          baseUrl: Uri.parse('https://staging.example.test'),
          transport: transport,
          credentials: storage,
        ),
      ),
    );

    await tester.pumpWidget(BmmApplication(controller: controller));
    await tester.pumpAndSettle();
    expect(controller.status, AuthStatus.signedIn);

    offline = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(controller.status, AuthStatus.signedIn);
    expect(storage.pair, isNotNull);
  });

  testWidgets('non-production builds display the environment banner',
      (tester) async {
    final controller = AuthController(
      AuthRepository(
        ApiClient(
          baseUrl: Uri.parse('https://staging.example.test'),
          transport: CallbackTransport(
            (_) async => const ApiResponse(statusCode: 401),
          ),
          credentials: MemoryCredentialStore(),
        ),
      ),
    );
    await tester.pumpWidget(
      BmmApplication(controller: controller, environmentBanner: 'STAGING'),
    );
    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsOneWidget);
    final banner = tester.widget<Banner>(find.byType(Banner));
    expect(banner.message, 'STAGING');
  });

  test('revalidate is a no-op when no user is signed in', () async {
    final transport = CallbackTransport(
      (_) async => const ApiResponse(statusCode: 500),
    );
    final controller = AuthController(
      AuthRepository(
        ApiClient(
          baseUrl: Uri.parse('https://staging.example.test'),
          transport: transport,
          credentials: MemoryCredentialStore(),
        ),
      ),
    );
    controller.status = AuthStatus.signedOut;
    await controller.revalidate();
    expect(transport.requests, isEmpty);
  });
}
