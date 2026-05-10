import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Native implementation using IOWebSocketChannel with cookie headers and
/// configurable ping interval.
///
/// Note: [protocols] is supported on native via the `protocols` argument.
WebSocketChannel createPlatformWebSocketChannel(
  String url, {
  Map<String, String> headers = const {},
  List<String>? protocols,
  Duration pingInterval = const Duration(seconds: 3),
}) {
  return IOWebSocketChannel.connect(
    url,
    headers: headers,
    protocols: protocols,
    pingInterval: pingInterval,
  );
}
