# Bot simples de trading para Binance (par cotado em BRL).
#
# A decisao de comprar/vender fica em strategy.cs (a mesma usada pelo backtest.ps1):
# compra quando o preco cai X% abaixo do topo dos ultimos N minutos e vende com
# +Y% (lucro) ou -Z% (stop loss). Este script cuida de precos, saldo, ordens e logs,
# e para quando o patrimonio em BRL chega na meta (se houver) ou nao ha saldo para operar.
#
# modo "simulacao": usa precos reais da Binance, mas NAO envia ordens.
# modo "real": envia ordens usando a chave de API das variaveis de ambiente
#              BINANCE_API_KEY e BINANCE_API_SECRET.
#
# Uso: powershell -ExecutionPolicy Bypass -File bot.ps1 [-Config caminho\config.json]
# -SemConfirmacao pula o "digite SIM"; usado pelo bandeja.ps1, que pede a confirmacao numa janela.
# -SoSimulacao recusa iniciar se o config nao estiver em "simulacao" (usado pelo simulacao.ps1).

param(
    [string]$Config = (Join-Path $PSScriptRoot 'config.json'),
    [switch]$SemConfirmacao,
    [switch]$SoSimulacao
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Inv = [Globalization.CultureInfo]::InvariantCulture
$Base = 'https://api.binance.com'
Add-Type -Path (Join-Path $PSScriptRoot 'strategy.cs')

# ---------- utilitarios ----------

function D($v) {
    if ($v -is [decimal]) { return $v }
    return [decimal]::Parse([string]$v, [Globalization.NumberStyles]::Float, $Inv)
}
function Qty([decimal]$v) { return $v.ToString('0.########', $Inv) }
function Brl([decimal]$v) { return $v.ToString('0.00', $Inv) }
# Preco de 1 unidade: 2 casas para BTC (433131.00), mais casas para moedas baratas (PEPE 0.00004523)
function Px([decimal]$v) {
    if ($v -ge 100) { return $v.ToString('0.00', $Inv) }
    if ($v -ge 1) { return $v.ToString('0.00##', $Inv) }
    return $v.ToString('0.00######', $Inv)
}
function Floor-Step([decimal]$v, [decimal]$step) { return [decimal]::Floor($v / $step) * $step }
function Now-Ms { return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
function Parse-Date([string]$s) { return [datetime]::Parse($s, $Inv, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() }
function From-Ms([long]$ms) { return [DateTimeOffset]::FromUnixTimeMilliseconds($ms).UtcDateTime }

# Escrita em arquivo que nunca derruba o bot: se o arquivo estiver momentaneamente travado
# (antivirus, indexador, editor aberto), tenta de novo algumas vezes e desiste em silencio.
# Em 06/10/2026 um Add-Content falhou assim ("O fluxo nao era legivel") e encerrou o bot.
function Append-Safe([string]$path, [string]$text) {
    for ($i = 0; $i -lt 5; $i++) {
        try { [IO.File]::AppendAllText($path, $text + "`r`n", [Text.Encoding]::Default); return $true }
        catch { Start-Sleep -Milliseconds 200 }
    }
    return $false
}
function Write-Safe([string]$path, [string]$text) {
    for ($i = 0; $i -lt 5; $i++) {
        try { [IO.File]::WriteAllText($path, $text, [Text.Encoding]::ASCII); return $true }
        catch { Start-Sleep -Milliseconds 200 }
    }
    return $false
}

# O log e rotacionado: ao passar de 1 MB vira log-<modo>.anterior.txt (substituindo o antigo),
# entao ocupa no maximo ~2 MB no disco.
function Log([string]$msg) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Write-Host $line
    try {
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) {
            Move-Item -Path $LogFile -Destination ($LogFile -replace '\.txt$', '.anterior.txt') -Force
        }
    } catch {}
    [void](Append-Safe $LogFile $line)
}

function Get-Public([string]$path) {
    return Invoke-RestMethod -Method Get -Uri ($Base + $path) -TimeoutSec 15
}

# Diferenca entre o relogio do PC e o da Binance (somada ao timestamp das chamadas assinadas)
function Sync-Time {
    $script:TimeOffset = [long](Get-Public '/api/v3/time').serverTime - (Now-Ms)
}

function Invoke-Signed([string]$method, [string]$path, $params, [bool]$retried = $false) {
    $params['recvWindow'] = 5000
    $params['timestamp'] = (Now-Ms) + $script:TimeOffset
    $query = ($params.GetEnumerator() | ForEach-Object { $_.Key + '=' + [Uri]::EscapeDataString([string]$_.Value) }) -join '&'
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = [Text.Encoding]::UTF8.GetBytes($script:ApiSecret)
    $sig = -join ($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($query)) | ForEach-Object { $_.ToString('x2') })
    $uri = $Base + $path + '?' + $query + '&signature=' + $sig
    try {
        return Invoke-RestMethod -Method $method -Uri $uri -Headers @{ 'X-MBX-APIKEY' = $script:ApiKey } -TimeoutSec 15
    } catch {
        $detail = "$($_.ErrorDetails.Message)"
        # -1021: o relogio do PC andou desde que o bot iniciou (ex.: 14/10/2026, horas de erro).
        # A Binance recusa antes de executar, entao e seguro ressincronizar e repetir uma vez.
        if (-not $retried -and $detail -match '"code":\s*-1021') {
            try { Sync-Time } catch {}
            return Invoke-Signed $method $path $params $true
        }
        throw "Binance recusou $method $path : $detail $($_.Exception.Message)"
    }
}

function Opt($name, $default) {
    if ($cfg.PSObject.Properties[$name]) { return $cfg.$name }
    return $default
}

# ---------- configuracao ----------

$cfg = Get-Content $Config -Raw | ConvertFrom-Json
$Symbol = ([string]$cfg.par).ToUpper()
$Mode = ([string]$cfg.modo).ToLower()
if ($Mode -ne 'simulacao' -and $Mode -ne 'real') { throw 'config.json: "modo" deve ser "simulacao" ou "real"' }
if ($SoSimulacao -and $Mode -ne 'simulacao') { throw "Recusado: -SoSimulacao, mas $Config esta em modo '$Mode'." }
$Deposit  = D $cfg.deposito_inicial_brl
$Target   = D (Opt 'meta_brl' 0)   # 0 = sem meta, roda indefinidamente
$Interval = [int]$cfg.intervalo_segundos
$SimFee   = (D $cfg.taxa_simulacao_pct) / 100
# carteira_propria: varios bots na mesma conta (carteira.ps1). Cada bot so usa os reais que sao dele
# (estado.brl_proprio no real; estado.brl na simulacao), recebe aportes pelo arquivo aporte-<modo>.txt
# e espera (em vez de encerrar) quando nao tem reais suficientes para comprar.
$Ledger   = [bool](Opt 'carteira_propria' $false)

