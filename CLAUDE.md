# Bot BTC/BRL — documentação do projeto para agentes de IA

Bot de trading simples para a Binance, em PowerShell 5.1 (sem instalar nada), que opera **BTC/BRL**
com o dinheiro real do usuário. O usuário fala **português** — responda sempre em português.

## REGRA: documente toda mudança e decisão

Este arquivo é a memória do projeto. **Toda alteração de código, de configuração ou decisão do
usuário deve ser registrada aqui na mesma tarefa**, antes de encerrar:

1. Atualize a seção afetada (arquitetura, configuração, cuidados técnicos…) para refletir o estado atual.
2. Acrescente uma linha datada em **Histórico de decisões e mudanças** (o quê, por quê, quem decidiu).
3. Se a mudança afeta o uso pelo usuário, atualize também o `LEIA-ME.md`.
4. Bugs encontrados vão para **Problemas conhecidos / resolvidos**, com a causa — para não voltarem.

Uma mudança sem registro aqui é considerada incompleta.

## Limites do agente (segurança — não negociável)

- **O agente nunca executa operações financeiras**: não roda o bot em modo real, não cria/cancela
  ordens, não deposita, não mexe na conta Binance pelo navegador. Quem liga o modo real é o usuário
  (atalho → confirmar "Sim"). O agente pode editar código/config; o efeito só acontece quando o
  usuário reinicia o bot.
- **Nunca peça, leia, grave ou exiba a chave de API.** Ela fica nas variáveis de ambiente do usuário
  (`BINANCE_API_KEY`, `BINANCE_API_SECRET`). A chave tem só leitura + negociação Spot, **sem saque**.
- **Não dê recomendação de investimento** (quanto depositar, se compra mais etc.). Mostre dados,
  backtests e consequências; a decisão é do usuário.
- **Nunca mate o processo do bot real** (`binance-bot\bot.ps1`) nem a bandeja real ao limpar processos.
  Ao final de cada resposta, encerre apenas processos de teste que o próprio agente iniciou.
- Editar `operacoes-real.csv` (histórico real) foi bloqueado pela permissão — não tente contornar.

## Como testar sem tocar no bot real

- Faça uma cópia em uma pasta de rascunho com `config.json` em `"modo": "simulacao"`
  (simulação usa preços reais da API pública e não envia ordens; arquivos `*-simulacao.*`).
- Na cópia da bandeja, troque o mutex `Global\BotBTC-Bandeja` por outro nome (ex.: `...-TESTE`),
  senão ela conflita com a bandeja real do usuário.
- `bandeja.ps1 -AbrirPainel` abre o painel na hora (útil para tirar print via `PrintWindow`).
- **Carteira em simulação**: copie `bot.ps1`, `strategy.cs`, `carteira.ps1`, `simulacao.ps1`, `robo.ico`,
  `config.json` (em simulação) para o rascunho e troque `Global\BotBTC-Simulacao-Bandeja` e
  `Global\BotBTC-Carteira-Bandeja` por `...-TESTE` na cópia do `carteira.ps1`. `simulacao.ps1 -AbrirPainel`.
  Para ver compra/venda em minutos, pré-crie `simulacao\<PAR>\config.json` da cópia com `queda`/`lucro`
  0,05% (o script não sobrescreve config existente). Aporte manual: grave o valor em
  `simulacao\<PAR>\aporte-simulacao.txt` (tmp + Move). A bandeja de teste herda o console (normal).
- **Carteira em modo real — só com BOT FALSO**: na cópia, troque o `bot.ps1` por um script que finge os
  `painel-real.json`/logs/aportes sem chamar a Binance (feito em 19/10 em `scratchpad\teste-real\bot.ps1`),
  rode com `$env:BINANCE_API_KEY=''; $env:BINANCE_API_SECRET=''` e, na cópia do `carteira.ps1`, troque
  `Ask`/`MessageBox`/`ShowBalloonTip` por uma classe que grava num arquivo (responde "Sim") e os nomes
  de mutex do bot antigo (`Global\BotBTC-Bandeja`, `Global\BotBTC-real`) por nomes inexistentes — senão
  a trava (correta) recusa abrir porque a bandeja real do usuário está aberta.
- **Funções do modo real do `bot.ps1`** (saldo próprio, taxas, aportes): extraia as funções pela AST
  (`FunctionDefinitionAst`) e substitua `Invoke-Signed`/`Get-Public`/`Log`/`Save-State` por versões
  falsas (feito em 19/10: `scratchpad\teste-funcoes-real.ps1`, 26 verificações). Nunca rode o real.
