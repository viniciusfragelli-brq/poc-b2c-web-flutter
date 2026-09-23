import 'dart:convert';

/// Tipos de mensagem que a SPA pode empurrar pelo canal JS.
enum BridgeMessageType {
  /// SPA carregou e enxergou o canal. Serve de handshake.
  ready,

  /// Login concluído, token no payload.
  authSuccess,

  /// Login falhou. `payload` traz code/message/correlationId.
  authError,

  /// Log da SPA espelhado no nativo, para diagnóstico.
  log,

  /// Qualquer coisa que não reconhecemos.
  unknown,
}

BridgeMessageType _typeFrom(String? raw) {
  switch (raw) {
    case 'ready':
      return BridgeMessageType.ready;
    case 'auth_success':
      return BridgeMessageType.authSuccess;
    case 'auth_error':
      return BridgeMessageType.authError;
    case 'log':
      return BridgeMessageType.log;
    default:
      return BridgeMessageType.unknown;
  }
}

/// Envelope trocado entre a SPA e o app.
///
/// O `nonce` não é enfeite: é o que distingue "a nossa SPA respondeu" de
/// "alguma página que a WebView carregou resolveu chamar o canal". O canal JS
/// é global no contexto da WebView, então qualquer documento carregado ali
/// consegue invocá-lo.
class BridgeMessage {
  const BridgeMessage({
    required this.type,
    required this.nonce,
    required this.payload,
    required this.raw,
  });

  final BridgeMessageType type;
  final String? nonce;
  final Map<String, dynamic> payload;
  final String raw;

  static BridgeMessage parse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return BridgeMessage(
          type: BridgeMessageType.unknown,
          nonce: null,
          payload: const {},
          raw: raw,
        );
      }
      final payload = decoded['payload'];
      return BridgeMessage(
        type: _typeFrom(decoded['type'] as String?),
        nonce: decoded['nonce'] as String?,
        payload: payload is Map<String, dynamic> ? payload : const {},
        raw: raw,
      );
    } on FormatException {
      return BridgeMessage(
        type: BridgeMessageType.unknown,
        nonce: null,
        payload: const {},
        raw: raw,
      );
    }
  }
}
