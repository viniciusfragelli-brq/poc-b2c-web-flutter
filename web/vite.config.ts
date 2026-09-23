import { resolve } from 'node:path';
import { defineConfig } from 'vite';

export default defineConfig({
  // A configuração fica num .env único na raiz do projeto, não dentro de web/.
  // As mesmas credenciais alimentam a SPA (variáveis VITE_*) e o app Flutter
  // (variáveis APP_*, lidas por scripts/rodar-app.sh). Um lugar só para
  // preencher, um lugar só para o .gitignore proteger.
  envDir: resolve(__dirname, '..'),
  server: {
    host: true,
    port: 5173,
    // O túnel (ngrok, Dev Tunnels, cloudflared) chega com um Host que o Vite
    // não conhece. Sem isto ele responde 403 "Blocked request" e a WebView
    // mostra uma tela branca sem explicação.
    allowedHosts: true,
  },
  preview: {
    port: 5173,
    allowedHosts: true,
  },
});
