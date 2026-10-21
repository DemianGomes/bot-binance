# Carteira com várias moedas: um bot.ps1 escondido por moeda, cada um na sua pasta, e um painel só.
#
# -Modo simulacao (atalho "Bot Simulação", robô AMARELO): dinheiro de mentira, preços reais.
#   Moedas em simulacao\moedas.json ({ "par", "valor_brl" }); pastas simulacao\<PAR>\.
#   Cada bot roda com -SoSimulacao (recusa iniciar se o config não estiver em simulação).
#
# -Modo real (atalho "Bot", robô verde-água): DINHEIRO REAL na conta Binance do usuário.
#   Moedas em real\moedas.json. O BTC usa a pasta principal (config.json, estado-real.json…) e tem
#   "reservado_brl" (R$ 20 do usuário); as outras moedas usam pastas real\<PAR>\ e dividem os reais
#   livres da conta conforme o "peso" de cada uma, por aportes que o usuário confirma.
#   Todos os bots usam "carteira_propria": cada um só gasta os reais que são dele.
#   O bot antigo (bandeja.ps1, que usa todo o saldo) não pode rodar junto.
#
# Uso: powershell -WindowStyle Hidden -ExecutionPolicy Bypass -File carteira.ps1 [-Modo real] [-AbrirPainel]

param([ValidateSet('simulacao', 'real')][string]$Modo = 'simulacao', [switch]$AbrirPainel)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Dir = $PSScriptRoot
$IsReal = $Modo -eq 'real'
if ($IsReal) { $SimDir = Join-Path $Dir 'real' } else { $SimDir = Join-Path $Dir 'simulacao' }
$ListFile = Join-Path $SimDir 'moedas.json'
$Inv = [Globalization.CultureInfo]::InvariantCulture
$Pt = [Globalization.CultureInfo]::GetCultureInfo('pt-BR')
if ($IsReal) { $AppTitle = 'Bot Carteira' } else { $AppTitle = 'Bot Simulação' }

function Ask([string]$text, [string]$icon = 'Question') {
    return [System.Windows.Forms.MessageBox]::Show($text, $AppTitle, 'YesNo', $icon) -eq 'Yes'
}
function Mutex-Exists([string]$name) {
    try { $mx = [System.Threading.Mutex]::OpenExisting($name); $mx.Dispose(); return $true } catch { return $false }
}

# Só uma carteira de cada modo aberta por vez. A real não pode rodar junto com o bot antigo (bandeja.ps1),
# que usa todo o saldo da conta. (O bot.ps1 também confere isso, por segurança.)
if ($IsReal) {
    if ((Mutex-Exists 'Global\BotBTC-Bandeja') -or (Mutex-Exists 'Global\BotBTC-real')) {
        [void][System.Windows.Forms.MessageBox]::Show("O bot antigo (só BTC) ainda está aberto.`n`nFeche-o antes: botão direito no robô verde da bandeja → Sair. Depois abra este atalho de novo.", $AppTitle)
        return
    }
    $trayName = 'Global\BotBTC-Carteira-Bandeja'
} else { $trayName = 'Global\BotBTC-Simulacao-Bandeja' }
$script:trayMutex = New-Object System.Threading.Mutex($false, $trayName)
try { $own = $script:trayMutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $own = $true }
if (-not $own) {
    if ($IsReal) { $where = 'o robô verde' } else { $where = 'o robô amarelo' }
    [void][System.Windows.Forms.MessageBox]::Show("Já está aberto. Procure $where na bandeja, perto do relógio (seta ^).", $AppTitle)
    return
}

# ---------- moedas e configs ----------

New-Item -ItemType Directory -Force $SimDir | Out-Null
if (-not (Test-Path $ListFile)) {
    if ($IsReal) {
        $def = [ordered]@{ moedas = @(
            [ordered]@{ par = 'BTCBRL'; reservado_brl = 20; pasta = '.' },
            [ordered]@{ par = 'SOLBRL'; peso = 11.5 }, [ordered]@{ par = 'NEARBRL'; peso = 16 },
            [ordered]@{ par = 'PEPEBRL'; peso = 11 }, [ordered]@{ par = 'SUIBRL'; peso = 11.5 }) }
    } else { $def = [ordered]@{ valor_por_moeda_brl = 12.5; moedas = @('SOLBRL', 'NEARBRL', 'PEPEBRL', 'SUIBRL') } }
    [IO.File]::WriteAllText($ListFile, ($def | ConvertTo-Json -Depth 4), [Text.Encoding]::ASCII)
}
$list = Get-Content $ListFile -Raw | ConvertFrom-Json
$DefaultValue = 12.5
if ($list.PSObject.Properties['valor_por_moeda_brl']) { $DefaultValue = [double]$list.valor_por_moeda_brl }
# "moedas" aceita "PAR" (usa valor_por_moeda_brl) ou objetos:
#   simulação: { "par": "PAR", "valor_brl": 16 }
#   real:      { "par": "BTCBRL", "reservado_brl": 20, "pasta": "." }  (reais fixos do usuário para a moeda)
#              { "par": "SOLBRL", "peso": 11.5 }  (fatia dos reais livres da conta, proporcional ao peso)
# Cada moeda precisa de ~R$ 10 + 2 lotes: um lote fica parado pela taxa cobrada na moeda e outro se perde
# no arredondamento da compra (NEAR, lote de 0,1 = ~R$ 2,68, travou com R$ 12,50 em 15/10/2026).
function Get-Prop($o, [string]$name, $default) {
    if ($o.PSObject.Properties[$name]) { return $o.$name }
    return $default
}
$coinList = @(foreach ($m in $list.moedas) {
    if ($m -is [string]) { @{ par = $m.ToUpper(); valor = $DefaultValue; peso = 0.0; pasta = '' } }
    else {
        @{ par = ([string]$m.par).ToUpper(); pasta = [string](Get-Prop $m 'pasta' '')
           valor = [double](Get-Prop $m 'valor_brl' (Get-Prop $m 'reservado_brl' 0)); peso = [double](Get-Prop $m 'peso' 0) }
    }
})
$mainCfg = Get-Content (Join-Path $Dir 'config.json') -Raw | ConvertFrom-Json

# O bot.ps1 de uma pasta de simulação está rodando? (mesmo nome de mutex que o bot.ps1 usa)
function Bot-Mutex-Held([string]$cd) {
    $md5 = [Security.Cryptography.MD5]::Create()
    $name = 'Global\BotBTC-simulacao-' + (-join ($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($cd.ToLowerInvariant())) | Select-Object -First 6 | ForEach-Object { $_.ToString('x2') }))
    try { $mx = [System.Threading.Mutex]::OpenExisting($name); $mx.Dispose(); return $true } catch { return $false }
}