$s = New-Object DipStrategy
$s.WindowMin   = [double]$cfg.janela_minutos
$s.WarmupMin   = [double]$cfg.aquecimento_minutos
$s.Dip         = [double]$cfg.queda_para_comprar_pct / 100
$s.TakeProfit  = [double]$cfg.lucro_para_vender_pct / 100
$s.StopLoss    = [double]$cfg.stop_loss_pct / 100
$s.CooldownMin = [double]$cfg.pausa_apos_stop_minutos
$s.TrendMin    = [double](Opt 'tendencia_minutos' 0)
$s.Trail       = [double](Opt 'trailing_pct' 0) / 100

$Dir = Split-Path -Parent (Resolve-Path $Config)
$StateFile  = Join-Path $Dir "estado-$Mode.json"
$TradesFile = Join-Path $Dir "operacoes-$Mode.csv"
$LogFile    = Join-Path $Dir "log-$Mode.txt"
$StopFlag   = Join-Path $Dir "parar-$Mode.flag"   # criado pelo bandeja.ps1 para pedir uma parada limpa

# Rodando escondido (bandeja), erros fatais so aparecem se forem para o log
trap {
    try { Log "ERRO FATAL (linha $($_.InvocationInfo.ScriptLineNumber)): $($_.Exception.Message)" } catch {}
    [Console]::Error.WriteLine("ERRO FATAL (linha $($_.InvocationInfo.ScriptLineNumber)): $($_.Exception.Message)")   # a bandeja guarda isso
    exit 1
}

# Impede dois bots no modo real ao mesmo tempo (ordens duplicadas na mesma conta).
# Na simulacao o bloqueio e por pasta: varios bots simulados (um por moeda) podem rodar juntos.
# No real com carteira propria o bloqueio e por moeda (um bot por par), e o bot antigo, que usa todo o
# saldo da conta, nao pode estar rodando junto (nem o contrario).
function Mutex-Exists([string]$name) {
    try { $mx = [System.Threading.Mutex]::OpenExisting($name); $mx.Dispose(); return $true } catch { return $false }
}
$mutexName = "Global\BotBTC-$Mode"
if ($Mode -eq 'simulacao') {
    $md5 = [Security.Cryptography.MD5]::Create()
    $mutexName += '-' + (-join ($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($Dir.ToLowerInvariant())) | Select-Object -First 6 | ForEach-Object { $_.ToString('x2') }))
} elseif ($Ledger) {
    if (Mutex-Exists 'Global\BotBTC-real') { throw 'O bot antigo (que usa todo o saldo da conta) esta rodando. Feche-o antes: robo verde na bandeja -> Sair.' }
    $mutexName = "Global\BotBTC-real-$Symbol"
} else {
    if ((Mutex-Exists 'Global\BotBTC-Carteira-Bandeja') -or (Mutex-Exists "Global\BotBTC-real-$Symbol")) {
        throw 'A carteira (varios bots reais) esta rodando. Este bot usaria todo o saldo da conta; feche a carteira antes.'
    }
}
$script:Mutex = New-Object System.Threading.Mutex($false, $mutexName)
try { $gotMutex = $script:Mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $gotMutex = $true }
if (-not $gotMutex) { throw "Ja existe um bot rodando em modo $Mode. Feche-o antes de abrir outro." }
if (Test-Path $StopFlag) { Remove-Item $StopFlag -Force }

# ---------- regras do par ----------

$info = (Get-Public "/api/v3/exchangeInfo?symbol=$Symbol").symbols[0]
if ($info.quoteAsset -ne 'BRL') { throw "O par $Symbol nao e cotado em BRL." }
if ($info.status -ne 'TRADING') { throw "O par $Symbol nao esta disponivel para negociacao agora." }
$BaseAsset = $info.baseAsset
$lot = $info.filters | Where-Object { $_.filterType -eq 'LOT_SIZE' }
$Step = D $lot.stepSize
$MinQty = D $lot.minQty
$MinNotional = D ($info.filters | Where-Object { $_.filterType -in 'NOTIONAL', 'MIN_NOTIONAL' } | Select-Object -First 1).minNotional
$Tick = D ($info.filters | Where-Object { $_.filterType -eq 'PRICE_FILTER' }).tickSize
# No modo real, depois de comprar, o bot deixa na Binance uma ordem OCO (venda com lucro + stop)
# que executa mesmo com o PC desligado. O trailing nao funciona assim, entao desliga o OCO.
$UseOco = ($Mode -eq 'real') -and ($s.Trail -le 0) -and [bool]$info.ocoAllowed
# Sem stop (stop_loss_pct = 0), a protecao vira uma ordem LIMIT simples so com a venda com lucro
$UseStop = $s.StopLoss -gt 0
if ($UseStop) { $WantProtection = 'oco' } else { $WantProtection = 'limit' }
Sync-Time

# ---------- estado (sobrevive a reinicios) ----------

$state = $null
if (Test-Path $StateFile) { $state = Get-Content $StateFile -Raw | ConvertFrom-Json }
if (-not $state) {
    $state = [pscustomobject]@{
        inicio        = (Get-Date).ToString('o')
        brl           = (Brl $Deposit)   # usado so na simulacao
        cripto        = '0'              # usado so na simulacao
        preco_entrada = ''
        operacoes     = 0
        pausa_ate     = ''
    }
}
if (-not $state.PSObject.Properties['oco_id']) { $state | Add-Member -NotePropertyName oco_id -NotePropertyValue '' }
# oco_id guarda o id da protecao ativa; protecao_tipo diz se e 'oco' (lucro + stop) ou 'limit' (so lucro)
if (-not $state.PSObject.Properties['protecao_tipo']) { $state | Add-Member -NotePropertyName protecao_tipo -NotePropertyValue 'oco' }
if (-not $state.PSObject.Properties['ultimo_aviso']) { $state | Add-Member -NotePropertyName ultimo_aviso -NotePropertyValue (Brl $Deposit) }
if ($Ledger) {
    # investido_brl = deposito inicial + aportes; brl_proprio = reais deste bot no modo real
    # (definido na 1a execucao, depois de ler o saldo da conta)
    if (-not $state.PSObject.Properties['investido_brl']) { $state | Add-Member -NotePropertyName investido_brl -NotePropertyValue (Brl $Deposit) }
    if ($Mode -eq 'real' -and -not $state.PSObject.Properties['brl_proprio']) { $state | Add-Member -NotePropertyName brl_proprio -NotePropertyValue '' }
}
# Reais que sao deste bot (carteira propria). Na simulacao o saldo inteiro do estado ja e do bot.
function Get-Own {
    if ($Mode -eq 'simulacao') { return D $state.brl }
    if (-not $state.brl_proprio) { return [decimal]0 }
    return D $state.brl_proprio
}
function Set-Own([decimal]$v) {
    if ($Mode -eq 'simulacao') { $state.brl = Brl $v } else { $state.brl_proprio = Qty $v }
}

