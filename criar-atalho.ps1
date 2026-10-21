# Cria os icones de robo e os atalhos na Area de Trabalho:
#   robo.ico (verde-agua)        -> "Bot"            (carteira.ps1 -Modo real: BTC + outras moedas, dinheiro real)
#   robo-simulacao.ico (amarelo) -> "Bot Simulacao"  (simulacao.ps1 = carteira em simulacao, dinheiro de mentira)
# (Ate 19/10/2026 o atalho real chamava "Bot BTC" e abria a bandeja.ps1, so BTC; o usuario o renomeou para "Bot".)
# Uso: powershell -ExecutionPolicy Bypass -File criar-atalho.ps1 [-SoSimulacao]
#   -SoSimulacao: cria so o icone/atalho da simulacao (nao mexe no atalho do bot real)
param([switch]$SoSimulacao)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function Rounded([System.Drawing.Drawing2D.GraphicsPath]$p, [float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $p.AddArc($x, $y, 2 * $r, 2 * $r, 180, 90)
    $p.AddArc($x + $w - 2 * $r, $y, 2 * $r, 2 * $r, 270, 90)
    $p.AddArc($x + $w - 2 * $r, $y + $h - 2 * $r, 2 * $r, 2 * $r, 0, 90)
    $p.AddArc($x, $y + $h - 2 * $r, 2 * $r, 2 * $r, 90, 90)
    $p.CloseFigure()
}

# Desenha o robo numa grade de 100x100 e escala para o tamanho pedido; retorna PNG em bytes
function Draw-Robot([int]$size, [System.Drawing.Color]$color) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.ScaleTransform($size / 100.0, $size / 100.0)
    $body = New-Object System.Drawing.SolidBrush $color
    $dark = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 15, 23, 42))    # azul-noite

    # antena
    $g.FillRectangle($body, 47, 8, 6, 14)
    $g.FillEllipse($body, 42, 2, 16, 16)
    # orelhas
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath; Rounded $p 4 44 10 24 4; $g.FillPath($body, $p)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath; Rounded $p 86 44 10 24 4; $g.FillPath($body, $p)
    # cabeca
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath; Rounded $p 12 22 76 70 18; $g.FillPath($body, $p)
    # visor
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath; Rounded $p 22 36 56 40 12; $g.FillPath($dark, $p)
    # olhos
    $g.FillEllipse($body, 31, 46, 14, 14)
    $g.FillEllipse($body, 55, 46, 14, 14)
    # boca
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath; Rounded $p 40 65 20 5 2.5; $g.FillPath($body, $p)

    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    return , $ms.ToArray()
}

# Monta um .ico com varias resolucoes (PNG dentro do ICO, suportado desde o Windows Vista)
function Write-Ico([string]$icoPath, [System.Drawing.Color]$color) {
    $sizes = 256, 64, 48, 32, 16
    $images = @($sizes | ForEach-Object { , (Draw-Robot $_ $color) })
    $fs = [System.IO.File]::Create($icoPath)
    $w = New-Object System.IO.BinaryWriter $fs
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $sz = $sizes[$i]; if ($sz -ge 256) { $sz = 0 }
        $w.Write([byte]$sz); $w.Write([byte]$sz); $w.Write([byte]0); $w.Write([byte]0)
        $w.Write([uint16]1); $w.Write([uint16]32)
        $w.Write([uint32]$images[$i].Length); $w.Write([uint32]$offset)
        $offset += $images[$i].Length
    }
    foreach ($img in $images) { $w.Write($img) }
    $w.Close()
}

# Atalho na Area de Trabalho que abre um script na bandeja (sem terminal)
function New-Shortcut([string]$name, [string]$script, [string]$icoPath, [string]$desc, [string]$extra = '') {
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) "$name.lnk"
    $sh = New-Object -ComObject WScript.Shell
    $sc = $sh.CreateShortcut($lnk)
    $sc.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $sc.Arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot $script) + '"' + $extra
    $sc.WindowStyle = 7   # minimizado, para a janela do PowerShell nao piscar
    $sc.WorkingDirectory = $PSScriptRoot
    $sc.IconLocation = "$icoPath,0"
    $sc.Description = $desc
    $sc.Save()
    Write-Host "Atalho: $lnk"
}

$ico = Join-Path $PSScriptRoot 'robo.ico'
$icoSim = Join-Path $PSScriptRoot 'robo-simulacao.ico'
if (-not $SoSimulacao) {
    Write-Ico $ico ([System.Drawing.Color]::FromArgb(255, 45, 212, 191))      # verde-agua: bot real
    # Carteira real na bandeja (BTC + outras moedas). O bot antigo, so BTC, continua em bandeja.ps1 / iniciar.bat.
    New-Shortcut 'Bot' 'carteira.ps1' $ico 'Carteira de bots (modo real): BTC + outras moedas' ' -Modo real'
}
Write-Ico $icoSim ([System.Drawing.Color]::FromArgb(255, 251, 191, 36))   # amarelo: simulacao
$simName = 'Bot Simula' + [char]0xE7 + [char]0xE3 + 'o'   # "Bot Simulacao" com acentos (arquivo fica so ASCII)
New-Shortcut $simName 'simulacao.ps1' $icoSim 'Simulacao com varias moedas (dinheiro de mentira, precos reais)'