# Muda o valor de uma moeda que já tem histórico: soma/subtrai a diferença no saldo em reais simulado
# (como um depósito/saque) e mantém o resultado acumulado. Só com o bot dela parado e se houver reais.
function Adjust-Coin([string]$cd, [string]$cf, $cc, [double]$valor) {
    $old = [double]$cc.deposito_inicial_brl
    $delta = $valor - $old
    $sf = Join-Path $cd 'estado-simulacao.json'
    if (Test-Path $sf) {
        if (Bot-Mutex-Held $cd) { return 'ajuste de valor adiado: o bot desta moeda ainda está rodando' }
        $st = Get-Content $sf -Raw | ConvertFrom-Json
        $brl = [double]::Parse([string]$st.brl, $Inv)
        if ($brl + $delta -lt 0) {
            return 'ajuste de valor adiado: a moeda está comprada agora e só há {0} em reais' -f ('R$ ' + $brl.ToString('N2', $Pt))
        }
        $st.brl = ($brl + $delta).ToString('0.00', $Inv)
        [IO.File]::WriteAllText($sf, ($st | ConvertTo-Json), [Text.Encoding]::ASCII)
    }
    $cc.deposito_inicial_brl = $valor
    [IO.File]::WriteAllText($cf, ($cc | ConvertTo-Json), [Text.Encoding]::ASCII)
    $line = '[{0}] SIMULACAO: valor mudou de R$ {1} para R$ {2} ({3} simulado de R$ {4}; resultado mantido)' -f `
        (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $old.ToString('0.00', $Inv), $valor.ToString('0.00', $Inv), $(if ($delta -ge 0) { 'deposito' } else { 'saque' }), ([Math]::Abs($delta)).ToString('0.00', $Inv)
    try { [IO.File]::AppendAllText((Join-Path $cd 'log-simulacao.txt'), $line + "`r`n", [Text.Encoding]::Default) } catch {}
    return ''
}

# Cria <pasta>\<PAR>\config.json na primeira vez, com a mesma estratégia do config.json principal.
# Depois disso só o valor da moeda pode mudar (via moedas.json, na simulação); a estratégia não muda
# no meio do teste. "pasta": "." usa a pasta principal (no real: o BTC, com o histórico que já existe).
function Prepare-Coin($ci) {
    $sym = $ci.par
    if ($ci.pasta -eq '.') { $cd = $Dir } else { $cd = Join-Path $SimDir $sym }
    New-Item -ItemType Directory -Force $cd | Out-Null
    $cf = Join-Path $cd 'config.json'
    if (-not (Test-Path $cf)) {
        $c = [ordered]@{}
        foreach ($p in $mainCfg.PSObject.Properties) { $c[$p.Name] = $p.Value }
        $c['modo'] = $Modo; $c['par'] = $sym; $c['meta_brl'] = 0; $c['carteira_propria'] = $true
        # no real, as moedas sem reserva começam com R$ 0 e recebem os reais por aporte
        $c['deposito_inicial_brl'] = $ci.valor
        [IO.File]::WriteAllText($cf, ($c | ConvertTo-Json), [Text.Encoding]::ASCII)
    }
    $cc = Get-Content $cf -Raw | ConvertFrom-Json
    # Todos os bots daqui usam carteira própria (configs antigos da simulação ganham a chave)
    if (-not $cc.PSObject.Properties['carteira_propria']) {
        $cc | Add-Member -NotePropertyName carteira_propria -NotePropertyValue $true
        [IO.File]::WriteAllText($cf, ($cc | ConvertTo-Json), [Text.Encoding]::ASCII)
    }
    $ok = (([string]$cc.modo).ToLower() -eq $Modo) -and (([string]$cc.par).ToUpper() -eq $sym) -and [bool]$cc.carteira_propria
    $note = ''
    if (-not $ok) { $note = "o config.json desta moeda não está em modo $Modo com carteira própria" }
    if ($ok -and -not $IsReal -and [Math]::Abs([double]$cc.deposito_inicial_brl - $ci.valor) -ge 0.005) {
        $note = Adjust-Coin $cd $cf $cc $ci.valor
        $cc = Get-Content $cf -Raw | ConvertFrom-Json
    }
    return @{
        sym = $sym; short = ($sym -replace 'BRL$', ''); dir = $cd; cfg = $cf; ok = $ok; note = $note
        deposit = [double]$cc.deposito_inicial_brl; fee = [double]$cc.taxa_simulacao_pct / 100; peso = $ci.peso
        log = (Join-Path $cd "log-$Modo.txt"); err = (Join-Path $cd "erro-bot-$Modo.txt")
        flag = (Join-Path $cd "parar-$Modo.flag"); panel = (Join-Path $cd "painel-$Modo.json")
        state = (Join-Path $cd "estado-$Modo.json"); trades = (Join-Path $cd "operacoes-$Modo.csv")
        aporte = (Join-Path $cd "aporte-$Modo.txt")
        proc = $null; userStopped = $false; restartAt = $null; restarts = @(); exitNotified = $false; why = ''
        logPos = -1
    }
}
$script:bots = New-Object System.Collections.ArrayList
foreach ($ci in $coinList) { [void]$script:bots.Add((Prepare-Coin $ci)) }
$TotalDeposit = 0.0; foreach ($bt in $script:bots) { $TotalDeposit += $bt.deposit }
$SumPeso = 0.0; foreach ($bt in $script:bots) { $SumPeso += $bt.peso }

# ---------- controle dos bots ----------

function Bot-Running($b) { return $b.proc -and -not $b.proc.HasExited }
function Running-Count { return @($script:bots | Where-Object { Bot-Running $_ }).Count }

# Escreve no log da moeda (aparece no painel como aviso)
function Append-CoinLog($b, [string]$msg) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    for ($i = 0; $i -lt 5; $i++) {
        try { [IO.File]::AppendAllText($b.log, $line + "`r`n", [Text.Encoding]::Default); return } catch { Start-Sleep -Milliseconds 200 }
    }
}

function Start-Coin($b) {
    if (-not $b.ok) { $b.why = $b.note; return }
    if (Bot-Running $b) { return }
    $b.userStopped = $false; $b.restartAt = $null; $b.exitNotified = $false; $b.why = ''
    if (Test-Path $b.flag) { Remove-Item $b.flag -Force }
    # simulação: -SoSimulacao (o bot recusa se o config estiver em real). Real: o usuário já confirmou ao abrir.
    $botArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Dir\bot.ps1`" -Config `"$($b.cfg)`" -SemConfirmacao"
    if (-not $IsReal) { $botArgs += ' -SoSimulacao' }
    $b.proc = Start-Process powershell.exe -ArgumentList $botArgs -WindowStyle Hidden -PassThru -RedirectStandardError $b.err
    $null = $b.proc.Handle   # sem isso o PowerShell 5.1 perde o ExitCode quando o processo termina
}
function Start-All { foreach ($b in $script:bots) { Start-Coin $b } }

function Stop-All {
    $running = @($script:bots | Where-Object { Bot-Running $_ })
    foreach ($b in $script:bots) { $b.userStopped = $true; $b.restartAt = $null }
    foreach ($b in $running) { New-Item -ItemType File -Path $b.flag -Force | Out-Null }   # cada bot termina a volta e sai
    foreach ($b in $running) { if (-not $b.proc.WaitForExit(20000)) { $b.proc.Kill() } }
}

# ---------- leitura de arquivos que os bots estão escrevendo ----------

function Read-Shared([string]$path) {
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite, Delete')
    try { return (New-Object IO.StreamReader($fs, [Text.Encoding]::Default)).ReadToEnd() } finally { $fs.Dispose() }
}
function Read-Json([string]$path) {
    try { return (Read-Shared $path) | ConvertFrom-Json } catch { return $null }
}
function Tail-Lines([string]$path, [int]$n) {
    if (-not (Test-Path $path)) { return @() }
    try {
        $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite, Delete')
        try {
            if ($fs.Length -gt 65536) { [void]$fs.Seek(-65536, 'End') }
            $all = (New-Object IO.StreamReader($fs, [Text.Encoding]::Default)).ReadToEnd()
        } finally { $fs.Dispose() }
    } catch { return @() }
    return @($all.Split("`n") | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_ -match '^\[' } | Select-Object -Last $n)
}
# Lucro real (vendas já feitas) e projetado (moedas que temos agora), pelo custo médio, a partir do
# operacoes-<modo>.csv:
#   compra: custo += quantidade × preço; quantidade += comprada − taxa cobrada na moeda (coluna taxa_qtd;
#           em históricos antigos, estimada pela taxa do config)
#   venda:  lucro real += recebido (já sem a taxa) − custo médio × vendido; custo e quantidade diminuem
#   projetado = moedas que temos × preço de agora − custo que sobrou (inclui sobras de lote)
# Lucro real + projetado = valor total − depositado. (O custo é quantidade × preço, e não valor_brl, porque
# a 1ª compra real de BTC, em 05/10, ficou registrada com R$ 20,00 em vez dos R$ 17,33 gastos.)
function Coin-Pnl($b, $pj, $st) {
    $r = @{ buys = 0; sells = 0; real = 0.0; proj = 0.0; fees = 0.0 }
    $qtyHeld = 0.0; $costHeld = 0.0; $text = ''
    try { $text = Read-Shared $b.trades } catch {}
    foreach ($l in $text.Split("`n")) {
        $f = $l.Trim().Split(',')
        if ($f.Count -lt 6) { continue }
        if ($f.Count -ge 7 -and $f[6] -match '^[\d.]+$') { $r.fees += [double]::Parse($f[6], $Inv) }
        elseif ($f[1] -eq 'COMPRA') { $r.fees += [double]::Parse($f[3], $Inv) * [double]::Parse($f[2], $Inv) * $b.fee }   # linha antiga: estimada
        elseif ($f[1] -like 'VENDA*') { $r.fees += [double]::Parse($f[4], $Inv) / (1 - $b.fee) * $b.fee }
        if ($f[1] -eq 'COMPRA') {
            $q = [double]::Parse($f[3], $Inv)
            if ($f.Count -ge 8 -and $f[7] -match '^[\d.]+$') { $qtyHeld += $q - [double]::Parse($f[7], $Inv) }
            else { $qtyHeld += $q * (1 - $b.fee) }
            $costHeld += $q * [double]::Parse($f[2], $Inv)
            $r.buys++
        } elseif ($f[1] -like 'VENDA*') {
            $q = [double]::Parse($f[3], $Inv)
            $costSold = 0.0
            if ($qtyHeld -gt 0) { $costSold = $costHeld * [Math]::Min(1.0, $q / $qtyHeld) }
            $r.real += [double]::Parse($f[4], $Inv) - $costSold
            $costHeld -= $costSold; $qtyHeld = [Math]::Max(0.0, $qtyHeld - $q)
            $r.sells++
        }
    }
    if ($pj) {
        $cr = [double]::Parse($pj.cripto, $Inv)
        # sem compra no histórico (arquivo perdido/apagado), mas com moeda comprada: usa o preço de entrada
        if ($r.buys -eq 0 -and $cr -gt 0 -and $st -and $st.preco_entrada) { $costHeld = $cr * [double]::Parse([string]$st.preco_entrada, $Inv) }
        $r.proj = $cr * [double]::Parse($pj.preco, $Inv) - $costHeld
    }
    return $r
}

