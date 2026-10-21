# Ícone do bot na bandeja do Windows (perto do relógio).
# - Roda o bot.ps1 escondido, sem janela de terminal.
# - Clique no ícone: abre o painel com o log ao vivo. Botão direito: menu.
# - Linhas "NOTIFICAR | título | texto" do log viram notificações do Windows.
# - Avisa se o bot parar sozinho.
# Uso: powershell -WindowStyle Hidden -ExecutionPolicy Bypass -File bandeja.ps1 [-AbrirPainel]

param([switch]$AbrirPainel)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Dir = $PSScriptRoot
$cfg = Get-Content (Join-Path $Dir 'config.json') -Raw | ConvertFrom-Json
$Mode = ([string]$cfg.modo).ToLower()
$LogFile = Join-Path $Dir "log-$Mode.txt"
$StopFlag = Join-Path $Dir "parar-$Mode.flag"

function Ask([string]$text, [string]$icon = 'Question') {
    return [System.Windows.Forms.MessageBox]::Show($text, 'Bot BTC', 'YesNo', $icon) -eq 'Yes'
}

# Só uma bandeja aberta por vez
$script:trayMutex = New-Object System.Threading.Mutex($false, 'Global\BotBTC-Bandeja')
try { $own = $script:trayMutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $own = $true }
if (-not $own) {
    [void][System.Windows.Forms.MessageBox]::Show('O Bot BTC já está aberto. Procure o robô na bandeja, perto do relógio (seta ^).', 'Bot BTC')
    return
}

# Carrega uma resolução do robo.ico (as imagens dentro dele são PNG)
function Load-Bitmap([int]$size) {
    $b = [IO.File]::ReadAllBytes((Join-Path $Dir 'robo.ico'))
    $count = [BitConverter]::ToUInt16($b, 4)
    for ($i = 0; $i -lt $count; $i++) {
        $e = 6 + 16 * $i
        $w = [int]$b[$e]; if ($w -eq 0) { $w = 256 }
        if ($w -eq $size) {
            $len = [BitConverter]::ToUInt32($b, $e + 8); $off = [BitConverter]::ToUInt32($b, $e + 12)
            $ms = New-Object IO.MemoryStream(, $b[$off..($off + $len - 1)])
            return New-Object System.Drawing.Bitmap $ms
        }
    }
    return $null
}
function Load-Icon([int]$size) {
    $bmp = Load-Bitmap $size
    if ($bmp) { return [System.Drawing.Icon]::FromHandle($bmp.GetHicon()) }
    return [System.Drawing.SystemIcons]::Application
}

# ---------- controle do bot ----------

$script:proc = $null
$script:userStopped = $false
$script:restartAt = $null        # horário marcado para reiniciar sozinho depois de uma queda
$script:restarts = @()           # quedas recentes (no máximo 5 reinícios por hora)
$ErrFile = Join-Path $Dir "erro-bot-$Mode.txt"   # saída de erro do processo do bot

function Bot-Running { return $script:proc -and -not $script:proc.HasExited }

# Escreve uma linha no log do bot (com novas tentativas se o arquivo estiver travado)
function Append-Log([string]$msg) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    for ($i = 0; $i -lt 5; $i++) {
        try { [IO.File]::AppendAllText($LogFile, $line + "`r`n", [Text.Encoding]::Default); return } catch { Start-Sleep -Milliseconds 200 }
    }
}

