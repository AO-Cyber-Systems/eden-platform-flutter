import 'package:web_socket_channel/web_socket_channel.dart';

import 'websocket_factory_stub.dart'
    if (dart.library.io) 'websocket_factory_io.dart'
    if (dart.library.js_interop) 'websocket_factory_web.dart';

/// Creates a cross-platform WebSocket channel.
///
/// On native (`dart:io`), uses `IOWebSocketChannel` with the supplied cookie
/// headers and `pingInterval`. On web, uses `WebSocketChannel.connect` —
/// the browser sends cookies automatically for same-origin requests, and
/// the [headers] parameter is ignored.
///
/// [protocols] is forwarded to the underlying channel. Pass the WS subprotocol
/// expected by your server — e.g. `['actioncable-v1-json']` for Rails
/// ActionCable.
WebSocketChannel createWebSocketChannel(
  String url, {
  Map<String, String> headers = const {},
  List<String>? protocols,
  Duration pingInterval = const Duration(seconds: 3),
}) {
  return createPlatformWebSocketChannel(
    url,
    headers: headers,
    protocols: protocols,
    pingInterval: pingInterval,
  );
}
