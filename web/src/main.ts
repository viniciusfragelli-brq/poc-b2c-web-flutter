import type { AccountInfo, PublicClientApplication } from '@azure/msal-browser';

import { clearNonce, initBridge, post } from './bridge';
import { config, missingConfig } from './config';
import {
  createApp,
  identityPayloadFromAccount,
  normalizeError,
  scopes,
  silentAdoToken,
  toBridgePayload,
} from './auth';
import { probeAdoFromBrowser } from './ado';
import {
  appendLog,
  onLogin,
  onProbe,
  setBridgeBadge,
  setDetail,
  setStatus,
  showActions,
  showProbe,
} from './ui';

let app: PublicClientApplication | null = null;
let lastAccessToken: string | null = null;

/** Impede laço de reload: uma tentativa de recuperação por aba. */
const RECOVERY_KEY = 'poc.interaction.recovered';

/**
 * Erros que significam a mesma coisa: o cache temporário do MSAL não
 * corresponde à realidade, e a saída é limpá-lo e começar de novo.
 *
 * Não é um código só. Interromper um login no meio deixa estados diferentes
 * dependendo de onde parou, e cada estado sai por um erro diferente — vistos
 * aqui: `interaction_in_progress` quando a trava sobrou inteira,
 * `no_token_request_cache_error` quando sobrou a trava mas não o pedido que ela
 * acompanhava. Tratar só o primeiro deixa a WebView travada pelos outros.
 */
const STALE_STATE_ERRORS = new Set([
  'interaction_in_progress',
  'no_token_request_cache_error',
  'state_not_found',
  'invalid_state',
  'state_interaction_type_mismatch',
]);

function alreadyRecovered(): boolean {
  try {
    return sessionStorage.getItem(RECOVERY_KEY) === '1';
  } catch {
    return false;
  }
}

function markRecovered(): void {
  try {
    sessionStorage.setItem(RECOVERY_KEY, '1');
  } catch {
    /* storage bloqueado */
  }
}

/**
 * Apaga o cache temporário do MSAL, que é onde mora a trava de interação.
 *
 * O MSAL marca `msal.interaction.status` quando começa um login interativo e só
 * limpa quando o redirect volta. Se o fluxo for interrompido no meio — a pessoa
 * fecha a WebView, o app é morto, o `?noredirect=1` bloqueia a saída — a marca
 * fica, e todo login seguinte morre em `interaction_in_progress`.
 *
 * No browser dá para limpar os dados do site. Dentro de uma WebView não há essa
 * porta: sem isto, o único jeito de sair é limpar os dados do app.
 *
 * Duas coisas que só se descobrem olhando o storage: a trava vive em
 * **sessionStorage**, não no `cacheLocation` configurado — o MSAL mantém o
 * cache temporário separado do cache de token. E ela vem acompanhada de
 * `request.params`, `request.origin` e `code.verifier`, que também precisam
 * sair, senão o login seguinte tenta retomar um fluxo que não existe mais.
 *
 * Mexe só no sessionStorage de propósito: o cache de conta e token está no
 * localStorage, e apagá-lo custaria o SSO silencioso sem necessidade.
 */
function clearStaleInteraction(): boolean {
  try {
    const stale = Object.keys(sessionStorage).filter((k) => k.startsWith('msal.'));
    for (const key of stale) sessionStorage.removeItem(key);
    return stale.length > 0;
  } catch {
    return false; // storage bloqueado
  }
}

async function startInteractiveLogin(): Promise<void> {
  if (!app) return;
  setStatus('Redirecionando para a Microsoft…');
  showActions(false);
  // Redirect, não popup: popup dentro de WebView depende de
  // setSupportMultipleWindows e de tratar onCreateWindow no nativo, e falha
  // silenciosamente quando isso não está configurado.
  await app.loginRedirect({ scopes });
}

/** Empurra o payload pela ponte e atualiza a tela. Camada única de entrega. */
function deliverPayload(payload: Record<string, unknown>): void {
  const account = payload['account'] as Record<string, unknown> | null;
  lastAccessToken = (payload['accessToken'] as string) || null;

  post('auth_success', payload);
  clearNonce();
  try {
    sessionStorage.removeItem(RECOVERY_KEY);
  } catch {
    /* storage bloqueado */
  }

  const scopeList = payload['scopes'] as string[] | undefined;
  setStatus('Token entregue ao lado nativo.', 'ok');
  setDetail(
    [
      `idp: ${config.idp}${config.identityOnly ? ' (só identidade, ID token)' : ''}`,
      `conta: ${account?.['username'] ?? '—'}`,
      `tenant: ${account?.['tenantId'] ?? '—'}`,
      `escopos: ${scopeList?.join(' ') || '—'}`,
      `expira: ${payload['expiresOn'] ?? '—'}`,
    ].join('\n'),
  );
  appendLog('auth_success enviado pelo canal');

  // Sem access token de recurso não há o que sondar: em modo identidade o que
  // atravessou foi o ID token, e ID token não abre API nenhuma.
  showProbe(Boolean(lastAccessToken) && Boolean(config.adoOrganization));
}