# Linhas "NOTIFICAR | titulo | texto" no log viram notificacoes do Windows (bandeja.ps1)
function Notify([string]$title, [string]$text) { Log "NOTIFICAR | $title | $text" }

# Patamares de aviso: a cada R$1 ate R$30, R$2 ate R$50, R$5 ate R$100, depois R$10
function Next-Milestone([decimal]$m) {
    if ($m -lt 30) { return $m + 1 }
    if ($m -lt 50) { return $m + 2 }
    if ($m -lt 100) { return $m + 5 }
    return $m + 10
}
function Check-Milestones([decimal]$equity) {
    $last = D $state.ultimo_aviso
    $reached = $last
    while ($equity -ge (Next-Milestone $reached)) { $reached = Next-Milestone $reached }
    if ($reached -gt $last) {
        $state.ultimo_aviso = Brl $reached
        Save-State
        Notify "Saldo: R$ $(Brl $equity)" ("Novo patamar de R$ {0} (lucro de R$ {1} sobre os R$ {2} iniciais)." -f (Brl $reached), (Brl ($equity - $Deposit)), (Brl $Deposit))
    }
}
function Save-State {
    if (-not (Write-Safe $StateFile ($state | ConvertTo-Json))) { Log 'AVISO: nao consegui salvar o arquivo de estado (tentarei de novo na proxima alteracao).' }
}
# Grava o estado ja na primeira execucao: guarda o horario de inicio mesmo antes da primeira compra
if (-not (Test-Path $StateFile)) { Save-State }

if (-not (Test-Path $TradesFile)) {
    Set-Content -Path $TradesFile -Encoding ASCII -Value 'data,tipo,preco,quantidade,valor_brl,patrimonio_brl,taxa_brl,taxa_qtd'
}
# valor_brl: compra = reais gastos; venda = reais recebidos ja sem a taxa.
# taxa_brl = taxa paga, em reais (ou o equivalente, se cobrada na moeda ou em BNB);
# taxa_qtd = parte da taxa descontada da propria moeda comprada (a Binance cobra a taxa da compra na moeda).
# Historicos antigos tem so as 6 primeiras colunas no cabecalho; as linhas novas trazem as 8.
function Write-Trade([string]$type, [decimal]$price, [decimal]$qty, [decimal]$value, [decimal]$equity, [decimal]$feeBrl = 0, [decimal]$feeQty = 0) {
    # valor_brl com ate 4 casas (desde 21/10/2026): com 2 casas, as somas do painel nao fechavam por centavos
    $row = '{0},{1},{2},{3},{4},{5},{6},{7}' -f (Get-Date -Format 's'), $type, (Px $price), (Qty $qty), $value.ToString('0.00##', $Inv), (Brl $equity), $feeBrl.ToString('0.0000', $Inv), (Qty $feeQty)
    if (-not (Append-Safe $TradesFile $row)) { Log "AVISO: nao consegui gravar no historico de operacoes: $row" }
}

# ---------- saldo e ordens ----------

# cripto = total (inclui o que esta reservado nas ordens OCO); criptoLivre = disponivel para vender
# brl = reais que este bot pode usar; brlConta = reais livres na conta (no real com carteira propria,
# brl = o menor entre os reais do bot e os livres na conta, para nunca gastar o que e de outro bot)
function Get-Balances {
    if ($Mode -eq 'simulacao') { return @{ brl = (D $state.brl); brlConta = (D $state.brl); cripto = (D $state.cripto); criptoLivre = (D $state.cripto) } }
    $acc = Invoke-Signed 'GET' '/api/v3/account' ([ordered]@{ omitZeroBalances = 'true' })
    $b = @{ brl = [decimal]0; brlConta = [decimal]0; cripto = [decimal]0; criptoLivre = [decimal]0 }
    foreach ($x in $acc.balances) {
        if ($x.asset -eq 'BRL') { $b.brl = D $x.free }
        if ($x.asset -eq $BaseAsset) { $b.criptoLivre = D $x.free; $b.cripto = (D $x.free) + (D $x.locked) }
    }
    $b.brlConta = $b.brl
    if ($Ledger -and $state.brl_proprio) {
        $own = D $state.brl_proprio
        if ($own -lt $b.brl) { $b.brl = $own }
    }
    return $b
}

# Taxa de uma ordem, a partir das "fills" (resposta da ordem) ou de /api/v3/myTrades (ordem LIMIT que
# executou depois). Retorna @{ brl = taxa paga em reais; qtd = taxa paga na propria moeda;
# total = tudo em reais (moeda e BNB convertidos pelo preco); txt = texto para o log }
function Fee-Summary($fills, [decimal]$price) {
    $f = @{ brl = [decimal]0; qtd = [decimal]0; total = [decimal]0; txt = '' }
    $parts = @()
    foreach ($x in $fills) {
        $c = D $x.commission
        if ($c -le 0) { continue }
        if ($x.commissionAsset -eq 'BRL') { $f.brl += $c; $f.total += $c }
        elseif ($x.commissionAsset -eq $BaseAsset) { $f.qtd += $c; $f.total += $c * $price }
        else {
            # ex.: BNB (desconto na taxa); converte pelo preco atual em reais, se existir o par
            try { $f.total += $c * (D (Get-Public "/api/v3/ticker/bookTicker?symbol=$($x.commissionAsset)BRL").bidPrice) } catch {}
            $parts += '{0} {1}' -f (Qty $c), $x.commissionAsset
        }
    }
    if ($f.qtd -gt 0) { $parts = @('{0} {1}' -f (Qty $f.qtd), $BaseAsset) + $parts }
    $f.txt = 'R$ {0}' -f $f.total.ToString('0.00##', $Inv)
    if ($parts.Count -gt 0) { $f.txt += ' (' + ($parts -join ' + ') + ')' }
    return $f
}
function Order-Fees([string]$orderId, [decimal]$price, [decimal]$gross) {
    try {
        $tr = Invoke-Signed 'GET' '/api/v3/myTrades' ([ordered]@{ symbol = $Symbol; orderId = $orderId })
        return Fee-Summary $tr $price
    } catch {
        # sem o historico de negocios: estima pela taxa maker da conta (ordem LIMIT de venda)
        $est = $gross * $script:MakerFee
        Log "Aviso: nao consegui ler a taxa da ordem $orderId ($($_.Exception.Message)); estimando R$ $($est.ToString('0.00##', $Inv))."
        return @{ brl = $est; qtd = [decimal]0; total = $est; txt = ('R$ {0} (estimada)' -f $est.ToString('0.00##', $Inv)) }
    }
}

