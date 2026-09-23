/**
 * A ponte da SPA para o lado nativo.
 *
 * No Android/iOS o Flutter injeta `window.<canal>` com um único método
 * `postMessage(string)`. É unidirecional: daqui para lá. Tudo que o nativo
 * precisa saber tem que caber numa string.
 */

export type BridgeMessageType = 'ready' | 'auth_success' | 'auth_error' | 'log';

interface NativeChannel {
  postMessage(message: string): void;
}

const DEFAULT_CHANNEL = 'FlutterAuthBridge';
const NONCE_KEY = 'poc.bridge.nonce';
const CHANNEL_KEY = 'poc.bridge.channel';

export interface BridgeInfo {
  /** Nonce que o Flutter gerou para esta sessão de login. */
  nonce: string | null;
  channelName: string;
  /** true quando existe um host nativo escutando. */
  native: boolean;
  host: string | null;
}

let info: BridgeInfo = {
  nonce: null,
  channelName: DEFAULT_CHANNEL,
  native: false,
  host: null,
};

/** sessionStorage some em alguns cenários de WebView; localStorage é a rede. */
function remember(key: string, value: string): void {
  for (const store of [sessionStorage, localStorage]) {
    try {
      store.setItem(key, value);
    } catch {
      /* modo privado / storage bloqueado */
    }
  }
}

function recall(key: string): string | null {
  for (const store of [sessionStorage, localStorage]) {
    try {
      const value = store.getItem(key);
      if (value) return value;
    } catch {
      /* idem */
    }
  }
  return null;
}

function channel(name: string): NativeChannel | null {
  const candidate = (window as unknown as Record<string, unknown>)[name];
  if (
    candidate &&
    typeof (candidate as NativeChannel).postMessage === 'function'
  ) {
    return candidate as NativeChannel;
  }
  return null;
}

/**
 * Lê o nonce e o nome do canal da URL e os guarda.
 *
 * Precisa ser chamado antes do MSAL: o redirect para o Entra ID e a volta para
 * o redirect URI apagam a query string, então o valor só sobrevive se estiver
 * no storage.
 */
export function initBridge(): BridgeInfo {
  const params = new URLSearchParams(window.location.search);

  const nonceFromUrl = params.get('bridge_nonce');
  if (nonceFromUrl) remember(NONCE_KEY, nonceFromUrl);

  const channelFromUrl = params.get('bridge_channel');
  if (channelFromUrl) remember(CHANNEL_KEY, channelFromUrl);

  const channelName = recall(CHANNEL_KEY) ?? DEFAULT_CHANNEL;

  info = {
    nonce: recall(NONCE_KEY),
    channelName,
    native: channel(channelName) !== null,
    host: params.get('bridge_host') ?? info.host,
  };
  return info;
}

export function bridgeInfo(): BridgeInfo {
  return info;
}

/**
 * Manda uma mensagem para o nativo. Sem host nativo, cai no console — que é o
 * modo de desenvolvimento no browser.
 */
export function post(
  type: BridgeMessageType,
  payload: Record<string, unknown> = {},
): void {
  const envelope = JSON.stringify({ type, nonce: info.nonce, payload });
  const native = channel(info.channelName);
  if (!native) {
    console.info(`[bridge:sem-host] ${type}`, payload);
    return;
  }
  native.postMessage(envelope);
}

export function log(message: string): void {
  post('log', { message });
}

/** Limpa o nonce depois do uso, para ele não vazar para um login seguinte. */
export function clearNonce(): void {
  for (const store of [sessionStorage, localStorage]) {
    try {
      store.removeItem(NONCE_KEY);
    } catch {
      /* idem */
    }
  }
}
