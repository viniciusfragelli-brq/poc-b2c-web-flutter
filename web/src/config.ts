/** Application ID do recurso Azure DevOps — constante em qualquer tenant. */
export const ADO_RESOURCE_ID = '499b84ac-1321-427f-aa17-267ca6975798';

/**
 * Qual família de IdP da Microsoft está atendendo.
 *
 * - `entra`    — tenant de workforce (funcionário com identidade corporativa)
 * - `b2c`      — Azure AD B2C (login de cliente final)
 * - `external` — Microsoft Entra External ID, o sucessor do B2C
 *
 * A ponte para o nativo é idêntica nos três. O que muda é a authority, o
 * escopo pedido e quem valida o token do outro lado.
 */
export type IdpKind = 'entra' | 'b2c' | 'external';

const idp = (import.meta.env.VITE_IDP ?? 'entra') as IdpKind;

const tenantId = import.meta.env.VITE_TENANT_ID ?? '';
const clientId = import.meta.env.VITE_CLIENT_ID ?? '';

/** Só o subdomínio: `contoso`, não `contoso.onmicrosoft.com`. */
const tenantName = import.meta.env.VITE_TENANT_NAME ?? '';

/** User flow do B2C, ex. `B2C_1_susi`. Ignorado nos outros modos. */
const policy = import.meta.env.VITE_B2C_POLICY ?? '';

const apiScope = import.meta.env.VITE_API_SCOPE ?? '';

function buildAuthority(): string {
  switch (idp) {
    case 'b2c':
      // b2clogin.com, não login.microsoftonline.com: o domínio antigo tem
      // comportamento de cookie diferente e a Microsoft pede o novo.
      return `https://${tenantName}.b2clogin.com/${tenantName}.onmicrosoft.com/${policy}`;
    case 'external':
      return `https://${tenantName}.ciamlogin.com/${tenantName}.onmicrosoft.com/`;
    case 'entra':
      return `https://login.microsoftonline.com/${tenantId}`;
  }
}

/**
 * O MSAL recusa authority fora de login.microsoftonline.com se ela não estiver
 * declarada aqui. Esquecer disto dá `endpoints_resolution_error`, que não
 * sugere em nada o que está faltando.
 */
function buildKnownAuthorities(): string[] {
  switch (idp) {
    case 'b2c':
      return [`${tenantName}.b2clogin.com`];
    case 'external':
      return [`${tenantName}.ciamlogin.com`];
    case 'entra':
      return [];
  }
}

/**
 * Escopos pedidos.
 *
 * Sem `VITE_API_SCOPE` o fluxo cai em modo identidade em **qualquer** IdP: pede
 * só `openid` e `profile`, e o que atravessa a ponte é o ID token. É o jeito de
 * provar o caminho inteiro sem ter que registrar uma aplicação de API antes.
 *
 * Para pedir token do Azure DevOps num tenant de workforce, o escopo é
 * explícito — `499b84ac-1321-427f-aa17-267ca6975798/.default`. Ele já foi o
 * default deste modo, e era uma armadilha: quem só queria provar identidade num
 * tenant workforce recebia um pedido de escopo do ADO que o tenant não tinha
 * permissão de conceder, e o erro não dizia nada sobre escopo.
 */
function buildScopes(): string[] {
  if (apiScope) return [apiScope];
  return ['openid', 'profile'];
}

export const config = {
  idp,
  tenantId,
  clientId,
  tenantName,
  policy,
  redirectUri: import.meta.env.VITE_REDIRECT_URI ?? '',
  adoOrganization: import.meta.env.VITE_ADO_ORG ?? '',
  authority: buildAuthority(),
  knownAuthorities: buildKnownAuthorities(),
  scopes: buildScopes(),
  /** true quando só a identidade atravessa, sem access token de recurso. */
  identityOnly: !apiScope,
} as const;

export function missingConfig(): string[] {
  const missing: string[] = [];
  if (!config.clientId) missing.push('VITE_CLIENT_ID');
  if (!config.redirectUri) missing.push('VITE_REDIRECT_URI');

  if (idp === 'entra' && !config.tenantId) missing.push('VITE_TENANT_ID');
  if (idp !== 'entra' && !config.tenantName) missing.push('VITE_TENANT_NAME');
  if (idp === 'b2c' && !config.policy) missing.push('VITE_B2C_POLICY');

  return missing;
}
