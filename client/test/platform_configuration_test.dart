// Static checks over the native platform runner files. These guard the
// release security posture and cross-platform identity against accidental
// regressions; they do not replace building and running on each platform.
import 'dart:io';

import 'package:bmm_auto_motors/core/config/app_config.dart';
import 'package:flutter_test/flutter_test.dart';

String _read(String relativePath) {
  final file = File(relativePath);
  expect(file.existsSync(), isTrue, reason: '$relativePath must exist');
  return file.readAsStringSync();
}

void main() {
  group('Android', () {
    test('release manifest requests INTERNET and forbids cleartext/backup', () {
      final manifest = _read('android/app/src/main/AndroidManifest.xml');
      expect(manifest, contains('android.permission.INTERNET'));
      expect(manifest, contains('android:usesCleartextTraffic="false"'));
      expect(manifest, contains('android:allowBackup="false"'));
      expect(
        manifest,
        contains(
          'android:networkSecurityConfig="@xml/network_security_config"',
        ),
      );
      expect(
        manifest,
        contains('android:label="${AppConfig.applicationName}"'),
      );
    });

    test('main network security config permits no cleartext or user CAs', () {
      final config =
          _read('android/app/src/main/res/xml/network_security_config.xml');
      expect(config, contains('cleartextTrafficPermitted="false"'));
      expect(config, isNot(contains('cleartextTrafficPermitted="true"')));
      expect(config, isNot(contains('src="user"')));
    });

    test('debug-only cleartext is limited to emulator and adb reverse hosts',
        () {
      final config =
          _read('android/app/src/debug/res/xml/network_security_config.xml');
      final domains = RegExp(r'<domain[^>]*>([^<]+)</domain>')
          .allMatches(config)
          .map((m) => m.group(1)!.trim())
          .toSet();
      expect(domains, {'10.0.2.2', '127.0.0.1', 'localhost'});
      expect(
        RegExp(r'<base-config cleartextTrafficPermitted="false"')
            .hasMatch(config),
        isTrue,
      );
    });

    test('secure-storage files are excluded from backup and device transfer',
        () {
      for (final path in [
        'android/app/src/main/res/xml/backup_rules.xml',
        'android/app/src/main/res/xml/data_extraction_rules.xml',
      ]) {
        expect(_read(path), contains('FlutterSecureStorage'), reason: path);
      }
    });

    test('Gradle application id matches AppConfig and signing stays external',
        () {
      final gradle = _read('android/app/build.gradle.kts');
      expect(
        gradle,
        contains('applicationId = "${AppConfig.androidApplicationId}"'),
      );
      expect(gradle, contains('rootProject.file("key.properties")'));
      expect(gradle, isNot(contains('storePassword = "')));
      final ignore = _read('android/.gitignore');
      expect(ignore, contains('key.properties'));
      expect(ignore, contains('**/*.jks'));
    });
  });

  group('iOS', () {
    test('Info.plist keeps ATS enabled and uses the shared display name', () {
      final plist = _read('ios/Runner/Info.plist');
      expect(
        RegExp(r'<key>NSAllowsArbitraryLoads</key>\s*<false/>').hasMatch(plist),
        isTrue,
      );
      expect(plist, isNot(contains('NSExceptionDomains')));
      expect(plist, isNot(contains('NSAllowsLocalNetworking')));
      expect(
        RegExp(
          '<key>CFBundleDisplayName</key>\\s*<string>'
          '${AppConfig.applicationName}</string>',
        ).hasMatch(plist),
        isTrue,
      );
    });

    test('Xcode project bundle identifier matches AppConfig', () {
      final project = _read('ios/Runner.xcodeproj/project.pbxproj');
      expect(
        project,
        contains(
          'PRODUCT_BUNDLE_IDENTIFIER = ${AppConfig.iosBundleIdentifier};',
        ),
      );
      expect(project, isNot(contains('DEVELOPMENT_TEAM = ')));
    });
  });

  group('Windows', () {
    test('executable name and window title match AppConfig', () {
      final cmake = _read('windows/CMakeLists.txt');
      final binaryName = AppConfig.windowsExecutableName.replaceAll('.exe', '');
      expect(cmake, contains('set(BINARY_NAME "$binaryName")'));
      expect(
        _read('windows/runner/main.cpp'),
        contains('L"${AppConfig.applicationName}"'),
      );
      final rc = _read('windows/runner/Runner.rc');
      expect(
        rc,
        contains('"OriginalFilename", "${AppConfig.windowsExecutableName}"'),
      );
      expect(rc, contains('"ProductName", "${AppConfig.applicationName}"'));
    });
  });

  test('client sources never disable TLS certificate validation', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      if (source.contains('badCertificateCallback') ||
          source.contains('HttpOverrides.global') ||
          source.contains('SecurityContext(withTrustedRoots: false')) {
        offenders.add(entity.path);
      }
    }
    expect(offenders, isEmpty);
  });

  test('client sources do not print or log credentials', () {
    final offenders = <String>[];
    final logCall = RegExp(r'\b(print|debugPrint|log)\s*\(');
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (logCall.hasMatch(entity.readAsStringSync())) {
        offenders.add(entity.path);
      }
    }
    expect(offenders, isEmpty);
  });
}
