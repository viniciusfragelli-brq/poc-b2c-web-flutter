---
name: poc-login-credenciais
description: Configura as credenciais da POC de login Microsoft em WebView (App Registration, redirect URI, escopo) e escreve o arquivo .env. Use quando alguém clonar este repositório e precisar rodar a POC pela primeira vez, quando o app mostrar "Configuração incompleta", quando a audience do token for recusada, ou quando pedirem "configura as chaves", "cadê o .env", "como rodo essa POC". Não use para alterar o código da ponte nem para diagnosticar erro de rede.
---

# Configurar as credenciais da POC de login

Esta POC não tem segredo nenhum no código. Toda a configuração vive num único
arquivo `.env` na raiz, que não é versionado. Esta skill leva a pessoa de "acabei
de clonar" até "rodando no celular".

## Antes de qualquer coisa

Leia `.env.example` na raiz. Ele é a fonte da verdade sobre quais variáveis
existem e o que cada uma significa. Esta skill diz **como obter** os valores;
o `.env.example` diz **onde eles vão**.

Verifique o que já existe:

```bash
ls -la .env 2>/dev/null && grep -c "<PREENCHER>" .env
```

- `.env` não existe → siga da Fase 1.
- `.env` existe sem `<PREENCHER>` → já está configurado. Vá para a Fase 4 e
  valide, em vez de refazer.
- `.env` existe com `<PREENCHER>` → pergunte à pessoa só os valores que faltam.

## Fase 1 — descobrir o que a pessoa já tem

Pergunte, numa única rodada:

1. **Já existe um App Registration** no Entra ID / B2C para esta POC, ou precisa
   criar?
2. **Qual IdP**: tenant de workforce (`entra`), Azure AD B2C (`b2c`) ou
   Microsoft Entra External ID (`external`)?
3. **Como o celular vai alcançar a máquina**: `adb reverse` com localhost
   (Android, mais simples) ou um túnel HTTPS (iPhone, ou para abrir no navegador
   do celular)?

Não avance sem essas três respostas — elas mudam o que pedir a seguir.

## Fase 2 — criar o App Registration, se não houver

Entregue estes passos e **espere a confirmação**. Não invente valores.

1. Portal → **App registrations → New registration**.
2. *Supported account types*: **Accounts in this organizational directory only**.
3. *Redirect URI*: plataforma **Single-page application (SPA)** — nunca "Web".
   Valor: a URL onde a SPA será servida, **com barra final**.
   - com `adb reverse`: `http://localhost:5173/`
   - com túnel: `https://<seu-dominio>/`
   - vale cadastrar as duas, evita voltar ao portal depois.
4. **Não** crie client secret. O fluxo é authorization code + PKCE.
5. Anote da tela **Visão geral**: *Application (client) ID* e
   *Directory (tenant) ID*.

Só para B2C: crie também um **user flow** do tipo *Sign up and sign in* e anote
o nome (ex. `B2C_1_susi`), e o subdomínio do tenant (`contoso`, sem
`.onmicrosoft.com`).

> **A plataforma tem que ser SPA.** Registrada como "Web", o endpoint de token
> não devolve cabeçalho CORS, a troca do `code` falha no navegador, e o erro do
> MSAL não menciona a causa. Se a pessoa já tiver criado como Web, peça para
> remover de lá e recadastrar em SPA — a mesma URI não pode existir nas duas.

## Fase 3 — escrever o .env

Peça os valores e escreva o arquivo. **Nunca peça senha nem client secret**:
client id e tenant id são identificadores públicos, e esta POC não usa segredo.

```bash
cp .env.example .env
```

Preencha:

| Variável | De onde vem |
| --- | --- |
| `VITE_IDP` | resposta da Fase 1 |
| `VITE_CLIENT_ID` | Application (client) ID |
| `VITE_TENANT_ID` | Directory (tenant) ID — só para `entra` |
| `VITE_TENANT_NAME` | subdomínio do tenant — só `b2c` / `external` |
| `VITE_B2C_POLICY` | nome do user flow — só `b2c` |
| `VITE_REDIRECT_URI` | o mesmo cadastrado no portal, barra final inclusa |
| `APP_SPA_BASE_URL` | mesma URL do redirect URI |
| `APP_TENANT_ID` | igual ao `VITE_TENANT_ID` |

### A audience é a que mais dá errado

`APP_EXPECTED_AUDIENCE` é o valor que o lado nativo exige no claim `aud`.
Depende do que está sendo pedido, e não é óbvio:

| Situação | Valor |
| --- | --- |
| `VITE_API_SCOPE` vazio, IdP `entra` | `00000003-0000-0000-c000-000000000000` — a Microsoft devolve um access token do Graph mesmo pedindo só `openid`/`profile` |
| `VITE_API_SCOPE` vazio, IdP `b2c`/`external` | o próprio `VITE_CLIENT_ID` — o ID token tem como audience quem o pediu |
| Azure DevOps | `499b84ac-1321-427f-aa17-267ca6975798` |
| API própria | o client id da aplicação de API |

Não souber de antemão: deixe rodar, e o app mostra na tela a audience que
chegou e o valor exato a usar. Aí corrija o `.env`.

`APP_PROBE_URL` é a API que o lado nativo chama para provar que o token serve.
Com Graph, use `https://graph.microsoft.com/v1.0/me`. Vazio desliga a sonda.

## Fase 4 — validar

```bash
# a SPA
cd web && npm install && npm run dev
```

Abra `http://localhost:5173/dev-host.html` no navegador. Essa página finge ser o
app: instala um `window.FlutterAuthBridge` falso e mostra tudo que a SPA mandaria
para o nativo. Faça o login ali **antes** de mexer no celular — é muito mais
rápido de iterar.

- "Configuração incompleta" → falta variável no `.env`; a tela diz qual.
- `endpoints_resolution_error` → authority errada: confira `VITE_TENANT_NAME` e
  `VITE_B2C_POLICY`.
- `AADSTS50011` → o redirect URI do `.env` não bate com o do portal. Compare
  caractere a caractere, barra final inclusa.
- `AADSTS50020` → a conta usada não existe nesse diretório. Crie um usuário
  nativo no tenant, ou convide a conta como externa.
- Chegou "Token entregue ao lado nativo" → funcionou.

Depois, no celular Android:

```bash
./scripts/rodar-app.sh
```

O script lê o `.env`, cria o `adb reverse` e monta os `--dart-define`. Não passe
os defines à mão: foi assim que um teste rodou com os defaults errados e o
sintoma (audience recusada) não apontava para a causa.

## Onde cada valor é consumido

Para quem for mexer no código:

| Arquivo | Papel |
| --- | --- |
| `.env` | único lugar com valores reais. Não versionado |
| `.env.example` | documenta todas as variáveis. Versionado |
| `web/vite.config.ts` | `envDir` faz o Vite ler o `.env` da raiz |
| `web/src/config.ts` | lê `import.meta.env.VITE_*`, monta authority e escopos |
| `app/lib/config.dart` | lê os `--dart-define`; nenhum valor fixo no código |
| `scripts/rodar-app.sh` | converte `APP_*` do `.env` em `--dart-define` |

Não há credencial no código-fonte. Se aparecer uma, é regressão — tire de lá e
mande para o `.env`.

## Limites

Esta skill não altera o código da ponte, não diagnostica erro de rede
(`ERR_CONNECTION_REFUSED` costuma ser `adb reverse` ausente) e não cria tenant.
Para entender o mecanismo, leia o `README.md`.