async function deliver(
  result: Awaited<ReturnType<PublicClientApplication['acquireTokenSilent']>>,
): Promise<void> {
  deliverPayload(toBridgePayload(result));
}

function fail(error: unknown): void {
  const normalized = normalizeError(error);

  if (STALE_STATE_ERRORS.has(normalized.code) && !alreadyRecovered()) {
    // O reload é a recuperação; a limpeza é só garantia. O MSAL às vezes já
    // limpou o cache temporário antes de lançar o erro, e condicionar o reload
    // a ter achado chave para apagar deixava justamente esses casos travados.
    markRecovered();
    clearStaleInteraction();
    appendLog(`estado órfão (${normalized.code}) — limpando e recarregando`);
    window.location.reload();
    return;
  }

  post('auth_error', { ...normalized });
  setStatus(`Falhou: ${normalized.code}`, 'error');
  setDetail(`${normalized.message}\ncorrelationId: ${normalized.correlationId ?? '—'}`);
  appendLog(`auth_error ${normalized.code}`);
  showActions(true);
}

async function boot(): Promise<void> {
  const bridge = initBridge();
  setBridgeBadge(bridge.native, bridge.channelName);

  const missing = missingConfig();
  if (missing.length > 0) {
    setStatus('Configuração incompleta.', 'error');
    setDetail(
      `Faltam: ${missing.join(', ')}\n\n` +
        'O arquivo .env fica na RAIZ do projeto, não em web/.\n' +
        'Copie .env.example para .env, preencha e reinicie o `npm run dev`.\n\n' +
        'No Claude Code, a skill /poc-login-credenciais faz isso guiado.',
    );
    post('auth_error', {
      code: 'config_missing',
      message: `Variáveis ausentes: ${missing.join(', ')}`,
    });
    return;
  }

  appendLog(
    `nonce ${bridge.nonce ? 'recebido' : 'AUSENTE — o nativo vai descartar as mensagens'}`,
  );

  app = await createApp();
  post('ready', { nonce: bridge.nonce, href: window.location.origin });

  // Volta do redirect do Entra ID. Se veio com resultado, o token já está aqui.
  const redirectResult = await app.handleRedirectPromise();
  if (redirectResult) {
    appendLog('voltou do redirect com resultado');
    await deliver(redirectResult);
    return;
  }

  const account: AccountInfo | null =
    app.getActiveAccount() ?? app.getAllAccounts()[0] ?? null;

  if (!account) {
    setStatus('Ninguém autenticado.');
    setDetail('A SPA precisa mandar você para o Entra ID.');
    // Dentro da WebView o login é a única razão da página existir, então
    // dispara sozinho. No browser, deixa o botão para facilitar depuração.
    if (bridge.native) {
      await startInteractiveLogin();
    } else {
      showActions(true);
    }
    return;
  }

  app.setActiveAccount(account);
  setStatus(`Sessão encontrada para ${account.username}. Pedindo token…`);

  if (config.identityOnly) {
    const cached = identityPayloadFromAccount(account);
    if (cached) {
      appendLog('ID token recuperado da conta em cache');
      deliverPayload(cached);
      return;
    }
    appendLog('sem ID token válido em cache — login interativo');
    await startInteractiveLogin();
    return;
  }

  const silent = await silentAdoToken(app, account);
  if (silent) {
    appendLog('token obtido silenciosamente (cache ou refresh)');
    await deliver(silent);
    return;
  }

  appendLog('o Entra ID exigiu interação');
  await app.acquireTokenRedirect({ scopes, account });
}

onLogin(() => {
  startInteractiveLogin().catch(fail);
});

onProbe(() => {
  if (!lastAccessToken) return;
  setDetail('Chamando o Azure DevOps pelo browser…');
  probeAdoFromBrowser(lastAccessToken)
    .then((message) => {
      setDetail(message);
      appendLog(`probe web: ${message}`);
    })
    .catch((error: unknown) => setDetail(String(error)));
});

boot().catch(fail);
