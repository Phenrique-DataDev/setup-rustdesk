<#
.SYNOPSIS
    Valida a instalacao: binario, servico, watchdog e as DUAS configs.

.DESCRIPTION
    Cada verificacao vira uma linha PASS / FALHA / AVISO. Sai com codigo 1 se
    houver qualquer FALHA, para poder ser usado em automacao.

    Somente leitura: nao altera nada. Roda sem elevacao, mas as verificacoes
    da config do servico exigem Administrador (o diretorio e protegido) e
    aparecem como AVISO quando nao ha privilegio.

.PARAMETER ShowLogs
    Inclui as ultimas linhas dos logs do servico e do terminal-helper.
#>
[CmdletBinding()]
param(
    [string]$ConfigFile,
    [switch]$ShowLogs
)

$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot '..\lib\RustDeskCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\lib\RustDeskToml.psm1')   -Force

$script:falhas = 0
$script:avisos = 0

function Test-Item($nome, $ok, $detalhe = '') {
    if ($ok -eq $true) {
        Write-Host "  [PASS]  $nome" -ForegroundColor Green
    } elseif ($ok -eq 'aviso') {
        Write-Host "  [AVISO] $nome" -ForegroundColor Yellow
        $script:avisos++
    } else {
        Write-Host "  [FALHA] $nome" -ForegroundColor Red
        $script:falhas++
    }
    if ($detalhe) { Write-Host "          $detalhe" -ForegroundColor DarkGray }
}

$paths    = Get-RustDeskPaths
$elevated = Test-Elevated

Write-Host ''
Write-Host '=== RustDesk: verificacao do setup ===' -ForegroundColor Cyan
if (-not $elevated) {
    Write-Host '  (sem elevacao: a config do servico nao pode ser lida)' -ForegroundColor Yellow
}
Write-Host ''

# --- binario e servico ------------------------------------------------
Write-Host 'Instalacao' -ForegroundColor Cyan
Test-Item 'rustdesk.exe encontrado' $paths.Installed $paths.Exe

$svc = Get-Service -Name $paths.ServiceName -ErrorAction SilentlyContinue
Test-Item 'servico rustdesk registrado' ([bool]$svc)
if ($svc) {
    Test-Item 'servico rodando'        ($svc.Status    -eq 'Running')   "status: $($svc.Status)"
    Test-Item 'inicializacao Automatic' ($svc.StartType -eq 'Automatic') "StartType: $($svc.StartType)"
}

if ($elevated -and $svc) {
    $qf = (& sc.exe qfailure $paths.ServiceName) -join ' '
    # a saida do sc.exe e localizada; o numero 5000 (ms) aparece em qualquer idioma
    Test-Item 'recovery do SCM configurado' ($qf -match '5000') 'reinicio automatico apos falha'
}

# --- configs -----------------------------------------------------------
Write-Host ''
Write-Host 'Configuracao' -ForegroundColor Cyan

if (-not $ConfigFile) {
    $custom  = Join-Path $PSScriptRoot '..\config\custom.psd1'
    $default = Join-Path $PSScriptRoot '..\config\default.psd1'
    $ConfigFile = if (Test-Path -LiteralPath $custom) { $custom } else { $default }
}
$esperado = Import-RustDeskConfigFile -Path $ConfigFile
Write-Host "  esperado conforme: $(Split-Path $ConfigFile -Leaf)" -ForegroundColor DarkGray

foreach ($alvo in @(
    @{ Nome = 'usuario'; Arquivo = $paths.UserConfig;    Protegido = $false },
    @{ Nome = 'servico'; Arquivo = $paths.ServiceConfig; Protegido = $true  }
)) {
    Write-Host "  --- config do $($alvo.Nome) ---" -ForegroundColor DarkGray

    if ($alvo.Protegido -and -not $elevated) {
        Test-Item "config do $($alvo.Nome) legivel" 'aviso' 'requer Administrador'
        continue
    }
    if (-not (Test-Path -LiteralPath $alvo.Arquivo)) {
        Test-Item "config do $($alvo.Nome) existe" $false $alvo.Arquivo
        continue
    }

    Test-Item "config do $($alvo.Nome) sem BOM" (-not (Test-TomlBom -Path $alvo.Arquivo)) `
        'o formato nativo do RustDesk e UTF-8 sem BOM'

    foreach ($k in $esperado.Keys) {
        $atual = Get-TomlOption -Path $alvo.Arquivo -Key $k
        Test-Item "$($alvo.Nome): $k = '$($esperado[$k])'" ($atual -eq $esperado[$k]) `
            $(if ($null -eq $atual) { 'ausente do arquivo' } elseif ($atual -ne $esperado[$k]) { "encontrado: '$atual'" } else { '' })
    }
}

