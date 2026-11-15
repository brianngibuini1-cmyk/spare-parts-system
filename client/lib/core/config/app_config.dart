import 'package:flutter/foundation.dart';

/// Deployment environment for the BMM Auto Motors client.
enum AppEnvironment {
  development,
  staging,
  production;

  static AppEnvironment parse(String rawValue) {
    final normalized = rawValue.trim().toLowerCase();
    return switch (normalized) {
      '' || 'staging' || 'stage' => AppEnvironment.staging,
      'development' || 'dev' => AppEnvironment.development,
      'production' || 'prod' => AppEnvironment.production,
      _ => throw ConfigurationException(
          'Unsupported APP_ENV "$rawValue". Expected development, staging, or production.',
        ),
    };
  }
}

/// Runtime configuration for the Flutter client.
///
/// Synchronization note:
/// The FastAPI backend configures its maximum product image upload size via
/// `SPARE_PARTS_PRODUCT_IMAGE_MAX_BYTES` in `app/config.py` (defaulting to
/// 5 MiB = 5,242,880 bytes, with a maximum supported ceiling of 20 MiB =
/// 20,971,520 bytes) and does not expose a runtime settings endpoint.
/// To keep client-side validation synchronized with the backend without
/// hardcoding an unchangeable constant, [AppConfig] uses the same 5 MiB default
/// and reads `--dart-define=SPARE_PARTS_PRODUCT_IMAGE_MAX_BYTES=<bytes>` (or
/// `--dart-define=PRODUCT_IMAGE_MAX_BYTES=<bytes>`) when a deployment overrides
/// the backend setting.
class AppConfig {
  const AppConfig({
    required this.apiBaseUrl,
    this.environment = AppEnvironment.staging,
    this.productImageMaxBytes = defaultProductImageMaxBytes,
  });

  static const String applicationName = 'BMM Auto Motors';
  static const String androidApplicationId =
      'com.bmmautomotors.bmm_auto_motors';
  static const String iosBundleIdentifier = 'com.bmmautomotors.bmmAutoMotors';
  static const String windowsApplicationId =
      'com.bmmautomotors.bmm_auto_motors';
  static const String windowsExecutableName = 'bmm_auto_motors.exe';

  static const int defaultProductImageMaxBytes = 5 * 1024 * 1024;
  static const int maxSupportedProductImageMaxBytes = 20 * 1024 * 1024;

  static const Set<String> _loopbackHosts = <String>{
    'localhost',
    '127.0.0.1',
    '::1',
    '[::1]',
  };
  static const String androidEmulatorHostAlias = '10.0.2.2';

  final Uri apiBaseUrl;
  final AppEnvironment environment;
  final int productImageMaxBytes;

  /// Visible marker for non-production builds so staging or development
  /// clients cannot be mistaken for the live shop system. Production has none.
  String? get environmentBannerLabel => switch (environment) {
        AppEnvironment.production => null,
        AppEnvironment.staging => 'STAGING',
        AppEnvironment.development => 'DEV',
      };

  static int configuredProductImageMaxBytes() {
    const rawSpareParts = String.fromEnvironment(
      'SPARE_PARTS_PRODUCT_IMAGE_MAX_BYTES',
    );
    if (rawSpareParts.isNotEmpty) {
      return parseProductImageMaxBytes(rawSpareParts);
    }
    const rawShort = String.fromEnvironment('PRODUCT_IMAGE_MAX_BYTES');
    if (rawShort.isNotEmpty) {
      return parseProductImageMaxBytes(rawShort);
    }
    return defaultProductImageMaxBytes;
  }

  static int parseProductImageMaxBytes(String rawValue) {
    final trimmed = rawValue.trim();
    if (trimmed.isEmpty) {
      return defaultProductImageMaxBytes;
    }
    final parsed = int.tryParse(trimmed);
    if (parsed == null ||
        parsed <= 0 ||
        parsed > maxSupportedProductImageMaxBytes) {
      throw const ConfigurationException(
        'Product image upload limit must be an integer between 1 and 20971520 bytes.',
      );
    }
    return parsed;
  }

  /// Reads configuration from build-time `--dart-define` values.
  ///
  /// Supported defines:
  /// * `API_BASE_URL` (required): HTTPS API origin.
  /// * `APP_ENV`: `development`, `staging` (default) or `production`.
  /// * `ALLOW_INSECURE_DEV_HTTP`: development-only cleartext opt-in.
  /// * `ANDROID_ADB_REVERSE`: development-only opt-in that lets an Android
  ///   device reach the development computer through `adb reverse` on its own
  ///   loopback address.
  /// * `SPARE_PARTS_PRODUCT_IMAGE_MAX_BYTES` / `PRODUCT_IMAGE_MAX_BYTES`.
  static AppConfig fromEnvironment() {
    const value = String.fromEnvironment('API_BASE_URL');
    const appEnvRaw = String.fromEnvironment('APP_ENV');
    const allowInsecureDevHttp = bool.fromEnvironment(
      'ALLOW_INSECURE_DEV_HTTP',
    );
    const androidAdbReverse = bool.fromEnvironment('ANDROID_ADB_REVERSE');
    return fromValue(
      value,
      appEnvRaw: appEnvRaw,
      allowInsecureDevHttp: allowInsecureDevHttp,
      androidAdbReverse: androidAdbReverse,
      isReleaseMode: kReleaseMode,
      targetPlatform: defaultTargetPlatform,
      productImageMaxBytesRaw: const String.fromEnvironment(
        'SPARE_PARTS_PRODUCT_IMAGE_MAX_BYTES',
        defaultValue: String.fromEnvironment('PRODUCT_IMAGE_MAX_BYTES'),
      ),
    );
  }

