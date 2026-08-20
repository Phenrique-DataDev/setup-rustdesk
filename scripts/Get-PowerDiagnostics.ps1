<#
.SYNOPSIS
    Coleta o estado de energia da maquina num relatorio. Nao altera nada.

.DESCRIPTION
    Existe para responder uma pergunta que nenhuma verificacao responde: o que
    exatamente acontece quando a maquina sai do ocioso e algo nao volta.

    Ele reune, num arquivo so, o que normalmente se busca em cinco lugares
    diferentes - estados de suspensao suportados, valores do plano ativo, quem
    esta segurando a maquina acordada, motivo do ultimo wake, energia do
    adaptador de rede, Fast Startup - e correlaciona os eventos de
    suspensao/retorno com o log do watchdog e o log do servico do RustDesk na
    mesma janela de tempo. E na correlacao que se ve se, depois de acordar, o
    servico reclamou de IPv6, de bind, ou nao reclamou de nada.

    Somente leitura. Pode rodar sem elevacao, mas duas fontes ficam cegas:
    o log do servico (mora no perfil do LocalService) e Get-ScheduledTask, que
    devolve VAZIO em vez de negar acesso para tarefas de SYSTEM. O script
    detecta e avisa em vez de reportar ausencia como se fosse fato.

.EXAMPLE
    .\scripts\Get-PowerDiagnostics.ps1
    Coleta e imprime o caminho do relatorio.

.EXAMPLE
    .\scripts\Get-PowerDiagnostics.ps1 -Hours 168
    Uma semana de eventos em vez das 72 horas padrao.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 720)]
    [int]$Hours = 72,
    [string]$OutputDir,
    [switch]$NoHtmlReports   # pula sleepstudy e batteryreport, que sao lentos
)

$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot '..\lib\RustDeskCommon.psm1') -Force

$paths   = Get-RustDeskPaths
$elevado = Test-Elevated
$desde   = (Get-Date).AddHours(-$Hours)

if (-not $OutputDir) { $OutputDir = $paths.DiagnosticsDir }
if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}
$carimbo  = Get-Date -Format 'yyyyMMdd-HHmmss'
$relatorio = Join-Path $OutputDir "power-diagnostics-$carimbo.txt"

$out = New-Object System.Collections.Generic.List[string]
function Add-Linha { param([string]$T = '') ; $out.Add($T) }
function Add-Secao {
    param([string]$Titulo)
    Add-Linha ''
    Add-Linha ('=' * 72)
    Add-Linha "  $Titulo"
    Add-Linha ('=' * 72)
}
function Add-Comando {
    # powercfg falha em algumas maquinas (sleepstudy sem suporte, waketimers
    # sem permissao). Nenhuma dessas falhas pode abortar a coleta.
    param([string]$Titulo, [scriptblock]$Bloco)
    Add-Secao $Titulo
    try {
        $r = & $Bloco 2>&1 | Out-String
        if ([string]::IsNullOrWhiteSpace($r)) { Add-Linha '(sem saida)' }
        else { Add-Linha $r.TrimEnd() }
    } catch {
        Add-Linha "FALHOU: $($_.Exception.Message)"
    }
}

Add-Linha "Diagnostico de energia - setup-rustdesk"
Add-Linha "Gerado em .....: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Add-Linha "Maquina .......: $env:COMPUTERNAME"
Add-Linha "Elevado .......: $elevado"
Add-Linha "Portatil ......: $(Test-IsLaptop)"
Add-Linha "Bateria .......: $(Get-BatteryPercent)%"
Add-Linha "Janela ........: ultimas $Hours h (desde $($desde.ToString('yyyy-MM-dd HH:mm:ss')))"
Add-Linha "Sessao remota .: $(if (Test-RemoteSessionActive) { 'ATIVA agora' } else { 'nenhuma agora' })"
if (-not $elevado) {
    Add-Linha ''
    Add-Linha 'AVISO: rodando SEM elevacao. Duas fontes ficam cegas e a ausencia'
    Add-Linha '       delas nao prova nada: o log do servico do RustDesk (perfil do'
    Add-Linha '       LocalService) e Get-ScheduledTask para tarefas de SYSTEM, que'
    Add-Linha '       devolve vazio em vez de negar acesso.'
}

# --- estado da maquina -------------------------------------------------
Add-Comando 'powercfg /a - estados de suspensao suportados' { powercfg /a }
Add-Comando 'powercfg /requests - quem segura a maquina acordada AGORA' { powercfg /requests }
Add-Comando 'powercfg /lastwake - o que acordou a maquina da ultima vez' { powercfg /lastwake }
Add-Comando 'powercfg /waketimers - timers que podem acordar a maquina' { powercfg /waketimers }

