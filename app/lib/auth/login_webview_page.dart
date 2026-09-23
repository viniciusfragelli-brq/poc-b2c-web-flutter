import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../config.dart';
import 'auth_token.dart';
import 'bridge_message.dart';
import 'login_outcome.dart';
import 'token_verifier.dart';

/// Tela que hospeda a SPA de login e escuta o canal JS.
///
/// Devolve um [LoginOutcome] pelo `Navigator.pop`, ou `null` se a pessoa
/// fechou no meio.
class LoginWebViewPage extends StatefulWidget {
  const LoginWebViewPage({super.key});

  @override
  State<LoginWebViewPage> createState() => _LoginWebViewPageState();
}

class _LoginWebViewPageState extends State<LoginWebViewPage> {
  late final WebViewController _controller;
  late final String _nonce;

  final List<String> _diagnostics = [];
  bool _showDiagnostics = false;
  bool _finished = false;
  int _progress = 0;

  @override
  void initState() {
    super.initState();
    _nonce = _generateNonce();
    _log('nonce desta sessão: $_nonce');
    _log('origem confiável: ${AppConfig.spaOrigin}');
    _controller = _buildController();
  }

  /// 32 bytes de aleatoriedade criptográfica. A SPA recebe isto na URL,
  /// guarda em sessionStorage (para sobreviver ao redirect do Entra ID) e
  /// devolve em toda mensagem.
  static String _generateNonce() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(32, (_) => rnd.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  Uri get _loginUri {
    final base = AppConfig.loginUri;
    return base.replace(queryParameters: {
      ...base.queryParameters,
      'bridge_nonce': _nonce,
      'bridge_channel': AppConfig.bridgeChannel,
      'bridge_host': defaultTargetPlatform.name,
    });
  }

  WebViewController _buildController() {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..addJavaScriptChannel(
        AppConfig.bridgeChannel,
        onMessageReceived: _onBridgeMessage,
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _onNavigationRequest,
          onProgress: (p) => setState(() => _progress = p),
          onPageStarted: (url) => _log('→ carregando ${_shorten(url)}'),
          onPageFinished: (url) => _log('✓ carregou ${_shorten(url)}'),
          onWebResourceError: (e) {
            // Erro de subrecurso (imagem, css) polui o log e não quebra login.
            if (!e.isForMainFrame.orTrue) return;
            _log('✗ erro de rede: ${e.errorCode} ${e.description}');
          },
          onHttpError: (e) => _log(
            '✗ HTTP ${e.response?.statusCode} em ${_shorten(e.request?.uri.toString() ?? '')}',
          ),
        ),
      );

    controller.setOnConsoleMessage(
      (msg) => _log('[js:${msg.level.name}] ${msg.message}'),
    );

    if (controller.platform is AndroidWebViewController) {
      AndroidWebViewController.enableDebugging(kDebugMode);
    }

    if (AppConfig.webViewUserAgent.isNotEmpty) {
      controller.setUserAgent(AppConfig.webViewUserAgent);
      _log('user-agent trocado para ${AppConfig.webViewUserAgent}');
    }

    controller.loadRequest(_loginUri, headers: AppConfig.initialHeaders);
    return controller;
  }

  // --------------------------------------------------------------------------
  // Fronteira 1: por onde a WebView pode navegar
  // --------------------------------------------------------------------------

  /// Uma WebView que aceita navegar para qualquer lugar é uma WebView em que
  /// qualquer página consegue falar com o canal JS. A allowlist é o que
  /// transforma "canal aberto" em "canal aberto para a nossa SPA e para o
  /// Entra ID".
  NavigationDecision _onNavigationRequest(NavigationRequest req) {
    final uri = Uri.tryParse(req.url);
    if (uri == null) return NavigationDecision.prevent;

    if (_isTrustedSpa(uri)) return NavigationDecision.navigate;

    final host = uri.host.toLowerCase();
    final allowed = AppConfig.allowedAuthHostSuffixes.any(
      (suffix) => host == suffix || host.endsWith('.$suffix'),
    );
    if (allowed) return NavigationDecision.navigate;

    _log('⛔ navegação bloqueada para `$host` — se o login travou aqui, '
        'acrescente esse host em AppConfig.allowedAuthHostSuffixes');
    return NavigationDecision.prevent;
  }

  bool _isTrustedSpa(Uri uri) {
    final spa = AppConfig.loginUri;
    return uri.scheme == spa.scheme &&
        uri.host.toLowerCase() == spa.host.toLowerCase() &&
        uri.port == spa.port;
  }

