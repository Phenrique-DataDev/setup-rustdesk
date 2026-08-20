<#
    Daemon RustDeskAwake - template.

    NAO edite a copia em ProgramData: ela e gerada por
    scripts/Install-AwakeGuard.ps1 a partir deste arquivo, substituindo os
    marcadores __LOGFILE__, __POLL__ e __MINBAT__. Editar la se perde na
    proxima instalacao.

    O que ele faz: enquanto houver sessao remota do RustDesk em curso, impede
    que a maquina suspenda por ociosidade. Isso existe porque o timer de
    ociosidade do Windows olha teclado e mouse, e uma sessao so de Terminal nao
    produz nenhum dos dois - a maquina dormiria no meio de um agente rodando.

    O que ele NAO faz: nao impede o painel de apagar (ES_DISPLAY_REQUIRED fica
    de fora de proposito - em notebook o painel e o maior consumidor isolado), e
    nao segura a maquina acordada com a bateria abaixo do limiar. Desligar por
    carga zero e pior do que suspender.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$logFile   = '__LOGFILE__'
$poll      = __POLL__
$minBat    = __MINBAT__

# --- log ---------------------------------------------------------------
# Mesmo esquema do watchdog: mutex nomeado porque a tarefa pode reiniciar por
# cima de si mesma, e rotacao para o arquivo nao crescer sem limite.
function Write-Log {
    param([string]$Mensagem)
    $linha = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Mensagem"
    $mtx = New-Object System.Threading.Mutex($false, 'Global\RustDeskAwakeLog')
    try {
        [void]$mtx.WaitOne(5000)
        $dir = Split-Path -Parent $logFile
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if ((Test-Path -LiteralPath $logFile) -and (Get-Item -LiteralPath $logFile).Length -gt 1MB) {
            $manter = Get-Content -LiteralPath $logFile -Tail 2000
            Set-Content -LiteralPath $logFile -Value $manter -Encoding UTF8
        }
        Add-Content -LiteralPath $logFile -Value $linha -Encoding UTF8
    } catch {
    } finally {
        try { $mtx.ReleaseMutex() } catch { }
        $mtx.Dispose()
    }
}

# --- P/Invoke ----------------------------------------------------------
# O estado e por THREAD, nao por processo: a chamada tem que sair da mesma
# thread que continua viva. Um Start-Job ou runspace novo perderia o bloqueio
# sem erro nenhum, e a maquina dormiria com a sessao aberta. Por isso o laco
# fica na thread principal do script.
if (-not ('RustDeskAwake.Native' -as [type])) {
    Add-Type -Namespace RustDeskAwake -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);
'@
}

$ES_CONTINUOUS      = [uint32]0x80000000
$ES_SYSTEM_REQUIRED = [uint32]0x00000001

function Set-Bloqueio {
    param([bool]$Ativo)
    $flags = if ($Ativo) { $ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED } else { $ES_CONTINUOUS }
    $r = [RustDeskAwake.Native]::SetThreadExecutionState($flags)
    return ($r -ne 0)
}

function Test-SessaoRemota {
    # Mesma definicao usada pelo watchdog: o connection manager (--cm) so existe
    # enquanto alguem esta conectado. Devolve [bool], nunca a linha de comando -
    # ela carrega --password e nao pode ir para log.
    try {
        $p = @(Get-CimInstance Win32_Process -Filter "Name='rustdesk.exe'" -ErrorAction Stop |
               Where-Object { $_.CommandLine -match '--cm' })
        return ($p.Count -gt 0)
    } catch {
        return $false
    }
}

function Get-Carga {
    try {
        $b = @(Get-CimInstance Win32_Battery -ErrorAction Stop |
               Where-Object { $null -ne $_.EstimatedChargeRemaining })
        if ($b.Count -eq 0) { return 100 }
        return [int]($b | Measure-Object -Property EstimatedChargeRemaining -Minimum).Minimum
    } catch {
        return 100
    }
}

# --- sair sempre solta -------------------------------------------------
# Um daemon morto deixando a maquina insone para sempre e pior do que nao ter
# daemon nenhum. Duas redes: o finally do laco e o evento de saida do host.
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    try { [RustDeskAwake.Native]::SetThreadExecutionState([uint32]0x80000000) | Out-Null } catch { }
}

Write-Log "Daemon iniciado. Intervalo ${poll}s, limiar de bateria ${minBat}%."

$estadoAnterior = $null
try {
    while ($true) {
        $sessao = Test-SessaoRemota
        $carga  = Get-Carga
        $querBloquear = $sessao -and ($carga -ge $minBat)

        $ok = Set-Bloqueio -Ativo $querBloquear

        # Logar so na transicao: a cada passada encheria o arquivo de ruido e
        # esconderia justamente o evento que interessa.
        if ($estadoAnterior -ne $querBloquear) {
            if ($querBloquear) {
                Write-Log "Sessao remota ativa (bateria ${carga}%). Segurando a maquina acordada."
            } elseif ($sessao) {
                Write-Log "Sessao remota ativa, mas a bateria caiu para ${carga}% (limiar ${minBat}%). Soltando: e melhor suspender do que desligar."
            } else {
                Write-Log 'Sem sessao remota. Bloqueio solto - a maquina volta a poder suspender.'
            }
            if (-not $ok) { Write-Log 'AVISO: SetThreadExecutionState devolveu 0 (a chamada falhou).' }
            $estadoAnterior = $querBloquear
        }

        Start-Sleep -Seconds $poll
    }
} finally {
    [RustDeskAwake.Native]::SetThreadExecutionState($ES_CONTINUOUS) | Out-Null
    Write-Log 'Daemon encerrado. Bloqueio solto.'
}
