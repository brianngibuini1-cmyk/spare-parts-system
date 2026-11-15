import 'package:bmm_auto_motors/app/app.dart';
import 'package:bmm_auto_motors/core/config/app_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('application shows setup guidance when configuration is missing',
      (tester) async {
    String? configurationError;
    try {
      AppConfig.fromValue('');
    } on ConfigurationException catch (error) {
      configurationError = error.message;
    }
    expect(configurationError, isNotNull);

    await tester.pumpWidget(
      BmmApplication(
        controller: null,
        configurationError: configurationError,
      ),
    );

    expect(find.text('Connect the application to its service'), findsOneWidget);
    expect(find.text(configurationError!), findsOneWidget);
  });
}