# "Comprado" = ha cripto suficiente para uma ordem (minimo da Binance, R$ 10). Com compra aberta, mede
# pelo preco de entrada: assim uma queda que deixe a posicao abaixo de R$ 10 nao faz o bot esquecer a
# compra nem encerrar por "saldo abaixo do minimo". Sobras de lote (sem compra aberta) usam o preco atual.
function In-Position($bal, [decimal]$bid) {
    $px = $bid
    if ($state.preco_entrada) { $px = D $state.preco_entrada }
    return ($bal.cripto * $px) -ge $MinNotional
}

# Precos das ordens de protecao a partir do preco de entrada
function Oco-Prices([decimal]$entry) {
    $tp = [decimal]::Ceiling($entry * (1 + [decimal]$s.TakeProfit) / $Tick) * $Tick
    $stop = Floor-Step ($entry * (1 - [decimal]$s.StopLoss)) $Tick
    $lim = Floor-Step ($stop * [decimal]0.995) $Tick   # margem para o stop conseguir executar
    return @{ tp = $tp; stop = $stop; lim = $lim }
}

function Place-Oco([decimal]$entry) {
    $b = Get-Balances
    $qty = Floor-Step $b.criptoLivre $Step
    $px = Oco-Prices $entry
    if ($UseStop) { $minPx = $px.lim } else { $minPx = $px.tp }
    if ($qty -lt $MinQty -or ($qty * $minPx) -lt $MinNotional) {
        Log 'Saldo pequeno demais para ordens de protecao; o bot vai vender sozinho enquanto estiver ligado.'
        return
    }
    $left = $b.criptoLivre - $qty
    if ($left -gt 0) {
        Log ("Obs.: {0} {1} (~R$ {2}) ficam fora da protecao: a Binance so vende em lotes de {3} {1}. Essa sobra continua no seu saldo." -f (Qty $left), $BaseAsset, (Brl ($left * $entry)), (Qty $Step))
    }
    if (-not $UseStop) {
        try {
            $r = Invoke-Signed 'POST' '/api/v3/order' ([ordered]@{
                symbol = $Symbol; side = 'SELL'; type = 'LIMIT'; timeInForce = 'GTC'
                quantity = (Qty $qty); price = (Qty $px.tp); newOrderRespType = 'RESULT' })
            $state.oco_id = [string]$r.orderId
            $state.protecao_tipo = 'limit'
            Save-State
            Log ("Ordem de venda criada na Binance: vende {0} {1} em R$ {2} (lucro). Sem stop: se o preco cair, o bot espera ele voltar." -f (Qty $qty), $BaseAsset, (Px $px.tp))
        } catch {
            Log "Nao consegui criar a ordem de venda ($($_.Exception.Message)). O bot vai vender sozinho enquanto estiver ligado."
        }
        return
    }
    try {
        $r = Invoke-Signed 'POST' '/api/v3/orderList/oco' ([ordered]@{
            symbol = $Symbol; side = 'SELL'; quantity = (Qty $qty)
            aboveType = 'LIMIT_MAKER'; abovePrice = (Qty $px.tp)
            belowType = 'STOP_LOSS_LIMIT'; belowStopPrice = (Qty $px.stop); belowPrice = (Qty $px.lim); belowTimeInForce = 'GTC' })
        $state.oco_id = [string]$r.orderListId
        $state.protecao_tipo = 'oco'
        Save-State
        Log ("Ordens de protecao criadas na Binance: vende {0} {1} em R$ {2} (lucro) ou stop em R$ {3}. Funcionam mesmo com o PC desligado." -f (Qty $qty), $BaseAsset, (Px $px.tp), (Px $px.stop))
    } catch {
        Log "Nao consegui criar as ordens de protecao ($($_.Exception.Message)). O bot vai vender sozinho enquanto estiver ligado."
    }
}

# Retorna $null se o OCO ainda esta aberto; senao @{ filled; type; qty; got (bruto, antes da taxa); id }
function Check-Oco {
    if ($state.protecao_tipo -eq 'limit') {
        $od = Invoke-Signed 'GET' '/api/v3/order' ([ordered]@{ symbol = $Symbol; orderId = $state.oco_id })
        if ($od.status -in 'NEW', 'PARTIALLY_FILLED', 'PENDING_NEW') { return $null }
        if ((D $od.executedQty) -gt 0) { return @{ filled = $true; type = $od.type; qty = (D $od.executedQty); got = (D $od.cummulativeQuoteQty); id = [string]$od.orderId } }
        return @{ filled = $false }
    }
    $l = Invoke-Signed 'GET' '/api/v3/orderList' ([ordered]@{ orderListId = $state.oco_id })
    if ($l.listOrderStatus -ne 'ALL_DONE') { return $null }
    foreach ($o in $l.orders) {
        $od = Invoke-Signed 'GET' '/api/v3/order' ([ordered]@{ symbol = $Symbol; orderId = $o.orderId })
        if ((D $od.executedQty) -gt 0) {
            return @{ filled = $true; type = $od.type; qty = (D $od.executedQty); got = (D $od.cummulativeQuoteQty); id = [string]$od.orderId }
        }
    }
    return @{ filled = $false }
}

function Cancel-Oco {
    try {
        if ($state.protecao_tipo -eq 'limit') {
            [void](Invoke-Signed 'DELETE' '/api/v3/order' ([ordered]@{ symbol = $Symbol; orderId = $state.oco_id }))
        } else {
            [void](Invoke-Signed 'DELETE' '/api/v3/orderList' ([ordered]@{ symbol = $Symbol; orderListId = $state.oco_id }))
        }
    }
    catch { Log "Aviso ao cancelar ordens de protecao: $($_.Exception.Message)" }
    $state.oco_id = ''
    Save-State
}

# $got = reais recebidos ja sem a taxa; $fees = resultado de Fee-Summary/Order-Fees
function Record-Sale([decimal]$price, [decimal]$qty, [decimal]$got, [string]$reason, [decimal]$brlBefore, $fees) {
    # preco_entrada pode estar vazio se a venda for registrada depois de um reinicio (ex.: PEPE, 20/10/2026)
    $varTxt = 'n/d'
    if ($state.preco_entrada) { $varTxt = Brl (($price / (D $state.preco_entrada) - 1) * 100) }
    $state.preco_entrada = ''
    $state.operacoes = [int]$state.operacoes + 1
    if ($Ledger -and $Mode -eq 'real') { Set-Own ((Get-Own) + $got) }   # na simulacao o Sell ja somou
    Save-State
    Log ("VENDA   ({0}) {1} {2} a R$ {3} (recebeu R$ {4}, taxa {5}, variacao {6}%)" -f $reason, (Qty $qty), $BaseAsset, (Px $price), (Brl $got), $fees.txt, $varTxt)
    Write-Trade "VENDA-$reason" $price $qty $got ($brlBefore + $got) $fees.total $fees.qtd
}

