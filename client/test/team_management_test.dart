import 'dart:async';

import 'package:bmm_auto_motors/core/errors/api_exception.dart';
import 'package:bmm_auto_motors/core/network/api_client.dart';
import 'package:bmm_auto_motors/core/network/api_transport.dart';
import 'package:bmm_auto_motors/core/security/credential_store.dart';
import 'package:bmm_auto_motors/features/navigation/app_shell.dart';
import 'package:bmm_auto_motors/features/team/team_controller.dart';
import 'package:bmm_auto_motors/features/team/team_management_screen.dart';
import 'package:bmm_auto_motors/features/team/team_models.dart';
import 'package:bmm_auto_motors/features/team/team_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _NoopTransport implements ApiTransport {
  @override
  void close({bool force = false}) {}

  @override
  Future<ApiResponse> send(ApiRequest request) =>
      throw UnimplementedError('Unexpected network call in fake test.');
}

class _NoopCredentialStore implements CredentialStore {
  @override
  Future<void> clear() async {}

  @override
  Future<TokenPair?> read() async => null;

  @override
  Future<void> write(TokenPair pair) async {}
}

ApiClient _dummyApiClient() => ApiClient(
      baseUrl: Uri.parse('https://example.test'),
      transport: _NoopTransport(),
      credentials: _NoopCredentialStore(),
    );

class _FakeTeamRepository extends TeamRepository {
  _FakeTeamRepository() : super(_dummyApiClient());

  final List<AttendantAccount> accounts = <AttendantAccount>[
    AttendantAccount(
      id: 2,
      loginName: 'attendant1@example.test',
      isActive: true,
      createdAt: DateTime.utc(2026, 11, 10, 9),
    ),
  ];

  ApiException? nextListError;
  ApiException? nextMutationError;
  Completer<void>? mutationCompleter;
  int createCalls = 0;

  @override
  Future<List<AttendantAccount>> listAttendants() async {
    if (nextListError != null) {
      final err = nextListError!;
      nextListError = null;
      throw err;
    }
    return List<AttendantAccount>.unmodifiable(accounts);
  }

  @override
  Future<AttendantAccount> createAttendant(AttendantCreateInput input) async {
    createCalls += 1;
    if (mutationCompleter != null) {
      await mutationCompleter!.future;
    }
    if (nextMutationError != null) {
      final err = nextMutationError!;
      nextMutationError = null;
      throw err;
    }
    final normalized = input.loginName.trim().toLowerCase();
    if (accounts.any((a) => a.loginName == normalized)) {
      throw const ApiException(
        409,
        'An account with that login name already exists.',
      );
    }
    final created = AttendantAccount(
      id: accounts.length + 2,
      loginName: normalized,
      isActive: true,
      createdAt: DateTime.utc(2026, 11, 13, 12),
    );
    accounts.add(created);
    return created;
  }

  @override
  Future<AttendantAccount> setAttendantStatus(
    int userId,
    AttendantStatusInput input,
  ) async {
    if (mutationCompleter != null) {
      await mutationCompleter!.future;
    }
    if (nextMutationError != null) {
      final err = nextMutationError!;
      nextMutationError = null;
      throw err;
    }
    final idx = accounts.indexWhere((a) => a.id == userId);
    if (idx == -1) {
      throw const ApiException(404, 'Attendant not found.');
    }
    final current = accounts[idx];
    final updated = AttendantAccount(
      id: current.id,
      loginName: current.loginName,
      isActive: input.isActive,
      role: current.role,
      createdAt: current.createdAt,
    );
    accounts[idx] = updated;
    return updated;
  }
}