  // --------------------------------------------------------------------------
  // Fronteira 2: quem pode falar pelo canal
  // --------------------------------------------------------------------------

  Future<void> _onBridgeMessage(JavaScriptMessage message) async {
    if (_finished) return;

    // O canal é global no contexto da WebView: a URL corrente é a única pista
    // de qual documento está falando.
    final currentUrl = await _controller.currentUrl();
    final currentUri = currentUrl == null ? null : Uri.tryParse(currentUrl);
    if (currentUri == null || !_isTrustedSpa(currentUri)) {
      _log('⛔ mensagem descartada: veio de ${_shorten(currentUrl ?? 'url desconhecida')}');
      return;
    }

    final msg = BridgeMessage.parse(message.message);
    if (msg.nonce != _nonce) {
      _log('⛔ mensagem descartada: nonce não confere (recebi `${msg.nonce}`)');
      return;
    }

    switch (msg.type) {
      case BridgeMessageType.ready:
        _log('🤝 handshake: a SPA enxergou o canal ${AppConfig.bridgeChannel}');
      case BridgeMessageType.log:
        _log('[spa] ${msg.payload['message']}');
      case BridgeMessageType.authError:
        final code = msg.payload['code'] ?? 'erro';
        final detail = msg.payload['message'] ?? '';
        final correlation = msg.payload['correlationId'];
        _log('✗ auth_error $code: $detail');
        _finish(LoginOutcome(
          error: [
            '$code',
            if ('$detail'.isNotEmpty) '$detail',
            if (correlation != null) 'correlationId: $correlation',
          ].join('\n'),
          diagnostics: List.of(_diagnostics),
        ));
      case BridgeMessageType.authSuccess:
        _log('🎟️ auth_success recebido pelo canal');
        final pretty =
            const JsonEncoder.withIndent('  ').convert(msg.payload);
        final token = AuthToken.fromJson(msg.payload);
        final verification = TokenVerifier.verify(token);
        for (final check in verification.checks) {
          _log('  ✓ $check');
        }
        for (final issue in verification.issues) {
          _log('  ${issue.fatal ? '✗' : '!'} ${issue.label}: ${issue.detail}');
        }
        _finish(LoginOutcome(
          token: token,
          verification: verification,
          diagnostics: List.of(_diagnostics),
          rawPayload: pretty,
        ));
      case BridgeMessageType.unknown:
        _log('? mensagem não reconhecida: ${_shorten(msg.raw, 120)}');
    }
  }

  void _finish(LoginOutcome outcome) {
    if (_finished || !mounted) return;
    _finished = true;
    Navigator.of(context).pop(outcome);
  }

  void _log(String line) {
    final stamped = '${DateTime.now().toIso8601String().substring(11, 23)}  $line';
    debugPrint('[bridge] $line');
    if (!mounted) {
      _diagnostics.add(stamped);
      return;
    }
    setState(() => _diagnostics.add(stamped));
  }

  static String _shorten(String value, [int max = 72]) =>
      value.length <= max ? value : '${value.substring(0, max)}…';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Entrar com Microsoft'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cancelar',
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            icon: Icon(_showDiagnostics ? Icons.visibility_off : Icons.bug_report),
            tooltip: 'Diagnóstico da ponte',
            onPressed: () => setState(() => _showDiagnostics = !_showDiagnostics),
          ),
        ],
        bottom: _progress < 100
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(value: _progress / 100),
              )
            : null,
      ),
      body: Column(
        children: [
          Expanded(child: WebViewWidget(controller: _controller)),
          if (_showDiagnostics)
            SizedBox(
              height: 220,
              child: _DiagnosticsPanel(lines: _diagnostics),
            ),
        ],
      ),
    );
  }
}

class _DiagnosticsPanel extends StatelessWidget {
  const _DiagnosticsPanel({required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF11151C),
      padding: const EdgeInsets.all(8),
      child: ListView.builder(
        reverse: true,
        itemCount: lines.length,
        itemBuilder: (context, i) => Text(
          lines[lines.length - 1 - i],
          style: const TextStyle(
            color: Color(0xFFB8C4D4),
            fontFamily: 'monospace',
            fontSize: 11,
            height: 1.45,
          ),
        ),
      ),
    );
  }
}

extension on bool? {
  bool get orTrue => this ?? true;
}
