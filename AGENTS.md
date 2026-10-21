# Instruções para agentes de IA (Codex e outros)

Bot de trading para a Binance (pares em reais: BTC/BRL, SOL/BRL…) em **Windows PowerShell 5.1**, que pode
operar **dinheiro real**. O usuário fala português: responda em português.

Leia o **[CLAUDE.md](CLAUDE.md)** antes de mexer no código: ele tem a arquitetura, a configuração, os
cuidados técnicos e os problemas já resolvidos (o nome é do Claude Code, mas vale para qualquer agente).
Para o usuário: resumo no [README.md](README.md), manual completo no [LEIA-ME.md](LEIA-ME.md).

## Regras de segurança (obrigatórias)

- **Nunca rode o bot em modo real**, nem crie/cancele ordens, nem mexa na conta Binance. Quem liga o modo
  real é o usuário (atalho "Bot" → confirmar). Você pode editar código e config; o efeito só vale quando o
  usuário reiniciar o bot.
- **Nunca peça, leia, grave ou exiba a chave de API** (variáveis de ambiente `BINANCE_API_KEY` e
  `BINANCE_API_SECRET`). Nunca coloque chave em arquivo. A chave deve ter só leitura + negociação Spot,
  **nunca saque**.
- **Não dê recomendação de investimento** (quanto colocar, qual moeda comprar). Mostre dados, backtests e
  consequências; a decisão é do usuário.
- Não apague nem edite à mão os arquivos que o bot cria (`estado-*`, `operacoes-*`, `log-*`): são o
  histórico do usuário. Não encerre processos do bot real; ao testar, encerre só os processos que você abriu.

## Ambiente

- Windows 10/11, `powershell.exe` 5.1, sem instalar nada. Rode sempre com
  `powershell -NoProfile -ExecutionPolicy Bypass -File <script>.ps1`.
- A bandeja e o painel (`carteira.ps1`, `bandeja.ps1`) usam WinForms: **só Windows**. Fora do Windows
  (ex.: sandbox Linux na nuvem) dá para ler/editar o código e checar sintaxe, mas não rodar o painel.
- O bot precisa de acesso à internet para `https://api.binance.com` (preços públicos, sem chave, na simulação).

## Rodar e testar sem dinheiro

1. Se a pasta veio de um `.zip`: `Get-ChildItem -Recurse | Unblock-File` (o Windows bloqueia scripts baixados).
2. Atalhos na Área de Trabalho: `powershell -ExecutionPolicy Bypass -File criar-atalho.ps1`
   ("Bot Simulação" = simulação; "Bot" = modo real).
3. **Simulação com painel:** `powershell -ExecutionPolicy Bypass -File simulacao.ps1 -AbrirPainel`.
   Moedas e valores em `simulacao\moedas.json`. Dinheiro de mentira, preços reais, nenhuma ordem é enviada
   (cada bot roda com `-SoSimulacao`, que recusa um config em modo real). Para parar: robô amarelo na
   bandeja → Sair.
4. Um bot só, com terminal: `powershell -ExecutionPolicy Bypass -File bot.ps1` (usa `config.json`, que vem
   em `"modo": "simulacao"`; não troque para real).
5. Backtest (180 dias de candles de 1 min, baixados para `data\`, demora alguns minutos):
   `powershell -ExecutionPolicy Bypass -File backtest.ps1 -Par BTCBRL`.
6. Checagem de sintaxe sem executar (na pasta do bot):
   `$e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path 'bot.ps1').Path, [ref]$null, [ref]$e); $e`
   (sem saída = sem erros).
7. Para testar mudanças, use uma **cópia** da pasta e troque os nomes de mutex `Global\BotBTC-...` na cópia
   (senão ela conflita com o bot do usuário). Detalhes em "Como testar" no CLAUDE.md.

## Armadilhas que já causaram bugs (mais no CLAUDE.md)

- Variáveis do PowerShell **não diferenciam maiúsculas**: `$base` sobrescreve `$Base` (a URL da API).
- Números: `[decimal]`/`[double]::Parse(..., InvariantCulture)`; o Windows pode estar em pt-BR (vírgula).
- `.ps1` com acentos (`carteira.ps1`, `bandeja.ps1`) precisam de **UTF-8 com BOM**; `bot.ps1` é só ASCII.
- Gravar arquivos com `Append-Safe`/`Write-Safe` (nunca `Add-Content` direto: travou e derrubou o bot).
- A regra de compra/venda fica **só** em `strategy.cs` (a mesma no bot e no backtest).
- Lotes da Binance: cada moeda precisa de ~R$ 10 + 2 lotes, senão trava no mínimo de R$ 10.

## Documente

Toda mudança de código, config ou decisão do usuário vai para o `CLAUDE.md` (atualize a seção afetada e
acrescente uma linha no histórico), como o próprio arquivo pede.
