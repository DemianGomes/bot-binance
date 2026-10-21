# Atalho "Bot Simulação": abre a carteira em modo simulação (dinheiro de mentira). Ver carteira.ps1.
param([switch]$AbrirPainel)
& (Join-Path $PSScriptRoot 'carteira.ps1') -Modo simulacao -AbrirPainel:$AbrirPainel