# Retorna o preco medio da compra.
function Buy([decimal]$ask, $bal) {
    $spend = [decimal]::Floor($bal.brl * 100) / 100
    if ($Mode -eq 'simulacao') {
        # Igual a Binance: compra em lotes inteiros de $Step e cobra a taxa no proprio cripto
        $qty = Floor-Step ($spend / $ask) $Step
        $spent = $qty * $ask
        # A Binance recusaria a ordem abaixo do minimo; a simulacao tambem recusa (nova tentativa em 1 min)
        if ($qty -lt $MinQty -or $spent -lt $MinNotional) {
            throw "Simulacao: compra de R$ $(Brl $spent) abaixo do minimo da Binance (R$ $(Brl $MinNotional))"
        }
        $price = $ask
        $fees = Fee-Summary @(@{ commission = ($qty * $SimFee).ToString($Inv); commissionAsset = $BaseAsset }) $price
        $state.brl = Brl ($bal.brl - $spent)
        $state.cripto = Qty ((D $state.cripto) + $qty - $fees.qtd)
    } else {
        $r = Invoke-Signed 'POST' '/api/v3/order' ([ordered]@{
            symbol = $Symbol; side = 'BUY'; type = 'MARKET'; quoteOrderQty = (Brl $spend); newOrderRespType = 'FULL' })
        $qty = D $r.executedQty
        $spent = D $r.cummulativeQuoteQty   # valor realmente gasto (a Binance arredonda para lotes inteiros)
        $price = $spent / $qty
        $fees = Fee-Summary $r.fills $price
        if ($Ledger) { Set-Own ((Get-Own) - $spent - $fees.brl) }
    }
    $state.preco_entrada = $price.ToString($Inv)
    $state.operacoes = [int]$state.operacoes + 1
    Save-State
    Log ("COMPRA  {0} {1} a R$ {2} | gastou R$ {3} | taxa {4}" -f (Qty $qty), $BaseAsset, (Px $price), (Brl $spent), $fees.txt)
    $leftBrl = $bal.brl - $spent
    if ($leftBrl -ge 0.01) {
        Log ("Obs.: R$ {0} ficaram em reais: a Binance so compra em lotes de {1} {2} (~R$ {3})." -f (Brl $leftBrl), (Qty $Step), $BaseAsset, (Brl ($Step * $price)))
    }
    Write-Trade 'COMPRA' $price $qty $spent ($bal.brl) $fees.total $fees.qtd
    return $price
}

# Retorna $true se vendeu.
function Sell([decimal]$bid, $bal, [string]$reason) {
    if ($Mode -eq 'simulacao') {
        $qty = Floor-Step $bal.cripto $Step
        $price = $bid
        $fees = Fee-Summary @(@{ commission = ($qty * $bid * $SimFee).ToString($Inv); commissionAsset = 'BRL' }) $price
        $got = $qty * $bid - $fees.brl
        $state.brl = Brl ($bal.brl + $got)
        $state.cripto = Qty ($bal.cripto - $qty)
    } else {
        $qty = Floor-Step $bal.criptoLivre $Step
        if ($qty -lt $MinQty -or ($qty * $bid) -lt $MinNotional) {
            Log "Nao foi possivel vender: quantidade abaixo do minimo da Binance."
            return $false
        }
        $r = Invoke-Signed 'POST' '/api/v3/order' ([ordered]@{
            symbol = $Symbol; side = 'SELL'; type = 'MARKET'; quantity = (Qty $qty); newOrderRespType = 'FULL' })
        $gross = D $r.cummulativeQuoteQty
        $price = $gross / (D $r.executedQty)
        $fees = Fee-Summary $r.fills $price
        $got = $gross - $fees.brl   # a taxa da venda sai dos reais recebidos
    }
    Record-Sale $price $qty $got $reason $bal.brl $fees
    return $true
}

# ---------- dados para o painel (bandeja.ps1) ----------

# Valor investido = depositos em BRL menos saques em BRL (historico fiat da Binance).
# Se a Binance nao retornar nada (ex.: Pix via parceiro), usa deposito_inicial_brl do config.
$script:Invested = $Deposit
$script:InvestedSrc = 'config'
$script:InvestedWarned = $false
if ($Ledger) { $script:Invested = D $state.investido_brl; $script:InvestedSrc = 'carteira' }
function Update-Invested {
    if ($Mode -ne 'real' -or $Ledger) { return }   # carteira propria: investido = deposito do bot + aportes
    try {
        $begin = ([DateTimeOffset](Parse-Date $state.inicio).AddDays(-60)).ToUnixTimeMilliseconds()
        $sum = [decimal]0; $found = $false
        foreach ($type in 0, 1) {   # 0 = depositos, 1 = saques
            $r = Invoke-Signed 'GET' '/sapi/v1/fiat/orders' ([ordered]@{ transactionType = $type; beginTime = $begin; rows = 500 })
            foreach ($o in $r.data) {
                if ($o.fiatCurrency -ne 'BRL' -or $o.status -ne 'Successful') { continue }
                $found = $true
                if ($type -eq 0) { $sum += D $o.amount } else { $sum -= D $o.indicatedAmount }
            }
        }
        if ($found -and $sum -gt 0) { $script:Invested = $sum; $script:InvestedSrc = 'binance' }
    } catch {
        if (-not $script:InvestedWarned) {
            $script:InvestedWarned = $true
            Log "Nao consegui ler o historico de depositos; o valor investido usa o config.json. ($($_.Exception.Message))"
        }
    }
}

# Grava um resumo atual em painel-<modo>.json (troca o arquivo de uma vez, sem leitura pela metade)
$PanelFile = Join-Path $Dir "painel-$Mode.json"
function Write-Panel([decimal]$bid, $bal, [decimal]$equity, [string]$situacao) {
    $o = [ordered]@{
        atualizado      = (Get-Date).ToString('s')
        preco           = $bid.ToString($Inv)
        brl             = $bal.brl.ToString($Inv)
        cripto          = (Qty $bal.cripto)
        ativo           = $BaseAsset
        patrimonio      = $equity.ToString($Inv)
        investido       = $script:Invested.ToString($Inv)
        investido_fonte = $script:InvestedSrc
        situacao        = $situacao
        brl_proprio     = (Get-Own).ToString($Inv)       # reais deste bot (carteira propria)
        # a moeda saiu da conta e a ordem de venda ainda nao foi conferida: os reais dela ainda nao
        # entraram em brl_proprio (a carteira.ps1 nao oferece distribuir enquanto isso)
        conferindo_venda = [bool]($state.oco_id -and -not (In-Position $bal $bid))
        brl_conta       = $bal.brlConta.ToString($Inv)   # reais livres na conta (todos os bots)
    }
    try {
        $tmp = "$PanelFile.tmp"
        $o | ConvertTo-Json | Set-Content -Path $tmp -Encoding ASCII
        Move-Item -Path $tmp -Destination $PanelFile -Force
    } catch {}   # painel lendo no mesmo instante: tenta de novo na proxima volta
}

