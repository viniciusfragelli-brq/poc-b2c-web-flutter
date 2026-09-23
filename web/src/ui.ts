type Tone = 'info' | 'ok' | 'warn' | 'error';

function el<T extends HTMLElement>(id: string): T {
  const node = document.getElementById(id);
  if (!node) throw new Error(`Elemento #${id} não existe no index.html`);
  return node as T;
}

export function setStatus(text: string, tone: Tone = 'info'): void {
  const node = el('status');
  node.textContent = text;
  node.dataset.tone = tone;
}

export function setDetail(text: string): void {
  el('detail').textContent = text;
}

export function appendLog(line: string): void {
  const node = el('log');
  const stamp = new Date().toISOString().slice(11, 23);
  node.textContent = `${stamp}  ${line}\n${node.textContent ?? ''}`;
}

export function showActions(visible: boolean): void {
  el('actions').hidden = !visible;
}

export function onLogin(handler: () => void): void {
  el<HTMLButtonElement>('login').addEventListener('click', handler);
}

export function onProbe(handler: () => void): void {
  el<HTMLButtonElement>('probe').addEventListener('click', handler);
}

export function showProbe(visible: boolean): void {
  el('probe').hidden = !visible;
}

export function setBridgeBadge(native: boolean, channelName: string): void {
  const node = el('bridge');
  node.textContent = native
    ? `ponte nativa ativa · window.${channelName}`
    : 'sem host nativo · rodando no browser';
  node.dataset.tone = native ? 'ok' : 'warn';
}
