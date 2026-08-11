<#
.SYNOPSIS
    Instala uma versao fixa do RustDesk e registra o servico do Windows.

.DESCRIPTION
    Idempotente: se ja estiver instalado, apenas relata e garante que o
    servico exista e esteja em Automatic.

    A versao vem de config/version.psd1 (ou version-custom.psd1). O .msi e
    baixado da release do GitHub e so e executado depois de conferir o
    SHA-256 fixado e a assinatura Authenticode.

.PARAMETER Version
    Sobrepoe a versao fixada. Use 'latest' para resolver a ultima release
    estavel na hora - conveniente, mas sem verificacao de hash, porque nao ha
    hash fixado para uma versao que so se conhece em tempo de execucao.

.NOTES
    Exige Administrador.

    O winget saiu do caminho de instalacao: o pacote RustDesk.RustDesk nao
    existe mais no repositorio winget ('No package found matching input
    criteria' em 2026-08-11), entao o ramo que dependia dele nunca teria como
    funcionar. Baixar o .msi da release tambem e o que torna o pin de versao
    possivel - o winget nao instalaria uma versao que ele nao lista.
#>
[CmdletBinding()]
param(
    [switch]$SkipInstall,   # so registra/valida o servico, nao baixa nada
    [string]$Version
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\lib\RustDeskCommon.psm1') -Force

Assert-Elevated
$log = @()

$paths = Get-RustDeskPaths
$pin   = Get-RustDeskPin
if ($Version) { $pin.Version = $Version }

# --- 1) instalar o binario -------------------------------------------
if ($paths.Installed) {
    $log += "RustDesk ja instalado: $($paths.Exe)"

    # Um binario instalado fora do pin nao e erro - a maquina pode ter vindo
    # com outra versao. Mas e exatamente o que o pin existe para tornar
    # visivel, entao vale um aviso em vez de silencio.
    $atual = Get-RustDeskVersion -Exe $paths.Exe
    if ($atual -and $pin.Version -ne 'latest' -and $atual -ne $pin.Version) {
        $log += "  AVISO: versao instalada ($atual) difere da fixada ($($pin.Version))."
        $log += '  Para alinhar: desinstale o RustDesk e rode .\Setup.ps1 -Install de novo.'
        $log += '  Ou fixe a versao atual em config/version-custom.psd1.'
    } elseif ($atual) {
        $log += "  versao: $atual (bate com o pin)"
    }
} elseif ($SkipInstall) {
    throw 'RustDesk nao encontrado e -SkipInstall foi usado. Instale antes de continuar.'
} else {
    if ($pin.Version -eq 'latest') {
        $pin.Version = Resolve-RustDeskLatestVersion
        $log += "versao 'latest' resolvida para $($pin.Version) - sem verificacao de hash"
        $pin.Sha256 = ''
    }

    $url = $pin.UrlTemplate -f $pin.Version
    $msi = Join-Path ([System.IO.Path]::GetTempPath()) "rustdesk-$($pin.Version)-x86_64.msi"

    $log += "baixando RustDesk $($pin.Version)..."
    $log += "  $url"
    try {
        # o ProgressPreference derruba a velocidade do Invoke-WebRequest em
        # ordens de grandeza quando ha barra de progresso para desenhar
        $pp = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $url -OutFile $msi -UseBasicParsing
    } catch {
        throw "falha ao baixar $url : $($_.Exception.Message)"
    } finally {
        $ProgressPreference = $pp
    }

    $tam = (Get-Item -LiteralPath $msi).Length
    $log += "  baixado: $([math]::Round($tam / 1MB, 1)) MB"

    # --- verificacao antes de executar qualquer coisa ---
    if ($pin.Sha256) {
        $hash = (Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash
        if ($hash -ne $pin.Sha256.ToUpperInvariant()) {
            Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
            throw @"
SHA-256 do instalador nao bate com o fixado em config/version.psd1.
  esperado: $($pin.Sha256.ToUpperInvariant())
  obtido:   $hash
O arquivo foi apagado sem ser executado. Se voce acabou de trocar a versao no
config, atualize tambem o Sha256.
"@
        }
        $log += '  SHA-256 confere com o pin'
    }

    $sig = Get-AuthenticodeSignature -LiteralPath $msi
    if ($sig.Status -ne 'Valid') {
        Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
        throw "assinatura do instalador invalida ($($sig.Status)). O arquivo foi apagado sem ser executado."
    }
    if ($pin.SignerSubject -and $sig.SignerCertificate.Subject -notlike "*$($pin.SignerSubject)*") {
        Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
        throw @"
instalador assinado por quem nao se esperava.
  esperado conter: $($pin.SignerSubject)
  obtido:          $($sig.SignerCertificate.Subject)
O arquivo foi apagado sem ser executado.
"@
    }
    $log += "  assinatura valida: $($sig.SignerCertificate.Subject)"

    $log += '  instalando em modo silencioso...'
    $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', "`"$msi`"", '/qn', '/norestart') -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        throw "msiexec retornou codigo $($p.ExitCode). O .msi ficou em $msi para diagnostico."
    }
    Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue

    Start-Sleep -Seconds 5
    $paths = Get-RustDeskPaths
    if (-not $paths.Installed) {
        throw 'msiexec terminou mas rustdesk.exe nao foi encontrado. Verifique a instalacao.'
    }
    $log += "instalado: $($paths.Exe) ($(Get-RustDeskVersion -Exe $paths.Exe))"
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
