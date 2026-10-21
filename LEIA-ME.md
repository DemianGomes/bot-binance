# Bot de trading Binance (BRL)

Bot simples em PowerShell (não precisa instalar nada). Ele acompanha o preço de um par em BRL
(padrão: BTC/BRL) a cada 2 segundos e segue esta regra:

1. Olha o **topo dos últimos 240 min** (4 h).
2. Se o preço cair **2,5%** abaixo desse topo → **compra** com todo o BRL.
3. Se subir **2,5%** acima do preço de compra → **vende** (lucro).
   Hoje **sem stop loss** (`stop_loss_pct` 0): se o preço cair, o bot espera ele voltar.
4. Sem meta (`meta_brl` 0): roda indefinidamente. Para se o saldo ficar abaixo do mínimo de ordem da
   Binance (R$ 10).

Esses parâmetros vieram do backtest (veja abaixo). Todos ficam no `config.json`.
Opcionais: `tendencia_minutos` (só compra se o preço estiver acima da média móvel desse período;
0 = desligado) e `trailing_pct` (depois de atingir o lucro, segue subindo e vende quando cair X% do pico;
0 = desligado). No backtest de abr–out/2026, nenhum dos dois ajudou.

## Arquivos
| Arquivo | Para quê |
|---|---|
| `bot.ps1` | o bot (preços, saldo, ordens, logs) |
| `strategy.cs` | a regra de compra/venda — **a mesma** usada pelo bot e pelo backtest |
| `backtest.ps1` / `backtest.cs` | testa a regra em meses de preços históricos |
| `config.json` | parâmetros |
| `previsao.ps1` | simula o bot começando em cada dia do histórico e mostra o que esperar em 1, 3, 7, 30 e 60 dias |
| `log-<modo>.txt` | tudo que o bot fez, com status a cada 30 s |
| `operacoes-<modo>.csv` | uma linha por compra/venda (abre no Excel) |
| `estado-<modo>.json` | saldo simulado, preço de entrada, início. **Apague para recomeçar do zero.** |
| `backtest-todos.ps1` | roda o backtest em vários pares BRL e compara |
| `resultado-backtest-<PAR>.txt` | último relatório do backtest de cada par |
| `resumo-pares.csv` | uma linha por par testado (abre no Excel) |
| `carteira.ps1` | bandeja com várias moedas e um painel só — real (atalho **Bot**) ou simulação (atalho **Bot Simulação**) |
| `real\moedas.json` | moedas da carteira real: o BTC com a reserva dele e as outras com o "peso" (fatia dos reais livres) |
| `simulacao\moedas.json` | quais moedas a simulação usa e quanto em cada uma (`par` + `valor_brl`) |
| `operacoes-<modo>.csv` | (também em `real\<PAR>\` e `simulacao\<PAR>\`) cada compra/venda, com a **taxa paga** (`taxa_brl`) |

## Passo 1 — Simulação (sem dinheiro, sem chave)
`config.json` já vem com `"modo": "simulacao"`. Dê dois cliques em **`iniciar.bat`**.
O bot usa os preços reais da Binance, mas não envia ordens, e desconta 0,1% de taxa por operação.
Ao iniciar, ele baixa as últimas 4 h de preços, então já sai sabendo onde comprar.
Para parar: feche a janela ou Ctrl+C. Ao abrir de novo, continua de onde parou.

## Passo 2 — Modo real (você faz)
1. **Crie a chave de API** na Binance: Perfil → *Gerenciamento de API* → Criar API.
   - Marque **apenas** "Ativar leitura" e "Ativar negociação Spot e Margem".
   - **NUNCA** marque "Ativar saques".
   - Se possível, restrinja ao seu IP.
2. **Guarde a chave no Windows** (abra o PowerShell e rode, trocando pelos seus valores):
   ```
   setx BINANCE_API_KEY "sua_api_key"
   setx BINANCE_API_SECRET "seu_secret"
   ```
   Feche e abra o terminal depois disso. Não cole a chave em chats nem em arquivos do bot.
3. Deposite os R$ 20 em BRL na carteira **Spot**.
4. No `config.json`, troque `"modo": "simulacao"` por `"modo": "real"`.
5. Rode `iniciar.bat`. O bot mostra a taxa real da sua conta e o saldo, e pede para você digitar
   **SIM** antes de operar.

**Sem stop:** com `"stop_loss_pct": 0` o bot não vende no prejuízo — fica registrada na Binance só
a venda com lucro, e se o preço cair ele espera voltar. Ao mudar esse valor, reinicie o bot: ele troca
sozinho a ordem que já está na Binance pelo tipo certo. (No backtest de abr–out/2026, sem stop rendeu
+41,9% em 6 meses contra +51,3% com stop de 3%, e ficou meses parado durante a queda.)

**Proteção na Binance (modo real):** logo depois de cada compra, o bot cria na Binance uma ordem
OCO — venda com lucro (+2,5%) **ou** stop (−3%); quando uma executa, a outra é cancelada. Ela fica
nos servidores da Binance, então a venda acontece **mesmo com o PC desligado**. Ao religar, o bot
confere o que aconteceu e registra no log. A compra, porém, só acontece com o bot rodando.
Obs.: o BTC só pode ser vendido em múltiplos de 0,00001 BTC (~R$ 4,40), então uma sobra pequena de
BTC (até ~R$ 4) pode ficar na conta fora da ordem; ela entra na próxima venda.

Consumo: ~0,2% de um núcleo de CPU e ~100 MB de RAM.

## Carteira: um bot só para BTC e outras moedas (desde 19/10/2026)
O atalho **Bot** da Área de Trabalho abre a **carteira em modo real**: um robô verde-água na bandeja
que cuida do BTC e de SOL, NEAR, PEPE e SUI ao mesmo tempo, **com o dinheiro da sua conta Binance**.

- **O BTC fica só com a reserva dele** (`reservado_brl` em `real\moedas.json`, hoje R$ 20: o BTC comprado
  + o que sobrou em reais da compra). As outras moedas não mexem nesse dinheiro.
- **Os outros reais livres da conta** vão para SOL, NEAR, PEPE e SUI, na proporção testada na
  simulação (11,5 / 16 / 11 / 11,5 — com R$ 50: R$ 11,50, R$ 16, R$ 11 e R$ 11,50). Cada moeda só
  gasta a parte dela.
- Cada compra e venda mostra no log **quanto foi de taxa**; o painel soma as "taxas pagas".
- A venda com lucro fica registrada na Binance logo depois de cada compra, então vende **mesmo com o PC
  desligado**. As compras só acontecem com o PC ligado.

**Para ligar:**
1. Feche o bot antigo: botão direito no robô verde da bandeja → **Sair**. (A carteira não abre com ele
   aberto, para os dois não mexerem no mesmo dinheiro.)
2. Deposite os reais na carteira **Spot** da Binance.
3. Abra o atalho **Bot** e confirme o modo real.
4. Uns 30 segundos depois aparece: "Há R$ X em reais livres… Distribuir assim?" com quanto vai para
   cada moeda. Confira e clique **Sim**. (Se depositar mais depois: botão direito no robô →
   *Distribuir reais livres…*.)

Fechar o painel só o esconde; botão direito → *Parar carteira* / *Sair*. As ordens de venda que já estão
na Binance continuam valendo. Notificações: cada venda (com o valor recebido e a taxa) e problemas.

**Por que o painel difere um pouco do app da Binance?** O painel calcula cada moeda pelo preço que você
receberia vendendo agora (o "bid"); o app usa o último preço negociado, então diferenças de centavos são
normais. O valor de cada moeda inclui as **sobras de lote** (ex.: ~0,1 NEAR que fica fora da ordem de
venda, porque a taxa da compra é cobrada na moeda). E "vende em" é o preço exato da ordem na Binance.
Lucro real + lucro projetado = valor total − depositado, em cada linha.

**Reais "sem dono" na linha TOTAL logo depois de uma venda?** Até 21/10/2026 um defeito fazia o bot às
vezes não registrar uma venda feita pela Binance (aconteceu com o PEPE em 20/10): o dinheiro fica na
conta, mas sem dono. Já corrigido; ao reiniciar a carteira, o bot confere a ordem e registra a venda.
Se voltar a acontecer, **não use "Distribuir reais livres"** (daria esse dinheiro para outras moedas):
reinicie a carteira e confira o log da moeda.

O bot antigo, só BTC, ainda existe (`bandeja.ps1` / `iniciar.bat`), mas não roda junto com a carteira.

## Bandeja e notificações (bot antigo, só BTC)
A `bandeja.ps1` abre o bot só de BTC **sem terminal**: ele fica como um robô na
bandeja do Windows (perto do relógio). Clique no robô para ver o painel com o log; botão direito para
*Parar/Iniciar bot* e *Sair*. Fechar o painel só o esconde — o bot continua. (`iniciar.bat` ainda
abre a versão com terminal.) Nunca rode os dois ao mesmo tempo — o bot bloqueia uma segunda cópia.

Sem meta (`"meta_brl": 0`): o bot opera indefinidamente. Notificações do Windows quando o saldo
atinge um novo patamar: a cada R$ 1 até R$ 30, R$ 2 até R$ 50, R$ 5 até R$ 100, depois R$ 10.
Cada patamar avisa uma vez só (fica salvo em `ultimo_aviso` no estado). Se o bot parar por qualquer
motivo que não seja você, também chega uma notificação com o motivo.

Erro **-1021** ("Timestamp ... ahead of the server's time") no log = relógio do PC fora de hora.
Desde 14/10/2026 o bot ressincroniza sozinho (vale depois de reiniciar o bot). Se continuar aparecendo,
acerte o relógio: Configurações → Hora e idioma → Data e hora → **Sincronizar agora**.

## Simulação com várias moedas (robô amarelo)
O atalho **Bot Simulação** da Área de Trabalho roda **5 bots ao mesmo tempo, com dinheiro de mentira**:
BTC R$ 20 · SOL R$ 11,50 · NEAR R$ 16 · PEPE R$ 11 · SUI R$ 11,50 (R$ 70 no total), com **a mesma
regra** do bot real e os preços reais da Binance. **Nenhuma ordem é enviada** e a chave de API não é usada.

- Fica como um **robô amarelo** na bandeja (o do bot real é verde-água). Pode rodar junto com o bot real.
- Clique nele para ver o painel:
  - **Depositado**: quanto foi colocado (de mentira).
  - **Valor total**: reais + moedas, a preço de agora. Sobe e desce com as moedas.
  - **Lucro projetado**: quanto as moedas que estão compradas agora ganhariam (+) ou perderiam (−) se
    fossem vendidas a preço de agora. Muda o tempo todo.
  - **Lucro real**: o que as vendas já feitas trouxeram a mais do que custaram. Já está em reais.
  - Lucro real + lucro projetado = valor total − depositado.
  - Embaixo, uma linha por moeda (com quanto falta para comprar ou vender) e as últimas compras e vendas.
- **Por que valores diferentes por moeda?** A Binance só negocia em lotes inteiros (NEAR: 0,1 NEAR ≈
  R$ 2,70) e cobra a taxa da compra na própria moeda, então um lote sempre fica parado e outro se perde no
  arredondamento. Cada moeda precisa de uns **R$ 10 + 2 lotes**; com R$ 12,50 o NEAR travava ("compra de
  R$ 8, abaixo do mínimo"). Se o saldo não formar um lote válido, o bot avisa ("Quer comprar, mas…") e espera.
- Botão direito → *Parar simulação* / *Iniciar simulação* / *Sair*. O resultado fica salvo: ao abrir de
  novo, continua de onde parou. Se um bot cair, ele é reiniciado sozinho em 30 s.
- O PC precisa ficar ligado para a simulação andar (ela não deixa ordens na Binance como o bot real).
- Trocar as moedas ou o valor: edite `simulacao\moedas.json` (`"par"` e `"valor_brl"`) e reabra a
  simulação (robô amarelo → *Sair*, depois o atalho). Mudar o valor de uma moeda que já rodou funciona
  como um depósito/saque simulado: o lucro acumulado é mantido. Cada moeda tem sua pasta em
  `simulacao\<PAR>\` (log, operações, estado). Para recomeçar uma moeda do zero, apague a pasta dela
  com a simulação fechada.
- Deixe rodar **2 a 4 semanas** antes de tirar conclusões: o bot opera poucas vezes por semana.

## Compartilhar o bot com alguém
Rode `powershell -ExecutionPolicy Bypass -File exportar.ps1`. Ele cria a pasta **`compartilhar\`** e o
arquivo **`bot-binance-compartilhar.zip`** só com o código e os manuais — **sem** os seus saldos, logs,
histórico de operações nem estados, e com o `config.json` em simulação. Envie só essa pasta (ou o zip),
**nunca a pasta principal do bot**. A chave de API não vai junto (ela fica no seu Windows); a outra pessoa
cria a dela. Ao mudar o bot, rode o `exportar.ps1` de novo e envie os arquivos atualizados.

## Como melhorar o bot (ciclo recomendado)
1. Rode **`backtest.bat`**. Ele baixa os últimos 180 dias de candles de 1 min, testa ~3000
   combinações nos primeiros 4 meses (TREINO) e roda as 10 melhores nos últimos 2 meses (TESTE).
2. Olhe **só a linha `te`** (teste) para decidir: o treino sempre parece melhor do que é.
   Prefira configurações que vão bem nos dois períodos e cujos vizinhos (valores parecidos) também
   vão bem — um resultado isolado costuma ser sorte.
3. Copie os parâmetros para o `config.json`, rode em simulação, compare o log com o backtest.
   Para outra moeda: `powershell -ExecutionPolicy Bypass -File backtest.ps1 -Par ETHBRL`.
   Para comparar várias: `powershell -ExecutionPolicy Bypass -File backtest-todos.ps1`.
4. Repita uma vez por mês, com dados novos. Mudar os parâmetros toda hora para "acertar o passado"
   (overfitting) é o erro mais comum de bots.

## Atualização 14/10/2026 — config atual (sem stop), 17/04 a 14/10/2026
- BTC/BRL: **+9% a +30%** em 6 meses, conforme o quanto o bot consegue pegar das mínimas de cada minuto
  (só segurar BTC: +6%). Nos últimos 30 dias: **−5%**, 1 operação (é a compra de 05/10, ainda aberta).
- Outras 15 moedas BRL testadas (inclusive as mais voláteis): sem a NEAR, a média foi **~+0,7%** em 6
  meses, com quedas de 30–50% no caminho. Com stop de 3%, as voláteis perderam 50–90%.
  Os pares BRL de altcoins quase não negociam (90–99% dos minutos sem nenhum negócio).

## Expectativa realista (backtest abr–out/2026, com taxa de 0,1%, config antiga com stop 3%)
- Config atual: **+29%** em 4 meses de TREINO (BTC caiu 9% no período) e **+17%** em 2 meses de
  TESTE (BTC subiu 36% — só segurar teria ganhado mais).
- Ritmo: ~**0,25–0,3% ao dia** em média, mas em saltos — cerca de **uma operação a cada 4–5 dias**.
  Em um dia qualquer, o mais provável é o bot **não fazer nada**.
- Nesse ritmo, R$ 20 → R$ 30 levaria uns **4–5 meses**. Pode ser mais rápido, mais lento, ou dar
  prejuízo: o passado não garante o futuro.
- A configuração antiga (compra em quedas de 0,6%, 15 min) **perdeu 11%** no treino.
  Operar mais vezes paga mais taxa — no teste com operações por segundo, perdeu ~1,8% em 45 s.