# Linhas novas do log de uma moeda desde a última leitura (para as notificações do modo real)
function Read-NewLines($b) {
    if (-not (Test-Path $b.log)) { return @() }
    $text = ''
    try {
        $fs = [IO.File]::Open($b.log, 'Open', 'Read', 'ReadWrite, Delete')
        try {
            if ($b.logPos -lt 0) { $b.logPos = $fs.Length; return @() }   # 1a leitura: só o que vier depois
            if ($fs.Length -lt $b.logPos) { $b.logPos = 0 }                # log foi rotacionado
            [void]$fs.Seek($b.logPos, 'Begin')
            $text = (New-Object IO.StreamReader($fs, [Text.Encoding]::Default)).ReadToEnd()
        } finally { $fs.Dispose() }
    } catch { return @() }
    $cut = $text.LastIndexOf("`n")
    if ($cut -lt 0) { return @() }   # linha ainda sendo escrita
    $b.logPos += $cut + 1            # log em ANSI: 1 byte por caractere
    return @($text.Substring(0, $cut).Split("`n") | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_ })
}

# ---------- reais livres e aportes (só no modo real) ----------

# Reais livres na conta que não são de nenhum bot = reais livres − soma dos reais de cada bot.
# Vem dos painel-real.json; só vale se todos os bots gravaram depois de $after (senão $null).
function Get-Unallocated([datetime]$after) {
    $free = 0.0; $freeAt = [datetime]::MinValue; $owned = 0.0
    foreach ($b in $script:bots) {
        if (-not $b.ok) { continue }
        $pj = Read-Json $b.panel
        if (-not $pj -or -not $pj.PSObject.Properties['brl_conta']) { return $null }
        $at = [datetime]::Parse($pj.atualizado, $Inv)
        if ($at -lt $after) { return $null }
        # moeda vendida na Binance mas a venda ainda não registrada: os reais dela parecem "sem dono"
        if ($pj.PSObject.Properties['conferindo_venda'] -and $pj.conferindo_venda) { return $null }
        $owned += [double]::Parse($pj.brl_proprio, $Inv)
        if ($at -gt $freeAt) { $freeAt = $at; $free = [double]::Parse($pj.brl_conta, $Inv) }
    }
    return @{ free = $free; owned = $owned; unalloc = $free - $owned }
}

# Manda R$ $v para o bot de uma moeda: ele soma no saldo próprio e no investido (aporte-real.txt)
function Send-Aporte($b, [double]$v) {
    $cur = 0.0
    if (Test-Path $b.aporte) { try { $cur = [double]::Parse([IO.File]::ReadAllText($b.aporte).Trim(), $Inv) } catch {} }
    $tmp = "$($b.aporte).tmp"
    [IO.File]::WriteAllText($tmp, ($cur + $v).ToString('0.00', $Inv), [Text.Encoding]::ASCII)
    Move-Item -Path $tmp -Destination $b.aporte -Force
    Append-CoinLog $b ("CARTEIRA: aporte de R$ {0} enviado para este bot" -f $v.ToString('0.00', $Inv))
}

