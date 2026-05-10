import 'package:cookie_jar/cookie_jar.dart';

/// Cookie jar that survives app restarts (native) or lives in memory (web).
///
/// Must be initialized before use via [initCookieJar] or [initCookieJarWeb].
CookieJar? _cookieJar;

/// Initialize the cookie jar with the app's storage directory (native only).
///
/// [storagePath] should be a writable directory — typically the app's
/// `getApplicationDocumentsDirectory()`. Cookies are stored under
/// `<storagePath>/.cookies/`.
Future<void> initCookieJar(String storagePath) async {
  _cookieJar = PersistCookieJar(storage: FileStorage('$storagePath/.cookies/'));
}

/// Initialize an in-memory cookie jar for web platform.
///
/// On web the browser already manages cookies via the same-origin policy.
/// This in-memory jar exists so the cookie-manager interceptor has somewhere
/// to write to without erroring; web app code should rely on the browser's
/// own cookie handling.
void initCookieJarWeb() {
  _cookieJar = CookieJar();
}

/// Access the global cookie jar instance.
///
/// Throws if neither [initCookieJar] nor [initCookieJarWeb] has been called.
CookieJar get cookieJar {
  assert(_cookieJar != null,
      'Cookie jar not initialized. Call initCookieJar() or initCookieJarWeb() first.');
  return _cookieJar!;
}

/// Test-only: reset the cookie jar so subsequent `initCookieJar*` calls
/// re-initialize cleanly. Not exported through `eden_platform.dart`.
@Deprecated('Test only — do not call in production code.')
void resetCookieJarForTesting() {
  _cookieJar = null;
}