# $auto = reinício automático depois de uma queda (você já confirmou o modo real ao abrir)
function Start-Bot([bool]$auto = $false) {
    if (-not $auto -and $Mode -eq 'real' -and -not (Ask "Iniciar o bot em modo REAL?`n`nEle vai comprar e vender BTC com o dinheiro da sua conta Binance." 'Warning')) {
        return $false
    }
    $script:userStopped = $false
    $script:restartAt = $null
    $botArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Dir\bot.ps1`" -SemConfirmacao"
    $script:proc = Start-Process powershell.exe -ArgumentList $botArgs -WindowStyle Hidden -PassThru -RedirectStandardError $ErrFile
    $null = $script:proc.Handle   # sem isso o PowerShell 5.1 perde o ExitCode quando o processo termina
    return $true
}

function Stop-Bot {
    if (-not (Bot-Running)) { return }
    $script:userStopped = $true
    New-Item -ItemType File -Path $StopFlag -Force | Out-Null   # o bot termina a volta atual e sai
    if (-not $script:proc.WaitForExit(20000)) { $script:proc.Kill() }
}

# ---------- leitura do log ----------

$script:logPos = 0
if (Test-Path $LogFile) { $script:logPos = (Get-Item $LogFile).Length }   # só o que for novo

function Read-NewLines {
    if (-not (Test-Path $LogFile)) { return @() }
    $fs = [IO.File]::Open($LogFile, 'Open', 'Read', 'ReadWrite, Delete')
    try {
        if ($fs.Length -lt $script:logPos) { $script:logPos = 0 }   # log foi rotacionado
        [void]$fs.Seek($script:logPos, 'Begin')
        $text = (New-Object IO.StreamReader($fs, [Text.Encoding]::Default)).ReadToEnd()
    } finally { $fs.Dispose() }
    $cut = $text.LastIndexOf("`n")
    if ($cut -lt 0) { return @() }   # linha ainda sendo escrita
    $script:logPos += $cut + 1       # log em ANSI: 1 byte por caractere
    return @($text.Substring(0, $cut).Split("`n") | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_ })
}

# Últimas linhas do log (lê só o final do arquivo)
function Tail-Lines([int]$n) {
    if (-not (Test-Path $LogFile)) { return @() }
    $fs = [IO.File]::Open($LogFile, 'Open', 'Read', 'ReadWrite, Delete')
    try {
        if ($fs.Length -gt 65536) { [void]$fs.Seek(-65536, 'End') }
        $all = (New-Object IO.StreamReader($fs, [Text.Encoding]::Default)).ReadToEnd()
    } finally { $fs.Dispose() }
    return @($all.Split("`n") | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_ -match '^\[' } | Select-Object -Last $n)
}
function Tail-Log([int]$n) { return (Tail-Lines $n) -join "`r`n" }

# ---------- painel ----------

$Inv = [Globalization.CultureInfo]::InvariantCulture
$Pt = [Globalization.CultureInfo]::GetCultureInfo('pt-BR')
$Deposit = [double]$cfg.deposito_inicial_brl
$StateFile = Join-Path $Dir "estado-$Mode.json"
$PanelFile = Join-Path $Dir "painel-$Mode.json"   # resumo gravado pelo bot a cada 5 s

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
# Troca "R$ 434085.60" (formato do log) por "R$ 434.085,60"
function Pretty([string]$s) {
    return [regex]::Replace($s, 'R\$ (\d+(\.\d+)?)', { param($m) Money ([double]::Parse($m.Groups[1].Value, $Inv)) })
}
function Next-Milestone([double]$m) {
    if ($m -lt 30) { return $m + 1 }; if ($m -lt 50) { return $m + 2 }; if ($m -lt 100) { return $m + 5 }; return $m + 10
}

function Rounded-Panel([int]$x, [int]$y, [int]$w, [int]$h, $parent) {
    $p = New-Object System.Windows.Forms.Panel
    $p.SetBounds($x, $y, $w, $h)
    $p.BackColor = $Clr.card
    Set-Round $p
    $p.add_Resize({ Set-Round $this })   # refaz os cantos arredondados quando a janela muda de tamanho
    $parent.Controls.Add($p)
    return $p
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
function Add-Label($parent, [string]$text, [int]$x, [int]$y, $font, $color) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y); $l.AutoSize = $true
    $l.Font = $font; $l.ForeColor = $color; $l.BackColor = [System.Drawing.Color]::Transparent
    $parent.Controls.Add($l)
    return $l
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Bot BTC'
$form.ClientSize = New-Object System.Drawing.Size(764, 486)
$form.FormBorderStyle = 'Sizable'
$form.MinimumSize = $form.Size
$form.StartPosition = 'CenterScreen'
$form.BackColor = $Clr.bg
$form.Icon = Load-Icon 48