# --- plano ativo -------------------------------------------------------
Add-Secao 'plano de energia ativo - subvalores que este repositorio ajusta'
foreach ($item in @(
    @{ Sub = 'SUB_BUTTONS'; Setting = 'LIDACTION';     Rotulo = 'acao ao fechar a tampa' },
    @{ Sub = 'SUB_SLEEP';   Setting = 'STANDBYIDLE';   Rotulo = 'suspender por ociosidade' },
    @{ Sub = 'SUB_SLEEP';   Setting = 'HIBERNATEIDLE'; Rotulo = 'hibernar por ociosidade' },
    @{ Sub = 'SUB_VIDEO';   Setting = 'VIDEOIDLE';     Rotulo = 'desligar o painel' },
    @{ Sub = 'SUB_NONE';    Setting = 'F15576E8-98B7-4186-B944-EAFA664402D9'; Rotulo = 'conectividade em espera' }
)) {
    $saida = (& powercfg /q SCHEME_CURRENT $item.Sub $item.Setting 2>&1 | Out-String)
    # Os rotulos do powercfg sao traduzidos; o formato 0x00000000 nao e.
    $m = [regex]::Matches($saida, '0x[0-9A-Fa-f]{8}')
    if ($m.Count -ge 2) {
        $ac = [Convert]::ToInt64($m[$m.Count - 2].Value, 16)
        $dc = [Convert]::ToInt64($m[$m.Count - 1].Value, 16)
        Add-Linha ("{0,-30} AC={1,-8} DC={2}" -f $item.Rotulo, $ac, $dc)
    } else {
        Add-Linha ("{0,-30} nao exposto pelo plano ativo" -f $item.Rotulo)
    }
}

# --- Fast Startup ------------------------------------------------------
Add-Secao 'Fast Startup (hiberboot)'
$hb = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
                       -Name HiberbootEnabled -ErrorAction SilentlyContinue
if ($null -eq $hb) {
    Add-Linha 'HiberbootEnabled ausente (equivale a desligado nesta maquina).'
} elseif ($hb.HiberbootEnabled -eq 1) {
    Add-Linha 'HiberbootEnabled = 1 (LIGADO).'
    Add-Linha 'Efeito: desligar e ligar nao e um boot - a sessao do kernel e hibernada'
    Add-Linha 'e restaurada, e o LastBootUpTime NAO avanca. Por isso o watchdog carimba'
    Add-Linha 'a epoca com boot MAIS ultimo resume; so o boot travaria a correcao de IPv6.'
} else {
    Add-Linha 'HiberbootEnabled = 0 (desligado). Desligar e ligar e um boot de verdade.'
}

# --- adaptadores de rede ----------------------------------------------
Add-Secao 'adaptadores de rede - energia'
$nics = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
if ($nics.Count -eq 0) { Add-Linha '(nenhum adaptador fisico ativo)' }
foreach ($nic in $nics) {
    Add-Linha "$($nic.Name) [$($nic.InterfaceDescription)]"
    $pm = Get-NetAdapterPowerManagement -Name $nic.Name -ErrorAction SilentlyContinue
    if (-not $pm) {
        Add-Linha '  o driver nao expoe gerenciamento de energia'
    } else {
        Add-Linha "  AllowComputerToTurnOffDevice: $($pm.AllowComputerToTurnOffDevice)"
        Add-Linha "  DeviceSleepOnDisconnect ....: $($pm.DeviceSleepOnDisconnect)"
        Add-Linha "  WakeOnMagicPacket ..........: $($pm.WakeOnMagicPacket)"
        Add-Linha "  WakeOnPattern ..............: $($pm.WakeOnPattern)"
        if ($pm.AllowComputerToTurnOffDevice -eq 'Enabled') {
            Add-Linha '  ATENCAO: com isto ligado, o Windows pode desligar o adaptador durante a'
            Add-Linha '           suspensao e a rede demora a voltar. E o suspeito numero um de'
            Add-Linha '           "acordou mas o RustDesk so reconecta minutos depois".'
        }
    }
}

# --- tarefas -----------------------------------------------------------
Add-Secao 'tarefas agendadas do setup'
foreach ($t in @($paths.TaskName, $paths.AwakeTask, 'HerdrServer')) {
    $task = Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
    if (-not $task) {
        $nota = if (-not $elevado -and $t -ne 'HerdrServer') { ' (pode ser falso negativo: sem elevacao)' } else { '' }
        Add-Linha "$t : NAO ENCONTRADA$nota"
        continue
    }
    $info = $task | Get-ScheduledTaskInfo
    Add-Linha "$t : $($task.State), ultimo run $($info.LastRunTime), resultado $($info.LastTaskResult)"
    $tipos = ($task.Triggers | ForEach-Object { $_.CimClass.CimClassName }) -join ', '
    Add-Linha "  triggers: $tipos"
}
Add-Linha ''
Add-Linha 'Lembrete: LastTaskResult 267009 (0x41301) e SCHED_S_TASK_RUNNING - o valor'
Add-Linha 'saudavel para RustDeskAwake e HerdrServer, que rodam em foreground. Um 0 ali'
Add-Linha 'significaria que o processo saiu.'

