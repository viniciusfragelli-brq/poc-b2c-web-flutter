import {
  PublicClientApplication,
  InteractionRequiredAuthError,
  AuthError,
  LogLevel,
  type AuthenticationResult,
  type AccountInfo,
  type Configuration,
} from '@azure/msal-browser';

import { config } from './config';
import { log } from './bridge';

/**
 * `?noredirect=1` impede a saída para o Entra ID e apenas registra a URL de
 * authorize que o MSAL montou.
 *
 * É o que permite conferir client id, redirect URI e escopo pedidos sem sair
 * da página — e o que torna possível testar a ponte sem tenant nenhum.
 */
const blockRedirect = new URLSearchParams(window.location.search).has('noredirect');

/** Escopos vindos da configuração — ver `buildScopes` em config.ts. */
export const scopes = config.scopes;

const msalConfig: Configuration = {
  auth: {
    clientId: config.clientId,
    authority: config.authority,
    knownAuthorities: config.knownAuthorities,
    redirectUri: config.redirectUri,
    ...(blockRedirect
      ? {
          onRedirectNavigate: (url: string) => {
            log(`redirect bloqueado por ?noredirect=1 → ${url}`);
            return false;
          },
        }
      : {}),
  },
  cache: {
    // Dentro da WebView localStorage sobrevive melhor que sessionStorage ao
    // ir e voltar do login.microsoftonline.com.
    cacheLocation: 'localStorage',
  },
  system: {
    loggerOptions: {
      piiLoggingEnabled: false,
      logLevel: LogLevel.Warning,
      loggerCallback: (_level, message, containsPii) => {
        if (containsPii) return;
        log(`msal: ${message}`);
      },
    },
  },
};

export async function createApp(): Promise<PublicClientApplication> {
  const app = new PublicClientApplication(msalConfig);
  await app.initialize();
  return app;
}

/**
 * Pega o token do Azure DevOps sem interação, e devolve `null` quando o Entra
 * ID exige que a pessoa apareça (primeiro login, MFA, consent, sessão
 * expirada). Nesse caso quem chama dispara o redirect.
 */
export async function silentAdoToken(
  app: PublicClientApplication,
  account: AccountInfo,
): Promise<AuthenticationResult | null> {
  try {
    return await app.acquireTokenSilent({ scopes, account });
  } catch (error) {
    if (error instanceof InteractionRequiredAuthError) return null;
    throw error;
  }
}

export interface NormalizedError {
  code: string;
  message: string;
  correlationId?: string;
}

/** Normaliza o erro para o envelope que o lado nativo sabe ler. */
export function normalizeError(error: unknown): NormalizedError {
  if (error instanceof AuthError) {
    return {
      code: error.errorCode || 'auth_error',
      message: error.errorMessage || error.message,
      correlationId: error.correlationId,
    };
  }
  if (error instanceof Error) {
    return { code: error.name, message: error.message };
  }
  return { code: 'unknown', message: String(error) };
}

function accountPayload(account: AccountInfo | null): Record<string, unknown> | null {
  if (!account) return null;
  return {
    name: account.name ?? '',
    username: account.username,
    tenantId: account.tenantId,
    homeAccountId: account.homeAccountId,
  };
}

/** Só o que o nativo precisa. Nada de despejar o AuthenticationResult inteiro. */
export function toBridgePayload(
  result: AuthenticationResult,
): Record<string, unknown> {
  return {
    accessToken: result.accessToken,
    idToken: result.idToken,
    tokenType: result.tokenType,
    expiresOn: result.expiresOn?.toISOString() ?? null,
    scopes: result.scopes,
    account: accountPayload(result.account),
  };
}

/** `exp` de um JWT, em milissegundos. `null` se não der para ler. */
export function jwtExpiryMs(jwt: string): number | null {
  const part = jwt.split('.')[1];
  if (!part) return null;
  try {
    const padded = part.replace(/-/g, '+').replace(/_/g, '/');
    const json = JSON.parse(
      atob(padded + '='.repeat((4 - (padded.length % 4)) % 4)),
    ) as { exp?: unknown };
    return typeof json.exp === 'number' ? json.exp * 1000 : null;
  } catch {
    return null;
  }
}

/**
 * Payload de identidade montado a partir da conta em cache.
 *
 * Em modo identidade não há como renovar por `acquireTokenSilent`: os escopos
 * pedidos são só `openid` e `profile`, que o MSAL trata como reservados e
 * remove — não sobra escopo de recurso para pedir. Mas o ID token cru fica
 * guardado em `AccountInfo.idToken`, então numa segunda execução basta lê-lo de
 * lá. Devolve `null` quando não há token, ou quando ele expira em menos de um
 * minuto — aí o caminho é login interativo.
 */
export function identityPayloadFromAccount(
  account: AccountInfo,
): Record<string, unknown> | null {
  const raw = account.idToken;
  if (!raw) return null;

  const expiryMs = jwtExpiryMs(raw);
  if (expiryMs !== null && expiryMs <= Date.now() + 60_000) return null;

  return {
    accessToken: '',
    idToken: raw,
    tokenType: 'Bearer',
    expiresOn: expiryMs === null ? null : new Date(expiryMs).toISOString(),
    scopes: [],
    account: accountPayload(account),
  };
}
