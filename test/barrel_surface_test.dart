// The two entrypoints' PUBLIC SURFACE, asserted by compilation.
//
// These are the package's public API, and 13 of eden's consumers resolve it by
// LOCAL PATH rather than a pinned git ref — so a silent removal reaches them on
// merge with no version gate, and nothing in this repository's CI would notice.
// A symbol named below cannot be dropped from a barrel without turning this file
// red, which is a stronger guarantee than any export-line diff: `export 'x.dart'`
// surviving says nothing about whether x.dart still declares the symbol.
//
// Test-list items 1, 2 and 3.
//
// ITEM 2 IS A STAND-IN FOR A GATE IN ANOTHER REPOSITORY. politihub's APP-06 gate
// greps consumer sources for `^import 'package:(http|dio)/` and requires the dio
// types to be taken from `networking.dart` instead. That gate cannot fail here,
// so if the re-export is ever narrowed this file is the only thing between the
// change and a broken downstream build.

@TestOn('vm')
library;

import 'dart:io';

// DELIBERATE: this file imports ONLY the two barrels. Reaching into
// `src/...` would defeat the point — the assertion is about what the
// ENTRYPOINTS expose, not about what the package contains.
import 'package:eden_platform_flutter/eden_platform.dart' as full;
import 'package:eden_platform_flutter/networking.dart' as net;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('item 1 — eden_platform.dart resolves every functional area', () {
    test('auth / company / nav / settings / entitlements / shell / networking / '
        'providers / observability all resolve from the full barrel', () {
      // One symbol per functional area. Each `Type` reference is a compile-time
      // resolution: if the export disappears, this file stops compiling.
      final areas = <String, Type>{
        'auth (notifier)': full.AuthNotifier,
        'auth (state)': full.AuthState,
        'auth (strategy)': full.AuthStrategy,
        'auth (token storage)': full.TokenStorage,
        'auth (secure storage)': full.SecureTokenStorage,
        'auth (login screen)': full.PlatformLoginScreen,
        'auth (signup screen)': full.PlatformSignUpScreen,
        'company (notifier)': full.CompanyNotifier,
        'company (switcher widget)': full.CompanySwitcher,
        'navigation (notifier)': full.NavNotifier,
        'navigation (sidebar widget)': full.PlatformSidebar,
        'settings (notifier)': full.SettingsNotifier,
        'settings (screen)': full.PlatformSettingsScreen,
        'entitlements (notifier)': full.EntitlementsNotifier,
        'entitlements (gate widget)': full.EdenFeatureGate,
        'entitlements (quota widget)': full.EdenQuotaBar,
        'entitlements (plan widget)': full.EdenPlanBadge,
        'shell': full.PlatformShell,
        'api repository': full.PlatformRepository,
        'models': full.PlatformSession,
        'config': full.EdenPlatformConfig,
        'config (mode enum)': full.PlatformMode,
        'networking (exception)': full.ApiException,
        'networking (auth interceptor)': full.AuthInterceptor,
        'networking (retry interceptor)': full.RetryInterceptor,
        'networking (dio config)': full.DioClientConfig,
        'providers (paginated)': full.PaginatedAsyncNotifier,
        'providers (mutation)': full.MutationNotifier,
      };
      // Non-vacuity: an empty or tiny map would make the loop prove nothing.
      expect(areas.length, greaterThanOrEqualTo(20));
      areas.forEach((area, type) {
        expect(type, isNotNull, reason: '$area vanished from eden_platform.dart');
      });

      // Function/getter-shaped exports cannot be named as a Type, so reference
      // them as values. connect_cookie_interceptor and sentry_init are the two
      // the test list singles out as present on the full barrel and absent from
      // networking.dart — the asymmetry that makes the two barrels non-nested.
      expect(full.connectCookieInterceptor, isNotNull);
      expect(full.initSentry, isNotNull);
      expect(full.initCookieJar, isNotNull);
      expect(full.analyticsProvider, isNotNull);
      expect(full.edenSnapshotFromAsyncValue, isNotNull);
    });
  });

  group('item 2 — networking.dart still exposes the dio symbols', () {
    test('the politihub APP-06 dio re-export is intact, symbol for symbol', () {
      // Every symbol in networking.dart's `show` clause. This list is derived
      // from the file, not from memory: the test list asserts "fourteen dio symbols"
      // in five places and the measured count is ELEVEN. Trusting the prose
      // would have written a wrong assertion here.
      final dioSymbols = <String, Type>{
        'Dio': net.Dio,
        'Interceptor': net.Interceptor,
        'RequestOptions': net.RequestOptions,
        'RequestInterceptorHandler': net.RequestInterceptorHandler,
        'ResponseInterceptorHandler': net.ResponseInterceptorHandler,
        'ErrorInterceptorHandler': net.ErrorInterceptorHandler,
        'Response': net.Response,
        'DioException': net.DioException,
        'HttpClientAdapter': net.HttpClientAdapter,
        'ResponseBody': net.ResponseBody,
        'Options': net.Options,
      };
      expect(
        dioSymbols.length,
        11,
        reason:
            'networking.dart re-exports exactly 11 dio symbols. If this count '
            'changed, politihub APP-06 consumers may have lost a type — verify '
            'against the export block before updating this number.',
      );
      dioSymbols.forEach((name, type) {
        expect(type, isNotNull, reason: 'dio symbol $name was dropped');
      });
    });

    test('the dio types are USABLE, not merely named — a consumer can build an '
        'interceptor and a fake adapter without importing package:dio', () {
      // This is the shape politihub's BearerAuthInterceptor + _FakeDioAdapter
      // actually take. Naming a type proves the export; constructing one proves
      // the export is complete enough to be worth having.
      final dio = net.Dio();
      expect(dio, isA<net.Dio>());
      expect(dio.interceptors, isNotNull);

      final opts = net.RequestOptions(path: '/x');
      expect(opts.path, '/x');

      final resp = net.Response<String>(requestOptions: opts, data: 'ok');
      expect(resp.data, 'ok');

      final err = net.DioException(requestOptions: opts);
      expect(err, isA<net.DioException>());

      expect(net.Options(headers: const {'a': 'b'}).headers, isNotNull);
    });

    test('the full barrel ALSO exposes the dio symbols (added by the barrel consolidation), and '
        'they are the SAME declarations — no ambiguity for a consumer '
        'importing both entrypoints', () {
      // Purely additive convenience. Identity of the declarations is what makes
      // importing both barrels legal, so assert identity rather than mere
      // presence.
      expect(full.Dio, same(net.Dio));
      expect(full.Interceptor, same(net.Interceptor));
      expect(full.Response, same(net.Response));
      expect(full.DioException, same(net.DioException));
      expect(full.HttpClientAdapter, same(net.HttpClientAdapter));
      expect(full.Options, same(net.Options));
      expect(full.RequestOptions, same(net.RequestOptions));
      expect(full.ResponseBody, same(net.ResponseBody));
    });
  });

  group('item 3 — networking.dart does NOT drag in the auth/shell surface', () {
    test('the four networking-only consumers keep the narrow surface they '
        'chose, asserted as a deliberate property', () {
      // aodex/flutter and aofamily/{ai,connect,browser} import ONLY this file.
      // A bare `export 'eden_platform.dart';` here would silently hand them the
      // whole auth/company/nav/shell surface — and would make the dio re-export
      // transitive, which networking.dart's own comment says the APP-06 gate
      // cannot detect. Both failure modes are invisible to a symbol test that
      // only checks presence, so check ABSENCE.
      //
      // Source-level rather than symbol-level by necessity: an absent export
      // cannot be named in Dart without failing to compile.
      final src = File('lib/networking.dart').readAsStringSync();
      final code = src
          .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
          .replaceAll(RegExp(r'//[^\n]*'), '');

      final exportLines = RegExp(r"^\s*export\s+'([^']+)'", multiLine: true)
          .allMatches(code)
          .map((m) => m.group(1)!)
          .toList();

      // Non-vacuity: a broken regexp yielding [] would pass every check below.
      expect(
        exportLines.length,
        greaterThanOrEqualTo(10),
        reason:
            'expected ~12 export directives in networking.dart; found '
            '${exportLines.length}. A low count means the parser broke.',
      );

      expect(
        exportLines,
        isNot(contains('eden_platform.dart')),
        reason:
            'networking.dart must NOT be a re-export of the full barrel — that '
            'hands four consumers a surface they deliberately declined and '
            'makes the dio re-export transitive.',
      );

      // Every first-party export must stay inside src/networking/.
      final widened = exportLines
          .where((e) => !e.startsWith('package:'))
          .where((e) => !e.startsWith('src/networking/'))
          .toList();
      expect(
        widened,
        isEmpty,
        reason:
            'networking.dart may only export from src/networking/ (plus the '
            'package:dio re-export). Offending: $widened',
      );

      // And the dio re-export is present exactly once, in THIS file.
      expect(
        exportLines.where((e) => e == 'package:dio/dio.dart').length,
        1,
        reason: 'the APP-06 dio re-export must be present exactly once',
      );
    });

    test('the header no longer claims a riverpod incompatibility that no '
        'longer exists', () {
      final header = File('lib/networking.dart').readAsStringSync();

      // NORMALISE before matching: strip the `//` comment markers and collapse
      // all whitespace to single spaces. Without this, any phrase that happens
      // to straddle a line break is invisible to `contains`. That is not a
      // hypothetical — it fired on the first run of this very test ("NO LONGER"
      // ended one line and "EXISTS" began the next), and it is the THIRD time a
      // dartdoc line-wrap has defeated a string check in this objective
      // (doc/riverpod-3-migration.md §3.9 records the first two). A gate that
      // depends on where a comment happens to wrap is not a gate.
      final lower = header
          .replaceAll(RegExp(r'^\s*//+', multiLine: true), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .toLowerCase();

      // The false clauses, gone.
      expect(
        lower,
        isNot(contains('are incompatible with')),
        reason: 'the "incompatible with flutter_riverpod 3.x consumers" claim '
            'was made false by Stage B and must not survive',
      );
      expect(
        lower,
        isNot(contains('flutter_riverpod 3.x consumers)')),
        reason: 'the old parenthetical incompatibility clause must be gone',
      );

      // The current truth, present — and pointing at the evidence.
      expect(lower, contains('no longer exists'));
      expect(lower, contains('riverpod-3-migration'));
      // The two reasons the file is KEPT, so nobody deletes it in six months.
      expect(lower, contains('app-06'));
      expect(lower, contains('four consumer packages'));

      // Non-vacuity, two ways. (a) the header must be substantial, or every
      // `isNot(contains(...))` above would pass on an empty file. (b) the
      // normaliser must actually have removed the comment markers, or `lower`
      // could be some degenerate string that trivially fails every `contains`.
      expect(header.length, greaterThan(800));
      expect(lower, isNot(contains('//')));
      expect(lower, contains('networking-only entrypoint'));
    });
  });
}
