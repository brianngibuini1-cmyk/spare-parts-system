import 'package:bmm_auto_motors/app/theme.dart';
import 'package:bmm_auto_motors/app/app.dart';
import 'package:bmm_auto_motors/core/network/api_client.dart';
import 'package:bmm_auto_motors/core/network/api_transport.dart';
import 'package:bmm_auto_motors/core/security/credential_store.dart';
import 'package:bmm_auto_motors/features/authentication/auth_controller.dart';
import 'package:bmm_auto_motors/features/authentication/auth_repository.dart';
import 'package:bmm_auto_motors/features/authentication/login_screen.dart';
import 'package:bmm_auto_motors/features/navigation/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('login validates empty fields before calling the API',
      (tester) async {
    final api = ApiClient(
      baseUrl: Uri.parse('https://staging.example.test'),
      transport: CallbackTransport(
        (_) async => throw StateError('API must not be called'),
      ),
      credentials: MemoryCredentialStore(),
    );
    final controller = AuthController(AuthRepository(api))
      ..status = AuthStatus.signedOut;
    await tester.pumpWidget(
      MaterialApp(
        theme: BmmTheme.light,
        home: LoginScreen(controller: controller),
      ),
    );
    await tester.tap(find.text('Sign in'));
    await tester.pump();
    expect(find.text('Enter your login name.'), findsOneWidget);
    expect(find.text('Enter your password.'), findsOneWidget);
  });

  testWidgets('attendant navigation exposes attendant destinations',
      (tester) async {
    tester.view.physicalSize = const Size(400, 850);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      MaterialApp(
        theme: BmmTheme.light,
        home: AppShell(
          user: const AuthenticatedUser(
            id: 3,
            loginName: 'attendant',
            role: 'SHOP_ATTENDANT',
          ),
          onLogout: () async {},
        ),
      ),
    );
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    expect(find.text('Stock receiving'), findsOneWidget);
    expect(find.text('Receipts'), findsOneWidget);
    expect(find.text('Team management'), findsNothing);
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  testWidgets('owner navigation includes approval and team management',
      (tester) async {
    tester.view.physicalSize = const Size(400, 850);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      MaterialApp(
        theme: BmmTheme.light,
        home: AppShell(
          user:
              const AuthenticatedUser(id: 1, loginName: 'owner', role: 'OWNER'),
          onLogout: () async {},
        ),
      ),
    );
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    expect(find.text('Product approvals'), findsOneWidget);
    expect(find.text('Team management'), findsOneWidget);
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  testWidgets('application restores a saved session from the authenticated API',
      (tester) async {
    final storage = MemoryCredentialStore()
      ..pair = TokenPair(
        accessToken: 'a',
        refreshToken: 'r',
        accessExpiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
      );
    final transport = CallbackTransport((request) async {
      expect(request.uri.path, '/api/v1/native/auth/me');
      return ApiResponse(statusCode: 200, body: meResponse(role: 'OWNER'));
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
    expect(find.text('Dashboard'), findsWidgets);
    expect(controller.user?.role, 'OWNER');
  });

  test('credential abstraction supports atomic replacement and clearing',
      () async {
    final storage = MemoryCredentialStore();
    final pair = TokenPair(
      accessToken: 'access',
      refreshToken: 'refresh',
      accessExpiresAt: DateTime.utc(2026),
    );
    await storage.write(pair);
    expect((await storage.read())?.refreshToken, 'refresh');
    await storage.clear();
    expect(await storage.read(), isNull);
  });
}