- Ao encerrar processos de teste, filtre pela linha de comando (`-match 'scratchpad\\teste-sim\\'`) e
  confira antes de `Stop-Process`. (Um `-like '*\scratchpad\...*'` no mesmo comando que `Remove-Item`
  fez a ferramenta bloquear o comando inteiro — use `[IO.File]::Delete`.)
- Checagem de sintaxe: `[System.Management.Automation.Language.Parser]::ParseFile(...)`.
- O caminho de ordens reais (OCO/LIMIT, histórico de depósitos) só é verificável na conta do usuário:
  diga a ele qual linha conferir no log depois de reiniciar.

## Arquivos

| Arquivo | Papel |
|---|---|
| `bot.ps1` | Loop principal: preço (bookTicker a cada 2 s), saldo, ordens, logs, estado, notificações, `painel-<modo>.json`. Params `-Config`, `-SemConfirmacao` (usado pela bandeja) e `-SoSimulacao` (recusa iniciar se o config não for simulação). Arquivos ficam na pasta do config. Com `carteira_propria` (carteira.ps1): saldo próprio, aportes, mutex por par. |
| `carteira.ps1` | **Bandeja com várias moedas, um painel só.** `-Modo simulacao` (robô amarelo, atalho "Bot Simulação") ou `-Modo real` (robô verde-água, atalho **"Bot"**). Um `bot.ps1` escondido por moeda, reinício automático, painel Depositado / Valor total / Lucro projetado / Lucro real + tabela por moeda, distribuição dos reais livres (real). |
| `simulacao.ps1` | Só chama `carteira.ps1 -Modo simulacao` (mantém o atalho antigo funcionando). |
| `simulacao\moedas.json` | `moedas`: `{ "par", "valor_brl" }` (ou só `"PAR"`, que usa `valor_por_moeda_brl`). Hoje BTC 20 · SOL 11,50 · NEAR 16 · PEPE 11 · SUI 11,50 = R$ 70. |
| `real\moedas.json` | Carteira real: `{ "par": "BTCBRL", "reservado_brl": 20, "pasta": "." }` (usa a pasta principal: `config.json`, `estado-real.json`, `operacoes-real.csv` de sempre) + `{ "par", "peso" }` (SOL 11,5 · NEAR 16 · PEPE 11 · SUI 11,5): fatias dos reais livres. |
| `simulacao\<PAR>\`, `real\<PAR>\` | `config.json` (criado na 1ª vez a partir do `config.json` principal, com `modo`, `par`, `carteira_propria: true`; no real `deposito_inicial_brl` 0) + `estado/log/operacoes/painel/erro-bot-<modo>.*` + `aporte-<modo>.txt` (temporário). |
| `strategy.cs` | Classe `DipStrategy` — **única** regra de compra/venda, usada pelo bot e pelo backtest (C# 5, compilado com `Add-Type`). |
| `backtest.ps1` / `backtest.cs` | Baixa candles 1 min (cache em `data\`, só últimos 180 dias), grade de ~3000 combinações, treino 2/3 × teste 1/3. Params `-Par`, `-Dias`, `-MinOpsDia`. |
| `backtest-todos.ps1` | Roda o backtest em vários pares BRL → `resumo-pares*.csv`. |
| `previsao.ps1` | Simula o bot começando em cada dia do histórico → o que esperar em 1/3/7/30/60 dias. |
| `criar-atalho.ps1` | Gera `robo.ico` (verde-água) + atalho **"Bot"** → `carteira.ps1 -Modo real`, e `robo-simulacao.ico` (amarelo) + atalho "Bot Simulação" → `simulacao.ps1`. `-SoSimulacao` cria só o da simulação. (O atalho real se chamava "Bot BTC" → `bandeja.ps1`; o usuário o renomeou para "Bot"; em 19/10 passou a abrir a carteira.) |
| `bandeja.ps1` / `iniciar.bat` | Bot antigo, **só BTC** (sem atalho desde 19/10). Não roda junto com a carteira real (travas nos dois lados). |
| `iniciar.bat` | Abre o bot com terminal (pede "SIM"). Não use junto com a bandeja. |
| `config.json` | Parâmetros (ver abaixo). |
| `estado-<modo>.json` | Estado persistente: preço de entrada, id da ordem na Binance (`oco_id` + `protecao_tipo`), pausa, `ultimo_aviso`. **Necessário** para retomar após reinício. |
| `painel-<modo>.json` | Resumo gravado a cada 5 s para o painel (BRL, BTC, preço, patrimônio, investido, situação). |
| `log-<modo>.txt` | Log; rotaciona em 1 MB → `log-<modo>.anterior.txt`. Linhas `NOTIFICAR \| título \| texto` viram notificações; linhas `BANDEJA:` são escritas pela bandeja. |
| `erro-bot-<modo>.txt` | stderr do processo do bot (erro fatal com nº da linha). |
| `operacoes-<modo>.csv` | Uma linha por compra/venda: `data,tipo,preco,quantidade,valor_brl,patrimonio_brl,taxa_brl,taxa_qtd` (desde 19/10; históricos antigos têm só 6 colunas no cabeçalho). `valor_brl` da venda = recebido **já sem a taxa**. `taxa_brl` = taxa em reais (moeda/BNB convertidos); `taxa_qtd` = taxa descontada da moeda comprada. |
| `LEIA-ME.md` | Manual do usuário. |
| `README.md` | Página de entrada para quem recebe o bot (GitHub): o que é, riscos, simulação, modo real. |
| `AGENTS.md` | Instruções para outros agentes de IA (o Codex lê `AGENTS.md` sozinho): regras de segurança, como rodar/testar, armadilhas; aponta para este `CLAUDE.md`. Mantenha as regras de segurança iguais às daqui. |
| `exportar.ps1` | Recria `compartilhar\` + `bot-binance-compartilhar.zip` só com código e docs (lista fixa de arquivos): `config.json` em simulação e sem `carteira_propria`, `CLAUDE.md` sem o histórico de decisões e com números de ordens trocados por `<id da ordem>`, `.gitignore` para os arquivos que o bot cria. **Nunca** compartilhe a pasta principal (tem estado, logs, operações e saldos do usuário). |

## Arquitetura e fluxo

1. **Bandeja** (`bandeja.ps1`, mutex único) pergunta "Iniciar em modo REAL?" e inicia `bot.ps1 -SemConfirmacao`
   escondido, com stderr em `erro-bot-<modo>.txt`. A cada 2 s lê linhas novas do log (notificações),
   atualiza o painel se visível e verifica se o bot morreu.
2. **Bot** pré-carrega 4 h de candles, depois a cada 2 s. Mutex: bot único real `Global\BotBTC-real`;
   carteira real `Global\BotBTC-real-<PAR>` (e recusa se `Global\BotBTC-real` existir; o bot único recusa
   se `Global\BotBTC-Carteira-Bandeja` ou `...-real-<PAR>` existir); simulação `Global\BotBTC-simulacao-<md5 da pasta>`.
   Volta do loop:
   lê preço → saldo (Binance a cada 60 s; inclui BTC travado em ordens) → confere a ordem de proteção
   a cada 15 s → avisos de patamar → `DipStrategy.OnTick` → compra/venda → painel/status.
3. **Compra** a mercado com `quoteOrderQty` = todo o BRL; registra o valor **realmente gasto**
   (`cummulativeQuoteQty`) e a taxa.
4. **Proteção na Binance** logo após comprar (funciona com o PC desligado):
   - com stop: OCO (`/api/v3/orderList/oco`: LIMIT_MAKER no lucro + STOP_LOSS_LIMIT com limite 0,5% abaixo);
   - **sem stop (atual)**: ordem LIMIT GTC só no preço de lucro.
   Ao iniciar, se o tipo da ordem existente não bate com o config, o bot cancela e recria.
5. **Venda**: detectada consultando a ordem (a cada 15 s, ou a cada 3 s se a moeda saiu da conta); o bot
   registra, aplica pausa se foi stop, volta a vigiar. Enquanto houver `oco_id`, a sincronização com o saldo
   não apaga o preço de entrada (quem resolve é o `Check-Oco`).
6. **Parada limpa**: a bandeja cria `parar-<modo>.flag`; o bot termina a volta e sai.
7. **Queda inesperada**: a bandeja grava `BANDEJA: ... (codigo X). Erro: ...` no log, notifica e reinicia
   em 30 s (máx. 5 reinícios/hora). Saída com código 0 (ex.: saldo insuficiente) não reinicia.
8. **"Comprado"** (`In-Position`): cripto × **preço de entrada** ≥ `minNotional` quando há compra aberta
   (senão × preço atual, para sobras de lote). Assim uma queda abaixo de R$ 10 não faz o bot esquecer a compra.
9. **Lote mínimo antes de comprar**: com sinal de compra, se `floor(BRL / ask, stepSize) × ask < minNotional`,
   o bot não manda a ordem (real ou simulada), registra `Sinal de compra, mas ...` no máximo 1×/hora e põe
   `| lote minimo: ...` na situação. Compra sozinho se o preço passar a permitir um lote válido.

10. **Taxas** (desde 19/10): compra e venda registram a taxa no log (`taxa R$ 0.0125 (0.00000003 BTC)`)
    e no CSV. Real: das `fills` da ordem a mercado ou de `/api/v3/myTrades?orderId=` (venda LIMIT que
    executou na Binance); se falhar, estima pela taxa maker da conta. BNB é convertido pelo `BNBBRL`.
    A taxa da venda sai dos reais recebidos (o bot antes registrava o valor bruto).

### Carteira própria (`carteira_propria: true`, usada por todos os bots da `carteira.ps1`)

- Cada bot só usa os reais que são dele. Real: `estado-real.json` → `brl_proprio`; `Get-Balances` devolve
  `brl` = menor entre `brl_proprio` e os reais livres da conta, e `brlConta` = reais livres da conta.
  Simulação: o próprio `estado.brl`. Compra: −gasto (−taxa em BRL, se houver); venda: +recebido sem taxa.
- 1ª execução real (sem `brl_proprio`): `deposito_inicial_brl − cripto × preço de entrada ÷ (1 − taker)`,
  limitado aos reais livres. BTC em 19/10: 20 − 0,00003996 × 433.131 ÷ 0,999 = **R$ 2,67** (os R$ 20 dele).
  Moedas novas: depósito 0 → R$ 0 até receber aporte.
- **Aporte**: `aporte-<modo>.txt` com o valor (negativo = retirada, recusada se faltar saldo); o bot soma em
  `brl_proprio`/`brl` e em `investido_brl`, apaga o arquivo e loga `APORTE R$ ...`.
- Sem reais para uma ordem e sem moeda: não encerra (o bot único encerra), mostra `aguardando reais: ...`.
- Sem avisos de patamar (a carteira avisa as vendas). `painel-<modo>.json` ganha `brl_proprio`, `brl_conta`;
  `investido` = `investido_brl`.

### Carteira real (`carteira.ps1 -Modo real`, atalho "Bot")

- Ao abrir: recusa se `Global\BotBTC-Bandeja` (bandeja antiga) ou `Global\BotBTC-real` (bot antigo)
  existirem; pede confirmação do modo real; acrescenta `carteira_propria: true` aos configs que não têm
  (inclusive o `config.json` principal, do BTC — feito só quando o usuário abre a carteira real).
- BTC = pasta principal (mesmo estado, ordem LIMIT <id da ordem> e histórico de antes). SOL/NEAR/PEPE/SUI =
  `real\<PAR>\`, configs em real com depósito 0.
- **Distribuição**: reais sem dono = `brl_conta` (painel mais recente) − Σ `brl_proprio` (todos os painéis
  gravados depois do início). ~30 s após abrir, se ≥ R$ 10 e estável em 2 leituras com 10 s, pergunta
  "Distribuir assim? SOL R$ 11,50, NEAR R$ 16,00…" (proporcional ao `peso`; BTC fica fora) → aportes.
  Menu "Distribuir reais livres…" para depósitos novos. Linha TOTAL mostra os reais sem dono.
- Notificações (balão): cada `VENDA` (com recebido e taxa) e `NOTIFICAR` exceto `Saldo:`; queda de bot.
  Linhas da bandeja no log das moedas: `CARTEIRA: ...` (na simulação, `SIMULACAO: ...`).
- Vendas continuam funcionando com o PC desligado (ordem LIMIT na Binance após cada compra, em todas as
  moedas); compras e a detecção das vendas só com o PC ligado.

### Carteira em simulação (`carteira.ps1 -Modo simulacao`, atalho "Bot Simulação")

- Mutex da bandeja `Global\BotBTC-Simulacao-Bandeja` (independente da bandeja real). Sem confirmação
  (não há dinheiro real). Robô amarelo na bandeja e no atalho, para não confundir com o real.
- Na 1ª vez cria `simulacao\<PAR>\config.json` copiando a estratégia do `config.json` principal, com
  `modo=simulacao`, `par`, `deposito_inicial_brl=valor_brl`, `meta_brl=0`, `carteira_propria`. Antes de
  iniciar, confere `modo`/`par`; e cada bot roda com **`-SoSimulacao`** (dupla trava contra modo real).
- Simulação do `bot.ps1`: compra em lotes inteiros de `stepSize`, taxa cobrada na moeda, recusa compra
  abaixo de `minNotional` (como a Binance), vende a mercado no bid quando bate o alvo.
- **Valor por moeda ≥ R$ 10 + 2 lotes** (`stepSize` × preço): um lote fica parado porque a taxa da compra
  é cobrada na moeda (0,5 NEAR vira 0,4995 → só 0,4 vende), outro se perde no arredondamento da compra.
  Em 15/10: NEAR (lote 0,1 ≈ R$ 2,68) precisa ~R$ 15,35; SOL/SUI ~R$ 11,05; PEPE ~R$ 10; BTC ~R$ 18,40.
- **Mudar o valor de uma moeda** (`moedas.json`): ao abrir, `Adjust-Coin` soma/subtrai a diferença em
  `estado.brl` (depósito/saque simulado) e grava o novo `deposito_inicial_brl`; resultado acumulado mantido;
  linha `SIMULACAO: valor mudou...` no log. Só se o bot daquela pasta não estiver rodando (`Bot-Mutex-Held`,
  mesmo nome de mutex do `bot.ps1`) e se houver reais suficientes; senão adia e mostra o motivo.
- Painel (pedido do usuário, 15/10): cartões **Depositado**, **Valor total** (reais + moedas a preço de
  agora; sub com ± sobre o depositado), **Lucro projetado**, **Lucro real**. `Coin-Pnl` calcula pelo
  **custo médio** a partir do `operacoes-<modo>.csv`: compra → custo += **quantidade × preço** (não
  `valor_brl`: a 1ª compra real de BTC ficou com R$ 20,00 no CSV), qtd += comprada − `taxa_qtd` (ou × (1 − taxa)
  em linhas antigas); venda → real += recebido − custo médio × vendido. Projetado = cripto atual × preço −
  custo restante (inclui sobras de lote; sem compra no CSV usa `preco_entrada` do estado).
  **Real + projetado = valor total − depositado** — desde 21/10 forçado: o projetado exibido é
  `total − depositado − real` (o custo médio dá o mesmo a menos de centavos de arredondamento do CSV).
  Depositado = `investido` do painel do bot. Cartão Lucro real mostra também "taxas pagas" (soma de
  `taxa_brl`; linhas antigas estimadas pela taxa do config). Tabela por moeda com as mesmas colunas +
  vendas + situação (distância % até compra/venda; "vende em" = preço exato da ordem na Binance;
  "Quer comprar, mas … lote" em amarelo). Eventos (últimos 12): COMPRA/VENDA do **CSV completo** (gasto =
  qtd × preço) + do final do log (~400 linhas) ERRO na ordem/`SIMULACAO:`/`CARTEIRA:`/APORTE/`Sinal de compra`.
- Diferenças esperadas em relação ao app da Binance: o painel avalia as moedas pelo **bid** (o que se
  receberia vendendo agora), o app usa o último preço; o valor de cada moeda inclui as **sobras de lote**
  (ex.: 0,0974 NEAR ≈ R$ 2,60 fora da ordem de venda); R$ 0,0048 de arredondamento do BTC fica "sem dono".
  Quedas → `SIMULACAO:` no log, reinício em 30 s (máx. 5/h). "Parar simulação" usa `parar-simulacao.flag`.
- Recursos: ~110 MB de RAM por bot (4 bots + painel ≈ 570 MB); bookTicker de 4 pares a cada 2 s
  (~240 de peso/min, limite da Binance 6000).
- Multi-bot real: existe desde 19/10 (carteira real, acima).

## Configuração atual (`config.json`)

| Chave | Valor | Significado |
|---|---|---|
| `modo` | `real` | `simulacao` ou `real` |
| `par` | `BTCBRL` | |
| `deposito_inicial_brl` | 20 | base dos avisos e fallback do "valor investido" |
| `meta_brl` | 0 | 0 = sem meta, roda indefinidamente |
| `janela_minutos` | 240 | topo dos últimos N min |
| `queda_para_comprar_pct` | 2,5 | compra quando o preço cai X% abaixo do topo |
| `lucro_para_vender_pct` | 2,5 | vende com +Y% sobre a entrada |
| `stop_loss_pct` | **0** | 0 = **sem stop** (decisão do usuário, ver histórico) |
| `pausa_apos_stop_minutos` | 10 | |
| `tendencia_minutos`, `trailing_pct` | 0 | desligados (não ajudaram no backtest; trailing desliga a proteção na Binance) |
| `taxa_simulacao_pct` | 0,1 | taxa usada na simulação/backtest |
| `carteira_propria` | (ausente) | `true` = bot da carteira (saldo próprio, aportes, mutex por par). A `carteira.ps1 -Modo real` acrescenta `true` ao abrir pela 1ª vez; até lá o BTC segue como bot único. |

**Avisos de patamar** (notificação do Windows, uma vez cada, salvo em `ultimo_aviso`): a cada R$ 1 até
R$ 30, R$ 2 até R$ 50, R$ 5 até R$ 100, depois R$ 10.

**Valor investido**: soma de depósitos − saques em BRL de `/sapi/v1/fiat/orders` (a cada 10 min);
se vazio/erro, usa `deposito_inicial_brl`. O card mostra a fonte ("inv. Binance" / "inv. do config").
O "Lucro" do painel = patrimônio − investido.

## Painel (bandeja)

Tema escuro (fundo `#0B1120`, cartões `#162033`, destaque verde-água `#2DD4BF`), barra de título escura,
janela redimensionável. Cartões: **Saldo** (BRL / BTC com valor em R$ / Inv.), **Lucro**,
**Reais em BTC** (R$ 1/50/100 em BTC + preço de 1 BTC), **Próximo aviso**. Linha de situação.
**Últimos 10 registros** do log (sem filtro, texto completo, cores por tipo) + link "Abrir log completo".
Indicador: Rodando / Reiniciando… / Parado.

