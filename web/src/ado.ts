import { config } from './config';

/**
 * Chamada de teste ao Azure DevOps feita pelo browser.
 *
 * É best-effort: `dev.azure.com` não garante cabeçalho CORS para chamada de
 * SPA, então uma falha aqui não diz nada sobre o token. A prova que vale é a
 * do lado nativo, onde não existe CORS.
 */
export async function probeAdoFromBrowser(accessToken: string): Promise<string> {
  if (!config.adoOrganization) return 'VITE_ADO_ORG não definida.';

  const url = `https://dev.azure.com/${config.adoOrganization}/_apis/projects?api-version=7.1`;
  try {
    const res = await fetch(url, {
      headers: { Authorization: `Bearer ${accessToken}` },
    });
    if (res.status === 203) {
      return 'HTTP 203 — o ADO devolveu tela de login: a organização provavelmente não está ligada a este tenant.';
    }
    if (!res.ok) return `HTTP ${res.status}`;
    const body = (await res.json()) as { value?: Array<{ name?: string }> };
    const names = (body.value ?? []).map((p) => p.name).filter(Boolean);
    return `OK — ${names.length} projeto(s): ${names.join(', ') || '(nenhum)'}`;
  } catch (error) {
    return `Falhou no browser (provavelmente CORS, não o token): ${String(error)}`;
  }
}