# Pergunta se distribui os reais sem dono entre as moedas com "peso" (o BTC tem reserva fixa, fica fora)
function Offer-Distribution($u) {
    $targets = @($script:bots | Where-Object { $_.ok -and $_.peso -gt 0 })
    if ($targets.Count -eq 0 -or $SumPeso -le 0) { return }
    $amount = [Math]::Floor($u.unalloc * 100) / 100
    $parts = @(foreach ($b in $targets) { [Math]::Floor($amount * $b.peso / $SumPeso * 100) / 100 })
    $lines = for ($i = 0; $i -lt $targets.Count; $i++) { '   {0}: {1}' -f $targets[$i].short, (Money $parts[$i]) }
    $msg = "Há {0} em reais livres na sua conta que ainda não são de nenhum bot.`n(Os reais do BTC ficam de fora: ele continua só com a reserva dele.)`n`nDistribuir assim?`n`n{1}`n`nCada bot só usa a parte dele. Se escolher Não, os reais ficam parados na conta." -f (Money $amount), ($lines -join "`n")
    if (-not (Ask $msg 'Warning')) { return }
    for ($i = 0; $i -lt $targets.Count; $i++) { if ($parts[$i] -gt 0) { Send-Aporte $targets[$i] $parts[$i] } }
}

# ---------- aparência (mesma do painel do bot real, com destaque amarelo) ----------

function Col([int]$r, [int]$g, [int]$b) { return [System.Drawing.Color]::FromArgb($r, $g, $b) }
$Clr = @{
    bg = (Col 11 17 32); card = (Col 22 32 51); line = (Col 36 50 74)
    text = (Col 226 232 240); muted = (Col 140 154 178); accent = (Col 45 212 191)
    green = (Col 74 222 128); red = (Col 248 113 113); amber = (Col 251 191 36)
}
function Fnt([float]$size, [string]$style = 'Regular', [string]$family = 'Segoe UI') {
    return New-Object System.Drawing.Font($family, $size, [System.Drawing.FontStyle]$style)
}
function Money([double]$v) { return 'R$ ' + $v.ToString('N2', $Pt) }
# Preço de 1 unidade: moedas baratas (PEPE) precisam de mais casas
function PxPt([double]$v) {
    if ($v -ge 100) { $f = 'N2' } elseif ($v -ge 1) { $f = '#,##0.00##' } else { $f = '0.00######' }
    return 'R$ ' + $v.ToString($f, $Pt)
}
# Troca "R$ 0.00004523" (formato do log) por "R$ 0,00004523"
function Pretty([string]$s) {
    return [regex]::Replace($s, 'R\$ (\d+(\.\d+)?)', { param($m) PxPt ([double]::Parse($m.Groups[1].Value, $Inv)) })
}
function Signed([double]$v) {
    if ($v -lt 0) { return '−' + (Money ([Math]::Abs($v))) }
    return '+' + (Money $v)
}
function Pct([double]$v) {
    if ($v -lt 0) { return '−' + [Math]::Abs($v).ToString('N2', $Pt) + '%' }
    return '+' + $v.ToString('N2', $Pt) + '%'
}
function Result-Color([double]$v) {
    if ([Math]::Abs($v) -lt 0.005) { return $Clr.text }
    if ($v -gt 0) { return $Clr.green }
    return $Clr.red
}

# Robô da bandeja em amarelo (o real é verde-água), para não confundir os dois
function Load-Bitmap([int]$size) {
    $bytes = [IO.File]::ReadAllBytes((Join-Path $Dir 'robo.ico'))
    $count = [BitConverter]::ToUInt16($bytes, 4)
    for ($i = 0; $i -lt $count; $i++) {
        $e = 6 + 16 * $i
        $w = [int]$bytes[$e]; if ($w -eq 0) { $w = 256 }
        if ($w -eq $size) {
            $len = [BitConverter]::ToUInt32($bytes, $e + 8); $off = [BitConverter]::ToUInt32($bytes, $e + 12)
            $ms = New-Object IO.MemoryStream(, $bytes[$off..($off + $len - 1)])
            $src = New-Object System.Drawing.Bitmap $ms
            $bmp = New-Object System.Drawing.Bitmap $src   # cópia editável
            $src.Dispose()
            if ($IsReal) { return $bmp }   # real: robô verde-água original
            for ($y = 0; $y -lt $bmp.Height; $y++) {
                for ($x = 0; $x -lt $bmp.Width; $x++) {
                    $c = $bmp.GetPixel($x, $y)
                    if ($c.A -eq 0) { continue }
                    # 0 = azul-noite do visor, 1 = verde-água do corpo -> mesma escala do azul-noite ao amarelo
                    $t = [Math]::Max(0.0, [Math]::Min(1.0, ($c.G - 23) / 189.0))
                    $bmp.SetPixel($x, $y, [System.Drawing.Color]::FromArgb($c.A, [int](15 + $t * 236), [int](23 + $t * 168), [int](42 - $t * 6)))
                }
            }
            return $bmp
        }
    }
    return $null
}
function Load-Icon([int]$size) {
    $bmp = Load-Bitmap $size
    if ($bmp) { return [System.Drawing.Icon]::FromHandle($bmp.GetHicon()) }
    return [System.Drawing.SystemIcons]::Application
}

function Set-Round($p) {
    $r = 12; $w = $p.Width; $h = $p.Height
    if ($w -lt 2 * $r -or $h -lt 2 * $r) { return }
    $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $gp.AddArc(0, 0, 2 * $r, 2 * $r, 180, 90); $gp.AddArc($w - 2 * $r, 0, 2 * $r, 2 * $r, 270, 90)
    $gp.AddArc($w - 2 * $r, $h - 2 * $r, 2 * $r, 2 * $r, 0, 90); $gp.AddArc(0, $h - 2 * $r, 2 * $r, 2 * $r, 90, 90)
    $gp.CloseFigure()
    $p.Region = New-Object System.Drawing.Region($gp)
}
function Rounded-Panel([int]$x, [int]$y, [int]$w, [int]$h, $parent) {
    $p = New-Object System.Windows.Forms.Panel
    $p.SetBounds($x, $y, $w, $h)
    $p.BackColor = $Clr.card
    Set-Round $p
    $p.add_Resize({ Set-Round $this })
    $parent.Controls.Add($p)
    return $p
}
function Add-Label($parent, [string]$text, [int]$x, [int]$y, $font, $color) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y); $l.AutoSize = $true
    $l.Font = $font; $l.ForeColor = $color; $l.BackColor = [System.Drawing.Color]::Transparent
    $parent.Controls.Add($l)
    return $l
}
# Célula de tabela: largura fixa, corta com "…" se o texto não couber
function Cell($parent, [string]$text, $font, $color) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.AutoSize = $false; $l.AutoEllipsis = $true; $l.TextAlign = 'MiddleLeft'
    $l.Font = $font; $l.ForeColor = $color; $l.BackColor = [System.Drawing.Color]::Transparent
    $parent.Controls.Add($l)
    return $l
}

# ---------- painel ----------

$form = New-Object System.Windows.Forms.Form
$form.Text = $AppTitle
$RowH = 30
$TableH = 44 + $script:bots.Count * $RowH + 12 + $RowH + 8
$form.ClientSize = New-Object System.Drawing.Size(1040, (192 + $TableH + 46 + 170 + 20))
$form.FormBorderStyle = 'Sizable'
$form.MinimumSize = $form.Size
$form.StartPosition = 'CenterScreen'
$form.BackColor = $Clr.bg
$form.Icon = Load-Icon 48

