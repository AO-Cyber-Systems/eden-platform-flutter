// Shared Sentry initialisation + PII scrubbing for every AOCyber Flutter app.
//
// opsCluster. Promoted from eden-biz's
// lib/core/security/sentry_init.dart, which was the only
// app that scrubbed anything. Before this, aodex and aocore-admin shipped
// `SentryFlutter.init` with nothing but a DSN and `tracesSampleRate = 1.0` — no
// beforeSend, no beforeBreadcrumb — and they were the two apps actually sending
// events. Privacy-first is a stated brand pillar, so unscrubbed customer crash
// payloads are the thing this objective must not ship.
//
// It lives HERE, in the platform package, rather than in eden_ui_flutter — the
// only package all five apps share — because eden_ui_flutter is a pure
// design-system package (google_fonts, qr_flutter, showcaseview) with no Sentry
// dependency. Putting error-reporting infrastructure there would invert the
// dependency direction and force sentry_flutter on every consumer of the UI kit.
//
// [scrubEvent] and [scrubBreadcrumb] are top-level PURE functions so they can be
// unit-tested without booting the SDK, and asserted against a serialized
// envelope via InMemoryTransport.
library;

import 'dart:async';

// sentry_flutter re-exports the public surface of `sentry`; a dual import would
// trip the analyzer's unnecessary_import lint.
import 'package:sentry_flutter/sentry_flutter.dart';

/// Headers stripped from `event.request` by [scrubEvent].
///
/// Compared case-INSENSITIVELY: Dio lower-cases `authorization` on outbound
/// requests while hand-built requests usually title-case it, and a
/// case-sensitive match silently misses half of them.
const kSensitiveHeaders = <String>{
  'authorization',
  'cookie',
  'set-cookie',
  'x-company-id',
  'x-api-key',
  'x-aoedge-identity-context',
  'proxy-authorization',
};

/// Keys stripped from `breadcrumb.data` by [scrubBreadcrumb].
///
/// Matched case-insensitively for the same reason as [kSensitiveHeaders].
const kSensitiveBreadcrumbKeys = <String>{
  'authorization',
  'cookie',
  'company_id',
  'token',
  'access_token',
  'refresh_token',
  'id_token',
  'api_key',
  'apikey',
  'password',
  'secret',
};

/// Strips sensitive headers and drops the request body from [event].
///
/// The body is dropped WHOLESALE rather than filtered. Request bodies leak
/// product and customer data even when the headers look clean, and there is no
/// reliable allow-list for an arbitrary JSON payload.
SentryEvent? scrubEvent(SentryEvent event, Hint hint) {
  // DEFENCE IN DEPTH: also scrub the event's own breadcrumbs.
  //
  // In the normal path beforeBreadcrumb already cleaned these as they were
  // recorded, so this is usually a no-op. But breadcrumbs attached directly to
  // an event — or captured before the SDK was configured — never pass through
  // that hook, and a test proved they then survive verbatim into the serialized
  // envelope. Scrubbing here makes beforeSend self-sufficient rather than
  // dependent on beforeBreadcrumb having run first.
  // sentry 9.x deprecates copyWith in favour of direct assignment. That is also
  // the safer API here: copyWith treats a null argument as "keep the existing
  // value", so it CANNOT null-out a field — a copyWith(data: null) would have
  // silently retained the very request body this function exists to remove.
  // Direct assignment says what it means.
  if (event.breadcrumbs != null) {
    event.breadcrumbs = event.breadcrumbs!
        .map((b) => scrubBreadcrumb(b, hint))
        .whereType<Breadcrumb>()
        .toList();
  }

  final request = event.request;
  if (request == null) return event;

  final headers = <String, String>{};
  request.headers.forEach((key, value) {
    if (!kSensitiveHeaders.contains(key.toLowerCase())) {
      headers[key] = value;
    }
  });

  event.request = SentryRequest(
    url: request.url,
    method: request.method,
    queryString: request.queryString,
    headers: headers,
    fragment: request.fragment,
    apiTarget: request.apiTarget,
    // data + cookies deliberately omitted → dropped wholesale.
  );
  return event;
}

/// Strips sensitive keys from `breadcrumb.data`.
Breadcrumb? scrubBreadcrumb(Breadcrumb? breadcrumb, Hint hint) {
  if (breadcrumb == null) return null;
  final data = breadcrumb.data;
  if (data == null || data.isEmpty) return breadcrumb;

  final cleaned = <String, dynamic>{};
  data.forEach((key, value) {
    if (!kSensitiveBreadcrumbKeys.contains(key.toLowerCase())) {
      cleaned[key] = value;
    }
  });
  breadcrumb.data = cleaned;
  return breadcrumb;
}

