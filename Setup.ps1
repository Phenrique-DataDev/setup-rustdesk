<#
.SYNOPSIS
    Configura a stack de acesso remoto no Windows - RustDesk (transporte) e
    Herdr (terminal persistente) - incluindo o Terminal com a tela bloqueada.

.DESCRIPTION
    Sem parametros, roda apenas a verificacao (Test), que nao altera nada.
    Use -All para o setup completo.

.EXAMPLE
    .\Setup.ps1
    So verifica o estado atual. Nao precisa de Administrador.

.EXAMPLE
    .\Setup.ps1 -All
    Instala e configura o RustDesk, instala o watchdog, instala e configura o
    Herdr com o servidor subindo no logon, e verifica. Exige Administrador.

.EXAMPLE
    .\Setup.ps1 -Configure
    So reaplica as opcoes das configs do RustDesk. Exige Administrador.

.EXAMPLE
    .\Setup.ps1 -Herdr
    So a metade Herdr: instala, configura e poe o servidor no logon.
    NAO precisa de Administrador.

.LINK
    README.md
#>
[CmdletBinding()]
param(
    [switch]$All,
    [switch]$Install,
    [switch]$Configure,
    [switch]$Watchdog,
    [switch]$Herdr,
    [switch]$Test,
    [string]$ConfigFile,
    [string]$HerdrConfigFile,
    [int]$IntervalMinutes = 10,
    [switch]$SkipHerdrInstall,
    [switch]$ShowLogs
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\RustDeskCommon.psm1') -Force

if ($All) { $Install = $Configure = $Watchdog = $Herdr = $Test = $true }

# nada pedido: so verifica, que e a acao segura
if (-not ($Install -or $Configure -or $Watchdog -or $Herdr -or $Test)) { $Test = $true }

# o passo do Herdr fica de fora: ele mora no perfil do usuario e nao eleva
$precisaAdmin = $Install -or $Configure -or $Watchdog
if ($precisaAdmin -and -not (Test-Elevated)) {
    Write-Host ''
    Write-Host 'Este modo exige privilegios de Administrador.' -ForegroundColor Red
    Write-Host 'Abra o PowerShell como Administrador e rode de novo:' -ForegroundColor Yellow
    Write-Host "  cd `"$PSScriptRoot`"" -ForegroundColor White
    Write-Host "  .\Setup.ps1 $($PSBoundParameters.Keys | ForEach-Object { "-$_" })" -ForegroundColor White
    Write-Host ''
    exit 1
}

function Write-Passo($titulo) {
    Write-Host ''
    Write-Host ('=' * 64) -ForegroundColor Cyan
    Write-Host " $titulo" -ForegroundColor Cyan
    Write-Host ('=' * 64) -ForegroundColor Cyan
}

if ($Install) {
    Write-Passo '1/5  Instalando RustDesk e registrando o servico'
    & (Join-Path $PSScriptRoot 'scripts\Install-RustDesk.ps1')
}

if ($Configure) {
    Write-Passo '2/5  Aplicando a configuracao nas duas configs do RustDesk'
    $p = @{}
    if ($ConfigFile) { $p['ConfigFile'] = $ConfigFile }
    & (Join-Path $PSScriptRoot 'scripts\Set-RustDeskConfig.ps1') @p
}

if ($Watchdog) {
    Write-Passo '3/5  Instalando o watchdog'
    & (Join-Path $PSScriptRoot 'scripts\Install-Watchdog.ps1') -IntervalMinutes $IntervalMinutes
}

if ($Herdr) {
    Write-Passo '4/5  Instalando e configurando o Herdr (terminal da sessao)'
    $p = @{}
    if ($SkipHerdrInstall) { $p['SkipInstall'] = $true }
    & (Join-Path $PSScriptRoot 'scripts\Install-Herdr.ps1') @p

    $p = @{}
    if ($HerdrConfigFile) { $p['ConfigFile'] = $HerdrConfigFile }
    & (Join-Path $PSScriptRoot 'scripts\Set-HerdrConfig.ps1') @p
}

if ($Test) {
    Write-Passo '5/5  Verificando'
    $p = @{}
    if ($ConfigFile)      { $p['ConfigFile']      = $ConfigFile }
    if ($HerdrConfigFile) { $p['HerdrConfigFile'] = $HerdrConfigFile }
    if ($ShowLogs)        { $p['ShowLogs']        = $true }
    & (Join-Path $PSScriptRoot 'scripts\Test-RustDeskSetup.ps1') @p
}
