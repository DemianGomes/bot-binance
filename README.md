# Bot de trading Binance (BRL) — BTC e outras moedas

Bot simples em **PowerShell** (Windows 10/11, não precisa instalar nada) que opera na Binance em pares
cotados em reais (BTC/BRL, SOL/BRL, NEAR/BRL, PEPE/BRL, SUI/BRL…).

**Regra:** compra quando a moeda cai **2,5%** abaixo do topo das últimas 4 horas e deixa registrada na
Binance a venda com **+2,5%** de lucro (vende mesmo com o PC desligado). Sem stop loss: se o preço cair,
espera voltar.

> ⚠️ **Dinheiro real envolve risco.** O bot pode ficar meses "preso" numa compra se a moeda cair, e o
> passado (backtest/simulação) não garante o futuro. Isto não é recomendação de investimento.
> Comece pela **simulação** (dinheiro de mentira, preços reais).

## Começar (simulação, sem dinheiro e sem chave)

1. Baixe esta pasta para o seu PC (ex.: `C:\bot-binance`). Se baixou como `.zip`: antes de extrair,
   botão direito no `.zip` → Propriedades → marque **Desbloquear** → OK (senão o Windows pode bloquear os
   scripts por virem da internet).
2. Clique com o botão direito em `criar-atalho.ps1` → **Executar com o PowerShell**. Isso cria na Área de
   Trabalho os atalhos **Bot Simulação** (robô amarelo) e **Bot** (robô verde, modo real).
   Se o Windows bloquear: abra o PowerShell na pasta e rode
   `powershell -ExecutionPolicy Bypass -File criar-atalho.ps1`.
3. Abra **Bot Simulação**. Ele roda as moedas de `simulacao\moedas.json` com dinheiro de mentira; clique no
   robô amarelo perto do relógio para ver o painel.

## Modo real (você decide)

1. Crie uma chave de API na Binance (Perfil → Gerenciamento de API) marcando **só** "Ativar leitura" e
   "Ativar negociação Spot". **Nunca** marque "Ativar saques". Se possível, restrinja ao seu IP.
2. Guarde a chave nas variáveis de ambiente do Windows (PowerShell):
   ```
   setx BINANCE_API_KEY "sua_api_key"
   setx BINANCE_API_SECRET "seu_secret"
   ```
   A chave **não** fica em nenhum arquivo do bot. Não a cole em chats nem a envie para ninguém.
3. Deposite reais na carteira **Spot**.
4. No `config.json`, troque `"modo": "simulacao"` por `"modo": "real"` (ele é o config do BTC e o modelo
   das outras moedas). Confira `real\moedas.json`: o BTC fica com uma reserva fixa (`reservado_brl`, R$ 20) e as outras moedas
   dividem o resto dos reais livres conforme o `peso`. Cada moeda precisa de uns **R$ 10 + 2 lotes**
   (ex.: NEAR ~R$ 16, SOL/SUI ~R$ 11,50, PEPE ~R$ 11), senão trava no mínimo de R$ 10 da Binance.
5. Abra o atalho **Bot**, confirme o modo real e, quando ele perguntar (uns 30 s depois), confira e
   confirme a divisão dos reais entre as moedas.

O manual completo está em **[LEIA-ME.md](LEIA-ME.md)**. Detalhes técnicos (para quem for mexer no código,
inclusive com ajuda de IA) em **[CLAUDE.md](CLAUDE.md)**; regras para agentes de IA (Codex etc.) em
**[AGENTS.md](AGENTS.md)**.

## Arquivos principais

| Arquivo | Para quê |
|---|---|
| `carteira.ps1` | bandeja com várias moedas e painel (atalhos **Bot** e **Bot Simulação**) |
| `bot.ps1` | o bot de uma moeda (preços, saldo, ordens, logs) |
| `strategy.cs` | a regra de compra/venda — a mesma do backtest |
| `backtest.ps1` / `backtest-todos.ps1` | testa a regra em 180 dias de preços históricos |
| `config.json` | parâmetros da estratégia (vem em `"modo": "simulacao"`) |
| `real\moedas.json`, `simulacao\moedas.json` | quais moedas e quanto em cada uma |

Os arquivos que o bot cria ao rodar (`estado-*`, `log-*`, `operacoes-*`, `painel-*`, `data\`) são seus e
estão no `.gitignore`: não suba esses arquivos para o GitHub.