function Finish([string]$why, [decimal]$equity) {
    $elapsed = (Get-Date) - (Parse-Date $state.inicio).ToLocalTime()
    $profit = $equity - $Deposit
    Log '=================== FIM ==================='
    Log "Motivo: $why"
    Log ("Tempo total desde o inicio: {0} dias, {1} h, {2} min" -f $elapsed.Days, $elapsed.Hours, $elapsed.Minutes)
    $pct = [decimal]0; if ($Deposit -gt 0) { $pct = $profit / $Deposit * 100 }
    Log ("Operacoes: {0} | Patrimonio: R$ {1} | Resultado: R$ {2} ({3}%)" -f $state.operacoes, (Brl $equity), (Brl $profit), (Brl $pct))
}

# Aporte (ou retirada, se negativo) de reais para este bot: a carteira.ps1 grava o valor em
# aporte-<modo>.txt; o bot soma no seu saldo proprio e no investido, e apaga o arquivo.
$AporteFile = Join-Path $Dir "aporte-$Mode.txt"
function Apply-Aporte {
    $txt = ''
    try { $txt = [IO.File]::ReadAllText($AporteFile).Trim(); [IO.File]::Delete($AporteFile) } catch { return }
    $v = [decimal]0
    if (-not [decimal]::TryParse($txt, [Globalization.NumberStyles]::Float, $Inv, [ref]$v)) { Log "AVISO: aporte invalido ignorado: '$txt'"; return }
    $own = Get-Own
    if ($own + $v -lt 0) { Log ("AVISO: retirada de R$ {0} recusada: este bot so tem R$ {1} em reais." -f (Brl (-$v)), (Brl $own)); return }
    Set-Own ($own + $v)
    $state.investido_brl = Qty ((D $state.investido_brl) + $v)
    $script:Invested = D $state.investido_brl
    Save-State
    Log ("APORTE R$ {0}: saldo proprio deste bot agora R$ {1}; investido R$ {2}." -f (Brl $v), (Brl (Get-Own)), (Brl $script:Invested))
}

# ---------- inicio ----------