$logo = New-Object System.Windows.Forms.PictureBox
$logo.SetBounds(24, 20, 44, 44); $logo.SizeMode = 'Zoom'; $logo.Image = Load-Bitmap 64
$form.Controls.Add($logo)
if ($IsReal) { $headTitle = 'Carteira' } else { $headTitle = 'Simulação' }
[void](Add-Label $form $headTitle 78 16 (Fnt 18 'Bold') $Clr.text)
$names = (@($script:bots | ForEach-Object { $_.short }) -join ', ')
if ($IsReal) { $subTxt = "{0} moedas ({1}) · MODO REAL, dinheiro da sua conta Binance" -f $script:bots.Count, $names }
else { $subTxt = "{0} moedas ({1}) · dinheiro de mentira, preços reais · nenhuma ordem é enviada" -f $script:bots.Count, $names }
$lbSub = Add-Label $form $subTxt 81 52 (Fnt 9.5) $Clr.muted
$lbSub.BringToFront()

Add-Type -Namespace Native -Name Dwm -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);'
$form.add_HandleCreated({ $on = 1; [void][Native.Dwm]::DwmSetWindowAttribute($form.Handle, 20, [ref]$on, 4) })
$pill = Rounded-Panel 724 28 152 30 $form
$lbPill = Add-Label $pill '●  Iniciando' 16 5 (Fnt 10 'Bold') $Clr.muted

# Cartões do total
function New-Card([string]$title) {
    $c = Rounded-Panel 0 84 170 96 $form
    [void](Add-Label $c $title 14 12 (Fnt 9) $Clr.muted)
    $v = Add-Label $c '—' 12 32 (Fnt 16 'Bold') $Clr.text
    $s = Add-Label $c '' 14 66 (Fnt 8.5) $Clr.muted
    return @{ panel = $c; value = $v; sub = $s }
}
if ($IsReal) { $cDep = New-Card 'Depositado' } else { $cDep = New-Card 'Depositado (de mentira)' }
$cTot = New-Card 'Valor total'
$cProj = New-Card 'Lucro projetado'
$cReal = New-Card 'Lucro real'
$cards = @($cDep, $cTot, $cProj, $cReal)

# Tabela por moeda
$tbl = Rounded-Panel 24 192 852 $TableH $form
$Keys = 'coin', 'dep', 'tot', 'real', 'proj', 'ops', 'sit'
$NCols = $Keys.Count
function New-Row([string[]]$texts, $fonts, $colors) {
    $r = @{}
    for ($k = 0; $k -lt $NCols; $k++) { $r[$Keys[$k]] = Cell $tbl $texts[$k] $fonts[$k] $colors[$k] }
    return $r
}
$hdrFont = Fnt 8 'Bold'
$hdr = New-Row @('MOEDA', 'DEPOSITADO', 'VALOR TOTAL', 'LUCRO REAL', 'PROJETADO', 'VENDAS', 'SITUAÇÃO') `
    @(1..$NCols | ForEach-Object { $hdrFont }) @(1..$NCols | ForEach-Object { $Clr.muted })
$rowFonts = @((Fnt 10 'Bold'), (Fnt 10), (Fnt 10), (Fnt 10 'Bold'), (Fnt 10 'Bold'), (Fnt 10), (Fnt 9.5))
$rows = New-Object System.Collections.ArrayList
foreach ($b in $script:bots) {
    [void]$rows.Add((New-Row @($b.short, (Money $b.deposit), '—', '—', '—', '0', 'Iniciando…') $rowFonts `
        @($Clr.text, $Clr.muted, $Clr.text, $Clr.text, $Clr.text, $Clr.text, $Clr.muted)))
}
$sep = New-Object System.Windows.Forms.Panel
$sep.BackColor = $Clr.line
$tbl.Controls.Add($sep)
$totBold = Fnt 10 'Bold'
$tot = New-Row @('TOTAL', '—', '—', '—', '—', '0', '') @($totBold, $totBold, $totBold, $totBold, $totBold, $totBold, (Fnt 9)) `
    @($Clr.text, $Clr.text, $Clr.text, $Clr.text, $Clr.text, $Clr.text, $Clr.muted)

# Operações e avisos de todas as moedas
$lbEv = Add-Label $form 'ÚLTIMAS OPERAÇÕES E AVISOS' 26 0 (Fnt 8.5 'Bold') $Clr.muted
$lnkDir = New-Object System.Windows.Forms.LinkLabel
if ($IsReal) { $lnkDir.Text = 'Abrir pasta da carteira' } else { $lnkDir.Text = 'Abrir pasta da simulação' }
$lnkDir.AutoSize = $true; $lnkDir.Font = Fnt 8.5
$lnkDir.LinkColor = $Clr.amber; $lnkDir.ActiveLinkColor = $Clr.text; $lnkDir.LinkBehavior = 'HoverUnderline'
$lnkDir.BackColor = [System.Drawing.Color]::Transparent
$lnkDir.add_LinkClicked({ Start-Process explorer.exe -ArgumentList "`"$SimDir`"" })
$form.Controls.Add($lnkDir)
$evPanel = Rounded-Panel 24 0 852 170 $form
$rtb = New-Object System.Windows.Forms.RichTextBox
$rtb.BorderStyle = 'None'; $rtb.ReadOnly = $true; $rtb.ScrollBars = 'Vertical'; $rtb.DetectUrls = $false; $rtb.WordWrap = $true
$rtb.BackColor = $Clr.card; $rtb.ForeColor = $Clr.text; $rtb.Font = Fnt 9.5 'Regular' 'Consolas'
$rtb.TabStop = $false
$evPanel.Controls.Add($rtb)
$script:lastEvents = $null

function Place-Row($r, [int]$y, [int[]]$xs, [int[]]$ws) {
    for ($k = 0; $k -lt $NCols; $k++) { $r[$Keys[$k]].SetBounds($xs[$k], $y, $ws[$k], 24) }
}
function Do-Layout {
    $W = $form.ClientSize.Width; $H = $form.ClientSize.Height
    $pill.Left = $W - 24 - $pill.Width
    $cw = [int][Math]::Floor(($W - 48 - 36) / 4)
    $x = 24
    foreach ($c in $cards) { $c.panel.SetBounds($x, 84, $cw, 96); $x += $cw + 12 }
    $tbl.Width = $W - 48
    # Larguras fixas; a Situação fica com o resto
    $ws = @(60, 98, 100, 104, 104, 58, 0)
    $ws[6] = [Math]::Max(120, $tbl.Width - 32 - 60 - 98 - 100 - 104 - 104 - 58)
    $xs = @(16); for ($k = 1; $k -lt $NCols; $k++) { $xs += $xs[$k - 1] + $ws[$k - 1] }
    Place-Row $hdr 12 $xs $ws
    $y = 40
    foreach ($r in $rows) { Place-Row $r $y $xs $ws; $y += $RowH }
    $sep.SetBounds(16, $y + 4, $tbl.Width - 32, 1)
    Place-Row $tot ($y + 12) $xs $ws
    $evTop = 192 + $TableH + 16
    $lbEv.Location = New-Object System.Drawing.Point(26, $evTop)
    $lnkDir.Location = New-Object System.Drawing.Point(($W - 24 - $lnkDir.Width), ($evTop - 1))
    $evPanel.SetBounds(24, $evTop + 22, $W - 48, [Math]::Max(80, $H - $evTop - 22 - 20))
    $rtb.SetBounds(14, 10, $evPanel.Width - 22, $evPanel.Height - 18)
}
$form.add_Resize({ Do-Layout })
Do-Layout