  static AppConfig fromValue(
    String value, {
    String appEnvRaw = '',
    bool allowInsecureDevHttp = false,
    bool androidAdbReverse = false,
    bool isReleaseMode = kReleaseMode,
    TargetPlatform? targetPlatform,
    String productImageMaxBytesRaw = '',
  }) {
    final trimmedValue = value.trim();
    if (trimmedValue.isEmpty) {
      throw const ConfigurationException(
        'API endpoint is not configured. Build with --dart-define=API_BASE_URL=https://your-staging-api.example',
      );
    }

    final environment = AppEnvironment.parse(appEnvRaw);
    if (isReleaseMode && environment == AppEnvironment.development) {
      throw const ConfigurationException(
        'Development environment (APP_ENV=development) is not permitted in release builds.',
      );
    }
    if (isReleaseMode && allowInsecureDevHttp) {
      throw const ConfigurationException(
        'ALLOW_INSECURE_DEV_HTTP is not permitted in release builds.',
      );
    }
    if (androidAdbReverse &&
        (isReleaseMode || environment != AppEnvironment.development)) {
      throw const ConfigurationException(
        'ANDROID_ADB_REVERSE is only permitted in non-release development builds.',
      );
    }

    final uri = Uri.tryParse(trimmedValue);
    if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      throw const ConfigurationException(
        'API endpoint must be a valid HTTPS URL.',
      );
    }

    final canUseInsecureDevHttp = !isReleaseMode &&
        environment == AppEnvironment.development &&
        allowInsecureDevHttp;
    if (uri.scheme != 'https' &&
        !(canUseInsecureDevHttp && uri.scheme == 'http')) {
      throw const ConfigurationException(
        'API endpoint must be a valid HTTPS URL.',
      );
    }

    final host = uri.host.toLowerCase();
    final platform = targetPlatform ?? defaultTargetPlatform;
    final isLoopback = _loopbackHosts.contains(host);
    final isAndroidEmulatorAlias = host == androidEmulatorHostAlias;

    if (platform == TargetPlatform.android &&
        isLoopback &&
        !androidAdbReverse) {
      throw ConfigurationException(
        'API endpoint host "${uri.host}" refers to the Android device or emulator itself, not the development computer. Use 10.0.2.2 for an Android emulator, ANDROID_ADB_REVERSE=true with "adb reverse" for a USB-connected device, or a reachable HTTPS staging host.',
      );
    }
    if (platform != TargetPlatform.android && androidAdbReverse) {
      throw const ConfigurationException(
        'ANDROID_ADB_REVERSE is only valid for Android builds.',
      );
    }
    // The Android debug network security configuration permits cleartext only
    // to the emulator host alias and to loopback (adb reverse). Any other HTTP
    // host would be refused by the operating system at runtime, so reject it
    // here with an actionable message instead of a generic network failure.
    if (platform == TargetPlatform.android &&
        uri.scheme == 'http' &&
        !isAndroidEmulatorAlias &&
        !isLoopback) {
      throw ConfigurationException(
        'Cleartext HTTP to "${uri.host}" is blocked by Android. Use 10.0.2.2 (emulator), ANDROID_ADB_REVERSE=true with a loopback URL (USB device), or an HTTPS staging host.',
      );
    }
    if (platform == TargetPlatform.iOS && isLoopback) {
      throw ConfigurationException(
        'API endpoint host "${uri.host}" on iOS refers to the iPhone itself. Configure a reachable HTTPS staging or production endpoint.',
      );
    }
    if (platform == TargetPlatform.iOS && uri.scheme != 'https') {
      throw const ConfigurationException(
        'iOS builds require an HTTPS API endpoint in every environment.',
      );
    }
    if (platform != TargetPlatform.android && isAndroidEmulatorAlias) {
      throw const ConfigurationException(
        'API endpoint host "10.0.2.2" is the Android emulator host alias and is only valid on Android.',
      );
    }

    if ((environment != AppEnvironment.development || isReleaseMode) &&
        (isLoopback || isAndroidEmulatorAlias)) {
      throw ConfigurationException(
        'Development host "${uri.host}" is not permitted in ${environment.name} or release builds.',
      );
    }

    return AppConfig(
      apiBaseUrl: uri,
      environment: environment,
      productImageMaxBytes: parseProductImageMaxBytes(productImageMaxBytesRaw),
    );
  }
}

class ConfigurationException implements Exception {
  const ConfigurationException(this.message);
  final String message;
}
