import 'package:bmm_auto_motors/core/config/app_config.dart';
import 'package:bmm_auto_motors/core/security/credential_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rejects insecure and malformed API endpoints by default', () {
    for (final value in [
      'http://api.example.test',
      'not a url',
      'https://user:secret@example.test',
    ]) {
      expect(
        () => AppConfig.fromValue(value),
        throwsA(isA<ConfigurationException>()),
      );
    }
  });

  test('accepts a configured HTTPS staging endpoint', () {
    final config = AppConfig.fromValue('https://staging.example.test');
    expect(config.apiBaseUrl.host, 'staging.example.test');
    expect(config.environment, AppEnvironment.staging);
    expect(config.productImageMaxBytes, 5 * 1024 * 1024);
  });

  test('parses APP_ENV values and rejects unknown environment names', () {
    expect(AppEnvironment.parse(''), AppEnvironment.staging);
    expect(AppEnvironment.parse('staging'), AppEnvironment.staging);
    expect(AppEnvironment.parse('STAGE'), AppEnvironment.staging);
    expect(AppEnvironment.parse('development'), AppEnvironment.development);
    expect(AppEnvironment.parse('dev'), AppEnvironment.development);
    expect(AppEnvironment.parse('production'), AppEnvironment.production);
    expect(AppEnvironment.parse('PROD'), AppEnvironment.production);

    expect(
      () => AppConfig.fromValue(
        'https://staging.example.test',
        appEnvRaw: 'unknown-env',
      ),
      throwsA(isA<ConfigurationException>()),
    );
  });

  test(
      'permits controlled development HTTP only in non-release development mode with explicit opt-in',
      () {
    // Without ALLOW_INSECURE_DEV_HTTP, HTTP is rejected even in development.
    expect(
      () => AppConfig.fromValue(
        'http://127.0.0.1:8000',
        appEnvRaw: 'development',
        targetPlatform: TargetPlatform.windows,
      ),
      throwsA(isA<ConfigurationException>()),
    );

    // Windows desktop controlled local development with explicit opt-in succeeds.
    final windowsDev = AppConfig.fromValue(
      'http://127.0.0.1:8000',
      appEnvRaw: 'development',
      allowInsecureDevHttp: true,
      isReleaseMode: false,
      targetPlatform: TargetPlatform.windows,
    );
    expect(windowsDev.environment, AppEnvironment.development);
    expect(windowsDev.apiBaseUrl.toString(), 'http://127.0.0.1:8000');

    // Release builds never allow development mode or cleartext HTTP.
    expect(
      () => AppConfig.fromValue(
        'https://staging.example.test',
        appEnvRaw: 'development',
        isReleaseMode: true,
        targetPlatform: TargetPlatform.windows,
      ),
      throwsA(isA<ConfigurationException>()),
    );
    expect(
      () => AppConfig.fromValue(
        'https://staging.example.test',
        allowInsecureDevHttp: true,
        isReleaseMode: true,
        targetPlatform: TargetPlatform.windows,
      ),
      throwsA(isA<ConfigurationException>()),
    );
    expect(
      () => AppConfig.fromValue(
        'http://staging.example.test',
        appEnvRaw: 'staging',
        allowInsecureDevHttp: true,
        isReleaseMode: false,
        targetPlatform: TargetPlatform.windows,
      ),
      throwsA(isA<ConfigurationException>()),
    );
  });

  test(
      'enforces platform-specific host rules for Android, Windows, and iOS targets',
      () {
    // On Android, localhost and 127.0.0.1 refer to the handset/emulator itself.
    for (final invalidAndroidUrl in [
      'https://localhost:8000',
      'https://127.0.0.1:8000',
      'http://localhost:8000',
      'http://127.0.0.1:8000',
    ]) {
      expect(
        () => AppConfig.fromValue(
          invalidAndroidUrl,
          appEnvRaw: 'development',
          allowInsecureDevHttp: true,
          isReleaseMode: false,
          targetPlatform: TargetPlatform.android,
        ),
        throwsA(isA<ConfigurationException>()),
      );
    }

    // Android emulator alias 10.0.2.2 is accepted on Android in development mode.
    final androidEmulatorConfig = AppConfig.fromValue(
      'http://10.0.2.2:8000',
      appEnvRaw: 'development',
      allowInsecureDevHttp: true,
      isReleaseMode: false,
      targetPlatform: TargetPlatform.android,
    );
    expect(androidEmulatorConfig.apiBaseUrl.host, '10.0.2.2');

    // Physical Android devices cannot use cleartext LAN HTTP: Android's debug
    // network security configuration blocks it, so the client rejects it with
    // guidance instead of failing later with a generic network error.
    expect(
      () => AppConfig.fromValue(
        'http://192.168.1.25:8000',
        appEnvRaw: 'development',
        allowInsecureDevHttp: true,
        isReleaseMode: false,
        targetPlatform: TargetPlatform.android,
      ),
      throwsA(
        isA<ConfigurationException>().having(
          (e) => e.message,
          'message',
          contains('blocked by Android'),
        ),
      ),
    );

    // A USB-connected physical device reaches the development computer via
    // `adb reverse` on its own loopback, only with the explicit opt-in.
    final androidAdbReverseConfig = AppConfig.fromValue(
      'http://127.0.0.1:8000',
      appEnvRaw: 'development',
      allowInsecureDevHttp: true,
      androidAdbReverse: true,
      isReleaseMode: false,
      targetPlatform: TargetPlatform.android,
    );
    expect(androidAdbReverseConfig.apiBaseUrl.host, '127.0.0.1');

    // HTTPS staging on a real host is the route for release device testing.
    final androidStaging = AppConfig.fromValue(
      'https://staging.example.test',
      appEnvRaw: 'staging',
      isReleaseMode: true,
      targetPlatform: TargetPlatform.android,
    );
    expect(androidStaging.apiBaseUrl.scheme, 'https');

    // 10.0.2.2 is rejected on Windows and iOS, and rejected on Android in staging/production/release.
    expect(
      () => AppConfig.fromValue(
        'http://10.0.2.2:8000',
        appEnvRaw: 'development',
        allowInsecureDevHttp: true,
        isReleaseMode: false,
        targetPlatform: TargetPlatform.windows,
      ),
      throwsA(isA<ConfigurationException>()),
    );
    expect(
      () => AppConfig.fromValue(
        'https://10.0.2.2:8000',
        appEnvRaw: 'staging',
        isReleaseMode: false,
        targetPlatform: TargetPlatform.android,
      ),
      throwsA(isA<ConfigurationException>()),
    );

    // On iOS, localhost/127.0.0.1 are rejected while HTTPS staging/production succeed.
    expect(
      () => AppConfig.fromValue(
        'https://localhost:8000',
        appEnvRaw: 'development',
        isReleaseMode: false,
        targetPlatform: TargetPlatform.iOS,
      ),
      throwsA(isA<ConfigurationException>()),
    );
    final iosProdConfig = AppConfig.fromValue(
      'https://api.bmmautomotors.example',
      appEnvRaw: 'production',
      isReleaseMode: true,
      targetPlatform: TargetPlatform.iOS,
    );
    expect(iosProdConfig.environment, AppEnvironment.production);
    expect(iosProdConfig.apiBaseUrl.host, 'api.bmmautomotors.example');

    // iOS requires HTTPS even in development with the cleartext opt-in.
    expect(
      () => AppConfig.fromValue(
        'http://192.168.1.25:8000',
        appEnvRaw: 'development',
        allowInsecureDevHttp: true,
        isReleaseMode: false,
        targetPlatform: TargetPlatform.iOS,
      ),
      throwsA(isA<ConfigurationException>()),
    );
  });

  test('ANDROID_ADB_REVERSE is restricted to non-release Android development',
      () {
    for (final (env, release, platform) in [
      ('staging', false, TargetPlatform.android),
      ('production', false, TargetPlatform.android),
      ('development', true, TargetPlatform.android),
      ('development', false, TargetPlatform.windows),
      ('development', false, TargetPlatform.iOS),
    ]) {
      expect(
        () => AppConfig.fromValue(
          'http://127.0.0.1:8000',
          appEnvRaw: env,
          allowInsecureDevHttp: !release,
          androidAdbReverse: true,
          isReleaseMode: release,
          targetPlatform: platform,
        ),
        throwsA(isA<ConfigurationException>()),
        reason: '$env release=$release $platform',
      );
    }
  });

  test('release builds reject every development endpoint shape', () {
    for (final platform in TargetPlatform.values) {
      for (final url in [
        'http://127.0.0.1:8000',
        'https://localhost:8443',
        'https://10.0.2.2:8443',
      ]) {
        expect(
          () => AppConfig.fromValue(
            url,
            appEnvRaw: 'production',
            isReleaseMode: true,
            targetPlatform: platform,
          ),
          throwsA(isA<ConfigurationException>()),
          reason: '$url on $platform',
        );
      }
    }
    expect(
      () => AppConfig.fromValue('', isReleaseMode: true),
      throwsA(isA<ConfigurationException>()),
    );
  });

  test('non-production environments expose a visible banner label', () {
    expect(
      AppConfig.fromValue('https://api.example.test', appEnvRaw: 'production')
          .environmentBannerLabel,
      isNull,
    );
    expect(
      AppConfig.fromValue('https://api.example.test').environmentBannerLabel,
      'STAGING',
    );
    expect(
      AppConfig.fromValue(
        'https://dev.example.test',
        appEnvRaw: 'development',
        isReleaseMode: false,
      ).environmentBannerLabel,
      'DEV',
    );
  });

  test('exposes consistent cross-platform application identity constants', () {
    expect(AppConfig.applicationName, 'BMM Auto Motors');
    expect(AppConfig.androidApplicationId, 'com.bmmautomotors.bmm_auto_motors');
    expect(AppConfig.iosBundleIdentifier, 'com.bmmautomotors.bmmAutoMotors');
    expect(AppConfig.windowsApplicationId, 'com.bmmautomotors.bmm_auto_motors');
    expect(AppConfig.windowsExecutableName, 'bmm_auto_motors.exe');
  });

  test('aligns product image upload byte limit with backend default and bounds',
      () {
    expect(AppConfig.defaultProductImageMaxBytes, 5 * 1024 * 1024);
    expect(AppConfig.maxSupportedProductImageMaxBytes, 20 * 1024 * 1024);
    expect(AppConfig.parseProductImageMaxBytes(''), 5 * 1024 * 1024);
    expect(AppConfig.parseProductImageMaxBytes('1048576'), 1048576);
    expect(
      AppConfig.parseProductImageMaxBytes('${20 * 1024 * 1024}'),
      20 * 1024 * 1024,
    );

    for (final invalid in ['0', '-5', '${20 * 1024 * 1024 + 1}', 'abc']) {
      expect(
        () => AppConfig.fromValue(
          'https://staging.example.test',
          productImageMaxBytesRaw: invalid,
        ),
        throwsA(isA<ConfigurationException>()),
      );
    }
  });

  test(
      'SecureCredentialStore persists, reads, clears, and heals corrupted records via FlutterSecureStorage',
      () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    final store = SecureCredentialStore();

    expect(
      SecureCredentialStore.defaultAndroidOptions.toMap(),
      containsPair('encryptedSharedPreferences', 'true'),
    );
    expect(
      SecureCredentialStore.defaultAndroidOptions.toMap(),
      containsPair('resetOnError', 'true'),
    );
    expect(
      SecureCredentialStore.defaultIosOptions.toMap(),
      containsPair('accessibility', 'first_unlock_this_device'),
    );
    expect(
      SecureCredentialStore.defaultIosOptions.toMap(),
      containsPair('synchronizable', 'false'),
    );

    expect(await store.read(), isNull);

    final expiresAt = DateTime.utc(2026, 11, 12, 10, 30);
    final pair = TokenPair(
      accessToken: 'access-token-1',
      refreshToken: 'refresh-token-1',
      accessExpiresAt: expiresAt,
    );
    await store.write(pair);

    final loaded = await store.read();
    expect(loaded, isNotNull);
    expect(loaded!.accessToken, 'access-token-1');
    expect(loaded.refreshToken, 'refresh-token-1');
    expect(loaded.accessExpiresAt, expiresAt);

    await store.clear();
    expect(await store.read(), isNull);

    // Corrupted JSON payload is automatically cleared and returns null.
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'bmm_native_session_v1': '{corrupted-json',
    });
    expect(await store.read(), isNull);
    expect(
      await SecureCredentialStore.defaultSecureStorage
          .read(key: 'bmm_native_session_v1'),
      isNull,
    );
  });
}