# Fechar o painel só esconde; a simulação continua
$form.add_FormClosing({ if ($_.CloseReason -eq 'UserClosing') { $_.Cancel = $true; $form.Hide() } })

# Texto da coluna Situação de uma moeda
function Situation($b, $pj) {
    if (-not $b.ok) { return @{ text = 'Não iniciado: ' + $b.why; color = $Clr.red } }
    if (-not (Bot-Running $b)) {
        if ($b.restartAt) { return @{ text = 'Reiniciando… (' + $b.why + ')'; color = $Clr.amber } }
        if ($b.why) { return @{ text = 'Parado: ' + $b.why; color = $Clr.red } }
        return @{ text = 'Parado'; color = $Clr.muted }
    }
    if (-not $pj) { return @{ text = 'Iniciando…'; color = $Clr.muted } }
    $price = [double]::Parse($pj.preco, $Inv)
    $s = [string]$pj.situacao
    $out = @{ text = (Pretty $s); color = $Clr.text }
    if ($s -match '^aguardando reais: este bot tem R\$ ([\d.]+)') {
        # carteira: a moeda ainda não recebeu reais (ou gastou e sobrou menos de R$ 10)
        $out = @{ text = ('Aguardando reais: esta moeda tem {0} (mínimo R$ 10 para comprar)' -f (Money ([double]::Parse($matches[1], $Inv)))); color = $Clr.muted }
    } elseif ($s -match 'lote minimo: R\$ ([\d.]+) so compram [\d.]+ \w+ \(R\$ ([\d.]+)\)') {
        # Sinal de compra, mas o saldo em lotes inteiros não chega ao mínimo de R$ 10 da Binance
        $have = [double]::Parse($matches[1], $Inv); $lot = [double]::Parse($matches[2], $Inv)
        $out = @{ text = ('Quer comprar, mas {0} só formam lote de {1} (mínimo R$ 10)' -f (Money $have), (Money $lot)); color = $Clr.amber }
    } elseif ($s -match '^comprado a R\$ ([\d.]+), vende em R\$ ([\d.]+)') {
        $entry = [double]::Parse($matches[1], $Inv); $tp = [double]::Parse($matches[2], $Inv)
        $out = @{ text = ('Comprada a {0} · vende em {1} ({2})' -f (PxPt $entry), (PxPt $tp), (Pct (($tp / $price - 1) * 100))); color = $Clr.amber }
    } elseif ($s -match 'compra abaixo de R\$ ([\d.]+)') {
        $buyAt = [double]::Parse($matches[1], $Inv)
        $out = @{ text = ('Em reais · compra se cair a {0} ({1})' -f (PxPt $buyAt), (Pct (($buyAt / $price - 1) * 100))); color = $Clr.accent }
    }
    $age = ((Get-Date) - [datetime]::Parse($pj.atualizado, $Inv)).TotalSeconds
    if ($age -gt 90) { $out.text += (' · sem atualização há {0} min' -f [int]($age / 60)); $out.color = $Clr.muted }
    return $out
}

