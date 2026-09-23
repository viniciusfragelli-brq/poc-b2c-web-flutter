import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';

class ProbeResult {
  const ProbeResult({
    required this.ok,
    required this.statusCode,
    required this.summary,
    this.items = const [],
    this.detail,
  });

  final bool ok;
  final int statusCode;
  final String summary;
  final List<String> items;
  final String? detail;
}

/// Chama uma API do lado nativo com o token que veio da WebView.
///
/// É esta chamada que fecha a POC: um token que atravessa a ponte mas não abre
/// nenhuma API não provou nada. E a chamada tem que ser daqui, do nativo — no
/// browser um erro de CORS é indistinguível de um token ruim.
///
/// A URL vem de `PROBE_URL`, ou da API de projetos do Azure DevOps quando só
/// `ADO_ORG` está definida.
class ResourceProbe {
  ResourceProbe({http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final http.Client _http;

  Future<ProbeResult> call({required String accessToken}) async {
    final uri = AppConfig.effectiveProbeUri;
    if (uri == null) {
      return const ProbeResult(
        ok: false,
        statusCode: 0,
        summary: 'Nenhuma API configurada para sondar',
        detail: 'Passe --dart-define=PROBE_URL=<url> ou --dart-define=ADO_ORG=<org>.',
      );
    }

    if (accessToken.isEmpty) {
      return const ProbeResult(
        ok: false,
        statusCode: 0,
        summary: 'Não há access token para usar',
        detail: 'O fluxo rodou em modo identidade e entregou só o ID token. '
            'ID token não é credencial de acesso: para chamar API, peça um '
            'escopo de recurso em VITE_API_SCOPE.',
      );
    }

    try {
      final res = await _http.get(uri, headers: {
        'Authorization': 'Bearer $accessToken',
        'Accept': 'application/json',
      });

      if (res.statusCode == 200) {
        return ProbeResult(
          ok: true,
          statusCode: 200,
          summary: '$uri respondeu 200',
          items: _names(res.body),
          detail: _trim(res.body, 240),
        );
      }

      // 203 é a pegadinha do Azure DevOps: em vez de 401 ele devolve 203 com o
      // HTML da tela de login quando o token não serve para a organização.
      if (res.statusCode == 203 && uri.host.contains('dev.azure.com')) {
        return ProbeResult(
          ok: false,
          statusCode: 203,
          summary: 'O Azure DevOps devolveu a tela de login (203)',
          detail: 'Quase sempre significa que a organização não está ligada ao '
              'tenant que emitiu o token, ou que a conta não é membro dela. '
              'Confira em Organization settings → Microsoft Entra.',
        );
      }

      return ProbeResult(
        ok: false,
        statusCode: res.statusCode,
        summary: 'HTTP ${res.statusCode} em $uri',
        detail: _trim(res.body),
      );
    } catch (e) {
      return ProbeResult(
        ok: false,
        statusCode: 0,
        summary: 'Falha de rede ao chamar $uri',
        detail: '$e',
      );
    }
  }

  /// Extrai nomes de uma resposta no formato `{value: [{name: …}]}`, que é o
  /// do Azure DevOps. Outra API simplesmente não casa e a lista fica vazia.
  static List<String> _names(String body) {
    try {
      final decoded = jsonDecode(body);
      final value = decoded is Map<String, dynamic> ? decoded['value'] : null;
      if (value is! List) return const [];
      return value
          .whereType<Map<String, dynamic>>()
          .map((e) => '${e['name']}')
          .where((n) => n != 'null')
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static String _trim(String body, [int max = 500]) =>
      body.length <= max ? body : '${body.substring(0, max)}…';
}
