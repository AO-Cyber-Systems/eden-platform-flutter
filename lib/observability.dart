/// Narrow entry point for the shared Sentry standard.
///
/// Import THIS, not `eden_platform.dart`, when all you want is [initSentry] and
/// the PII scrubbers.
///
/// `eden_platform.dart` is a barrel: it re-exports the whole package, including
/// `src/providers/mutation_notifier.dart`, which is written against
/// `flutter_riverpod ^2.6.1` (`Notifier.state` as a setter). Consumers that
/// override riverpod to 3.x — aodex does — fail to COMPILE the moment they
/// touch the barrel, with an error about `state` in a file they never asked
/// for and do not use.
///
/// Error reporting must not drag a state-management dependency in behind it, so
/// it gets its own door. Added for opsCluster, where the
/// barrel import blocked aodex's adoption of the shared init outright.
library;

export 'src/observability/sentry_init.dart';
