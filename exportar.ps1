# Monta a pasta compartilhar\ (e o arquivo bot-binance-compartilhar.zip) so com o codigo e a documentacao
# do bot, SEM dados pessoais, para enviar a outra pessoa (GitHub, zip). Recria tudo do zero a cada execucao.
# Fica de fora: estado-*, log-*, operacoes-*, painel-*, erro-bot-*, data\, real\<PAR>\, simulacao\<PAR>\,
# resultados de backtest e o historico de decisoes do CLAUDE.md (datas e valores da conta de quem exporta).
# O config.json vai em "modo": "simulacao". A chave de API nunca esta em arquivo (fica no Windows).
# Uso: powershell -ExecutionPolicy Bypass -File exportar.ps1
$ErrorActionPreference = 'Stop'
$Src = $PSScriptRoot
$Out = Join-Path $Src 'compartilhar'
$Zip = Join-Path $Src 'bot-binance-compartilhar.zip'
if (Test-Path $Out) { [IO.Directory]::Delete($Out, $true) }
New-Item -ItemType Directory -Force (Join-Path $Out 'real'), (Join-Path $Out 'simulacao') | Out-Null

$files = 'bot.ps1', 'strategy.cs', 'carteira.ps1', 'simulacao.ps1', 'bandeja.ps1', 'iniciar.bat',
         'backtest.ps1', 'backtest.cs', 'backtest-todos.ps1', 'backtest.bat', 'previsao.ps1', 'criar-atalho.ps1',
         'exportar.ps1', 'robo.ico', 'robo-simulacao.ico', 'README.md', 'LEIA-ME.md', 'AGENTS.md'
foreach ($f in $files) { Copy-Item (Join-Path $Src $f) (Join-Path $Out $f) }
Copy-Item (Join-Path $Src 'real\moedas.json') (Join-Path $Out 'real\moedas.json')
Copy-Item (Join-Path $Src 'simulacao\moedas.json') (Join-Path $Out 'simulacao\moedas.json')

# config.json: mesma estrategia, mas em simulacao e sem "carteira_propria" (a carteira real acrescenta)
$cfg = Get-Content (Join-Path $Src 'config.json') -Raw | ConvertFrom-Json
$cfg.modo = 'simulacao'
$cfg.PSObject.Properties.Remove('carteira_propria')
[IO.File]::WriteAllText((Join-Path $Out 'config.json'), ($cfg | ConvertTo-Json), [Text.Encoding]::ASCII)

# CLAUDE.md sem o historico de decisoes; o cabecalho da tabela fica, vazio, para a outra pessoa continuar
$md = [IO.File]::ReadAllText((Join-Path $Src 'CLAUDE.md'), [Text.Encoding]::UTF8)
$m = [regex]::Match($md, '(?m)^## Hist[^\r\n]*')
if ($m.Success) {
    $md = $md.Substring(0, $m.Index) + $m.Value + "`r`n`r`n" +
        "(O historico da conta de quem compartilhou foi omitido nesta copia.)`r`n`r`n" +
        "| Data | Mudanca / decisao | Por que / quem |`r`n|---|---|---|`r`n"
}
# numeros de ordens da Binance citados nas notas tecnicas (nao dao acesso a nada, mas sao da conta)
$md = [regex]::Replace($md, '(?<![\d.,])\d{8,10}(?![\d.,])', '<id da ordem>')   # nao pega casas decimais (0,00003996)
[IO.File]::WriteAllText((Join-Path $Out 'CLAUDE.md'), $md, (New-Object Text.UTF8Encoding($false)))

# .gitignore: o que o bot cria ao rodar sao dados da conta de quem usa; nao deve ir para o GitHub
$ignore = @(
    '# Criados pelo bot ao rodar (dados da sua conta): nao suba para o GitHub'
    'estado-*.json', 'log-*.txt', 'operacoes-*.csv', 'painel-*.json', 'painel-*.json.tmp'
    'erro-bot-*.txt', 'aporte-*.txt', 'aporte-*.txt.tmp', 'parar-*.flag'
    'data/', 'real/*/', 'simulacao/*/'
    'resultado-backtest-*.txt', 'resumo-pares*.csv', 'previsao-*.txt'
    'compartilhar/', '*.zip'
)
[IO.File]::WriteAllText((Join-Path $Out '.gitignore'), (($ignore -join "`r`n") + "`r`n"), [Text.Encoding]::ASCII)

if (Test-Path $Zip) { [IO.File]::Delete($Zip) }
Compress-Archive -Path (Join-Path $Out '*') -DestinationPath $Zip
Write-Host "Pasta: $Out"
Write-Host "Zip:   $Zip"
