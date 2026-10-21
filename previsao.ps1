# Previsao baseada no historico: simula o bot comecando em cada dia do periodo
# baixado (data\<PAR>-1m.csv, criado pelo backtest.ps1) e mede o que aconteceu
# depois de 1, 3, 7, 30 e 60 dias com os parametros do config.json.
# Uso: powershell -ExecutionPolicy Bypass -File previsao.ps1 [-Par BTCBRL]
param(
    [string]$Par = '',
    [string]$Config = (Join-Path $PSScriptRoot 'config.json')
)
$ErrorActionPreference = 'Stop'
$Inv = [Globalization.CultureInfo]::InvariantCulture
Add-Type -Path (Join-Path $PSScriptRoot 'strategy.cs'), (Join-Path $PSScriptRoot 'backtest.cs')

$cfg = Get-Content $Config -Raw | ConvertFrom-Json
$Symbol = ([string]$cfg.par).ToUpper()
if ($Par) { $Symbol = $Par.ToUpper() }
$Cash = [double]$cfg.deposito_inicial_brl
$Fee = [double]$cfg.taxa_simulacao_pct / 100

$file = Join-Path $PSScriptRoot "data\$Symbol-1m.csv"
if (-not (Test-Path $file)) { throw "Rode antes: backtest.ps1 -Par $Symbol" }
$rows = [IO.File]::ReadAllLines($file)
$n = $rows.Length
$T = New-Object long[] $n; $O = New-Object double[] $n; $H = New-Object double[] $n; $L = New-Object double[] $n; $C = New-Object double[] $n
for ($i = 0; $i -lt $n; $i++) {
    $f = $rows[$i].Split(',')
    $T[$i] = [long]$f[0]
    $O[$i] = [double]::Parse($f[1], $Inv); $H[$i] = [double]::Parse($f[2], $Inv)
    $L[$i] = [double]::Parse($f[3], $Inv); $C[$i] = [double]::Parse($f[4], $Inv)
}

$p = New-Object BtParams
$p.WindowMin = [double]$cfg.janela_minutos; $p.Dip = [double]$cfg.queda_para_comprar_pct / 100
$p.TakeProfit = [double]$cfg.lucro_para_vender_pct / 100; $p.StopLoss = [double]$cfg.stop_loss_pct / 100
$p.CooldownMin = [double]$cfg.pausa_apos_stop_minutos; $p.WarmupMin = [double]$cfg.aquecimento_minutos
if ($cfg.PSObject.Properties['tendencia_minutos']) { $p.TrendMin = [double]$cfg.tendencia_minutos }
if ($cfg.PSObject.Properties['trailing_pct']) { $p.Trail = [double]$cfg.trailing_pct / 100 }

$perDay = 1440
$days = [int][Math]::Floor($n / $perDay)
$out = New-Object System.Collections.Generic.List[string]
$out.Add("Previsao $Symbol com R$ $Cash | $p")
$out.Add("Base: $days dias de historico; o bot e simulado comecando em cada um desses dias.")
$out.Add('')
$out.Add('Apos     | comecos | com lucro | sem operar | ganhou 1+ venda | resultado tipico (mediana) | pior    | melhor  | chegou a R$30')
foreach ($hz in 1, 3, 7, 30, 60) {
    $finals = New-Object System.Collections.Generic.List[double]
    $profit = 0; $noTrade = 0; $sawWin = 0; $hit = 0
    for ($d = 0; $d + $hz -le $days; $d++) {
        $r = [Backtester]::Run($p, $T, $O, $H, $L, $C, $d * $perDay, ($d + $hz) * $perDay, $Fee, 0.00001, $Cash, $Cash * 1.5)
        $finals.Add($r.FinalEquity)
        if ($r.FinalEquity -gt $Cash + 0.005) { $profit++ }
        if ($r.Trades -eq 0 -and [Math]::Abs($r.FinalEquity - $Cash) -lt 0.005) { $noTrade++ }
        if ($r.Wins -gt 0) { $sawWin++ }
        if ($r.DaysToTarget -ge 0) { $hit++ }
    }
    $cnt = $finals.Count
    $sorted = $finals.ToArray(); [Array]::Sort($sorted)
    $out.Add(('{0,3} dias | {1,7} | {2,8:0}% | {3,9:0}% | {4,14:0}% | R$ {5,6:0.00} ({6:+0.00;-0.00}) | R$ {7,5:0.00} | R$ {8,5:0.00} | {9,4:0}%' -f `
        $hz, $cnt, (100.0 * $profit / $cnt), (100.0 * $noTrade / $cnt), (100.0 * $sawWin / $cnt), $sorted[[int]($cnt / 2)], ($sorted[[int]($cnt / 2)] - $Cash), $sorted[0], $sorted[$cnt - 1], (100.0 * $hit / $cnt)))
}
$out.Add('')
$out.Add('"com lucro" = terminou acima de R$ ' + $Cash + ' (contando o BTC pelo preco do momento).')
$out.Add('Isto descreve o passado recente; o futuro pode ser bem diferente.')
$out | ForEach-Object { Write-Host $_ }
$out | Set-Content -Path (Join-Path $PSScriptRoot "previsao-$Symbol.txt") -Encoding ASCII