## Cuidados técnicos (PowerShell 5.1)

- **Variáveis não diferenciam maiúsculas**: `$inv` sobrescreve `$Inv` (cultura invariante). Escolha nomes distintos.
  Em 19/10 quase entrou `$base = $Deposit` no loop do `bot.ps1`, que sobrescreveria `$Base` (URL da API).
  Depois de editar, procure colisões pela AST com um `HashSet` **Ordinal** (o `Sort-Object -Unique` não
  diferencia maiúsculas e esconde a colisão). Hoje só `$step` (parâmetro local de `Floor-Step`) e
  `$w/$W`, `$h/$H` (locais de funções do painel) — inofensivos.
- `[Math]::Min(1, $x)` com `1` inteiro escolhe a versão `int` e arredonda `$x` → use `1.0`.
- Números: sempre `[decimal]`/`[double]::Parse(..., InvariantCulture)`; o Windows do usuário é pt-BR (vírgula decimal).
  `-f` com `{0:N2}` usa a cultura atual (vírgula) — ok para exibição, nunca para enviar à API.
- Arquivos `.ps1` com acentos precisam de **UTF-8 com BOM** (a ferramenta Edit grava sem BOM:
  regrave com `UTF8Encoding($true)` depois de editar `bandeja.ps1`). `bot.ps1` não usa acentos de propósito.
