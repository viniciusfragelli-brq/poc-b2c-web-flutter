# POC — login Microsoft dentro de WebView no Flutter

Prova que um app Flutter pode delegar o login a uma página web carregada numa
WebView e receber de volta, por um canal JavaScript, um token que funciona de
fato numa API.

Três coisas, em ordem de importância:

1. o token atravessa web → nativo por um canal JS;
2. o lado nativo distingue a nossa página de qualquer outra que a WebView tenha
   carregado;
3. o token abre uma API a partir do código nativo — sem CORS, sem
   intermediário, o que é a única prova de que ele serve para alguma coisa.

Status: **validado em aparelho Android real**, com login real num tenant
Microsoft Entra ID, token entregue ao nativo e aprovado na conferência de
claims.

---

## Bibliotecas

| Lado | Biblioteca | Versão | Para quê |
| --- | --- | --- | --- |
| App | [`webview_flutter`](https://pub.dev/packages/webview_flutter) | 4.14.1 | a WebView e o canal JavaScript |
| App | `webview_flutter_android` | 4.14.1 | implementação Android (`WebView`, `addJavascriptInterface`) |
| App | `webview_flutter_wkwebview` | 3.26.1 | implementação iOS (`WKWebView`, `WKScriptMessageHandler`) |
| App | [`flutter_secure_storage`](https://pub.dev/packages/flutter_secure_storage) | 11.2.0 | Keychain (iOS) / KeyStore (Android) |
| App | [`http`](https://pub.dev/packages/http) | 1.6.0 | chamada nativa à API com o token |
| Web | [`@azure/msal-browser`](https://github.com/AzureAD/microsoft-authentication-library-for-js) | 5.22.0 | OAuth 2.0 / OIDC contra a Microsoft |
| Web | [`vite`](https://vite.dev) | 8.3.0 | dev server e build da SPA |
| Web | `typescript` | 7.0.2 | — |

Toolchain: Flutter 3.44.8 / Dart 3.12.2 (via [fvm](https://fvm.app)), Node 26.

Nenhuma biblioteca de "ponte" ou wrapper de terceiros. A comunicação usa a API
de canal do próprio `webview_flutter`.

---

## O mecanismo

### Visão geral

```
┌─ App Flutter ─────────────────────────────────────────────────────────┐
│                                                                       │
│  HomePage ──abre──► LoginWebViewPage                                  │
│                       │ gera nonce (32 bytes, Random.secure)          │
│                       │ addJavaScriptChannel('FlutterAuthBridge')     │
│                       │ loadRequest(SPA?bridge_nonce=<nonce>)         │
│                       │                                               │
│                       │   ┌─ WebView ──────────────────────────────┐  │
│                       │   │ SPA (Vite + MSAL.js)                   │  │
│                       │   │  guarda o nonce em storage             │  │
│                       │   │  postMessage {type:'ready'}      ──────┼─►│
│                       │   │  loginRedirect(scopes)                 │  │
│                       │   │     │                                  │  │
│                       │   │     ▼ navega para                      │  │
│                       │   │  login.microsoftonline.com  (senha+MFA)│  │
│                       │   │     │                                  │  │
│                       │   │     ▼ volta em redirect_uri com ?code=  │  │
│                       │   │  troca code por token (PKCE, sem secret)│  │
│                       │   │  postMessage {type:'auth_success'} ────┼─►│
│                       │   └────────────────────────────────────────┘  │
│                       ▼                                               │
│            confere origem + nonce + claims                            │
│                       ▼                                               │
│            Keychain / KeyStore ──► GET api/... (Dart, nativo)         │
└───────────────────────────────────────────────────────────────────────┘
```

O fluxo OAuth é **authorization code + PKCE** com cliente público. Não existe
client secret em lugar nenhum — nem no app, nem na página, nem no `.env`.

### Por que o login acontece na web, e não no nativo

Porque é isso que a POC quer provar: que dá para reaproveitar uma página de
login já existente — com o branding, as políticas e os provedores federados do
cliente — sem reimplementar OAuth no app. O nativo não sabe nada sobre o IdP;
ele só sabe receber um token pelo canal e conferir se pode confiar nele.

Isso também é o que permite trocar `entra` por `b2c` ou `external` mudando uma
variável de ambiente, sem tocar em uma linha de Dart.

### 1. O canal

`app/lib/auth/login_webview_page.dart`, em `_buildController()`:

```dart
final controller = WebViewController()
  ..setJavaScriptMode(JavaScriptMode.unrestricted)
  ..addJavaScriptChannel(
    AppConfig.bridgeChannel,          // 'FlutterAuthBridge'
    onMessageReceived: _onBridgeMessage,
  )
  ..setNavigationDelegate(NavigationDelegate(
    onNavigationRequest: _onNavigationRequest,
    // ...
  ));

controller.loadRequest(_loginUri, headers: AppConfig.initialHeaders);
```

`addJavaScriptChannel` é a API de plataforma: no Android o plugin registra um
`addJavascriptInterface`, no iOS um `WKScriptMessageHandler`. O nome vira
`window.FlutterAuthBridge` dentro da página, com um único método,
`postMessage(String)`. É **unidirecional**: web → nativo.

Não há injeção de JavaScript em runtime. O código Dart nunca chama
`runJavaScript`; a única coisa que o nativo empurra para dentro da página é o
nonce, e vai na query string da URL:

```dart
Uri get _loginUri => AppConfig.loginUri.replace(queryParameters: {
      ...AppConfig.loginUri.queryParameters,
      'bridge_nonce': _nonce,
      'bridge_channel': AppConfig.bridgeChannel,
      'bridge_host': defaultTargetPlatform.name,
    });
```

### 2. O contrato

Um envelope JSON, serializado como string. `nonce` é metadado de transporte e
fica fora do `payload`:

```json
{ "type": "auth_success", "nonce": "<nonce desta sessão>", "payload": { } }
```

| `type` | Quando | `payload` |
| --- | --- | --- |
| `ready` | a SPA carregou e achou o canal | `nonce`, `href` |
| `auth_success` | token obtido | `accessToken`, `idToken`, `tokenType`, `expiresOn`, `scopes`, `account` |
| `auth_error` | falha de auth ou de configuração | `code`, `message`, `correlationId` |
| `log` | espelha log da SPA no painel do app | `message` |

Os dois lados do contrato: `app/lib/auth/bridge_message.dart` e o tipo
`BridgeMessageType` em `web/src/bridge.ts`. Acrescentar um tipo de mensagem
significa mexer nos dois.

### 3. Quem monta e envia — web

`web/src/auth.ts` decide o que atravessa. Não se manda o `AuthenticationResult`
inteiro do MSAL: ele carrega estado interno que o nativo não tem o que fazer com.

```ts
export function toBridgePayload(result: AuthenticationResult): Record<string, unknown> {
  return {
    accessToken: result.accessToken,
    idToken: result.idToken,
    tokenType: result.tokenType,
    expiresOn: result.expiresOn?.toISOString() ?? null,
    scopes: result.scopes,
    account: accountPayload(result.account),
  };
}
```

`web/src/bridge.ts` faz a travessia:

```ts
export function post(type: BridgeMessageType, payload: Record<string, unknown> = {}): void {
  const envelope = JSON.stringify({ type, nonce: info.nonce, payload });
  const native = channel(info.channelName);
  if (!native) {
    console.info(`[bridge:sem-host] ${type}`, payload);   // rodando no browser
    return;
  }
  native.postMessage(envelope);
}
```

O canal é descoberto por duck typing, sem nada global nosso:

```ts
function channel(name: string): NativeChannel | null {
  const candidate = (window as unknown as Record<string, unknown>)[name];
  if (candidate && typeof (candidate as NativeChannel).postMessage === 'function') {
    return candidate as NativeChannel;
  }
  return null;
}
```

O fallback para `console.info` quando não há host nativo é o que permite
desenvolver a SPA inteira no navegador, sem compilar app.

### 4. Quem recebe — nativo

`app/lib/auth/login_webview_page.dart`, em `_onBridgeMessage()`. O que importa
vem **antes** de olhar o conteúdo:

```dart
Future<void> _onBridgeMessage(JavaScriptMessage message) async {
  // Fronteira 1 — quem está falando?
  final currentUrl = await _controller.currentUrl();
  final currentUri = currentUrl == null ? null : Uri.tryParse(currentUrl);
  if (currentUri == null || !_isTrustedSpa(currentUri)) {
    _log('⛔ mensagem descartada: veio de ${_shorten(currentUrl ?? '...')}');
    return;
  }

  // Fronteira 2 — é desta sessão de login?
  final msg = BridgeMessage.parse(message.message);
  if (msg.nonce != _nonce) {
    _log('⛔ mensagem descartada: nonce não confere');
    return;
  }

  switch (msg.type) {
    case BridgeMessageType.authSuccess:
      final pretty = const JsonEncoder.withIndent('  ').convert(msg.payload);
      final token = AuthToken.fromJson(msg.payload);
      final verification = TokenVerifier.verify(token);
      _finish(LoginOutcome(
        token: token, verification: verification, rawPayload: pretty,
      ));
    // ...
  }
}
```

### 5. As fronteiras de confiança

**O canal JS é global no contexto da WebView.** Qualquer documento que ela
carregar consegue chamar `window.FlutterAuthBridge.postMessage`. Se o nativo
apenas confiar no que chega ali, basta uma navegação para uma página hostil
para injetar um token falso. Três camadas fecham isso:

**(a) Allowlist de navegação** — `_onNavigationRequest` só libera a origem da
SPA e os domínios de login da Microsoft:

```dart
NavigationDecision _onNavigationRequest(NavigationRequest req) {
  final uri = Uri.tryParse(req.url);
  if (uri == null) return NavigationDecision.prevent;
  if (_isTrustedSpa(uri)) return NavigationDecision.navigate;

  final host = uri.host.toLowerCase();
  final allowed = AppConfig.allowedAuthHostSuffixes
      .any((s) => host == s || host.endsWith('.$s'));
  if (allowed) return NavigationDecision.navigate;

  _log('⛔ navegação bloqueada para `$host` — ...');
  return NavigationDecision.prevent;
}
```

A lista está em `AppConfig.allowedAuthHostSuffixes` e cobre workforce, B2C e
External ID. Um B2C com provedor federado (Google, SAML do cliente) vai navegar
para o domínio desse provedor — é o caso mais comum de precisar acrescentar
host.

**(b) Nonce por sessão de login** — 32 bytes de `Random.secure()`, gerados a
cada abertura da tela, passados na URL e exigidos em toda mensagem. A SPA os
guarda em storage porque o redirect ao IdP apaga a query string.

**(c) Origem no instante da mensagem** — `controller.currentUrl()` diz qual
documento está no ar quando a mensagem chega.

Depois disso, `TokenVerifier` (`app/lib/auth/token_verifier.dart`) confere
`aud`, `iss`, `tid` e `exp`.

---

## Estrutura

| Caminho | O que é |
| --- | --- |
| `.env` | **único lugar com valores reais**. Não versionado |
| `.env.example` | documenta todas as variáveis |
| `scripts/rodar-app.sh` | lê o `.env`, cria o `adb reverse`, monta os `--dart-define` |
| `.claude/skills/poc-login-credenciais/` | skill que guia o setup das credenciais |
| `web/src/bridge.ts` | lado web da ponte: nonce, canal, envelope |
| `web/src/auth.ts` | configuração do MSAL, payload e normalização de erro |
| `web/src/config.ts` | monta authority e escopos a partir do `.env` |
| `web/dev-host.html` | simulador do host nativo, para mexer na SPA sem app |
| `app/lib/config.dart` | tudo vem de `--dart-define`; nada fixo no código |
| `app/lib/auth/login_webview_page.dart` | a WebView, o canal e as fronteiras |
| `app/lib/auth/token_verifier.dart` | conferência de claims |
| `app/lib/api/resource_probe.dart` | chamada nativa à API com o token |

---

## Configuração

**Não há credencial no código-fonte.** Tudo vem do `.env` na raiz, que está no
`.gitignore`.

O caminho mais curto, dentro do Claude Code:

```
/poc-login-credenciais
```

A skill pergunta o que você tem, explica como criar o que falta no portal e
escreve o `.env`. À mão, copie `.env.example` para `.env` e siga os comentários
de lá.

Vale dizer o que **não** é segredo: client id e tenant id são identificadores
públicos, que aparecem na própria URL de login. Esta POC não usa client secret —
o PKCE existe justamente para dispensá-lo em cliente público.

### O ponto que mais quebra

O redirect URI precisa estar cadastrado na plataforma **Aplicativo de página
única (SPA)**, nunca "Web". Registrado como Web, o endpoint de token não devolve
cabeçalho CORS, a troca do `code` falha no navegador com `AADSTS9002326`, e nada
no erro do MSAL aponta para a causa.

---

## Rodar

### 1. A SPA

```bash
cd web && npm install && npm run dev
```

### 2. No navegador, antes do celular

Abra `http://localhost:5173/dev-host.html`. Essa página finge ser o Flutter:
instala um `window.FlutterAuthBridge` com a mesma assinatura do real e mostra na
tela cada mensagem que a SPA mandaria para o nativo. Iterar aqui é muito mais
rápido do que recompilar o app.

`?noredirect=1` bloqueia a saída para o IdP e apenas registra a URL de authorize
montada — jeito rápido de conferir client id, redirect URI e escopo.

### 3. No celular

```bash
./scripts/rodar-app.sh
```

Android plugado, depuração USB ligada. O script cria o `adb reverse`, lê o
`.env` e monta os `--dart-define`.

Use o script em vez de digitar os defines à mão — rodar com os defaults errados
produz "audience recusada", um sintoma que não aponta para a causa.

No app: **Entrar com Microsoft** → o ícone de inseto na AppBar abre o painel de
diagnóstico, com nonce conferido, origem validada e cada checagem de claim. O
JSON cru recebido do web aparece no card **"Última tentativa de login"**.

---

## Modelo de segurança

Ver **As fronteiras de confiança**, acima, para as três camadas que protegem o
canal. Além delas, o token fica em Keychain (iOS) / KeyStore (Android) via
`flutter_secure_storage`, e nunca volta para a WebView.

### O que a POC não protege

- **Não há verificação de assinatura.** `TokenVerifier` decodifica o JWT sem
  validar contra o JWKS do emissor; um token forjado passa por ela. É
  deliberado, e há teste cobrindo isso. Quem valida de verdade é o consumidor do
  token — a API de destino faz a dela. Um backend nosso que aceite esse token
  tem que validar assinatura por conta própria.
- **Não há refresh no nativo.** O access token vale cerca de uma hora. O refresh
  token fica no storage da WebView, não no app: expirado o token, o app reabre a
  WebView e o `acquireTokenSilent` resolve sem senha enquanto a sessão do
  browser durar. Passar refresh token pela ponte foi deixado de fora de
  propósito.
- **Nada disso resolve app comprometido.** Storage seguro protege contra leitura
  por outro app, não contra root ou jailbreak.

---

## Problemas conhecidos

| Sintoma | Causa provável |
| --- | --- |
| `ERR_CONNECTION_REFUSED` na WebView | falta `adb reverse tcp:5173 tcp:5173`. Ele morre ao desplugar o cabo. `adb reverse --list` mostra se está ativo |
| `AADSTS50011` redirect URI mismatch | a URI do `.env` não bate com a do portal. Compare caractere a caractere, barra final inclusa |
| `AADSTS9002326` cross-origin | redirect URI cadastrado como "Web" em vez de "Single-page application" |
| `AADSTS50020` | a conta não existe nesse diretório. Crie usuário nativo no tenant, ou convide como externa |
| `AADSTS53000` / `50097` device compliant | Conditional Access exigindo broker — ver **Plano B** |
| `endpoints_resolution_error` | authority não resolve: `VITE_TENANT_NAME` ou `VITE_B2C_POLICY` errados |
| `interaction_in_progress` | login interrompido deixou estado órfão. A SPA se recupera sozinha com um reload |
| Audience recusada pelo app | `APP_EXPECTED_AUDIENCE` errado. A tela diz qual audience chegou e o valor a usar |
| `crypto.subtle is undefined` | a SPA está numa origem que não é secure context — quase sempre IP de LAN em vez de `localhost` |
| Tela branca | HTTP puro no iOS (ATS), ou host bloqueado pela allowlist — veja o painel de diagnóstico |
| O app nunca pede senha de novo | cookie de sessão do IdP na WebView. O botão de logout limpa com `WebViewCookieManager` |

### Túnel HTTPS e a página de aviso do ngrok

Túnel só é necessário para iPhone, ou para abrir o site no navegador do celular.
No Android, `adb reverse` resolve e é o caminho padrão.

Se usar ngrok grátis: ele intercepta navegação com cara de navegador e mostra um
aviso antes do conteúdo. Como a volta do redirect do IdP é navegação top-level,
o aviso entra no meio do login. Medido em 22/09/2026, o gatilho é o prefixo
`Mozilla/` no User-Agent — não existe UA que pareça navegador e escape.

Saídas, da melhor para a pior: (1) não usar túnel; (2) um túnel sem
interstitial, como `cloudflared tunnel --url http://localhost:5173`;
(3) `APP_WEBVIEW_USER_AGENT=POCLogin/1.0` no `.env`, que funciona mas faz o IdP
ver esse UA também.

---

## Plano B, se Conditional Access barrar

**Com B2C ou External ID este risco praticamente não existe.** Eles atendem
identidade de cliente final, não gerenciam dispositivo e não tentam entregar a
autenticação ao Microsoft Authenticator.

O risco é do cenário workforce: se o tenant exigir dispositivo compliant ou app
protection policy, a WebView embutida não passa — o Entra ID quer entregar a
autenticação ao broker, e a WebView não participa disso. O caminho é trocar quem
hospeda o navegador, mantendo o resto:

- `flutter_web_auth_2` ou `ASWebAuthenticationSession`/Custom Tabs abre a
  **mesma SPA** no navegador do sistema;
- a SPA, em vez de `postMessage`, redireciona para um deep link do app;
- o app recebe no deep link e segue com o mesmo `TokenVerifier` e o mesmo
  `ResourceProbe`.

O código da SPA e a conferência do nativo não mudam — muda só o transporte. É
por isso que a ponte está isolada em `bridge.ts` e `login_webview_page.dart`.

Vale dizer que essa alternativa é também o que a Microsoft recomenda: navegador
do sistema em vez de WebView embutida, por causa de broker, SSO e gerenciador de
senhas.

---

## Verificação

```bash
cd app && fvm flutter analyze && fvm flutter test
cd web && npm run build
```
