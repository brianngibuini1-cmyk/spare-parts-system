import 'package:flutter/material.dart';

import '../features/authentication/auth_controller.dart';
import '../features/authentication/login_screen.dart';
import '../features/navigation/app_shell.dart';
import 'theme.dart';

class BmmApplication extends StatefulWidget {
  const BmmApplication({
    required this.controller,
    this.configurationError,
    this.environmentBanner,
    super.key,
  });
  final AuthController? controller;
  final String? configurationError;

  /// Optional non-production marker (for example `STAGING`) shown in the
  /// corner of every screen. `null` for production builds.
  final String? environmentBanner;

  @override
  State<BmmApplication> createState() => _BmmApplicationState();
}

class _BmmApplicationState extends State<BmmApplication>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.controller != null) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => widget.controller!.restore());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      widget.controller?.revalidate();
    }
  }

  Widget _withEnvironmentBanner(BuildContext context, Widget? child) {
    final content = child ?? const SizedBox.shrink();
    final label = widget.environmentBanner;
    if (label == null) return content;
    return Banner(
      message: label,
      location: BannerLocation.topEnd,
      color: Colors.deepOrange,
      child: content,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.configurationError != null || widget.controller == null) {
      return MaterialApp(
        title: 'BMM Auto Motors',
        theme: BmmTheme.light,
        home: _ConfigurationRequired(
          message: widget.configurationError ??
              'Application configuration is missing.',
        ),
      );
    }
    final controller = widget.controller!;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => MaterialApp(
        title: 'BMM Auto Motors',
        debugShowCheckedModeBanner: false,
        theme: BmmTheme.light,
        builder: _withEnvironmentBanner,
        home: switch (controller.status) {
          AuthStatus.loading =>
            const Scaffold(body: Center(child: CircularProgressIndicator())),
          AuthStatus.signedIn when controller.user != null => AppShell(
              user: controller.user!,
              onLogout: controller.signOut,
              api: controller.repository.api,
              onSessionExpired: controller.handleSessionExpired,
            ),
          AuthStatus.error => _RestoreError(
              message: controller.errorMessage ?? 'Unable to restore session.',
              onRetry: controller.restore,
            ),
          AuthStatus.signedOut ||
          AuthStatus.signedIn =>
            LoginScreen(controller: controller),
        },
      ),
    );
  }
}

class _ConfigurationRequired extends StatelessWidget {
  const _ConfigurationRequired({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_off_outlined, size: 48),
                  const SizedBox(height: 16),
                  Text(
                    'Connect the application to its service',
                    style: Theme.of(context).textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(message, textAlign: TextAlign.center),
                ],
              ),
            ),
          ),
        ),
      );
}

class _RestoreError extends StatelessWidget {
  const _RestoreError({required this.message, required this.onRetry});
  final String message;
  final Future<void> Function() onRetry;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_outlined, size: 44),
              const SizedBox(height: 12),
              Text(message),
              const SizedBox(height: 12),
              FilledButton(onPressed: onRetry, child: const Text('Try again')),
            ],
          ),
        ),
      );
}