- Gravação em arquivo: use `Append-Safe` / `Write-Safe` (novas tentativas). **Nunca `Add-Content` direto** — ver problema de 06/10.
- `Start-Process -PassThru`: leia `.Handle` logo após iniciar, senão `ExitCode` vem vazio.
- Leitura de arquivos que outro processo escreve: `[IO.File]::Open(..., 'Read', 'ReadWrite, Delete')`.
- Lotes da Binance no BTCBRL: `stepSize` 0,00001 BTC (~R$ 4,3), `minNotional` R$ 10, `tickSize` R$ 1.
- Event handlers do WinForms: use `$script:` para variáveis alteradas dentro deles.
- Preços no log/CSV/situação: use `Px` (2 casas ≥ R$ 100, até 4 casas ≥ R$ 1, até 8 abaixo — PEPE custa
  ~R$ 0,00002). `Brl` (2 casas) só para valores em reais. O painel da simulação formata com `PxPt`.
- `carteira.ps1` tem acentos → UTF-8 com BOM (regrave após usar Edit, como no `bandeja.ps1`).
  `simulacao.ps1` hoje é só ASCII (chama a carteira).
- `bot.ps1` grava o estado já na 1ª execução (horário de `inicio`), não só na 1ª compra.

## Resultados de referência (backtest abr–out/2026, taxa 0,1%)