# Cabeçalho
$logo = New-Object System.Windows.Forms.PictureBox
$logo.SetBounds(24, 20, 44, 44); $logo.SizeMode = 'Zoom'; $logo.Image = Load-Bitmap 64
$form.Controls.Add($logo)
[void](Add-Label $form 'Bot BTC' 78 16 (Fnt 18 'Bold') $Clr.text)
if ($Mode -eq 'real') { $modeTxt = 'BTC/BRL  ·  modo real' } else { $modeTxt = 'BTC/BRL  ·  simulação' }
$lbMode = Add-Label $form $modeTxt 81 52 (Fnt 9.5) $Clr.muted
$lbMode.BringToFront()

# Barra de título escura (Windows 10 20H1+ / 11)
Add-Type -Namespace Native -Name Dwm -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);'
$form.add_HandleCreated({ $on = 1; [void][Native.Dwm]::DwmSetWindowAttribute($form.Handle, 20, [ref]$on, 4) })
$pill = Rounded-Panel 604 28 136 30 $form
$lbPill = Add-Label $pill '●  Rodando' 16 5 (Fnt 10 'Bold') $Clr.green

# Cartões
function New-Card([int]$i, [string]$title) {
    $c = Rounded-Panel (24 + $i * 182) 84 170 96 $form
    [void](Add-Label $c $title 14 12 (Fnt 9) $Clr.muted)
    $v = Add-Label $c '—' 12 32 (Fnt 16 'Bold') $Clr.text
    $s = Add-Label $c '' 14 66 (Fnt 8.5) $Clr.muted
    return @{ panel = $c; value = $v; sub = $s }
}
$cSaldo = New-Card 0 'Saldo'
$cLucro = New-Card 1 'Lucro'
$cPreco = New-Card 2 'Reais em BTC'
# Estes cartões mostram 3 linhas pequenas em vez de um valor grande
function Make-ListCard($c) {
    $c.value.Font = Fnt 9 'Bold' 'Consolas'
    $c.value.Location = New-Object System.Drawing.Point(14, 31)
    $c.sub.Location = New-Object System.Drawing.Point(14, 77)
    $c.sub.Font = Fnt 8
    $c.value.BringToFront()
    $c.sub.BringToFront()
}
Make-ListCard $cSaldo
Make-ListCard $cPreco
$cAviso = New-Card 3 'Próximo aviso'

# Situação
$sit = Rounded-Panel 24 192 716 46 $form
$sitDot = Add-Label $sit '●' 14 12 (Fnt 11) $Clr.accent
$lbSit = Add-Label $sit 'Carregando...' 34 13 (Fnt 10) $Clr.text