function Refresh-Panel {
    $n = Running-Count
    if ($n -eq $script:bots.Count) { $lbPill.Text = "●  Rodando $n/$n"; $lbPill.ForeColor = $Clr.green }
    elseif ($n -gt 0) { $lbPill.Text = "●  Rodando $n/$($script:bots.Count)"; $lbPill.ForeColor = $Clr.amber }
    else { $lbPill.Text = '●  Parada'; $lbPill.ForeColor = $Clr.muted }

    $sumDep = 0.0; $sumTot = 0.0; $sumReal = 0.0; $sumProj = 0.0; $sumFees = 0.0; $sumBuys = 0; $sumSells = 0; $holding = 0; $since = $null
    for ($i = 0; $i -lt $script:bots.Count; $i++) {
        $b = $script:bots[$i]; $r = $rows[$i]
        $pj = Read-Json $b.panel
        $st = Read-Json $b.state
        $pnl = Coin-Pnl $b $pj $st
        # depositado = o que o bot informa (depósito inicial + aportes); antes de ele iniciar, o do config
        $dep = $b.deposit
        if ($pj -and $pj.PSObject.Properties['investido']) { $dep = [double]::Parse($pj.investido, $Inv) }
        $total = $dep
        if ($pj) { $total = [double]::Parse($pj.patrimonio, $Inv) }
        # Projetado = valor total − depositado − lucro real: assim os três sempre fecham (o cálculo pelo custo
        # médio dá o mesmo, a menos de centavos de arredondamento dos históricos antigos com 2 casas)
        if ($pj) { $pnl.proj = $total - $dep - $pnl.real }
        if ($b.ok) { $sumDep += $dep; $sumTot += $total; $sumReal += $pnl.real; $sumProj += $pnl.proj; $sumFees += $pnl.fees }
        $sumBuys += $pnl.buys; $sumSells += $pnl.sells
        if ($st -and $st.preco_entrada) { $holding++ }
        if ($st -and $st.inicio) {
            $t0 = ([DateTimeOffset]::Parse([string]$st.inicio, $Inv)).LocalDateTime
            if (-not $since -or $t0 -lt $since) { $since = $t0 }
        }
        $r.dep.Text = Money $dep
        $r.tot.Text = if ($pj) { Money $total } else { '—' }
        $r.real.Text = Signed $pnl.real; $r.real.ForeColor = Result-Color $pnl.real
        $r.proj.Text = if ($pj) { Signed $pnl.proj } else { '—' }
        $r.proj.ForeColor = Result-Color $pnl.proj
        $r.ops.Text = [string]$pnl.sells
        $sit = Situation $b $pj
        if ($b.note) { $sit = @{ text = $b.note + ' · ' + $sit.text; color = $Clr.amber } }
        $r.sit.Text = $sit.text; $r.sit.ForeColor = $sit.color
    }
    $sumRes = $sumTot - $sumDep
    $tot.dep.Text = Money $sumDep
    $tot.tot.Text = Money $sumTot
    $tot.real.Text = Signed $sumReal; $tot.real.ForeColor = Result-Color $sumReal
    $tot.proj.Text = Signed $sumProj; $tot.proj.ForeColor = Result-Color $sumProj
    $tot.ops.Text = [string]$sumSells
    $tot.sit.Text = "$holding de $($script:bots.Count) moedas compradas agora"
    if ($IsReal) {
        $u = Get-Unallocated ((Get-Date).AddMinutes(-3))
        if ($u) { $tot.sit.Text += ' · {0} em reais sem dono na conta' -f (Money ([Math]::Max(0, $u.unalloc))) }
    }

    # 1. Depositado
    $cDep.value.Text = Money $sumDep
    if ($since) {
        $el = (Get-Date) - $since
        if ($el.TotalHours -lt 1) { $ago = 'há {0} min' -f [int]$el.TotalMinutes }
        elseif ($el.TotalDays -lt 1) { $ago = 'há {0} h {1} min' -f [int][Math]::Floor($el.TotalHours), $el.Minutes }
        else { $ago = 'há {0} dias' -f $el.TotalDays.ToString('N1', $Pt) }
        $cDep.sub.Text = 'desde {0} · {1}' -f $since.ToString('dd/MM HH:mm'), $ago
    } else { $cDep.sub.Text = 'começando agora' }
    # 2. Valor total: reais + moedas a preço de agora (sobe e desce com as moedas)
    $cTot.value.Text = Money $sumTot
    $cTot.sub.Text = if ($sumDep -gt 0) { '{0} ({1}) sobre o depositado' -f (Signed $sumRes), (Pct ($sumRes / $sumDep * 100)) } else { '' }
    # 3. Lucro projetado: quanto as moedas que temos agora ganham/perdem se vendidas a preço de agora
    $cProj.value.Text = Signed $sumProj; $cProj.value.ForeColor = Result-Color $sumProj
    if ($holding -eq 0) { $cProj.sub.Text = 'nenhuma compra aberta (só sobras de lote)' }
    elseif ($holding -eq 1) { $cProj.sub.Text = '1 moeda comprada, a preço de agora' }
    else { $cProj.sub.Text = "$holding moedas compradas, a preço de agora" }
    # 4. Lucro real: o que as vendas já trouxeram a mais que o custo
    $cReal.value.Text = Signed $sumReal; $cReal.value.ForeColor = Result-Color $sumReal
    if ($sumSells -eq 1) { $vendas = '1 venda' } else { $vendas = "$sumSells vendas" }
    $cReal.sub.Text = '{0} · taxas pagas {1}' -f $vendas, (Money $sumFees)

    # Compras e vendas: do histórico de operações (completo). Avisos: do final do log (~2–3 h).
    # (Até 21/10/2026 as compras/vendas também vinham só do final do log e sumiam da lista em ~2,5 h.)
    $ev = New-Object System.Collections.Generic.List[object]
    foreach ($b in $script:bots) {
        $csvText = ''
        try { $csvText = Read-Shared $b.trades } catch {}
        foreach ($l in $csvText.Split("`n")) {
            $f = $l.Trim().Split(',')
            if ($f.Count -lt 6 -or $f[0] -notmatch '^(\d{4})-(\d\d)-(\d\d)T(\d\d:\d\d):\d\d$') { continue }
            $key = $f[0].Replace('T', ' '); $when = "$($matches[3])/$($matches[2]) $($matches[4])"
            $fee = ''
            if ($f.Count -ge 7 -and $f[6] -match '^[\d.]+$') { $fee = " | taxa R$ $($f[6])" }
            # gasto = quantidade × preço (a 1ª compra real de BTC ficou com R$ 20,00 no histórico; o gasto foi R$ 17,33)
            $spentTxt = ([double]::Parse($f[3], $Inv) * [double]::Parse($f[2], $Inv)).ToString('0.00', $Inv)
            if ($f[1] -eq 'COMPRA') { $msg = "COMPRA $($f[3]) $($b.short) a R$ $($f[2]) | gastou R$ $spentTxt$fee" }
            elseif ($f[1] -like 'VENDA*') { $msg = "VENDA ($($f[1] -replace '^VENDA-', '')) $($f[3]) $($b.short) a R$ $($f[2]) | recebeu R$ $($f[4])$fee" }
            else { continue }
            [void]$ev.Add([pscustomobject]@{ key = $key; when = $when; coin = $b.short; msg = $msg })
        }
        foreach ($l in (Tail-Lines $b.log 400)) {
            if ($l -notmatch '^\[(\d{4})-(\d\d)-(\d\d) (\d\d:\d\d):\d\d\] (.*)$') { continue }
            $key = $l.Substring(1, 19); $when = "$($matches[3])/$($matches[2]) $($matches[4])"; $msg = $matches[5]
            if ($msg -notmatch '^(ERRO (na ordem|FATAL)|SIMULACAO:|CARTEIRA:|APORTE|Carteira propria|Iniciando|Motivo:|Sinal de compra)') { continue }
            [void]$ev.Add([pscustomobject]@{ key = $key; when = $when; coin = $b.short; msg = $msg })
        }
    }
    $events = @($ev | Sort-Object key | Select-Object -Last 12)
    $sig = ($events | ForEach-Object { $_.key + $_.coin + $_.msg }) -join "`n"
    if ($sig -ne $script:lastEvents) {
        $script:lastEvents = $sig
        $tmp = New-Object System.Windows.Forms.RichTextBox
        $tmp.Font = $rtb.Font
        if ($events.Count -eq 0) { $tmp.SelectionColor = $Clr.muted; $tmp.AppendText('Nenhuma operação ainda. O bot compra quando a moeda cai 2,5% abaixo do topo das últimas 4 h.') }
        foreach ($e in $events) {
            $msg = $e.msg; $color = $Clr.text
            if ($msg -match '^Iniciando') { $msg = 'bot iniciado'; $color = $Clr.muted }
            elseif ($msg -match '^VENDA\s+\(stop\)|^ERRO') { $color = $Clr.red }
            elseif ($msg -match '^(COMPRA|VENDA)') { $color = $Clr.green }
            elseif ($msg -match '^(SIMULACAO|CARTEIRA):') { $msg = $msg -replace '^(SIMULACAO|CARTEIRA):\s*', ''; $color = $Clr.amber }
            elseif ($msg -match '^(APORTE|Carteira propria)') { $color = $Clr.accent }
            elseif ($msg -match '^Sinal de compra') { $color = $Clr.amber }
            $msg = Pretty ($msg -replace '\s{2,}', ' ')
            $tmp.SelectionColor = $Clr.muted; $tmp.AppendText("$($e.when)  ")
            $tmp.SelectionColor = $Clr.amber; $tmp.AppendText($e.coin.PadRight(6))
            $tmp.SelectionColor = $color; $tmp.AppendText("$msg`n")
        }
        $rtb.Rtf = $tmp.Rtf
        $rtb.SelectionStart = $rtb.TextLength
        $rtb.ScrollToCaret()
        $tmp.Dispose()
    }
}

function Show-Panel {
    Refresh-Panel
    $form.Show()
    $form.WindowState = 'Normal'
    $form.Activate()
}

# ---------- ícone e menu ----------

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = Load-Icon 32
$tray.Text = $AppTitle
$menu = New-Object System.Windows.Forms.ContextMenuStrip
if ($IsReal) { $What = 'a carteira'; $Tag = 'CARTEIRA' } else { $What = 'a simulação'; $Tag = 'SIMULACAO' }
$miOpen = $menu.Items.Add('Abrir painel')
$miToggle = $menu.Items.Add('Parar')
if ($IsReal) { $miDist = $menu.Items.Add('Distribuir reais livres…') }
[void]$menu.Items.Add('-')
$miExit = $menu.Items.Add('Sair')
$tray.ContextMenuStrip = $menu