- Parâmetros atuais **com stop 3%**: +28,9% treino (BTC −9%), +17,4% teste (BTC +36%), +51,3% em 6 meses;
  ~1 operação a cada 4–5 dias. **Sem stop**: −7,6% treino, +31,6% teste, +41,9% em 6 meses (só 3 vendas
  em 4 meses de queda).
- Previsão (com stop 3%): lucro típico ~R$ 0,27 em 1 semana, ~R$ 0,93 em 1 mês, ~R$ 2,88 em 2 meses (base R$ 20).
- Outros pares: BTC foi o único consistente; moedas de spread alto (ADA, DOGE, XRP, LINK) e operar
  rápido (≥ 1 op/dia) pioraram os resultados.

### Reanálise 14/10/2026 — 16 pares BRL, 17/04–14/10, config atual (2,5/2,5/240 min, **sem stop**)

Pedido do usuário: avaliar vários bots / moedas mais voláteis com R$ 50. `backtest.ps1` foi rerodado em
16 pares (as linhas de 14/10 do `resumo-pares.csv`; os `resultado-backtest-*.txt` antigos foram
**sobrescritos** com esta config). Teste de robustez extra, feito em rascunho: A = candles completos;
B = só o fechamento de cada minuto (sem pavios, mais conservador).

| Par | segurar 180 d | bot A | bot B | bot B c/ stop 3% | minutos sem negócio |
|---|---|---|---|---|---|
| NEAR | +247% | +358% | +318% | −18% | 97% |
| SOL | +17% | +19% | +22% | +1% | 68% |
| LINK | +29% | +20% | +16% | −1% | 98% |
| ETH | +1% | +19% | +13% | −14% | 34% |
| BTC | +6% | +30% | +9% | +10% | 9% |
| RENDER | +1% | +9% | +5% | −61% | 99% |
| LTC / SHIB / PEPE / BNB | +6 / −20 / +2 / +15% | +4 / −11 / +4 / +6% | +5 / +5 / +1 / +1% | −23 / −28 / −69 / −8% | 84–98% |
| POL / AVAX / ADA / SUI / XRP / DOGE | −18 a +9% | −2 a −20% | −1 a −21% | −21 a −86% | 78–99% |

