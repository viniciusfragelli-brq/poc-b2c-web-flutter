import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../api/resource_probe.dart';
import '../auth/auth_token.dart';
import '../auth/login_outcome.dart';
import '../auth/login_webview_page.dart';
import '../auth/token_store.dart';
import '../config.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _store = TokenStore();
  final _probe = ResourceProbe();

  AuthToken? _token;
  LoginOutcome? _lastOutcome;
  ProbeResult? _probeResult;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final stored = await _store.read();
    if (!mounted) return;
    setState(() => _token = stored);
  }

  Future<void> _login() async {
    final outcome = await Navigator.of(context).push<LoginOutcome>(
      MaterialPageRoute(builder: (_) => const LoginWebViewPage()),
    );
    if (!mounted || outcome == null) return;

    setState(() {
      _lastOutcome = outcome;
      _probeResult = null;
    });

    if (outcome.succeeded && outcome.token != null) {
      await _store.save(outcome.token!);
      if (!mounted) return;
      setState(() => _token = outcome.token);
    }
  }

  Future<void> _runProbe() async {
    final token = _token;
    if (token == null) return;
    setState(() => _busy = true);
    final result = await _probe.call(accessToken: token.accessToken);
    if (!mounted) return;
    setState(() {
      _probeResult = result;
      _busy = false;
    });
  }

  Future<void> _signOut() async {
    await _store.clear();
    // Sem limpar os cookies do Entra ID a próxima abertura da WebView faz SSO
    // silencioso e a demo parece que nunca pediu senha.
    await WebViewCookieManager().clearCookies();
    if (!mounted) return;
    setState(() {
      _token = null;
      _lastOutcome = null;
      _probeResult = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final token = _token;
    return Scaffold(
      appBar: AppBar(
        title: const Text('POC · Login AD em WebView'),
        actions: [
          if (token != null)
            IconButton(
              icon: const Icon(Icons.logout),
              tooltip: 'Encerrar sessão',
              onPressed: _signOut,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _ConfigCard(),
          const SizedBox(height: 12),
          if (token == null)
            _EmptyState(onLogin: _login)
          else
            _TokenCard(
              token: token,
              onProbe: _busy ? null : _runProbe,
              onRelogin: _login,
              busy: _busy,
            ),
          if (_probeResult != null) ...[
            const SizedBox(height: 12),
            _ProbeCard(result: _probeResult!),
          ],
          if (_lastOutcome != null) ...[
            const SizedBox(height: 12),
            _OutcomeCard(outcome: _lastOutcome!),
          ],
        ],
      ),
    );
  }
}

class _ConfigCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Configuração em uso',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            _kv('SPA', AppConfig.spaBaseUrl),
            _kv('Origem confiável', AppConfig.spaOrigin),
            _kv('Canal JS', 'window.${AppConfig.bridgeChannel}'),
            _kv('API a sondar',
                AppConfig.effectiveProbeUri?.toString() ?? '(nenhuma)'),
            _kv('Audience aceita', AppConfig.expectedAudiences.join(', ')),
            _kv('Tenant esperado',
                AppConfig.expectedTenantId.isEmpty ? '(checagem desligada)' : AppConfig.expectedTenantId),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onLogin});

  final VoidCallback onLogin;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Text(
              'Nenhum token no storage seguro.\n'
              'A WebView abre a SPA, a SPA fala com o Entra ID e devolve o '
              'token pelo canal JS.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onLogin,
              icon: const Icon(Icons.login),
              label: const Text('Entrar com Microsoft'),
            ),
          ],
        ),
      ),
    );
  }
}

class _TokenCard extends StatelessWidget {
  const _TokenCard({
    required this.token,
    required this.onProbe,
    required this.onRelogin,
    required this.busy,
  });

  final AuthToken token;
  final VoidCallback? onProbe;
  final VoidCallback onRelogin;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final account = token.account;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(token.isExpired ? Icons.error_outline : Icons.verified_user,
                    color: token.isExpired ? Colors.orange : Colors.green),
                const SizedBox(width: 8),
                Text(
                  token.isExpired ? 'Token expirado' : 'Token no lado nativo',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (account != null) ...[
              _kv('Conta', account.username),
              _kv('Nome', account.name),
            ],
            _kv('aud (access)', token.audience ?? '—'),
            if (token.idTokenClaims['aud'] != null)
              _kv('aud (id token)', '${token.idTokenClaims['aud']}'),
            _kv('tid', token.tenantId ?? '—'),
            _kv('appid', token.appId ?? '—'),
            _kv('Expira', '${token.effectiveExpiry ?? '—'}'),
            _kv('Scopes', token.scopes.isEmpty ? '—' : token.scopes.join(' ')),
            _kv('Token', token.preview),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: onProbe,
                  icon: busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.api),
                  label: const Text('Chamar a API com o token'),
                ),
                OutlinedButton.icon(
                  onPressed: onRelogin,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Repetir login'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ProbeCard extends StatelessWidget {
  const _ProbeCard({required this.result});

  final ProbeResult result;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: result.ok
          ? Colors.green.withValues(alpha: 0.08)
          : Colors.red.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              result.ok ? 'A API aceitou o token' : 'A API recusou o token',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(result.summary),
            if (result.items.isNotEmpty) ...[
              const SizedBox(height: 8),
              ...result.items.map((p) => Text('• $p')),
            ],
            if (result.detail != null) ...[
              const SizedBox(height: 8),
              Text(
                result.detail!,
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _OutcomeCard extends StatelessWidget {
  const _OutcomeCard({required this.outcome});

  final LoginOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final verification = outcome.verification;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Última tentativa de login',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (outcome.error != null)
              Text(outcome.error!,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            if (verification != null) ...[
              ...verification.checks.map((c) => Text('✓ $c')),
              ...verification.issues.map(
                (i) => Text('${i.fatal ? '✗' : '!'} ${i.label}: ${i.detail}'),
              ),
            ],
            if (outcome.rawPayload != null) ...[
              const SizedBox(height: 8),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('JSON recebido do web'),
                subtitle: const Text(
                  'exatamente o que a SPA empurrou pelo canal',
                  style: TextStyle(fontSize: 11),
                ),
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    color: const Color(0xFF11151C),
                    child: SelectableText(
                      outcome.rawPayload!,
                      style: const TextStyle(
                        color: Color(0xFFB8C4D4),
                        fontFamily: 'monospace',
                        fontSize: 10,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (outcome.diagnostics.isNotEmpty) ...[
              const SizedBox(height: 8),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Log da ponte'),
                children: [
                  SelectableText(
                    outcome.diagnostics.join('\n'),
                    style:
                        const TextStyle(fontFamily: 'monospace', fontSize: 11),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

Widget _kv(String key, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 116,
            child: Text(key,
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
