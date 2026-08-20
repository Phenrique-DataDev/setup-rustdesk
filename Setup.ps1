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
    .\Setup.ps1 -All -Password (Read-Host -AsSecureString 'senha')
    Setup completo em um comando so, ja com a senha permanente. Sem -Password o
    setup termina apontando que ela falta - nenhum script inventa uma senha.

.EXAMPLE
    .\Setup.ps1 -Power
    So o passo de energia: ajusta o plano (tampa, suspensao, painel, rede) e
    instala o daemon que impede a maquina de dormir com sessao remota aberta.
    So faz algo em notebook. Exige Administrador.

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
    [switch]$Power,
    [switch]$SkipPower,
    [switch]$Herdr,
    [switch]$Test,
    [string]$ConfigFile,
    [string]$HerdrConfigFile,
    [string]$Version,   # sobrepoe config/version.psd1; 'latest' resolve a ultima estavel
    [int]$IntervalMinutes = 10,
    [switch]$SkipHerdrInstall,
    [switch]$ShowLogs,
    [System.Security.SecureString]$Password
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\RustDeskCommon.psm1') -Force

if ($All) {
    $Install = $Configure = $Watchdog = $Herdr = $Test = $true
    # Energia so entra em portatil. Em desktop nao ha tampa nem bateria para
    # tratar, e mexer no plano de energia de graca seria efeito colateral.
    $Power = (Test-IsLaptop) -and -not $SkipPower
}

# nada pedido: so verifica, que e a acao segura
if (-not ($Install -or $Configure -or $Watchdog -or $Power -or $Herdr -or $Test)) { $Test = $true }

# o passo do Herdr fica de fora: ele mora no perfil do usuario e nao eleva
$precisaAdmin = $Install -or $Configure -or $Watchdog -or $Power
if ($precisaAdmin -and -not (Test-Elevated)) {
    Write-Host ''
    Write-Host 'Este modo exige privilegios de Administrador.' -ForegroundColor Red
    Write-Host 'Abra o PowerShell como Administrador e rode de novo:' -ForegroundColor Yellow
    Write-Host "  cd `"$PSScriptRoot`"" -ForegroundColor White
    Write-Host "  .\Setup.ps1 $($PSBoundParameters.Keys | ForEach-Object { "-$_" })" -ForegroundColor White
    Write-Host ''
    exit 1
}

# A numeracao era literal ('1/5'...'6/6') e passou a mentir assim que o passo de
# energia virou condicional. Contar antes e o unico jeito de o titulo bater com o
# que vai rodar de fato.
$totalPassos = @($Install, $Configure, $Watchdog, $Power, $Herdr, [bool]$Password, $Test |
                 Where-Object { $_ }).Count
$passoAtual  = 0

function Write-Passo($titulo) {
    $script:passoAtual++
    Write-Host ''
    Write-Host ('=' * 64) -ForegroundColor Cyan
    Write-Host " $script:passoAtual/$script:totalPassos  $titulo" -ForegroundColor Cyan
    Write-Host ('=' * 64) -ForegroundColor Cyan
}

if ($Install) {
    Write-Passo 'Instalando RustDesk e registrando o servico'
    $pInst = @{}
    if ($Version) { $pInst.Version = $Version }
    & (Join-Path $PSScriptRoot 'scripts\Install-RustDesk.ps1') @pInst
}

if ($Configure) {
    Write-Passo 'Aplicando a configuracao nas duas configs do RustDesk'
    $p = @{}
    if ($ConfigFile) { $p['ConfigFile'] = $ConfigFile }
    & (Join-Path $PSScriptRoot 'scripts\Set-RustDeskConfig.ps1') @p
}

if ($Watchdog) {
    Write-Passo 'Instalando o watchdog'
    & (Join-Path $PSScriptRoot 'scripts\Install-Watchdog.ps1') -IntervalMinutes $IntervalMinutes
}

# Depois do watchdog e antes do Herdr: o daemon de energia e infraestrutura da
# maquina, como o watchdog, e nao depende do terminal da sessao.
if ($Power) {
    Write-Passo 'Ajustando energia para notebook (tampa, suspensao, rede)'
    & (Join-Path $PSScriptRoot 'scripts\Set-PowerConfig.ps1')
    & (Join-Path $PSScriptRoot 'scripts\Install-AwakeGuard.ps1')
}

if ($Herdr) {
    Write-Passo 'Instalando e configurando o Herdr (terminal da sessao)'
    $p = @{}
    if ($SkipHerdrInstall) { $p['SkipInstall'] = $true }
    & (Join-Path $PSScriptRoot 'scripts\Install-Herdr.ps1') @p

    $p = @{}
    if ($HerdrConfigFile) { $p['ConfigFile'] = $HerdrConfigFile }
    & (Join-Path $PSScriptRoot 'scripts\Set-HerdrConfig.ps1') @p
}

# A senha permanente era o unico passo que -All nao fechava, e numa maquina
# zerada isso fazia o setup terminar em [FALHA]. Com -Password o fluxo inteiro
# vira um comando. Sem ela o comportamento e o de antes: o Test aponta o que
# falta.
if ($Password) {
    Write-Passo 'Definindo a senha permanente'
    & (Join-Path $PSScriptRoot 'scripts\Set-RustDeskPassword.ps1') -Password $Password
}

if ($Test) {
    Write-Passo 'Verificando'
    $p = @{}
    if ($ConfigFile)      { $p['ConfigFile']      = $ConfigFile }
    if ($HerdrConfigFile) { $p['HerdrConfigFile'] = $HerdrConfigFile }
    if ($ShowLogs)        { $p['ShowLogs']        = $true }
    & (Join-Path $PSScriptRoot 'scripts\Test-RustDeskSetup.ps1') @p
}
