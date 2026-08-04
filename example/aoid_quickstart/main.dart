// A minimal, COMPILING Mode A (BFF) integration with AOID.
//
// Mode A is D4's top-ranked posture: the refresh token never reaches the
// browser. Run `flutter analyze` from the package root — it covers this
// directory, so this file cannot silently drift from the API.
//
// Full documentation: lib/src/aoid/README.md

import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

void main() => runApp(const AoidQuickstartApp());

class AoidQuickstartApp extends StatefulWidget {
  const AoidQuickstartApp({super.key});

  @override
  State<AoidQuickstartApp> createState() => _AoidQuickstartAppState();
}

class _AoidQuickstartAppState extends State<AoidQuickstartApp> {
  final http.Client _http = http.Client();

  // 1. The callback scheme is REQUIRED and has no default, and the FULL
  //    redirect URI must be EXACT-match registered on your AOID client
  //    (aoid internal/oauth/service.go:457). No trailing slash, no case drift
  //    — AOID compares the whole string. `edenbiz` + `edenbiz://auth` is the
  //    registered pair for eden-biz-companion in config/oauth-clients.yaml.
  static const String _redirectUri = 'edenbiz://auth';
  final AoidRedirectOptions _redirect = AoidRedirectOptions(
    callbackScheme: 'edenbiz',
  );

  late final AoidNativeFlow _flow = AoidNativeFlow(
    client: AoidNativeClient(
      endpoints: AoidEndpoints.parse('https://auth.aocyber.ai'),
      httpClient: _http,
    ),
    clientId: 'your-aoid-client-id',
    tenantId: 'your-tenant',
    redirectUri: _redirectUri,
  );

  // 2. Mode A: your BACKEND holds the client secret and sets the httpOnly
  //    SameSite cookie. The SDK hands it {code, code_verifier}. The verifier
  //    is not a secret; the client secret never leaves your backend.
  late final AoidCodeSink _sink = HttpBffCodeSink(
    exchangeUrl: Uri.parse(
      'https://app.example.com${HttpBffCodeSink.conventionalExchangePath}',
    ),
    httpClient: _http,
  );

  AoidSession? _session;
  String? _error;

  Future<void> _exchangeWhenComplete(String codeVerifier) async {
    final code = _flow.authorizationCode;
    if (code == null) return; // ceremony still needs another factor
    try {
      final session = await _sink.submit(
        code: code,
        codeVerifier: codeVerifier,
        // Byte-identical to what the authorize request carried: this is the
        // code's audience binding, and AOID re-checks it at exchange time.
        redirectUri: _redirectUri,
      );
      setState(() => _session = session);
    } on AoidBffExchangeError catch (e) {
      // YOUR backend failed — not AOID, and not a bad password. Three failing
      // systems, three exception types; do not collapse them.
      setState(() => _error = e.kind.name);
    }
  }

  @override
  void dispose() {
    _http.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final verifier = PkceGenerator.generate().codeVerifier;
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: _session != null
              ? Text('signed in — cookieBound: ${_session!.cookieBound}')
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // 3. AoidLoginForm owns its own controller. There is
                    //    deliberately no way to read the password from app
                    //    code (D3). Do not look for one.
                    AoidLoginForm(controller: _flow),
                    if (_error != null) Text('exchange failed: $_error'),
                    Text('ephemeral session: ${_redirect.preferEphemeral}'),
                    TextButton(
                      onPressed: () => _exchangeWhenComplete(verifier),
                      child: const Text('finish sign-in'),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
