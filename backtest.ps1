# Backtest + otimizacao da estrategia com precos historicos reais da Binance.
#
# 1. Baixa candles de 1 minuto (API publica, sem chave) e guarda em data\.
# 2. Divide o periodo em TREINO (primeiros 2/3) e TESTE (ultimo 1/3).
# 3. Testa centenas de combinacoes de parametros no TREINO.
# 4. Roda as melhores no TESTE, que o otimizador nao viu. So o resultado do TESTE
#    indica o que esperar no futuro; o do TREINO sempre parece melhor do que e.
#
# Uso: powershell -ExecutionPolicy Bypass -File backtest.ps1 [-Dias 180]

param(
    [int]$Dias = 180,
    [string]$Par = '',   # vazio = usa o par do config.json
    [double]$MinOpsDia = 0,  # so considera configuracoes com pelo menos X vendas por dia no treino
    [string]$Config = (Join-Path $PSScriptRoot 'config.json')
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Inv = [Globalization.CultureInfo]::InvariantCulture
Add-Type -Path (Join-Path $PSScriptRoot 'strategy.cs'), (Join-Path $PSScriptRoot 'backtest.cs')

$cfg = Get-Content $Config -Raw | ConvertFrom-Json
$Symbol = ([string]$cfg.par).ToUpper()
if ($Par) { $Symbol = $Par.ToUpper() }
$Fee = [double]$cfg.taxa_simulacao_pct / 100
$Cash = [double]$cfg.deposito_inicial_brl
$Target = [double]$cfg.meta_brl

# ---------- dados ----------

$dataDir = Join-Path $PSScriptRoot 'data'
New-Item -ItemType Directory -Force $dataDir | Out-Null
$file = Join-Path $dataDir "$Symbol-1m.csv"
$nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$wantFrom = $nowMs - [long]$Dias * 86400000

$lines = New-Object System.Collections.Generic.List[string]
if (Test-Path $file) { $lines.AddRange([IO.File]::ReadAllLines($file)) }
if ($lines.Count -gt 0 -and [long]($lines[0].Split(',')[0]) -gt $wantFrom + 3600000) { $lines.Clear() }  # cache curto demais: baixa tudo
$next = $wantFrom
if ($lines.Count -gt 0) { $next = [long]($lines[$lines.Count - 1].Split(',')[0]) + 60000 }

Write-Host "Baixando candles de 1 min de $Symbol..."
while ($next -lt $nowMs - 120000) {
    $k = Invoke-RestMethod "https://api.binance.com/api/v3/klines?symbol=$Symbol&interval=1m&startTime=$next&limit=1000" -TimeoutSec 30
    if ($k.Count -eq 0) { break }
    foreach ($x in $k) {
        if ([long]$x[6] -lt $nowMs) { $lines.Add(('{0},{1},{2},{3},{4}' -f $x[0], $x[1], $x[2], $x[3], $x[4])) }
    }
    $next = [long]$k[$k.Count - 1][0] + 60000
    Write-Host -NoNewline '.'
}
Write-Host ''

# Usa e guarda so os ultimos $Dias dias (o arquivo nao cresce para sempre)
$rows = @($lines | Where-Object { [long]($_.Split(',')[0]) -ge $wantFrom })
[IO.File]::WriteAllLines($file, $rows)
$n = $rows.Count
$T = New-Object long[] $n; $O = New-Object double[] $n; $H = New-Object double[] $n; $L = New-Object double[] $n; $C = New-Object double[] $n
for ($i = 0; $i -lt $n; $i++) {
    $f = $rows[$i].Split(',')
    $T[$i] = [long]$f[0]
    $O[$i] = [double]::Parse($f[1], $Inv); $H[$i] = [double]::Parse($f[2], $Inv)
    $L[$i] = [double]::Parse($f[3], $Inv); $C[$i] = [double]::Parse($f[4], $Inv)
}
$split = [int]($n * 2 / 3)
# Meio spread = metade da diferenca compra/venda atual, com margem de 2x (minimo 0,001%)
$book = Invoke-RestMethod "https://api.binance.com/api/v3/ticker/bookTicker?symbol=$Symbol"
$HalfSpread = [Math]::Max(0.00001, ([double]::Parse($book.askPrice, $Inv) / [double]::Parse($book.bidPrice, $Inv) - 1))
function Fmt-Date([long]$ms) { return [DateTimeOffset]::FromUnixTimeMilliseconds($ms).ToLocalTime().ToString('dd/MM/yyyy') }
Write-Host ("{0} candles | TREINO {1} a {2} | TESTE {3} a {4}" -f $n, (Fmt-Date $T[0]), (Fmt-Date $T[$split - 1]), (Fmt-Date $T[$split]), (Fmt-Date $T[$n - 1]))

# ---------- grade de parametros ----------

$grid = New-Object System.Collections.Generic.List[BtParams]
foreach ($w in 15, 60, 240, 720) {
 foreach ($d in 0.7, 1.5, 2.5, 3.5, 5.0) {
  foreach ($tp in 0.7, 1.5, 2.5, 3.5, 5.0) {
   foreach ($sl in 1.0, 2.0, 3.0, 5.0, 8.0) {
    foreach ($tr in 0, 240, 1440) {
     foreach ($tl in 0, 0.5) {
        if ($tl -gt 0 -and $tl -ge $tp) { continue }
        $p = New-Object BtParams
        $p.CooldownMin = [double]$cfg.pausa_apos_stop_minutos; $p.WarmupMin = [double]$cfg.aquecimento_minutos
        $p.WindowMin = $w; $p.Dip = $d / 100; $p.TakeProfit = $tp / 100; $p.StopLoss = $sl / 100
        $p.TrendMin = $tr; $p.Trail = $tl / 100
        $grid.Add($p)
     }}}}}}

$cur = New-Object BtParams
$cur.WindowMin = [double]$cfg.janela_minutos; $cur.Dip = [double]$cfg.queda_para_comprar_pct / 100
$cur.TakeProfit = [double]$cfg.lucro_para_vender_pct / 100; $cur.StopLoss = [double]$cfg.stop_loss_pct / 100
$cur.CooldownMin = [double]$cfg.pausa_apos_stop_minutos; $cur.WarmupMin = [double]$cfg.aquecimento_minutos
if ($cfg.PSObject.Properties['tendencia_minutos']) { $cur.TrendMin = [double]$cfg.tendencia_minutos }
if ($cfg.PSObject.Properties['trailing_pct']) { $cur.Trail = [double]$cfg.trailing_pct / 100 }

Write-Host "Testando $($grid.Count) combinacoes no periodo de TREINO..."
$sw = [Diagnostics.Stopwatch]::StartNew()
$train = [Backtester]::RunMany($grid.ToArray(), $T, $O, $H, $L, $C, 0, $split, $Fee, $HalfSpread, $Cash, $Cash * 1.5)
$top = @($train | Where-Object { $_.Trades / [Math]::Max($_.Days, 1) -ge $MinOpsDia } | Sort-Object ReturnPct -Descending | Select-Object -First 10)
if ($top.Count -eq 0) { throw "Nenhuma configuracao fez $MinOpsDia operacoes por dia." }
$test = [Backtester]::RunMany(@($top | ForEach-Object { $_.P }), $T, $O, $H, $L, $C, $split, $n, $Fee, $HalfSpread, $Cash, $Cash * 1.5)
Write-Host ("Pronto em {0:0} s" -f $sw.Elapsed.TotalSeconds)

# ---------- relatorio ----------

function Row($label, $r) {
    '{0,-4} {1,8:0.00}% {2,8:0.00}%/dia {3,5} op {4,4} stops  queda max {5,6:0.0}%' -f $label, $r.ReturnPct, ($r.ReturnPct / [Math]::Max($r.Days, 1)), $r.Trades, $r.Stops, $r.MaxDrawdownPct
}
$out = New-Object System.Collections.Generic.List[string]
$out.Add("Backtest $Symbol | $n candles de 1 min | taxa $($Fee*100)% por operacao | gerado em $(Get-Date -Format 'dd/MM/yyyy HH:mm')")
$out.Add(("TREINO {0} a {1} | TESTE {2} a {3}" -f (Fmt-Date $T[0]), (Fmt-Date $T[$split - 1]), (Fmt-Date $T[$split]), (Fmt-Date $T[$n - 1])))
$hold = @{ tr = ($C[$split - 1] / $O[0] - 1) * 100; te = ($C[$n - 1] / $O[$split] - 1) * 100 }
$out.Add(("Referencia - so comprar e segurar BTC: TREINO {0:0.00}% | TESTE {1:0.00}%" -f $hold.tr, $hold.te))
$out.Add('')
$curTr = [Backtester]::Run($cur, $T, $O, $H, $L, $C, 0, $split, $Fee, $HalfSpread, $Cash, $Cash * 1.5)
$curTe = [Backtester]::Run($cur, $T, $O, $H, $L, $C, $split, $n, $Fee, $HalfSpread, $Cash, $Cash * 1.5)
$out.Add("CONFIG ATUAL: $cur")
$out.Add('  ' + (Row 'tr' $curTr))
$out.Add('  ' + (Row 'te' $curTe))
$out.Add('')
if ($MinOpsDia -gt 0) { $out.Add("(somente configuracoes com pelo menos $MinOpsDia vendas por dia)") }
$out.Add('TOP 10 DO TREINO e como foram no TESTE (o que importa e a linha "te"):')
for ($i = 0; $i -lt $top.Count; $i++) {
    $out.Add("#$($i + 1) $($top[$i].P)")
    $out.Add('  ' + (Row 'tr' $top[$i]))
    $out.Add('  ' + (Row 'te' $test[$i]))
}
$positive = @($train | Where-Object { $_.ReturnPct -gt 0 }).Count
$out.Add('')
$out.Add("No TREINO, $positive de $($grid.Count) combinacoes terminaram no lucro.")
$out | ForEach-Object { Write-Host $_ }
$sufixo = ''
if ($MinOpsDia -gt 0) { $sufixo = "-rapido$MinOpsDia" }
$out | Set-Content -Path (Join-Path $PSScriptRoot "resultado-backtest-$Symbol$sufixo.txt") -Encoding ASCII

# Uma linha de resumo por par, para comparar moedas (backtest-todos.ps1)
$resumo = Join-Path $PSScriptRoot "resumo-pares$sufixo.csv"
if (-not (Test-Path $resumo)) {
    Set-Content -Path $resumo -Encoding ASCII -Value 'data;par;spread_pct;hold_treino_pct;hold_teste_pct;config_atual_treino_pct;config_atual_teste_pct;melhor_treino_pct;melhor_no_teste_pct;media_top10_teste_pct;combinacoes_lucrativas_pct;melhor_parametros'
}
$avgTop = ($test | Measure-Object -Property ReturnPct -Average).Average
# Separador ";" e decimal com virgula: abre direto no Excel em portugues
Add-Content -Path $resumo -Value ('{0};{1};{2:0.0000};{3:0.00};{4:0.00};{5:0.00};{6:0.00};{7:0.00};{8:0.00};{9:0.00};{10:0.0};{11}' -f `
    (Get-Date -Format 's'), $Symbol, ($HalfSpread * 100), $hold.tr, $hold.te, $curTr.ReturnPct, $curTe.ReturnPct, $top[0].ReturnPct, $test[0].ReturnPct, $avgTop, ($positive * 100.0 / $grid.Count), $top[0].P)
