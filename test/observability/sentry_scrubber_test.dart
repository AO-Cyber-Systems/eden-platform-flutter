// opsCluster — PII-scrubber tests.
//
// The scrubbers are pure top-level functions, so they are tested directly here
// in the shared package. That is the point of putting them in ONE place: the
// privacy control gets ONE test suite instead of four divergent copies.
//
// The serialization assertions matter more than the unit assertions. Checking
// "scrubEvent removed the Authorization key" only proves the scrubber did what
// it was told; checking that the SERIALIZED payload contains zero occurrences of
// `Bearer` / `eyJ` / a seeded email catches secrets sitting in a field nobody
// thought to scrub — which is the failure mode that actually leaks.

import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

const _bearer = 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload.sig';
const _email = 'leak@me.test';
const _tenant = 'TENANT_X';

void main() {
  group('scrubEvent', () {
    test('strips sensitive headers case-insensitively', () {
      final event = SentryEvent(
        request: SentryRequest(
          url: 'https://api.aocyber.ai/v1/chat',
          method: 'POST',
          headers: {
            'Authorization': _bearer, // title case
            'cookie': 'session=$_bearer', // lower case
            'X-Company-Id': _tenant,
            'x-api-key': 'ak_live_secret',
            'Content-Type': 'application/json', // must SURVIVE
          },
        ),
      );

      final scrubbed = scrubEvent(event, Hint())!;
      final headers = scrubbed.request!.headers;

      expect(headers.containsKey('Authorization'), isFalse);
      expect(headers.containsKey('cookie'), isFalse);
      expect(headers.containsKey('X-Company-Id'), isFalse);
      expect(headers.containsKey('x-api-key'), isFalse);
      // Non-sensitive headers must be preserved — over-scrubbing destroys the
      // debuggability the tool exists for.
      expect(headers['Content-Type'], 'application/json');
    });

    test('drops the request body wholesale', () {
      final event = SentryEvent(
        request: SentryRequest(
          url: 'https://api.aocyber.ai/v1/chat',
          method: 'POST',
          headers: const {},
          data: {'prompt': 'customer secret', 'email': _email},
        ),
      );

      final scrubbed = scrubEvent(event, Hint())!;
      expect(scrubbed.request!.data, isNull,
          reason: 'request bodies leak product data even when headers are clean');
    });

    test('REGRESSION: copyWith cannot null a field, so data must not survive', () {
      // An earlier draft used request.copyWith(data: null). copyWith treats a
      // null argument as "keep the existing value", so the body silently
      // survived the scrub. This test pins the constructed-not-copied approach.
      final event = SentryEvent(
        request: SentryRequest(
          url: 'https://api.aocyber.ai/v1/x',
          headers: const {'Authorization': _bearer},
          data: {'secret': _bearer},
          cookies: 'session=$_bearer',
        ),
      );

      final serialized = scrubEvent(event, Hint())!.toJson().toString();
      expect(serialized.contains('Bearer'), isFalse);
      expect(serialized.contains('eyJ'), isFalse);
    });

    test('passes through an event with no request', () {
      final event = SentryEvent();
      expect(scrubEvent(event, Hint()), isNotNull);
    });
  });

  group('scrubBreadcrumb', () {
    test('strips sensitive data keys case-insensitively', () {
      final crumb = Breadcrumb(
        message: 'GET /v1/models',
        data: {
          'Authorization': _bearer,
          'access_token': 'at_$_bearer',
          'refresh_token': 'rt_secret',
          'company_id': _tenant,
          'PASSWORD': 'hunter2', // upper case — must still be stripped
          'status_code': 200, // must SURVIVE
        },
      );

      final scrubbed = scrubBreadcrumb(crumb, Hint())!;
      final data = scrubbed.data!;

      for (final key in [
        'Authorization',
        'access_token',
        'refresh_token',
        'company_id',
        'PASSWORD',
      ]) {
        expect(data.containsKey(key), isFalse, reason: '$key must be stripped');
      }
      expect(data['status_code'], 200);
    });

    test('handles null and empty breadcrumbs', () {
      expect(scrubBreadcrumb(null, Hint()), isNull);
      final empty = Breadcrumb(message: 'x');
      expect(scrubBreadcrumb(empty, Hint()), isNotNull);
    });
  });

  group('serialized envelope', () {
    test('contains zero hits for Bearer / JWT / email / tenant', () {
      final event = SentryEvent(
        request: SentryRequest(
          url: 'https://api.aocyber.ai/v1/chat',
          method: 'POST',
          headers: {
            'Authorization': _bearer,
            'Cookie': 'sid=abc; token=$_bearer',
            'X-Company-Id': _tenant,
          },
          data: {'email': _email, 'prompt': 'secret'},
          cookies: 'sid=abc',
        ),
        breadcrumbs: [
          Breadcrumb(
            message: 'auth',
            data: {'access_token': _bearer, 'company_id': _tenant},
          ),
        ],
      );

      // ONLY scrubEvent is applied here — deliberately. beforeSend must be
      // self-sufficient: a breadcrumb that never passed through
      // beforeBreadcrumb (attached directly to an event, or captured before the
      // SDK was configured) must still be scrubbed at send time. An earlier
      // draft of this test scrubbed breadcrumbs separately and hid the gap;
      // this version caught a real leak of `Bearer` via event.breadcrumbs.
      final scrubbedEvent = scrubEvent(event, Hint())!;
      final serialized = scrubbedEvent.toJson().toString();

      for (final needle in ['Bearer', 'eyJ', _email, _tenant]) {
        expect(serialized.contains(needle), isFalse,
            reason: '"$needle" leaked into the serialized envelope');
      }
    });
  });
  // opsCluster. These assert the OPTION-shaping half
  // of initSentry, which is otherwise only observable by booting the SDK.
  //
  // The default matters: sentry's own default is ['.*'] (attach sentry-trace +
  // baggage to EVERY outbound origin, third parties included). Narrowing it is
  // the point, but narrowing it to an EMPTY list would attach the headers to
  // nothing and silently kill Flutter->Go correlation — a failure that looks
  // identical to a backend bug. Both directions are pinned here.
  group('tracePropagationTargets', () {
    test('supplied targets replace the permissive default', () {
      final options = SentryFlutterOptions();
      applyTracePropagationTargets(options, const [
        r'^https://api\.dex\.aocyber\.ai',
      ]);
      expect(options.tracePropagationTargets,
          equals([r'^https://api\.dex\.aocyber\.ai']));
    });

    test('null leaves the SDK default untouched', () {
      final options = SentryFlutterOptions();
      final before = List<String>.from(options.tracePropagationTargets);
      applyTracePropagationTargets(options, null);
      expect(options.tracePropagationTargets, equals(before));
    });

    test('REGRESSION: an empty list must NOT disable propagation', () {
      final options = SentryFlutterOptions();
      final before = List<String>.from(options.tracePropagationTargets);
      applyTracePropagationTargets(options, const []);
      expect(options.tracePropagationTargets, equals(before),
          reason: 'empty must fall back to the default, not match nothing');
    });
  });

  // The single option that decides whether the telemetry work correlation must-have can
  // be met at all. Sentry's own default is false; every AOCyber backend speaks
  // W3C/OTel, so false means the Go side starts a fresh trace and the join
  // silently never happens.
  group('propagateTraceparent', () {
    test('SDK default is false — the thing we must override', () {
      expect(SentryFlutterOptions().propagateTraceparent, isFalse);
    });
  });

}
