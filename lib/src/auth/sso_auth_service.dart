import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/platform_models.dart';
import '../api/platform_repository.dart';

/// Handles the SSO OAuth flow for desktop platforms.
///
/// Desktop: Opens system browser → redirects to localhost callback server → captures tokens.
/// Web: Not yet supported (handled by router-level redirect).
class SSOAuthService {
  final PlatformRepository _repository;
  final String _apiBaseUrl;

  SSOAuthService({
    required PlatformRepository repository,
    required String apiBaseUrl,
  })  : _repository = repository,
        _apiBaseUrl = apiBaseUrl;

  /// Initiates SSO login flow for the given provider.
  /// Returns a [PlatformSession] on success.
  Future<PlatformSession> authenticate(String provider) async {
    if (kIsWeb) {
      throw UnimplementedError('Web SSO flow should be handled by the router');
    }
    return _authenticateDesktop(provider);
  }

  /// Desktop SSO flow:
  /// 1. Start a temporary localhost HTTP server
  /// 2. Request auth URL from backend (with localhost redirect)
  /// 3. Open system browser
  /// 4. Wait for redirect with tokens
  /// 5. Return session
  Future<PlatformSession> _authenticateDesktop(String provider) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    final redirectUri = 'http://localhost:$port/callback';

    try {
      final authUrl = await _repository.initiateSSOForDesktop(provider, redirectUri);

      // Open system browser
      if (Platform.isMacOS) {
        await Process.run('open', [authUrl]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [authUrl]);
      } else if (Platform.isWindows) {
        await Process.run('cmd', ['/c', 'start', authUrl]);
      }

      final completer = Completer<PlatformSession>();

      final timeout = Timer(const Duration(minutes: 5), () {
        if (!completer.isCompleted) {
          completer.completeError(Exception('SSO login timed out'));
          server.close();
        }
      });

      server.listen((request) async {
        if (request.uri.path == '/callback') {
          final accessToken = request.uri.queryParameters['access_token'];
          final refreshToken = request.uri.queryParameters['refresh_token'];

          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.html
            ..write('<html><body style="font-family:system-ui;display:flex;align-items:center;justify-content:center;height:100vh;margin:0">'
                '<div style="text-align:center"><h2>Login successful</h2><p>You can close this window.</p></div>'
                '</body></html>');
          await request.response.close();

          timeout.cancel();

          if (accessToken != null && refreshToken != null) {
            final session = PlatformSession(
              accessToken: accessToken,
              refreshToken: refreshToken,
              user: const PlatformUser(id: '', email: '', displayName: '', isActive: true),
              companyId: '',
              role: '',
            );
            if (!completer.isCompleted) completer.complete(session);
          } else {
            if (!completer.isCompleted) {
              completer.completeError(Exception('Missing tokens in SSO callback'));
            }
          }

          await server.close();
        }
      });

      return completer.future;
    } catch (e) {
      await server.close();
      rethrow;
    }
  }
}