# --- eventos de energia -------------------------------------------------
Add-Secao "eventos de energia (ultimas $Hours h)"
$eventos = @()
foreach ($f in @(
    @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power';         Id = @(41, 42, 107, 131, 507); StartTime = $desde },
    @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Power-Troubleshooter'; Id = @(1);                     StartTime = $desde }
)) {
    try {
        $eventos += Get-WinEvent -FilterHashtable $f -ErrorAction Stop
    } catch {
        # 'No events were found' e o caso normal numa maquina que nao suspendeu
    }
}
$eventos = @($eventos | Sort-Object TimeCreated)
if ($eventos.Count -eq 0) {
    Add-Linha 'Nenhum evento de suspensao ou retorno na janela. A maquina nao dormiu.'
} else {
    foreach ($e in $eventos) {
        $rotulo = switch ($e.Id) {
            41  { 'DESLIGOU SEM AVISO (41) - queda de energia ou travamento' }
            42  { 'ENTROU EM SUSPENSAO (42)' }
            107 { 'RETORNOU DA SUSPENSAO (107)' }
            131 { 'AVISO DE ENERGIA (131)' }
            507 { 'MODERN STANDBY (507)' }
            1   { 'RETORNO - motivo do wake (Power-Troubleshooter 1)' }
            default { "evento $($e.Id)" }
        }
        Add-Linha "$($e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))  $rotulo"
        if ($e.Id -eq 1) {
            $msg = ($e.Message -split "`n" | Where-Object { $_ -match ':' } | Select-Object -First 6)
            $msg | ForEach-Object { Add-Linha "    $($_.Trim())" }
        }
    }
}

# --- correlacao: o ponto do script -------------------------------------
Add-Secao 'correlacao - o que o RustDesk fez em volta de cada retorno'
$resumes = @($eventos | Where-Object { $_.Id -eq 107 -or $_.Id -eq 1 })
if ($resumes.Count -eq 0) {
    Add-Linha 'Sem retornos na janela - nada a correlacionar.'
} else {
    $linhasWd = @()
    if (Test-Path -LiteralPath $paths.WatchdogLog) {
        $linhasWd = Get-Content -LiteralPath $paths.WatchdogLog -ErrorAction SilentlyContinue
    } else {
        Add-Linha "watchdog.log nao encontrado em $($paths.WatchdogLog)"
    }

    $linhasSvc = @()
    $svcDir = Join-Path $paths.ServiceLogDir 'server'
    if (Test-Path -LiteralPath $svcDir) {
        $ultimo = Get-ChildItem $svcDir -Filter *.log -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($ultimo) { $linhasSvc = Get-Content -LiteralPath $ultimo.FullName -ErrorAction SilentlyContinue }
    } elseif (-not $elevado) {
        Add-Linha 'log do servico ilegivel sem elevacao - rode como Administrador para incluir.'
    } else {
        Add-Linha "log do servico nao encontrado em $svcDir"
    }

    foreach ($r in $resumes) {
        $ini = $r.TimeCreated.AddMinutes(-1)
        $fim = $r.TimeCreated.AddMinutes(15)
        Add-Linha ''
        Add-Linha "--- retorno em $($r.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')) (janela -1min / +15min) ---"

        # o watchdog carimba cada linha com 'yyyy-MM-dd HH:mm:ss | msg'
        $wd = $linhasWd | Where-Object {
            if ($_ -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') {
                $t = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $null)
                return ($t -ge $ini -and $t -le $fim)
            }
            return $false
        }
        if ($wd) { $wd | ForEach-Object { Add-Linha "  [watchdog] $_" } }
        else     { Add-Linha '  [watchdog] nenhuma passada registrada nesta janela.' }

        $svc = $linhasSvc | Where-Object { $_ -match '(IPv6|Failed to|relay|rendezvous|punch)' } |
               Select-Object -Last 8
        if ($svc) { $svc | ForEach-Object { Add-Linha "  [servico] $_" } }
        else      { Add-Linha '  [servico] nada relevante no log mais recente.' }
    }
}

# --- relatorios HTML ---------------------------------------------------
if (-not $NoHtmlReports) {
    Add-Secao 'relatorios HTML'
    foreach ($r in @(
        @{ Nome = 'sleepstudy';    Args = @('/sleepstudy',    '/output') },
        @{ Nome = 'batteryreport'; Args = @('/batteryreport', '/output') }
    )) {
        $destino = Join-Path $OutputDir "$($r.Nome)-$carimbo.html"
        try {
            & powercfg $r.Args[0] $r.Args[1] $destino 2>&1 | Out-Null
            if (Test-Path -LiteralPath $destino) { Add-Linha "$($r.Nome): $destino" }
            else { Add-Linha "$($r.Nome): nao gerado (a maquina pode nao suportar)" }
        } catch {
            Add-Linha "$($r.Nome): falhou - $($_.Exception.Message)"
        }
    }
}

# --- gravar ------------------------------------------------------------
Set-Content -LiteralPath $relatorio -Value $out -Encoding UTF8

Write-Host ''
Write-Host "  Relatorio gravado em: $relatorio"
if (-not $elevado) {
    Write-Host '  AVISO: sem elevacao. O log do servico e as tarefas de SYSTEM podem faltar.' -ForegroundColor Yellow
}
Write-Host '  Nada foi alterado - este script e somente leitura.'
Write-Host ''