Conclusões: o resultado do bot acompanha o da moeda (subiu → lucro; caiu → preso no prejuízo, quedas
de 30–50%); sem NEAR, a média B dos outros 15 pares foi ~+0,7% (segurar: ~+1,8%). Otimizar por moeda não
se sustenta (ex.: AVAX treino +89% → teste −19%; POL +44% → −29%). Escolher NEAR agora é retrospectiva.
Pares BRL de altcoins: spread 0,05–0,4% (BTC 0,001%) e quase sem negócios → backtest menos confiável.
`minNotional` R$ 10 em todos os pares → R$ 50 comportam no máximo ~3–4 bots.

**Multi-bot:** existe em simulação e, desde 19/10, em real (`carteira.ps1`, ver Arquitetura), com
carteira própria por bot (cada um só gasta os reais dele).

**Simulação 14/10 13:52 → 19/10 14:00 (SOL/NEAR/PEPE/SUI, R$ 50):** 6 vendas, lucro real +R$ 1,63,
projetado −R$ 1,50 (3 moedas compradas abaixo do preço de compra) → +R$ 0,13 se tudo virasse reais.

## Problemas conhecidos / resolvidos

- **Sobras por lote** (conhecido): com R$ 20, compra só lotes inteiros de 0,00001 BTC → sobra BRL
  (~R$ 2,67) e, como a taxa é cobrada em BTC, ~0,00001 BTC fica fora da ordem de venda. Pagar taxas
  com BNB resolveria a segunda parte (decisão do usuário).
