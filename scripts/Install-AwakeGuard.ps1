<#
.SYNOPSIS
    Instala o daemon RustDeskAwake em ProgramData e cria a tarefa agendada.

.DESCRIPTION
    O daemon impede que a maquina suspenda por ociosidade enquanto ha sessao
    remota do RustDesk em curso, e solta o bloqueio assim que ela termina.

    Ele existe porque o timer de ociosidade do Windows olha teclado e mouse: uma
    sessao usando so o Terminal nao gera nenhum dos dois, e a maquina dormiria
    no meio do trabalho. A alternativa de simplesmente desligar a suspensao
    custaria bateria em todas as horas em que ninguem esta conectado.

    So instala em maquina portatil. Em desktop nao ha o que resolver.

.EXAMPLE
    .\scripts\Install-AwakeGuard.ps1
    Instala o daemon e registra a tarefa RustDeskAwake.

.EXAMPLE
    .\scripts\Install-AwakeGuard.ps1 -Uninstall
    Remove a tarefa e o script. O bloqueio e solto quando o daemon morre.

.NOTES
    Exige Administrador.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigFile,
    [switch]$Uninstall,
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\lib\RustDeskCommon.psm1') -Force

Assert-Elevated
$log   = @()
$paths = Get-RustDeskPaths

function Stop-AwakeDaemon {
    <#
        Para a instancia viva do daemon e espera o Agendador confirmar.
        Devolve $true se havia instancia e ela parou, $false se nao havia
        nenhuma, e $null se ela nao parou dentro do prazo.

        Existe porque Register-ScheduledTask -Force troca a definicao e o
        script em disco, mas NAO toca na instancia que ja esta rodando: o
        powershell.exe antigo segue vivo com o codigo antigo em memoria. E como
        a tarefa e IgnoreNew, o Start-ScheduledTask seguinte e recusado
        (LastTaskResult 0x800710E0) - a reinstalacao parecia ter funcionado e
        nada tinha mudado. O mesmo vale para remover: Unregister-ScheduledTask
        apaga a tarefa e deixa o processo orfao rodando ate o proximo boot.

        O Stop mata o processo sem passar pelo finally do daemon; o bloqueio de
        suspensao e solto pelo Windows quando a thread morre.
    #>
    param([string]$TaskName, [int]$TimeoutSeconds = 20)

    # Guarda propria: nada aqui pode rodar em simulacao.
    if ($WhatIfPreference) { return $false }

    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t -or [string]$t.State -ne 'Running') { return $false }

    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $limite = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $limite) {
        $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if (-not $t -or [string]$t.State -ne 'Running') { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

if ($Uninstall) {
    [void](Stop-AwakeDaemon -TaskName $paths.AwakeTask)
    Unregister-ScheduledTask -TaskName $paths.AwakeTask -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $paths.AwakeScript -Force -ErrorAction SilentlyContinue
    Write-Host "  daemon removido (tarefa $($paths.AwakeTask) e script)"
    Write-Host '  o bloqueio de suspensao e solto quando o processo termina - nada fica preso'
    return
}

if (-not (Test-IsLaptop)) {
    Write-Host '  Esta maquina nao e portatil. Daemon nao instalado - nao ha suspensao por bateria a evitar.'
    return
}

# --- 1) opcoes ---------------------------------------------------------
if (-not $ConfigFile) {
    $custom  = Join-Path $PSScriptRoot '..\config\power-custom.psd1'
    $default = Join-Path $PSScriptRoot '..\config\power.psd1'
    $ConfigFile = if (Test-Path -LiteralPath $custom) { $custom } else { $default }
}
if (-not (Test-Path -LiteralPath $ConfigFile)) { throw "arquivo de configuracao nao encontrado: $ConfigFile" }

$opts = Import-RustDeskConfigFile -Path $ConfigFile
$log += "opcoes carregadas de: $(Resolve-Path $ConfigFile)"

if ($opts.Contains('KeepAwakeWhileConnected') -and $opts['KeepAwakeWhileConnected'] -ne $true) {
    [void](Stop-AwakeDaemon -TaskName $paths.AwakeTask)
    Unregister-ScheduledTask -TaskName $paths.AwakeTask -Confirm:$false -ErrorAction SilentlyContinue
    $log += 'KeepAwakeWhileConnected = $false: daemon nao instalado (e removido se existia).'
    $log | ForEach-Object { Write-Host "  $_" }
    return
}

$poll = if ($opts.Contains('KeepAwakePollSeconds')) { [int]$opts['KeepAwakePollSeconds'] } else { 30 }
$minB = if ($opts.Contains('KeepAwakeMinBatteryPercent')) { [int]$opts['KeepAwakeMinBatteryPercent'] } else { 15 }
if ($poll -lt 5 -or $poll -gt 600)  { throw "KeepAwakePollSeconds fora da faixa util (5..600): $poll" }
if ($minB -lt 0 -or $minB -gt 100)  { throw "KeepAwakeMinBatteryPercent fora de 0..100: $minB" }

$standbyDc = if ($opts.Contains('StandbyIdleDC')) { [int]$opts['StandbyIdleDC'] } else { 0 }
if ($standbyDc -gt 0 -and $poll -ge $standbyDc) {
    # Reagir depois de a maquina ja ter dormido nao serve para nada.
    $log += "AVISO: KeepAwakePollSeconds ($poll) nao e menor que StandbyIdleDC ($standbyDc)."
    $log += '  O daemon pode reagir tarde demais. Reduza o intervalo no power-custom.psd1.'
}

# --- 2) materializar o script a partir do template --------------------
$template = Join-Path $PSScriptRoot 'awake\rustdesk-awake.ps1'
if (-not (Test-Path -LiteralPath $template)) { throw "template nao encontrado: $template" }

$dir = Split-Path -Parent $paths.AwakeScript
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

# .Replace() e substituicao literal; -replace trataria a barra invertida dos
# caminhos do Windows como escape de regex.
$content = Get-Content -LiteralPath $template -Raw
$content = $content.Replace('__LOGFILE__', $paths.AwakeLog)
$content = $content.Replace('__POLL__',    [string]$poll)
$content = $content.Replace('__MINBAT__',  [string]$minB)

if ($content -match '__(LOGFILE|POLL|MINBAT)__') {
    throw 'algum marcador do template nao foi substituido - abortando para nao instalar script quebrado'
}

# valida a sintaxe antes de instalar: um daemon quebrado falha silencioso
$errs = $null; $toks = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$toks, [ref]$errs)
if ($errs) { throw "o daemon gerado tem erro de sintaxe: $($errs[0].Message)" }

if (-not $PSCmdlet.ShouldProcess($paths.AwakeScript, 'gravar o daemon')) {
    # o $log acumulado tambem sai aqui: em simulacao ele carrega justamente o
    # diagnostico (de onde vieram as opcoes, avisos de valor incoerente), e
    # descarta-lo tornava o -WhatIf menos informativo que a execucao real
    $log += "[SIMULACAO] gravaria $($paths.AwakeScript) e registraria a tarefa $($paths.AwakeTask)"
    $log | ForEach-Object { Write-Host "  $_" }
    return
}

# Parar ANTES de trocar script e definicao: sem isto a instancia antiga segue
# rodando o codigo velho e recusa a nova (ver Stop-AwakeDaemon).
$parou = Stop-AwakeDaemon -TaskName $paths.AwakeTask
if ($parou -eq $true) {
    $log += 'instancia anterior do daemon parada (o codigo novo so vale num processo novo)'
} elseif ($null -eq $parou) {
    $log += 'AVISO: a instancia anterior do daemon nao parou a tempo. A nova pode ser recusada (IgnoreNew).'
}

Set-Content -LiteralPath $paths.AwakeScript -Value $content -Encoding UTF8
$log += "script instalado: $($paths.AwakeScript)"

# --- 3) tarefa agendada ------------------------------------------------
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$($paths.AwakeScript)`""

# No boot e ao acordar. O trigger de resume importa porque a tarefa pode ter
# morrido durante a suspensao, e o daemon precisa estar de pe antes de qualquer
# sessao nova.
$triggers = @(New-ScheduledTaskTrigger -AtStartup)
try {
    $triggers += New-RustDeskResumeTrigger -DelaySeconds 10
    $log += 'trigger de resume adicionado (Power-Troubleshooter 1 e Kernel-Power 507)'
} catch {
    $log += "AVISO: nao foi possivel criar o trigger de resume: $($_.Exception.Message)"
    $log += '  O daemon ainda sobe no boot; so nao reinicia sozinho depois de uma suspensao.'
}

$principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -RunLevel Highest

# ExecutionTimeLimit 0 = sem limite. O default de tres dias mataria o daemon no
# meio do uso, exatamente como mataria o servidor do Herdr.
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask -TaskName $paths.AwakeTask -Action $action -Trigger $triggers `
    -Principal $principal -Settings $settings -Force | Out-Null

# Confirmar em vez de afirmar: o Register pode falhar sem ser terminante.
$reg = Get-ScheduledTask -TaskName $paths.AwakeTask -ErrorAction SilentlyContinue
if (-not $reg) {
    throw "a tarefa '$($paths.AwakeTask)' nao existe apos o registro. Sem ela a maquina suspende no meio da sessao."
}
$log += "tarefa '$($paths.AwakeTask)' registrada: no boot e ao acordar, como SYSTEM"
$log += "  intervalo de checagem: ${poll}s, limiar de bateria: ${minB}%"

# --- 4) primeira execucao ---------------------------------------------
if (-not $NoStart) {
    Start-ScheduledTask -TaskName $paths.AwakeTask
    Start-Sleep -Seconds 6
    # Confirmar em vez de afirmar: um Start recusado nao gera erro nenhum.
    $estado = [string](Get-ScheduledTask -TaskName $paths.AwakeTask -ErrorAction SilentlyContinue).State
    if ($estado -eq 'Running') {
        $log += 'daemon em execucao (tarefa em estado Running)'
    } else {
        $log += "AVISO: a tarefa nao ficou em execucao (estado: $estado). Veja $($paths.AwakeLog)."
    }
    if (Test-Path -LiteralPath $paths.AwakeLog) {
        $log += 'primeira execucao (ultimas linhas do log):'
        Get-Content -LiteralPath $paths.AwakeLog -Tail 3 | ForEach-Object { $log += "    $_" }
    } else {
        $log += "AVISO: $($paths.AwakeLog) nao foi criado. Verifique a tarefa no Agendador."
    }
}

$log | ForEach-Object { Write-Host "  $_" }
