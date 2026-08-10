<#
.SYNOPSIS
    Instala o watchdog do RustDesk em ProgramData e cria a tarefa agendada.

.DESCRIPTION
    A tarefa roda como SYSTEM, no boot e a cada N minutos. Ela cobre o caso
    de o servico ser removido ou desabilitado; as recovery actions do SCM
    (aplicadas por Install-RustDesk.ps1) cobrem quedas, que sao mais rapidas
    de detectar.

.NOTES
    Exige Administrador.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 1440)]
    [int]$IntervalMinutes = 10,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\lib\RustDeskCommon.psm1') -Force

Assert-Elevated
$log   = @()
$paths = Get-RustDeskPaths

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $paths.TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $paths.WatchdogScript -Force -ErrorAction SilentlyContinue
    Write-Host "  watchdog removido (tarefa $($paths.TaskName) e script)"
    return
}

if (-not $paths.Installed) { throw 'RustDesk nao esta instalado. Rode Setup.ps1 -Install antes.' }

# --- 1) materializar o script a partir do template --------------------
$template = Join-Path $PSScriptRoot 'watchdog\rustdesk-watchdog.ps1'
if (-not (Test-Path -LiteralPath $template)) { throw "template nao encontrado: $template" }

if (-not (Test-Path -LiteralPath $paths.WatchdogDir)) {
    New-Item -ItemType Directory -Path $paths.WatchdogDir -Force | Out-Null
}

# lista de configs vigiadas, no formato de array literal do PowerShell
$cfgLiteral = (@($paths.UserConfig, $paths.ServiceConfig) |
               ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ', '

# .Replace() e substituicao literal; -replace trataria a barra invertida dos
# caminhos do Windows como escape de regex.
$content = Get-Content -LiteralPath $template -Raw
$content = $content.Replace('__EXE__',      $paths.Exe)
$content = $content.Replace('__LOGFILE__',  $paths.WatchdogLog)
$content = $content.Replace('__CFGFILES__', $cfgLiteral)
$content = $content.Replace('__SVCLOGDIR__', $paths.ServiceLogDir)

if ($content -match '__(EXE|LOGFILE|CFGFILES|SVCLOGDIR)__') {
    throw 'algum marcador do template nao foi substituido - abortando para nao instalar script quebrado'
}

# valida a sintaxe antes de instalar: um watchdog quebrado falha silencioso
$errs = $null; $toks = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$toks, [ref]$errs)
if ($errs) { throw "o watchdog gerado tem erro de sintaxe: $($errs[0].Message)" }

Set-Content -LiteralPath $paths.WatchdogScript -Value $content -Encoding UTF8
$log += "script instalado: $($paths.WatchdogScript)"

# --- 2) tarefa agendada ------------------------------------------------
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$($paths.WatchdogScript)`""

$trigger = New-ScheduledTaskTrigger -AtStartup
# Sem -RepetitionDuration de proposito: Duration vazia significa "repetir
# indefinidamente" para o Agendador de Tarefas, que e o que se quer aqui.
#
# NAO use [TimeSpan]::MaxValue para isso. E o truque que circula para "repetir
# para sempre", mas ele serializa como P99999999DT23H59M59S e o Agendador
# rejeita o XML inteiro:
#   "O XML da tarefa contem um valor formatado incorretamente ou fora do
#    intervalo. (8,42):Duration:P99999999DT23H59M59S"
# O resultado e uma maquina sem watchdog nenhum - e como o erro nao e
# terminante, o script seguia adiante dizendo que havia registrado.
$trigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)).Repetition

$principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -RunLevel Highest

# DontStopIfGoingOnBatteries: em desktop com nobreak, uma queda de energia nao
# pode ser o motivo de o watchdog parar justamente quando ele e mais necessario.
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask -TaskName $paths.TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null

# Confirmar em vez de afirmar: o Register pode falhar sem ser terminante, e
# anunciar um watchdog que nao existe e pior do que nao ter watchdog.
$reg = Get-ScheduledTask -TaskName $paths.TaskName -ErrorAction SilentlyContinue
if (-not $reg) {
    throw "a tarefa '$($paths.TaskName)' nao existe apos o registro. Sem watchdog, uma queda do servico so seria corrigida na mao."
}
$rep = $reg.Triggers[0].Repetition
$dur = if ($rep.Duration) { $rep.Duration } else { 'indefinida' }
$log += "tarefa '$($paths.TaskName)' registrada: no boot + a cada $IntervalMinutes min, como SYSTEM"
$log += "  repeticao: intervalo $($rep.Interval), duracao $dur"

# --- 3) primeira execucao ---------------------------------------------
Start-ScheduledTask -TaskName $paths.TaskName
Start-Sleep -Seconds 8
if (Test-Path -LiteralPath $paths.WatchdogLog) {
    $log += 'primeira execucao (ultimas linhas do log):'
    Get-Content -LiteralPath $paths.WatchdogLog -Tail 5 | ForEach-Object { $log += "    $_" }
} else {
    $log += "AVISO: $($paths.WatchdogLog) nao foi criado. Verifique a tarefa no Agendador."
}

$log | ForEach-Object { Write-Host "  $_" }
