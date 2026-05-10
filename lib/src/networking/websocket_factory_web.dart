import 'package:web_socket_channel/web_socket_channel.dart';

/// Web implementation — browser sends cookies automatically for same-origin.
/// Headers parameter is ignored (browser manages auth via cookie jar).
///
/// [protocols] is forwarded to `WebSocketChannel.connect`. Pass your server's
/// expected subprotocol (e.g. `['actioncable-v1-json']` for Rails ActionCable).
///
/// [pingInterval] is currently ignored on web — the browser's WebSocket API
/// does not expose a ping interval. The platform sends pings at the
/// browser's discretion.
WebSocketChannel createPlatformWebSocketChannel(
  String url, {
  Map<String, String> headers = const {},
  List<String>? protocols,
  Duration pingInterval = const Duration(seconds: 3),
}) {
  // Convert http(s) to ws(s) scheme.
  final wsUrl = url
      .replaceFirst('https://', 'wss://')
      .replaceFirst('http://', 'ws://');

  return WebSocketChannel.connect(
    Uri.parse(wsUrl),
    protocols: protocols,
  );
}