# Últimos registros do log (as 10 linhas mais recentes, completas)
[void](Add-Label $form 'ÚLTIMOS 10 REGISTROS' 26 254 (Fnt 8.5 'Bold') $Clr.muted)
$lnkLog = New-Object System.Windows.Forms.LinkLabel
$lnkLog.Text = 'Abrir log completo'; $lnkLog.AutoSize = $true; $lnkLog.Font = Fnt 8.5
$lnkLog.LinkColor = $Clr.accent; $lnkLog.ActiveLinkColor = $Clr.text; $lnkLog.LinkBehavior = 'HoverUnderline'
$lnkLog.BackColor = [System.Drawing.Color]::Transparent
$lnkLog.add_LinkClicked({ if (Test-Path $LogFile) { Start-Process notepad.exe -ArgumentList "`"$LogFile`"" } })
$form.Controls.Add($lnkLog)
$evPanel = Rounded-Panel 24 276 716 190 $form
$rtb = New-Object System.Windows.Forms.RichTextBox
$rtb.BorderStyle = 'None'; $rtb.ReadOnly = $true; $rtb.ScrollBars = 'Vertical'; $rtb.DetectUrls = $false; $rtb.WordWrap = $true
$rtb.BackColor = $Clr.card; $rtb.ForeColor = $Clr.text; $rtb.Font = Fnt 9.5 'Regular' 'Consolas'
$rtb.TabStop = $false
$evPanel.Controls.Add($rtb)
$script:lastEvents = ''

# Reposiciona tudo quando a janela muda de tamanho
function Do-Layout {
    $W = $form.ClientSize.Width; $H = $form.ClientSize.Height
    $pill.Left = $W - 24 - $pill.Width
    # O cartão Saldo é mais largo (tem a linha "BTC 0,00000000 (R$ 00,00)"); os outros dividem o resto
    $free = $W - 48 - 36
    $x = 24
    $weights = 1.3, 0.9, 0.9, 0.9
    $i = 0
    foreach ($c in $cSaldo, $cLucro, $cPreco, $cAviso) {
        $cw = [int][Math]::Floor($free * $weights[$i] / 4)
        $c.panel.SetBounds($x, 84, $cw, 96)
        $x += $cw + 12; $i++
    }
    $sit.Width = $W - 48
    $lnkLog.Location = New-Object System.Drawing.Point(($W - 24 - $lnkLog.Width), 253)
    $evPanel.SetBounds(24, 276, $W - 48, [Math]::Max(80, $H - 276 - 20))
    $rtb.SetBounds(14, 10, $evPanel.Width - 22, $evPanel.Height - 18)
}
$form.add_Resize({ Do-Layout })
Do-Layout

# Fechar o painel só esconde; o bot continua rodando
$form.add_FormClosing({ if ($_.CloseReason -eq 'UserClosing') { $_.Cancel = $true; $form.Hide() } })

function Refresh-Panel {
    $lines = Tail-Lines 400

    # Status de bot ligado/desligado
    if (Bot-Running) { $lbPill.Text = '●  Rodando'; $lbPill.ForeColor = $Clr.green }
    elseif ($script:restartAt) { $lbPill.Text = '●  Reiniciando…'; $lbPill.ForeColor = $Clr.amber }
    else { $lbPill.Text = '●  Parado'; $lbPill.ForeColor = $Clr.muted }

    # Cartões e situação, a partir do resumo que o bot grava a cada 5 s (painel-<modo>.json)
    $pj = $null
    try {
        $fs = [IO.File]::Open($PanelFile, 'Open', 'Read', 'ReadWrite, Delete')
        try { $pj = (New-Object IO.StreamReader($fs)).ReadToEnd() | ConvertFrom-Json } finally { $fs.Dispose() }
    } catch {}
    if ($pj) {
        $price = [double]::Parse($pj.preco, $Inv)
        $brl = [double]::Parse($pj.brl, $Inv)
        $cripto = [double]::Parse($pj.cripto, $Inv)
        $eq = [double]::Parse($pj.patrimonio, $Inv)
        $invested = [double]::Parse($pj.investido, $Inv)
        $situacao = $pj.situacao
        $profit = $eq - $invested
        $pct = 0; if ($invested -gt 0) { $pct = $profit / $invested * 100 }
        $hora = ([datetime]::Parse($pj.atualizado, $Inv)).ToString('HH:mm')

        $cSaldo.value.Text = ('{0,-4} {1}' -f 'BRL', (Money $brl)) + "`n" +
            ('{0,-4} {1} ({2})' -f $pj.ativo, $cripto.ToString('N8', $Pt), (Money ($cripto * $price))) + "`n" +
            ('{0,-4} {1}' -f 'Inv.', (Money $invested))
        if ($pj.investido_fonte -eq 'binance') { $src = 'inv. Binance' } else { $src = 'inv. do config' }
        $cSaldo.sub.Text = "total $(Money $eq) · $src"
        if ($profit -ge 0) { $sign = '+'; $cLucro.value.ForeColor = $Clr.green } else { $sign = '−'; $cLucro.value.ForeColor = $Clr.red }
        if ([Math]::Abs($profit) -lt 0.005) { $cLucro.value.ForeColor = $Clr.text }
        $cLucro.value.Text = $sign + (Money ([Math]::Abs($profit)))
        $cLucro.sub.Text = $sign + [Math]::Abs($pct).ToString('N2', $Pt) + '% sobre o investido'
        $cPreco.value.Text = (@(1, 50, 100) | ForEach-Object { '{0,-6} {1}' -f "R`$ $_", ($_ / $price).ToString('N8', $Pt) }) -join "`n"
        $cPreco.sub.Text = '1 BTC = R$ ' + $price.ToString('N0', $Pt) + ' · ' + $hora

        if ($situacao -like 'comprado*') {
            $sitDot.ForeColor = $Clr.amber
            $lbSit.Text = Pretty ($situacao -replace '^comprado a', 'Comprado a' -replace ', vende em', '  ·  vende em' -replace ' ou stop em', '  ·  stop em' -replace ', sem stop', '  ·  sem stop')
        } else {
            $sitDot.ForeColor = $Clr.accent
            $lbSit.Text = Pretty ($situacao -replace '^em BRL, compra abaixo de', 'Em reais, aguardando o BTC cair abaixo de')
        }
    }

    # Próximo aviso, a partir do estado salvo
    try {
        $st = Get-Content $StateFile -Raw | ConvertFrom-Json
        $last = [double]::Parse([string]$st.ultimo_aviso, $Inv)
        $cAviso.value.Text = Money (Next-Milestone $last)
        $cAviso.sub.Text = 'notifica ao atingir'
    } catch {}

    # As 10 linhas mais recentes do log, sem filtro
    $events = @($lines | Select-Object -Last 10)
    $key = $events -join "`n"
    if ($key -ne $script:lastEvents) {
        $script:lastEvents = $key
        # Monta numa caixa fora da tela e troca de uma vez (sem piscar nem mostrar a lista pela metade)
        $tmp = New-Object System.Windows.Forms.RichTextBox
        $tmp.Font = $rtb.Font
        foreach ($l in $events) {
            if ($l -notmatch '^\[\d{4}-(\d\d)-(\d\d) (\d\d:\d\d):\d\d\] (.*)$') { continue }
            $when = "$($matches[2])/$($matches[1]) $($matches[3])"
            $msg = $matches[4]
            $color = $Clr.text
            if ($msg -match '^NOTIFICAR \| (.*?) \| (.*)$') { $msg = "Aviso: $($matches[2])"; $color = $Clr.amber }
            elseif ($msg -match 'ERRO|stop\)|Nao consegui|recusou|inesperadamente|caiu 5') { $color = $Clr.red }
            elseif ($msg -match '^BANDEJA:') { $color = $Clr.amber }
            elseif ($msg -match '^(COMPRA|VENDA)') { $color = $Clr.green }
            elseif ($msg -match '^(Regras|Historico|Taxa|Protecao|preco R)') { $color = $Clr.muted }
            $msg = Pretty ($msg -replace '\s{2,}', ' ')            $tmp.SelectionColor = $Clr.muted; $tmp.AppendText("$when  ")
            $tmp.SelectionColor = $color; $tmp.AppendText("$msg`n")
        }
        $rtb.Rtf = $tmp.Rtf
        $rtb.SelectionStart = $rtb.TextLength   # mantém o mais recente visível
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
$tray.Text = 'Bot BTC'
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miOpen = $menu.Items.Add('Abrir painel')
$miToggle = $menu.Items.Add('Parar bot')
[void]$menu.Items.Add('-')
$miExit = $menu.Items.Add('Sair')
$tray.ContextMenuStrip = $menu

function Update-Ui {
    if (Bot-Running) { $miToggle.Text = 'Parar bot'; $tray.Text = "Bot BTC — rodando ($Mode)" }
    else { $miToggle.Text = 'Iniciar bot'; $tray.Text = 'Bot BTC — parado' }
}

$miOpen.add_Click({ Show-Panel })
$tray.add_MouseClick({ if ($_.Button -eq 'Left') { Show-Panel } })
$miToggle.add_Click({
    if (Bot-Running) {
        if (Ask "Parar o bot?`n`nSe houver BTC comprado, as ordens de proteção (lucro/stop) continuam ativas na Binance.") { Stop-Bot }
    } else { [void](Start-Bot) }
    Update-Ui
})
$miExit.add_Click({
    if ((Bot-Running) -and -not (Ask "Sair também para o bot. Continuar?`n`nSe houver BTC comprado, as ordens de proteção continuam ativas na Binance.")) { return }
    Stop-Bot
    $tray.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})

# ---------- loop de atualização (a cada 2 s) ----------

$script:exitNotified = $false
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.add_Tick({
    try {
        foreach ($l in (Read-NewLines)) {
            if ($l -match 'NOTIFICAR \| (.*?) \| (.*)$') { $tray.ShowBalloonTip(10000, $matches[1], $matches[2], 'Info') }
        }
        if ($form.Visible) { Refresh-Panel }
        if ($script:proc -and $script:proc.HasExited -and -not $script:exitNotified) {
            $script:exitNotified = $true
            if (-not $script:userStopped) {
                # Registra no log o motivo da saída: código do processo + erro que ele escreveu
                $code = $script:proc.ExitCode
                $err = ''
                try { $err = (@(Get-Content $ErrFile -ErrorAction Stop | Where-Object { $_.Trim() }) | Select-Object -Last 3) -join ' | ' } catch {}
                if ($code -eq 0) {
                    $why = 'o bot encerrou por conta propria: ' + ((Tail-Log 1) -replace '^\[[^\]]*\]\s*', '')
                } else {
                    $why = "o processo do bot terminou inesperadamente (codigo $code)"
                    if ($err) { $why += ". Erro: $err" } else { $why += ', sem mensagem de erro' }
                }
                Append-Log "BANDEJA: $why"
                $script:restarts = @($script:restarts | Where-Object { $_ -gt (Get-Date).AddHours(-1) })
                if ($code -ne 0 -and $script:restarts.Count -lt 5) {
                    $script:restartAt = (Get-Date).AddSeconds(30)
                    Append-Log 'BANDEJA: reiniciando o bot automaticamente em 30 s.'
                    $tray.ShowBalloonTip(15000, 'Bot BTC caiu — reiniciando', "Motivo: $why", 'Warning')
                } elseif ($code -ne 0) {
                    Append-Log 'BANDEJA: o bot caiu 5 vezes na ultima hora; nao vou reiniciar sozinho.'
                    $tray.ShowBalloonTip(15000, 'Bot BTC parou', "Caiu 5 vezes na última hora, então não reiniciei. Motivo: $why", 'Error')
                } else {
                    $tray.ShowBalloonTip(15000, 'Bot BTC parou', "Motivo: $why", 'Warning')
                }
            }
            Update-Ui
        }
        if ($script:restartAt -and (Get-Date) -ge $script:restartAt -and -not (Bot-Running)) {
            $script:restarts += Get-Date
            [void](Start-Bot $true)
            Append-Log 'BANDEJA: bot reiniciado automaticamente.'
            Update-Ui
        }
        if (Bot-Running) { $script:exitNotified = $false }
    } catch {}
})

# ---------- início ----------

if (-not (Start-Bot)) { $script:trayMutex.ReleaseMutex(); return }
$tray.Visible = $true
Update-Ui
$tray.ShowBalloonTip(8000, 'Bot BTC rodando', 'Ele fica aqui na bandeja, perto do relógio. Clique no robô para ver o painel.', 'Info')
$timer.Start()
if ($AbrirPainel) { Show-Panel }
[System.Windows.Forms.Application]::Run()
$tray.Dispose()