- **Histórico**: a 1ª compra (05/10 10:01) está no `operacoes-real.csv` com valor `20.00`; o real foi
  **R$ 17,33** (bug de registro já corrigido; a linha não foi editada).
- **05/10 — erro -2015 nas ordens**: chave sem permissão de negociação/IP. Leituras funcionavam,
  ordens não. Resolvido pelo usuário na Binance. Hoje: notificação única + nova tentativa a cada 1 min.
- **05/10 — painel congelava em erros**: status só era escrito no fim do `try`. Corrigido (ordem em `try` próprio).
- **06/10 — bot morreu às 02:36 sem log**: `Add-Content` falhou ("O fluxo não era legível", arquivo
  travado por outro processo) dentro do `catch` e do `trap`. Corrigido com `Append-Safe`/`Write-Safe`,
  stderr capturado, motivo registrado pela bandeja e reinício automático.
- **14/10 — erro -1021 por horas** ("Timestamp ... 1000ms ahead of the server's time"), a partir de 04:06:
  a diferença de relógio PC × Binance (`$script:TimeOffset`) era calculada **só ao iniciar**; o relógio do
  PC andou e as chamadas assinadas (saldo, consulta da ordem) passaram a ser recusadas. Preço (API pública)
  seguia funcionando e a ordem LIMIT na Binance continuou ativa. Corrigido: `Sync-Time` + no -1021 o
  `Invoke-Signed` ressincroniza e repete **uma vez** (seguro: a Binance recusa antes de executar, não duplica ordem).
  Vale só depois que o usuário reiniciar o bot.