/// Narrows which outbound origins carry `sentry-trace` / `baggage`.
///
/// A top-level function for the same reason [scrubEvent] is one: it can be
/// asserted directly, without booting the SDK.
///
/// [targets] null or empty is NOT the same as "propagate nowhere" — it means
/// "keep the SDK default", which is `['.*']`. Assigning an empty list would
/// match no origin at all and silently disable Flutter→Go correlation
/// everywhere, a failure indistinguishable from a backend that never received
/// the headers. Callers pass real hosts or nothing.
void applyTracePropagationTargets(
  SentryOptions options,
  List<String>? targets,
) {
  if (targets == null || targets.isEmpty) return;
  // `tracePropagationTargets` is declared `final List<String>` in sentry 9.x —
  // it is MUTATED, not reassigned. Assigning to it does not compile.
  options.tracePropagationTargets
    ..clear()
    ..addAll(targets);
}

/// Initialise Sentry for an AOCyber Flutter app.
///
/// [dsn] empty (the default when neither `window.APP_CONFIG.SENTRY_DSN` nor
/// `--dart-define=SENTRY_DSN` is supplied) makes the SDK a NO-OP while still
/// running [appRunner]. That keeps CI, tests and local dev off the Sentry quota
/// and is the reason an unconfigured app degrades silently rather than crashing.
///
/// [release] should be `<app>@<version>` and MUST match whatever `sentry-cli`
/// uploads sourcemaps/dSYMs under, or stack traces will not symbolicate.
///
/// [tracesSampleRate] defaults to 0.1, NOT 1.0. aodex and aocore-admin both ran
/// at 1.0, which was harmless while they reported into a SaaS project nobody
/// read and is not harmless now that several apps point at the self-hosted
/// stack. Error capture is unaffected — this samples performance traces only.
///
/// [tracePropagationTargets] controls which outbound origins receive the
/// `sentry-trace` and `baggage` headers that let a Flutter error be joined to
/// the Go span that served it (opsCluster).
///
/// The SDK default is `['.*']` — attach to EVERYTHING, including third-party
/// origins. That leaks internal trace ids to anyone the app talks to, so pass
/// the real API hosts explicitly. Entries are treated as regular expressions
/// matched against the request URL.
///
/// Getting this wrong looks exactly like a server-side bug: the headers are
/// simply never attached, the backend starts a fresh trace, and nothing in
/// either system reports an error. Note the browser can defeat this from the
/// other side too — `sentry-trace` and `baggage` are non-simple headers, so if
/// they are absent from the API's `Access-Control-Allow-Headers` the browser
/// strips them during CORS preflight before the request is ever sent.
///
/// [propagateTraceparent] defaults to **true**, which is NOT the SDK default.
///
/// Sentry attaches `sentry-trace` + `baggage`. Those are Sentry's own format —
/// an OpenTelemetry receiver does not understand them. Every AOCyber backend is
/// instrumented with `otelhttp` and the W3C propagator, which extracts
/// `traceparent`. With sentry's default (`propagateTraceparent = false`) the Go
/// side sees no header it recognises, starts a FRESH trace, and the Sentry event
/// and its server span become two unrelated searches — while every piece of
/// config looks correct. Turning it on is what actually joins the two systems.
///
/// [transport] and [eventProcessors] are test injection points
/// (InMemoryTransport + scope-injection processors for synthetic requests).
Future<void> initSentry({
  required String dsn,
  required FutureOr<void> Function() appRunner,
  String? release,
  String? dist,
  String environment = 'production',
  double tracesSampleRate = 0.1,
  List<String>? tracePropagationTargets,
  bool propagateTraceparent = true,
  Transport? transport,
  List<EventProcessor> eventProcessors = const [],
}) async {
  await SentryFlutter.init(
    (options) {
      options.dsn = dsn;
      options.environment = environment;
      if (release != null && release.isNotEmpty) options.release = release;
      if (dist != null && dist.isNotEmpty) options.dist = dist;
      options.tracesSampleRate = tracesSampleRate;
      applyTracePropagationTargets(options, tracePropagationTargets);
      // See the doc comment: without this the Go/OTel side cannot join.
      options.propagateTraceparent = propagateTraceparent;

      // PII posture. sendDefaultPii stays FALSE so the SDK does not attach
      // user IP / cookies of its own accord; the hooks below then remove what
      // the app itself may have attached.
      options.sendDefaultPii = false;
      options.beforeSend = scrubEvent;
      options.beforeBreadcrumb = scrubBreadcrumb;

      if (transport != null) options.transport = transport;
      for (final processor in eventProcessors) {
        options.addEventProcessor(processor);
      }
    },
    // appRunner (not `.then(runApp)`) so crashes raised during boot — including
    // inside runApp itself — are caught by the SDK's zone.
    appRunner: appRunner,
  );
}
