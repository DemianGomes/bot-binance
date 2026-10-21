# Roda o backtest em varios pares BRL e mostra um comparativo (resumo-pares.csv).
# Uso: powershell -ExecutionPolicy Bypass -File backtest-todos.ps1 [-Pares BTCBRL,ETHBRL] [-Dias 180]
param(
    [string[]]$Pares = @('BTCBRL', 'ETHBRL', 'SOLBRL', 'XRPBRL', 'BNBBRL', 'LTCBRL', 'ADABRL', 'DOGEBRL', 'LINKBRL', 'USDTBRL'),
    [int]$Dias = 180,
    [double]$MinOpsDia = 0   # ex.: 1 = so configuracoes que operam pelo menos 1x por dia
)
$sufixo = ''
if ($MinOpsDia -gt 0) { $sufixo = "-rapido$MinOpsDia" }
$ErrorActionPreference = 'Stop'
foreach ($p in $Pares) {
    Write-Host "================ $p ================"
    try {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'backtest.ps1') -Par $p -Dias $Dias -MinOpsDia $MinOpsDia | Out-Null
        Write-Host "ok -> resultado-backtest-$p$sufixo.txt"
    } catch { Write-Host "falhou: $($_.Exception.Message)" }
}
Write-Host ''
Import-Csv (Join-Path $PSScriptRoot "resumo-pares$sufixo.csv") -Delimiter ';' |
    Group-Object par | ForEach-Object { $_.Group[-1] } |
    Sort-Object { [double]::Parse($_.media_top10_teste_pct) } -Descending |
    Format-Table par, spread_pct, hold_teste_pct, config_atual_treino_pct, config_atual_teste_pct, melhor_treino_pct, melhor_no_teste_pct, media_top10_teste_pct, combinacoes_lucrativas_pct -AutoSize