- **14/10 — bot "esquecia" a compra abaixo de R$ 10** (latente, nunca ocorreu no real): "comprado" era
  cripto × preço **atual** ≥ R$ 10. Uma queda grande (≈ 42% no BTC real; 20% com R$ 12,50) zerava o preço de
  entrada e o bot encerrava com "Saldo abaixo do minimo" (código 0, sem reinício). Corrigido com `In-Position`.
- **14/10 — preços de moedas baratas apareciam "R$ 0.00"** no log/CSV (formato `Brl`, 2 casas). Corrigido com `Px`.
- **15/10 — NEAR da simulação travou** ("compra de R$ 8,02 abaixo do minimo", a cada minuto desde 17:55):
  comprou 0,5 NEAR, taxa em NEAR → 0,4995, vendeu só 0,4 (lote 0,1) → 0,0995 NEAR (~R$ 2,66) parados e
  R$ 10,27 em reais, que em lotes de R$ 2,68 só compram R$ 8,02. **Não é bug da simulação: aconteceria no
  real.** Correções: valores por moeda conforme o lote (NEAR R$ 16), pré-checagem do lote no `bot.ps1`
  (sem spam de erro). Pagar taxas com BNB eliminaria o lote parado (decisão do usuário, se for para o real).
- **Venda real registrava o valor bruto** (antes de 19/10): `cummulativeQuoteQty` inclui a taxa, que a
  Binance desconta dos reais recebidos. Corrigido: venda grava recebido − taxa (não houve venda real antes).
- **20/10 13:44 — venda do PEPE na Binance não foi registrada** (1º dinheiro real afetado; os reais ficaram
  na conta, "sem dono"). A ordem LIMIT <id da ordem> executou (489.923 PEPE a R$ 0,000023 = R$ 11,268, taxa
  R$ 0,0113). O saldo (lido a cada 60 s) mostrou o PEPE fora da conta **antes** da conferência da ordem
  (a cada 15 s); a sincronização "moeda sumiu → não está comprado" apagou `preco_entrada`; na conferência
  seguinte `Record-Sale` fez `D ''` → erro de Parse, e `oco_id` já estava limpo **só na memória** → a venda
  nunca foi registrada e `brl_proprio` ficou ~0 ("aguardando reais"); o painel mostrava R$ 11 a menos e
  R$ 11,26 "sem dono". Acontecia com ~25% das vendas LIMIT (NEAR e SUI escaparam por sorte); latente
  também no bot único. Corrigido em 21/10: confere a ordem logo (a cada 3 s) quando a moeda some da conta;
  a sincronização não apaga `preco_entrada` com `oco_id` registrado; `Record-Sale` aceita entrada vazia
  ("variacao n/d"); painel ganha `conferindo_venda` e a carteira não oferece distribuir enquanto houver
  venda por conferir (senão os reais do PEPE iriam para outras moedas). **Recuperação:** o
  `estado-real.json` do PEPE manteve `oco_id` <id da ordem> → ao reiniciar a carteira, o bot confere a ordem
  e registra a venda (testado com respostas falsas idênticas: `scratchpad\teste-pepe-venda.ps1`, 10 ok).

## Histórico de decisões e mudanças

(O historico da conta de quem compartilhou foi omitido nesta copia.)

| Data | Mudanca / decisao | Por que / quem |
|---|---|---|