if ($Target -gt 0) { $metaTxt = "meta R$ $(Brl $Target)" } else { $metaTxt = 'sem meta' }
Log "Iniciando em modo $($Mode.ToUpper()) | par $Symbol | $metaTxt | deposito base R$ $(Brl $Deposit) | proximo aviso em R$ $(Brl (Next-Milestone (D $state.ultimo_aviso)))"
if ($s.StopLoss -gt 0) { $stopTxt = "stop loss -$($s.StopLoss * 100)%" } else { $stopTxt = 'sem stop loss' }
Log ("Regras: compra se cair {0}% do topo dos ultimos {1} min | vende com +{2}% | {3} | tendencia {4} min | trailing {5}%" -f `
    ($s.Dip * 100), $s.WindowMin, ($s.TakeProfit * 100), $stopTxt, $s.TrendMin, ($s.Trail * 100))
if ($UseOco -and $UseStop) { Log 'Protecao ativada: depois de cada compra, a venda (lucro/stop) fica registrada na Binance.' }
elseif ($UseOco) { Log 'Depois de cada compra, a venda com lucro fica registrada na Binance (sem stop).' }

$script:MakerFee = [decimal]0.001   # taxas da conta (lidas abaixo no modo real); 0,1% se nao der para ler
$script:TakerFee = [decimal]0.001
if ($Mode -eq 'real') {
    $script:ApiKey = $env:BINANCE_API_KEY
    $script:ApiSecret = $env:BINANCE_API_SECRET
    if (-not $script:ApiKey -or -not $script:ApiSecret) {
        throw 'Defina as variaveis de ambiente BINANCE_API_KEY e BINANCE_API_SECRET (veja o LEIA-ME).'
    }
    try {
        $com = Invoke-Signed 'GET' '/api/v3/account/commission' ([ordered]@{ symbol = $Symbol })
        $script:MakerFee = D $com.standardCommission.maker
        $script:TakerFee = D $com.standardCommission.taker
        Log ("Taxa da sua conta em {0}: maker {1}% | taker (ordens a mercado) {2}%" -f $Symbol, ($script:MakerFee * 100).ToString('0.####', $Inv), ($script:TakerFee * 100).ToString('0.####', $Inv))
    } catch { Log "Nao consegui ler a taxa da conta: $($_.Exception.Message)" }
    $b = Get-Balances
    $px = D (Get-Public "/api/v3/ticker/bookTicker?symbol=$Symbol").bidPrice
    Log ("Saldo na conta: R$ {0} + {1} {2} (= R$ {3})" -f (Brl $b.brlConta), (Qty $b.cripto), $BaseAsset, (Brl ($b.brlConta + $b.cripto * $px)))
    if ($Ledger -and -not $state.brl_proprio) {
        # 1a execucao com carteira propria: os reais deste bot = deposito do config menos o custo da compra
        # aberta (ex.: BTC, R$ 20 - R$ 17,33 = R$ 2,67), nunca mais que os reais livres na conta.
        # Para as outras moedas o deposito do config e 0: os reais chegam por aporte (carteira.ps1).
        $own = $Deposit
        if ($state.preco_entrada -and $b.cripto -gt 0) { $own = $Deposit - $b.cripto * (D $state.preco_entrada) / ([decimal]1 - $script:TakerFee) }
        if ($own -gt $b.brlConta) { $own = $b.brlConta }
        if ($own -lt 0) { $own = [decimal]0 }
        Set-Own ([decimal]::Floor($own * 100) / 100)
        Save-State
        Log ("Carteira propria: R$ {0} dos R$ {1} livres na conta sao deste bot; o resto fica para os outros bots." -f (Brl (Get-Own)), (Brl $b.brlConta))
        $b = Get-Balances
    }
    if ($Ledger) { Log ("Reais deste bot: R$ {0} (investido R$ {1})." -f (Brl (Get-Own)), (Brl $script:Invested)) }
    Write-Host ''
    if (-not $SemConfirmacao) {
        Write-Host 'ATENCAO: modo REAL. O bot vai enviar ordens de compra e venda com o seu dinheiro.' -ForegroundColor Yellow
        $ok = Read-Host 'Digite SIM para continuar'
        if ($ok -ne 'SIM') { Log 'Cancelado pelo usuario.'; return }
    }
}

# Pre-carrega o historico recente (candles de 1 min) para nao comecar "cego".
$preMin = [int][Math]::Ceiling([Math]::Max([Math]::Max($s.WindowMin, $s.WarmupMin), $s.TrendMin * 3)) + 5
$from = (Now-Ms) - [long]$preMin * 60000
$loaded = 0
while ($true) {
    $k = Get-Public "/api/v3/klines?symbol=$Symbol&interval=1m&startTime=$from&limit=1000"
    foreach ($x in $k) {
        $ct = From-Ms ([long]$x[0])
        $o = [double]::Parse($x[1], $Inv); $h = [double]::Parse($x[2], $Inv); $l = [double]::Parse($x[3], $Inv); $c = [double]::Parse($x[4], $Inv)
        if ($c -ge $o) { $mid1 = $l; $mid2 = $h } else { $mid1 = $h; $mid2 = $l }
        $s.Feed($ct, $o); $s.Feed($ct.AddSeconds(15), $mid1); $s.Feed($ct.AddSeconds(30), $mid2); $s.Feed($ct.AddSeconds(45), $c)
        $loaded++
    }
    if ($k.Count -lt 1000) { break }
    $from = [long]$k[$k.Count - 1][0] + 60000
}
Log "Historico pre-carregado: $loaded minutos."

if ($state.preco_entrada) { $s.Bought([double](D $state.preco_entrada)) }
if ($state.pausa_ate) { $s.PauseUntil = Parse-Date $state.pausa_ate }

$lastStatus = [datetime]::MinValue
$lastBalRefresh = [datetime]::MinValue
$lastOcoCheck = [datetime]::MinValue
$ocoTried = $false
$lastInvCheck = [datetime]::MinValue
$lastPanel = [datetime]::MinValue
$nextOrderTry = [datetime]::MinValue
$lastCantBuyLog = [datetime]::MinValue
$orderErrNotified = $false
$errStreak = 0

# Se o stop foi ligado/desligado no config, troca a protecao que ja esta na Binance pela do tipo certo
# (o loop cria a nova logo em seguida, no mesmo preco de venda com lucro)
if ($UseOco -and $state.oco_id -and $state.protecao_tipo -ne $WantProtection) {
    if ($UseStop) { Log 'Stop ativado no config: trocando a ordem de venda atual por lucro + stop.' }
    else { Log 'Stop desativado no config: trocando a protecao atual (lucro + stop) por so a venda com lucro.' }
    Cancel-Oco
}
$bal = $null

while ($true) {
    if (Test-Path $StopFlag) {
        Remove-Item $StopFlag -Force
        if ($Mode -eq 'real') { Log 'Parado pelo usuario. As ordens de protecao (se houver) continuam ativas na Binance.' }
        else { Log 'Parado pelo usuario.' }
        break
    }
    try {
        $now = [datetime]::UtcNow
        if ($Ledger -and (Test-Path $AporteFile)) { Apply-Aporte; $lastBalRefresh = [datetime]::MinValue }
        $t = Get-Public "/api/v3/ticker/bookTicker?symbol=$Symbol"
        $bid = D $t.bidPrice
        $ask = D $t.askPrice

        # Na simulacao o saldo vem do estado; no modo real, da Binance a cada 60s ou apos ordens.
        if ($Mode -eq 'simulacao' -or ($now - $lastBalRefresh).TotalSeconds -ge 60) {
            $bal = Get-Balances
            $lastBalRefresh = $now
        }
        $equity = $bal.brl + $bal.cripto * $bid
        $inPos = In-Position $bal $bid

        # Confere se as ordens de protecao na Binance executaram (inclusive com o PC desligado)
        # Confere a cada 15 s; e logo (a cada 3 s) se a moeda sumiu da conta, que quase sempre e a ordem
        # que executou. Antes (ate 21/10/2026) o bot podia limpar o preco de entrada antes de conferir
        # e a venda nao era registrada (PEPE, 20/10 13:44).
        $ocoDue = ($now - $lastOcoCheck).TotalSeconds -ge 15
        if (-not $inPos -and ($now - $lastOcoCheck).TotalSeconds -ge 3) { $ocoDue = $true }
        if ($state.oco_id -and $ocoDue) {
            $lastOcoCheck = $now
            $res = Check-Oco
            if ($res) {
                $state.oco_id = ''
                if ($res.filled) {
                    if ($res.type -in 'LIMIT_MAKER', 'LIMIT') { $reason = 'lucro' } else { $reason = 'stop' }
                    $sellPx = $res.got / $res.qty
                    $fees = Order-Fees $res.id $sellPx $res.got
                    Record-Sale $sellPx $res.qty ($res.got - $fees.brl) $reason $bal.brl $fees
                    $s.Sold($now, $reason -eq 'stop')
                    if ($reason -eq 'stop') { $state.pausa_ate = $s.PauseUntil.ToString('o'); Save-State }
                } else {
                    Save-State
                    Log 'As ordens de protecao foram canceladas fora do bot; o bot volta a vender sozinho.'
                }
                $bal = Get-Balances
                $lastBalRefresh = $now
                $equity = $bal.brl + $bal.cripto * $bid
                $inPos = In-Position $bal $bid
            }
        }

        # Avisos de patamar so no bot unico; na carteira (varios bots) a bandeja avisa as vendas
        if (-not $Ledger) { Check-Milestones $equity }

        if ($Target -gt 0 -and $equity -ge $Target) {
            if ($state.oco_id) { Cancel-Oco; $bal = Get-Balances }
            if ($inPos) { [void](Sell $bid $bal 'meta'); $bal = Get-Balances; $equity = $bal.brl + $bal.cripto * $bid }
            Finish 'META ATINGIDA' $equity
            break
        }
        # Sem moeda e sem reais para uma ordem: o bot unico encerra; na carteira, espera um aporte
        $lowFunds = (-not $inPos) -and ($bal.brl -lt $MinNotional)
        if ($lowFunds -and -not $Ledger) {
            Finish "Saldo abaixo do minimo de ordem da Binance (R$ $(Brl $MinNotional))" $equity
            break
        }

        # Mantem a estrategia sincronizada com o saldo real (ex.: se voce mexer na conta)
        if ($inPos -and -not $s.InPosition) {
            if (-not $state.preco_entrada) {
                $state.preco_entrada = $bid.ToString($Inv); Save-State
                Log 'Ja havia cripto na conta; usando o preco atual como preco de entrada.'
            }
            $s.Bought([double](D $state.preco_entrada))
        } elseif (-not $inPos -and $s.InPosition -and -not $state.oco_id) {
            # (com ordem de venda registrada, quem resolve e o Check-Oco: ele registra a venda)
            $s.InPosition = $false
            $state.preco_entrada = ''; Save-State
        }
        if ($UseOco -and $inPos -and -not $state.oco_id -and -not $ocoTried) {
            $ocoTried = $true
            Place-Oco (D $state.preco_entrada)
        }

        $traded = $false
        $action = $s.OnTick($now, [double]$bid, [double]$ask)
        if ($action -and $now -lt $nextOrderTry) { $action = '' }   # espera depois de uma ordem recusada
        # Antes de comprar, confere se o saldo forma um lote valido (a Binance compra em lotes inteiros e
        # exige R$ 10). Ex. 15/10/2026: R$ 10,27 em NEAR (lote 0,1 = R$ 2,68) so comprava R$ 8,02.
        # Nesse caso espera (o preco pode mudar e permitir) em vez de mandar ordens que seriam recusadas.
        $cantBuy = ''
        if ($action -eq 'BUY' -and $lowFunds) { $action = '' }   # carteira sem reais: so espera o aporte
        if ($action -eq 'BUY') {
            $q = Floor-Step ($bal.brl / $ask) $Step
            if ($q -lt $MinQty -or ($q * $ask) -lt $MinNotional) {
                $action = ''
                $cantBuy = "R$ {0} so compram {1} {2} (R$ {3}), abaixo do minimo de R$ {4} da Binance" -f (Brl $bal.brl), (Qty $q), $BaseAsset, (Brl ($q * $ask)), (Brl $MinNotional)
                if (($now - $lastCantBuyLog).TotalMinutes -ge 60) {
                    $lastCantBuyLog = $now
                    Log "Sinal de compra, mas $cantBuy. Aguardando um preco que permita um lote valido."
                }
            }
        }
        try {
        if ($action -eq 'BUY') {
            $price = Buy $ask $bal
            $s.Bought([double]$price)
            if ($UseOco) { $ocoTried = $true; Place-Oco $price }
            $traded = $true
        } elseif ($action -eq 'SELL') {
            $reason = $s.Reason
            $doSell = $true
            if ($state.oco_id) {
                # A Binance ja cuida da venda. So intervem se o preco despencar abaixo do limite do stop
                # (nesse caso a ordem stop-limite pode nao executar).
                $doSell = ($reason -eq 'stop') -and ($bid -lt (Oco-Prices (D $state.preco_entrada)).lim)
                if ($doSell) {
                    Log 'Preco caiu abaixo do limite do stop; cancelando a protecao e vendendo a mercado.'
                    Cancel-Oco
                    $bal = Get-Balances
                }
            }
            if ($doSell -and (Sell $bid $bal $reason)) {
                $s.Sold($now, $reason -eq 'stop')
                if ($reason -eq 'stop') { $state.pausa_ate = $s.PauseUntil.ToString('o'); Save-State }
                $traded = $true
            }
        }
        if ($traded) { $orderErrNotified = $false }
        } catch {
            # Ordem recusada: registra, avisa uma vez e tenta de novo depois, sem travar o status
            if ($action -eq 'BUY') { $kind = 'compra' } else { $kind = 'venda' }
            $msg = $_.Exception.Message
            if ($msg -match '"msg":"([^"]+)"') { $short = $matches[1] } else { $short = $msg }
            if ($msg -match '-2015') { $short += ' (confira na Binance a permissao de negociacao e o IP liberado da chave de API)' }
            Log "ERRO na ordem de $kind : $short -- nova tentativa em 1 min"
            if (-not $orderErrNotified) {
                $orderErrNotified = $true
                Notify "Bot ${BaseAsset}: $kind recusada" "A Binance recusou a ordem: $short"
            }
            $nextOrderTry = $now.AddMinutes(1)
            $lastBalRefresh = [datetime]::MinValue
        }

        if ($traded) {
            $bal = Get-Balances
            $lastBalRefresh = $now
            $equity = $bal.brl + $bal.cripto * $bid
        }

        if ($s.InPosition) {
            # Com a ordem registrada na Binance, mostra o preco exato dela (arredondado ao passo de preco do
            # par, ex.: NEAR 27,4085 -> 27,41), e nao o alvo calculado
            $tpShow = [decimal]($s.Entry * (1 + $s.TakeProfit))
            if ($state.oco_id) { $tpShow = (Oco-Prices ([decimal]$s.Entry)).tp }
            $pos = "comprado a R$ {0}, vende em R$ {1}" -f (Px ([decimal]$s.Entry)), (Px $tpShow)
            if ($UseStop) { $pos += " ou stop em R$ {0}" -f (Px ([decimal]($s.Entry * (1 - $s.StopLoss)))) } else { $pos += ', sem stop' }
            if ($state.oco_id) { $pos += ' (registrado na Binance)' }
        } else {
            $pos = "em BRL, compra abaixo de R$ {0}" -f (Px ([decimal]($s.WindowTop * (1 - $s.Dip))))
            if (-not $s.TrendOk([double](($bid + $ask) / 2))) { $pos += ' (tendencia de baixa: aguardando)' }
            if ($cantBuy) { $pos += " | lote minimo: $cantBuy" }
            if ($lowFunds) { $pos = "aguardando reais: este bot tem R$ {0} (minimo R$ {1} para comprar)" -f (Brl $bal.brl), (Brl $MinNotional) }
        }
        if (($now - $lastInvCheck).TotalMinutes -ge 10) { $lastInvCheck = $now; Update-Invested }
        if ($traded -or ($now - $lastPanel).TotalSeconds -ge 5) { $lastPanel = $now; Write-Panel $bid $bal $equity $pos }

        if (($now - $lastStatus).TotalSeconds -ge 30) {
            $lastStatus = $now
            $pctRef = $Deposit; if ($Ledger) { $pctRef = $script:Invested }
            $pct = [decimal]0; if ($pctRef -gt 0) { $pct = ($equity / $pctRef - 1) * 100 }
            Log ("preco R$ {0} | patrimonio R$ {1} ({2}%) | {3}" -f (Px $bid), (Brl $equity), (Brl $pct), $pos)
        }
        $errStreak = 0
    } catch {
        $errStreak++
        Log "ERRO: $($_.Exception.Message) -- tentando de novo em 10s"
        if ($errStreak -eq 20) { Notify "Bot $BaseAsset com problemas" "20 erros seguidos (ex.: sem internet). Ultimo: $($_.Exception.Message)" }
        $lastBalRefresh = [datetime]::MinValue
        Start-Sleep -Seconds 10
    }
    Start-Sleep -Seconds $Interval
}
