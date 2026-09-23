/// Configuração da POC. Nada aqui é secreto (client id público, org, URLs),
/// mas tudo vem de `--dart-define` para não fixar ambiente no código.
class AppConfig {
  const AppConfig._();

  /// Origem da SPA que roda dentro da WebView.
  ///
  /// Precisa ser exatamente a mesma origem registrada como redirect URI
  /// (plataforma "Single-page application") no App Registration.
  ///
  /// O default é `http://localhost:5173` porque é a única origem HTTP que
  /// serve: o MSAL usa `crypto.subtle` para o PKCE, e `crypto.subtle` só
  /// existe em secure context. `http://192.168.x.x` não é secure context e o
  /// login quebra ali — `localhost` é, por especificação. Do celular,
  /// `localhost` chega no seu Mac via `adb reverse tcp:5173 tcp:5173`.
  static const String spaBaseUrl = String.fromEnvironment(
    'SPA_BASE_URL',
    defaultValue: 'http://localhost:5173',
  );

  /// Application ID do recurso Azure DevOps. É a mesma constante em qualquer
  /// tenant do mundo — não é um id nosso. Só se aplica a tenant de workforce:
  /// B2C e External ID não emitem token para este recurso.
  static const String adoResourceId = '499b84ac-1321-427f-aa17-267ca6975798';

  /// Organização do Azure DevOps, quando o alvo for o ADO.
  static const String adoOrganization = String.fromEnvironment('ADO_ORG');

  /// URL que o lado nativo chama para provar que o token serve.
  ///
  /// Vazio com [adoOrganization] preenchida cai na API de projetos do ADO.
  /// Vazio nos dois desliga a sonda — o que é o caso em modo identidade, onde
  /// o que atravessou foi um ID token e ID token não abre API nenhuma.
  static const String probeUrl = String.fromEnvironment('PROBE_URL');

  /// Audiences aceitas no token, separadas por vírgula.
  ///
  /// Vazio aceita as do Azure DevOps. Em B2C a audience é o client id do app
  /// que pediu o token — então aqui vai o client id, ou o do app de API.
  static const String expectedAudience =
      String.fromEnvironment('EXPECTED_AUDIENCE');

  /// Tenant esperado no claim `tid`. Vazio desliga a checagem.
  static const String expectedTenantId = String.fromEnvironment('TENANT_ID');

  /// Nome do JavaScriptChannel. A SPA procura por `window.<nome>`.
  static const String bridgeChannel = 'FlutterAuthBridge';

  /// User-Agent alternativo para a WebView. Vazio mantém o padrão do sistema.
  ///
  /// Existe por causa do ngrok grátis, que intercepta navegação com cara de
  /// navegador e mostra uma página de aviso antes de entregar o conteúdo. Um
  /// UA que não pareça navegador passa direto — mas afeta também as requisições
  /// ao IdP, então é remédio para usar só se a página de aviso aparecer.
  static const String webViewUserAgent =
      String.fromEnvironment('WEBVIEW_USER_AGENT');

  /// Cabeçalhos da primeira navegação.
  ///
  /// `ngrok-skip-browser-warning` pula a página de aviso do ngrok. Só vale para
  /// esta requisição: a volta do redirect do IdP é navegação iniciada pelo
  /// próprio navegador e não carrega cabeçalho nosso. Inofensivo em outro host.
  static const Map<String, String> initialHeaders = {
    'ngrok-skip-browser-warning': 'true',
  };

  static Uri get loginUri => Uri.parse(spaBaseUrl);

  /// Origem canônica da SPA (scheme://host[:port]), usada para decidir se uma
  /// mensagem que chegou no canal veio de onde deveria.
  static String get spaOrigin {
    final u = loginUri;
    final hasExplicitPort = u.hasPort &&
        !((u.scheme == 'https' && u.port == 443) ||
            (u.scheme == 'http' && u.port == 80));
    return hasExplicitPort
        ? '${u.scheme}://${u.host}:${u.port}'
        : '${u.scheme}://${u.host}';
  }

  static List<String> get expectedAudiences {
    if (expectedAudience.isEmpty) {
      return const [
        adoResourceId,
        'https://app.vssps.visualstudio.com/',
        'https://management.core.windows.net/',
      ];
    }
    return expectedAudience
        .split(',')
        .map((a) => a.trim())
        .where((a) => a.isNotEmpty)
        .toList();
  }

  static Uri? get effectiveProbeUri {
    if (probeUrl.isNotEmpty) return Uri.tryParse(probeUrl);
    if (adoOrganization.isNotEmpty) {
      return Uri.https(
        'dev.azure.com',
        '/$adoOrganization/_apis/projects',
        {'api-version': '7.1'},
      );
    }
    return null;
  }

  /// Hosts pelos quais a WebView pode navegar durante o login.
  ///
  /// Casamento por sufixo de domínio. Cobre workforce
  /// (`login.microsoftonline.com`), B2C (`b2clogin.com`) e External ID
  /// (`ciamlogin.com`). Se o login travar numa tela branca, olhe o painel de
  /// diagnóstico: o host bloqueado aparece lá e basta acrescentá-lo aqui.
  ///
  /// Um B2C com identity provider federado (Google, Facebook, um SAML do
  /// cliente) vai navegar para o domínio desse provedor, que não está aqui —
  /// é o caso mais comum de precisar mexer nesta lista.
  static const Set<String> allowedAuthHostSuffixes = {
    // Workforce
    'login.microsoftonline.com',
    'login.microsoft.com',
    'login.windows.net',
    'login.live.com',
    'microsoftazuread-sso.com',
    'microsoftonline-p.com',
    // B2C e External ID
    'b2clogin.com',
    'ciamlogin.com',
    // Assets das telas de login
    'msftauth.net',
    'msauth.net',
    'office.com',
  };
}
