<#
.SYNOPSIS
    Configura o RustDesk no Windows para acesso remoto confiavel, incluindo
    o Terminal com a tela bloqueada.

.DESCRIPTION
    Sem parametros, roda apenas a verificacao (Test), que nao altera nada.
    Use -All para o setup completo.

.EXAMPLE
    .\Setup.ps1
    So verifica o estado atual. Nao precisa de Administrador.

.EXAMPLE
    .\Setup.ps1 -All
    Instala, configura, instala o watchdog e verifica. Exige Administrador.

.EXAMPLE
    .\Setup.ps1 -Configure
    So reaplica as opcoes das configs. Exige Administrador.

.LINK
    README.md
#>
[CmdletBinding()]
param(
    [switch]$All,
    [switch]$Install,
    [switch]$Configure,
    [switch]$Watchdog,
    [switch]$Test,
    [string]$ConfigFile,
    [int]$IntervalMinutes = 10,
    [switch]$ShowLogs
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\RustDeskCommon.psm1') -Force

if ($All) { $Install = $Configure = $Watchdog = $Test = $true }

# nada pedido: so verifica, que e a acao segura
if (-not ($Install -or $Configure -or $Watchdog -or $Test)) { $Test = $true }

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
    Write-Passo '1/4  Instalando RustDesk e registrando o servico'
    & (Join-Path $PSScriptRoot 'scripts\Install-RustDesk.ps1')
}

if ($Configure) {
    Write-Passo '2/4  Aplicando a configuracao nas duas configs'
    $p = @{}
    if ($ConfigFile) { $p['ConfigFile'] = $ConfigFile }
    & (Join-Path $PSScriptRoot 'scripts\Set-RustDeskConfig.ps1') @p
}

if ($Watchdog) {
    Write-Passo '3/4  Instalando o watchdog'
    & (Join-Path $PSScriptRoot 'scripts\Install-Watchdog.ps1') -IntervalMinutes $IntervalMinutes
}

if ($Test) {
    Write-Passo '4/4  Verificando'
    $p = @{}
    if ($ConfigFile) { $p['ConfigFile'] = $ConfigFile }
    if ($ShowLogs)   { $p['ShowLogs']   = $true }
    & (Join-Path $PSScriptRoot 'scripts\Test-RustDeskSetup.ps1') @p
}