void main() {
  testWidgets(
      'Owner can open Team Management from AppShell and view attendants',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = _FakeTeamRepository();
    final controller = TeamController(repo, isOwner: true);

    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(
          user: const AuthenticatedUser(
            id: 1,
            loginName: 'owner@example.test',
            role: 'OWNER',
          ),
          onLogout: () async {},
          teamController: controller,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Team management'));
    await tester.pumpAndSettle();

    expect(find.text('1 attendant account(s)'), findsOneWidget);
    expect(find.text('attendant1@example.test'), findsOneWidget);
    expect(find.text('Active'), findsOneWidget);
    controller.dispose();
  });

  testWidgets('Attendant cannot access Team Management in AppShell or screen',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = _FakeTeamRepository();
    final controller = TeamController(repo, isOwner: false);

    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(
          user: const AuthenticatedUser(
            id: 2,
            loginName: 'attendant1@example.test',
            role: 'SHOP_ATTENDANT',
          ),
          onLogout: () async {},
          teamController: controller,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Team management'), findsNothing);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TeamManagementScreen(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Owner access is required to manage attendant accounts.'),
      findsOneWidget,
    );
    expect(
      await controller.createAttendant(
        const AttendantCreateInput(
          loginName: 'blocked',
          password: 'password-at-least-15-chars',
        ),
      ),
      isNull,
    );
    expect(repo.createCalls, 0);
    controller.dispose();
  });

  testWidgets('TeamManagementScreen shows empty and error states with retry',
      (tester) async {
    final repo = _FakeTeamRepository()
      ..accounts.clear()
      ..nextListError = const ApiException(500, 'Server temporarily down.');
    final controller = TeamController(repo, isOwner: true);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TeamManagementScreen(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Server temporarily down.'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('No attendant accounts yet.'), findsOneWidget);
    controller.dispose();
  });

  testWidgets(
      'TeamManagementScreen validates input, creates, edits, deactivates, and reactivates',
      (tester) async {
    final repo = _FakeTeamRepository();
    final controller = TeamController(repo, isOwner: true);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TeamManagementScreen(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Open Add attendant dialog and trigger validation errors
    await tester.tap(find.text('Add attendant'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Create attendant'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a login name.'), findsOneWidget);
    expect(
      find.text('Password must contain at least 15 characters.'),
      findsOneWidget,
    );

    // Mismatched confirmation
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Login name *'),
      'attendant2@example.test',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password *'),
      'strong-attendant-pass-2026',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Confirm password *'),
      'different-password-2026',
    );
    await tester.tap(find.text('Create attendant'));
    await tester.pumpAndSettle();
    expect(find.text('Passwords do not match.'), findsOneWidget);

    // Valid creation
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Confirm password *'),
      'strong-attendant-pass-2026',
    );
    await tester.tap(find.text('Create attendant'));
    await tester.pumpAndSettle();

    expect(find.text('2 attendant account(s)'), findsOneWidget);
    expect(find.text('attendant2@example.test'), findsOneWidget);

    // Quick deactivate with confirmation
    await tester.tap(find.text('Deactivate').first);
    await tester.pumpAndSettle();
    expect(find.text('Deactivate attendant'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Deactivate'));
    await tester.pumpAndSettle();

    expect(find.text('Inactive'), findsOneWidget);

    // Edit via Manage dialog to reactivate
    await tester.tap(find.byIcon(Icons.edit_outlined).first);
    await tester.pumpAndSettle();
    expect(find.text('Attendant account'), findsOneWidget);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(find.text('Inactive'), findsNothing);
    expect(find.text('Active'), findsNWidgets(2));
    controller.dispose();
  });

  test('TeamController handles 401 expiry and prevents duplicate submissions',
      () async {
    final repo = _FakeTeamRepository();
    String? expiredMsg;
    final completer = Completer<void>();
    repo.mutationCompleter = completer;

    final controller = TeamController(
      repo,
      isOwner: true,
      onSessionExpired: (msg) => expiredMsg = msg,
    );

    final firstCall = controller.createAttendant(
      const AttendantCreateInput(
        loginName: 'new.attendant',
        password: 'strong-attendant-pass-2026',
      ),
    );
    final duplicateCall = controller.createAttendant(
      const AttendantCreateInput(
        loginName: 'new.attendant',
        password: 'strong-attendant-pass-2026',
      ),
    );

    expect(await duplicateCall, isNull);
    expect(repo.createCalls, 1);

    completer.complete();
    final created = await firstCall;
    expect(created, isNotNull);

    repo.mutationCompleter = null;
    repo.nextListError = const ApiException(401, 'Session expired.');
    await controller.loadAttendants();
    expect(expiredMsg, 'Session expired.');
    controller.dispose();
  });
}