function Update-Ui {
    $n = Running-Count
    if ($n -gt 0) { $miToggle.Text = "Parar $($What -replace '^a ', '')"; $tray.Text = "$AppTitle — $n moedas rodando" }
    else { $miToggle.Text = "Iniciar $($What -replace '^a ', '')"; $tray.Text = "$AppTitle — parado" }
}

# Confirmação antes de ligar o modo real (ao abrir e ao iniciar pelo menu)
function Confirm-Real {
    if (-not $IsReal) { return $true }
    $names = (@($script:bots | ForEach-Object { $_.short }) -join ', ')
    return Ask ("Iniciar a carteira em modo REAL?`n`nOs bots vão comprar e vender {0} com o dinheiro da sua conta Binance.`nO BTC continua só com a reserva dele; as outras moedas usam os reais livres que você distribuir." -f $names) 'Warning'
}

if ($IsReal) {
    $StopMsg = "Parar a carteira?`n`nAs ordens de venda que já estão na Binance continuam valendo (vendem mesmo com o PC desligado). Ao iniciar de novo, cada bot continua de onde parou."
} else {
    $StopMsg = "Parar a simulação?`n`nO resultado fica salvo; ao iniciar de novo, ela continua de onde parou."
}
$miOpen.add_Click({ Show-Panel })
$tray.add_MouseClick({ if ($_.Button -eq 'Left') { Show-Panel } })
$miToggle.add_Click({
    if ((Running-Count) -gt 0) {
        if (Ask $StopMsg) { Stop-All }
    } elseif (Confirm-Real) { Start-All; $script:startedAt = Get-Date; $script:distDone = $false }
    Update-Ui
})
if ($IsReal) {
    $miDist.add_Click({
        $u = Get-Unallocated ((Get-Date).AddMinutes(-2))
        if (-not $u) { [void][System.Windows.Forms.MessageBox]::Show('Os bots ainda estão atualizando o saldo (ou conferindo uma venda). Tente de novo em 1 minuto.', $AppTitle); return }
        if ($u.unalloc -lt 1) { [void][System.Windows.Forms.MessageBox]::Show(('Não há reais livres sem dono na conta ({0}).' -f (Money ([Math]::Max(0, $u.unalloc)))), $AppTitle); return }
        Offer-Distribution $u
    })
}
$miExit.add_Click({
    if ((Running-Count) -gt 0 -and -not (Ask ("Sair também para {0}. Continuar?`n`n{1}" -f $What, ($StopMsg -replace '^[^\n]*\n\n', '')))) { return }
    Stop-All
    $tray.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})

# ---------- loop (a cada 2 s): quedas, reinícios, painel ----------

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.add_Tick({
    try {
        $changed = $false
        foreach ($b in $script:bots) {
            if ($b.proc -and $b.proc.HasExited -and -not $b.exitNotified) {
                $b.exitNotified = $true; $changed = $true
                if (-not $b.userStopped) {
                    $code = $b.proc.ExitCode
                    $err = ''
                    try { $err = (@(Get-Content $b.err -ErrorAction Stop | Where-Object { $_.Trim() }) | Select-Object -Last 3) -join ' | ' } catch {}
                    if ($code -eq 0) {
                        $b.why = 'encerrou sozinho: ' + ((@(Tail-Lines $b.log 1) -join '') -replace '^\[[^\]]*\]\s*', '')
                    } else {
                        $b.why = "caiu (codigo $code)"
                        if ($err) { $b.why += ": $err" }
                    }
                    Append-CoinLog $b "${Tag}: o bot $($b.why)"
                    $b.restarts = @($b.restarts | Where-Object { $_ -gt (Get-Date).AddHours(-1) })
                    if ($code -ne 0 -and $b.restarts.Count -lt 5) {
                        $b.restartAt = (Get-Date).AddSeconds(30)
                        Append-CoinLog $b "${Tag}: reiniciando em 30 s."
                    } elseif ($code -ne 0) {
                        Append-CoinLog $b "${Tag}: caiu 5 vezes na ultima hora; nao vou reiniciar sozinho."
                    }
                    if ($IsReal) { $tray.ShowBalloonTip(15000, "$($b.short): bot parou", "Motivo: $($b.why)", 'Warning') }
                }
            }
            if ($b.restartAt -and (Get-Date) -ge $b.restartAt -and -not (Bot-Running $b)) {
                $b.restarts += Get-Date
                Start-Coin $b
                Append-CoinLog $b "${Tag}: bot reiniciado automaticamente."
                $changed = $true
            }
            # Modo real: avisa cada venda e os problemas que o bot pedir (os avisos de patamar não)
            if ($IsReal) {
                foreach ($l in (Read-NewLines $b)) {
                    if ($l -match '\] (VENDA\s+\((\w+)\).*)$') {
                        $tray.ShowBalloonTip(10000, "$($b.short): venda ($($matches[2]))", (Pretty ($matches[1] -replace '\s{2,}', ' ')), 'Info')
                    } elseif ($l -match 'NOTIFICAR \| (.*?) \| (.*)$' -and $matches[1] -notmatch '^Saldo:') {
                        $title = $matches[1]; $body = $matches[2]
                        if ($title -notmatch '^Bot ') { $title = "$($b.short): $title" }   # o bot já põe "Bot <moeda>"
                        $tray.ShowBalloonTip(10000, $title, $body, 'Warning')
                    }
                }
            }
        }
        if ($changed) { Update-Ui }
        # Modo real: ~30 s depois de iniciar, se houver reais livres sem dono (ex.: depósito novo), oferece
        # distribuir. Espera duas leituras iguais com 10 s de intervalo (saldo estável, nenhum bot comprando).
        if ($IsReal -and -not $script:distDone -and (Get-Date) -gt $script:startedAt.AddSeconds(30)) {
            $u = Get-Unallocated $script:startedAt.AddSeconds(10)
            if ($u) {
                if ($script:distFirst -and ((Get-Date) - $script:distFirst.at).TotalSeconds -ge 10) {
                    if ([Math]::Abs($script:distFirst.v - $u.unalloc) -lt 0.01) {
                        $script:distDone = $true
                        if ($u.unalloc -ge 10) { Offer-Distribution $u }
                    }
                    $script:distFirst = $null
                } elseif (-not $script:distFirst) { $script:distFirst = @{ at = (Get-Date); v = $u.unalloc } }
            }
        }
        if ($form.Visible) { Refresh-Panel }
    } catch {}
})

# ---------- início ----------

if (-not (Confirm-Real)) { $script:trayMutex.ReleaseMutex(); return }
Start-All
$script:startedAt = Get-Date
$script:distDone = $false
$script:distFirst = $null
$tray.Visible = $true
Update-Ui
if ($IsReal) {
    $tray.ShowBalloonTip(8000, 'Carteira rodando (modo real)', ("{0} moedas. Clique no robô para ver o painel." -f $script:bots.Count), 'Info')
} else {
    $tray.ShowBalloonTip(8000, 'Simulação rodando', ("{0} moedas, {1} no total, dinheiro de mentira. Robô amarelo na bandeja = simulação." -f $script:bots.Count, (Money $TotalDeposit)), 'Info')
}
$timer.Start()
if ($AbrirPainel) { Show-Panel }
[System.Windows.Forms.Application]::Run()
$tray.Dispose()
