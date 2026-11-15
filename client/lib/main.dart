import 'package:flutter/material.dart';

import 'app/app.dart';
import 'core/config/app_config.dart';
import 'core/network/api_client.dart';
import 'core/network/api_transport.dart';
import 'core/security/credential_store.dart';
import 'features/authentication/auth_controller.dart';
import 'features/authentication/auth_repository.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final config = AppConfig.fromEnvironment();
    final credentials = SecureCredentialStore();
    final api = ApiClient(
      baseUrl: config.apiBaseUrl,
      transport: IoApiTransport(),
      credentials: credentials,
    );
    runApp(
      BmmApplication(
        controller: AuthController(AuthRepository(api)),
        environmentBanner: config.environmentBannerLabel,
      ),
    );
  } on ConfigurationException catch (error) {
    runApp(BmmApplication(controller: null, configurationError: error.message));
  }
}
