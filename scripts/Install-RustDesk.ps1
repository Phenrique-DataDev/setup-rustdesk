<#
.SYNOPSIS
    Instala o RustDesk (via winget) e registra o servico do Windows.

.DESCRIPTION
    Idempotente: se ja estiver instalado, apenas relata e garante que o
    servico exista e esteja em Automatic.

.NOTES
    Exige Administrador.
#>
[CmdletBinding()]
param(
    [switch]$SkipInstall   # so registra/valida o servico, nao chama o winget
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\lib\RustDeskCommon.psm1') -Force

Assert-Elevated
$log = @()

$paths = Get-RustDeskPaths

# --- 1) instalar o binario -------------------------------------------
if ($paths.Installed) {
    $log += "RustDesk ja instalado: $($paths.Exe)"
} elseif ($SkipInstall) {
    throw 'RustDesk nao encontrado e -SkipInstall foi usado. Instale antes de continuar.'
} else {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw @'
winget nao encontrado. Instale o "Instalador de Aplicativo" pela Microsoft Store
ou baixe o RustDesk manualmente em https://github.com/rustdesk/rustdesk/releases
e rode este script de novo com -SkipInstall.
'@
    }

    $log += 'instalando RustDesk via winget...'
    # --scope machine: instala em Program Files, requisito para o servico
    & winget.exe install --id RustDesk.RustDesk --scope machine `
        --accept-package-agreements --accept-source-agreements --silent
    if ($LASTEXITCODE -ne 0) { throw "winget retornou codigo $LASTEXITCODE" }

    Start-Sleep -Seconds 5
    $paths = Get-RustDeskPaths
    if (-not $paths.Installed) {
        throw 'winget terminou mas rustdesk.exe nao foi encontrado. Verifique a instalacao.'
    }
    $log += "instalado: $($paths.Exe)"
}

# --- 2) garantir o servico -------------------------------------------
$svc = Get-Service -Name $paths.ServiceName -ErrorAction SilentlyContinue
if (-not $svc) {
    $log += 'servico nao registrado - executando --install-service'
    $p = Start-Process -FilePath $paths.Exe -ArgumentList '--install-service' -Wait -PassThru
    $log += "install-service exit: $($p.ExitCode)"
    Start-Sleep -Seconds 6
    $svc = Get-Service -Name $paths.ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) { throw 'o servico rustdesk nao foi registrado. Instale o RustDesk manualmente e repita.' }
}

if ($svc.StartType -ne 'Automatic') {
    Set-Service -Name $paths.ServiceName -StartupType Automatic
    $log += "StartType corrigido: $($svc.StartType) -> Automatic"
}
if ($svc.Status -ne 'Running') {
    Start-Service -Name $paths.ServiceName
    Start-Sleep -Seconds 5
    $log += 'servico iniciado'
}

# --- 3) recovery actions do SCM --------------------------------------
# Sem isso, uma queda do servico so seria corrigida no proximo tique do
# watchdog - ate 10 minutos de acesso remoto indisponivel.
# sc.exe nao e cmdlet: ErrorActionPreference nao o alcanca e uma falha passaria
# em silencio, deixando o servico sem recovery com o log dizendo o contrario.
& sc.exe failure $paths.ServiceName reset= 0 actions= restart/5000/restart/5000/restart/5000 | Out-Null
$rc1 = $LASTEXITCODE
& sc.exe failureflag $paths.ServiceName 1 | Out-Null
$rc2 = $LASTEXITCODE
if ($rc1 -eq 0 -and $rc2 -eq 0) {
    $log += 'recovery do SCM: reiniciar 3x com 5s de intervalo, sem janela de reset'
} else {
    $log += "AVISO: sc.exe falhou (failure=$rc1, failureflag=$rc2). O servico fica sem recovery"
    $log += '  automatico - so o watchdog o traria de volta, e ate 10 min depois.'
}

$svc = Get-Service -Name $paths.ServiceName
$log += "estado final: $($svc.Status) / $($svc.StartType)"

# --- 4) garantir que as DUAS configs existam --------------------------
# Numa maquina zerada os RustDesk2.toml ainda nao nasceram: o RustDesk os cria
# na primeira vez que roda em cada perfil. Sem eles, o -Configure seguinte nao
# tem o que editar e o -All termina com falhas na primeira passada - foi o que
# um teste em Windows limpo mostrou. Esperar aqui e o que torna o -All
# utilizavel de uma vez so.
function Wait-Config($caminho, $rotulo, $segundos) {
    if (Test-Path -LiteralPath $caminho) { return $true }
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt $segundos) {
        Start-Sleep -Seconds 2
        if (Test-Path -LiteralPath $caminho) {
            $script:log += "  config do $rotulo criada em $([math]::Round(((Get-Date) - $t0).TotalSeconds))s"
            return $true
        }
    }
    return $false
}

$log += '--- aguardando as configs nascerem ---'

if (-not (Wait-Config $paths.ServiceConfig 'servico' 45)) {
    $log += '  AVISO: a config do servico nao apareceu em 45s.'
    $log += "  $($paths.ServiceConfig)"
}

# A config do usuario so nasce quando o RustDesk roda na sessao interativa.
# Start-RustDeskUI sobe a bandeja sem elevacao (via tarefa temporaria) - o
# jeito confiavel a partir de um console elevado.
if (-not (Test-Path -LiteralPath $paths.UserConfig)) {
    $log += '  config do usuario ausente - subindo a bandeja para cria-la'
    $log += (Start-RustDeskUI)
    if (-not (Wait-Config $paths.UserConfig 'usuario' 45)) {
        $log += '  AVISO: a config do usuario nao apareceu em 45s.'
        $log += '  Abra o RustDesk uma vez pelo menu Iniciar e rode: .\Setup.ps1 -Configure'
    }
}

$log | ForEach-Object { Write-Host "  $_" }