# --- senha permanente --------------------------------------------------
# Quem autentica com a tela bloqueada e o servico. Sem senha gravada no perfil
# dele, a conexao bloqueada falha mesmo com todas as opcoes corretas.
Write-Host ''
Write-Host 'Senha permanente' -ForegroundColor Cyan
foreach ($alvo in @(
    @{ Nome = 'usuario'; Arquivo = $paths.UserPassword;    Protegido = $false },
    @{ Nome = 'servico'; Arquivo = $paths.ServicePassword; Protegido = $true  }
)) {
    if ($alvo.Protegido -and -not $elevated) {
        Test-Item "senha do $($alvo.Nome)" 'aviso' 'requer Administrador'
        continue
    }
    if (-not (Test-Path -LiteralPath $alvo.Arquivo)) {
        Test-Item "senha do $($alvo.Nome) gravada" $false 'RustDesk.toml nao existe'
        continue
    }
    $temSenha = [bool](Select-String -LiteralPath $alvo.Arquivo -Pattern "^\s*password\s*=\s*'.+'" -Quiet)
    Test-Item "senha do $($alvo.Nome) gravada" $temSenha `
        $(if (-not $temSenha) { 'defina uma senha permanente na UI do RustDesk' } else { '' })
}

# --- watchdog ----------------------------------------------------------
Write-Host ''
Write-Host 'Watchdog' -ForegroundColor Cyan
Test-Item 'script do watchdog instalado' (Test-Path -LiteralPath $paths.WatchdogScript) $paths.WatchdogScript

# Sem elevacao, Get-ScheduledTask devolve vazio para tarefas de SYSTEM em vez
# de negar acesso - um falso negativo silencioso. So afirma ausencia se elevado.
$task = Get-ScheduledTask -TaskName $paths.TaskName -ErrorAction SilentlyContinue
if (-not $task -and -not $elevated) {
    Test-Item 'tarefa agendada registrada' 'aviso' 'requer Administrador para consultar tarefas de SYSTEM'
} else {
    Test-Item 'tarefa agendada registrada' ([bool]$task)
}
if ($task) {
    Test-Item 'tarefa habilitada' ($task.State -ne 'Disabled') "estado: $($task.State)"
    $info = Get-ScheduledTaskInfo -TaskName $paths.TaskName -ErrorAction SilentlyContinue
    if ($info) {
        Write-Host "          ultima execucao: $($info.LastRunTime) (resultado: $($info.LastTaskResult))" -ForegroundColor DarkGray
    }
}

# --- processos ---------------------------------------------------------
Write-Host ''
Write-Host 'Processos' -ForegroundColor Cyan
$procs = @(Get-CimInstance Win32_Process -Filter "Name='rustdesk.exe'" -ErrorAction SilentlyContinue)
Test-Item 'processo do servico (sessao 0) ativo' ([bool](@($procs | Where-Object { $_.SessionId -eq 0 }).Count))
foreach ($p in $procs) {
    $cmd = if ($p.CommandLine) { $p.CommandLine } else { '(sem acesso a linha de comando)' }
    Write-Host "          PID $($p.ProcessId) sessao $($p.SessionId)  $cmd" -ForegroundColor DarkGray
}

# um --cm anterior pendurado segura o pipe query_cm e faz o proximo morrer
# com "Acesso negado", o que pode derrubar conexoes novas
$cm = @($procs | Where-Object { $_.CommandLine -like '*--cm*' })
if ($cm.Count -gt 1) {
    Test-Item 'connection managers concorrentes' 'aviso' `
        "$($cm.Count) processos --cm ativos; um deles pode estar orfao segurando o pipe query_cm"
}

# --- logs --------------------------------------------------------------
if ($ShowLogs) {
    Write-Host ''
    Write-Host 'Logs recentes' -ForegroundColor Cyan
    $dirs = @($paths.UserLogDir)
    if ($elevated) { $dirs += $paths.ServiceLogDir }
    foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        Get-ChildItem -LiteralPath $d -Recurse -Filter '*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-2) } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 3 | ForEach-Object {
                Write-Host "  >>> $($_.FullName)" -ForegroundColor DarkGray
                Get-Content -LiteralPath $_.FullName -Tail 8 |
                    ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
            }
    }
}

# --- resumo ------------------------------------------------------------
Write-Host ''
if ($script:falhas -eq 0) {
    Write-Host "=== OK: nenhuma falha ($script:avisos aviso(s)) ===" -ForegroundColor Green
    Write-Host ''
    Write-Host 'Teste manual que falta: bloqueie a tela (Win+L) e conecte de outra maquina,' -ForegroundColor Cyan
    Write-Host 'abrindo o Terminal. Nenhuma verificacao automatica cobre esse caminho.'      -ForegroundColor Cyan
} else {
    Write-Host "=== $script:falhas falha(s), $script:avisos aviso(s) ===" -ForegroundColor Red
    exit 1
}
