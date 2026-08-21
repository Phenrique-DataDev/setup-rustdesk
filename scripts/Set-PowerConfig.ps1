<#
.SYNOPSIS
    Aplica as opcoes de config/power*.psd1 no plano de energia ativo.

.DESCRIPTION
    So faz sentido em notebook, e so roda la: em desktop o script sai limpo,
    sem erro, do mesmo jeito que Set-HerdrConfig.ps1 sai quando o Herdr nao
    esta instalado.

    O que ele resolve: a premissa deste repositorio e que a maquina fica
    alcancavel e o trabalho sobrevive. Num portatil com os defaults do Windows
    isso e falso - fechar a tampa suspende, e uma sessao so de Terminal nao
    conta como atividade para o timer de ociosidade, entao a maquina dorme no
    meio de um agente rodando.

    A suspensao na bateria NAO e desligada. Quem a impede enquanto ha sessao
    remota e o daemon RustDeskAwake (scripts/Install-AwakeGuard.ps1); aqui so
    ficam os valores estaticos.

.EXAMPLE
    .\scripts\Set-PowerConfig.ps1 -WhatIf
    Mostra o que mudaria no plano de energia, sem aplicar nada.

.EXAMPLE
    .\scripts\Set-PowerConfig.ps1
    Aplica. Exige Administrador.

.NOTES
    Exige Administrador.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigFile,   # default: config/power-custom.psd1 se existir, senao config/power.psd1
    [switch]$NoNic         # nao mexe no gerenciamento de energia do adaptador de rede
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\lib\RustDeskCommon.psm1') -Force

Assert-Elevated
$log       = @()
$simulando = [bool]$WhatIfPreference

# --- 0) so em portatil -------------------------------------------------
if (-not (Test-IsLaptop)) {
    $log += 'Esta maquina nao e portatil (sem bateria e PCSystemType diferente de 2).'
    $log += 'Passo pulado - as opcoes de energia deste repositorio so se aplicam a notebook.'
    $log | ForEach-Object { Write-Host "  $_" }
    return
}

# --- 1) carregar as opcoes --------------------------------------------
if (-not $ConfigFile) {
    $custom  = Join-Path $PSScriptRoot '..\config\power-custom.psd1'
    $default = Join-Path $PSScriptRoot '..\config\power.psd1'
    $ConfigFile = if (Test-Path -LiteralPath $custom) { $custom } else { $default }
}
if (-not (Test-Path -LiteralPath $ConfigFile)) { throw "arquivo de configuracao nao encontrado: $ConfigFile" }

$opts = Import-RustDeskConfigFile -Path $ConfigFile
$log += "opcoes carregadas de: $(Resolve-Path $ConfigFile)"

function Get-Opt {
    param([string]$Nome)
    if ($opts.Contains($Nome)) { return $opts[$Nome] }
    return $null
}

# --- 2) o que a maquina suporta ---------------------------------------
# powercfg /a diz quais estados existem. Em maquina sem Modern Standby a chave
# de conectividade em espera nao esta no plano, e tentar grava-la devolve erro -
# o certo ali e pular, nao falhar.
$estados = (& powercfg /a 2>&1 | Out-String)
$temModernStandby = [bool]($estados -match 'S0')
$log += "estados de suspensao: $(if ($temModernStandby) { 'Modern Standby (S0) presente' } else { 'sem S0 (S3 classico ou nenhum)' })"

# --- 3) aplicar os pares AC/DC ----------------------------------------
function Read-PowerIndex {
    <#
    .SYNOPSIS
        Le os indices AC e DC de um subvalor do plano ativo.
    .NOTES
        Os rotulos da saida do powercfg sao traduzidos em Windows localizado,
        entao procurar por 'Current AC Power Setting Index' daria falso negativo
        em pt-BR - mesma familia de armadilha do IsInRole com string. O que nao
        muda e o formato do valor: os indices saem como 0x00000000 e sao os
        unicos campos nesse formato na saida de /q de um setting. As duas
        ultimas ocorrencias sao, nesta ordem, AC e DC.
    #>
    param([string]$Sub, [string]$Setting)

    $saida = (& powercfg /q SCHEME_CURRENT $Sub $Setting 2>&1 | Out-String)
    $m = [regex]::Matches($saida, '0x[0-9A-Fa-f]{8}')
    if ($m.Count -lt 2) { return $null }
    return [PSCustomObject]@{
        Ac = [Convert]::ToInt64($m[$m.Count - 2].Value, 16)
        Dc = [Convert]::ToInt64($m[$m.Count - 1].Value, 16)
    }
}

$aplicar = @(
    @{ Sub = 'SUB_BUTTONS'; Setting = 'LIDACTION';     Ac = 'LidActionAC';     Dc = 'LidActionDC';     Rotulo = 'acao ao fechar a tampa' },
    @{ Sub = 'SUB_SLEEP';   Setting = 'STANDBYIDLE';   Ac = 'StandbyIdleAC';   Dc = 'StandbyIdleDC';   Rotulo = 'suspender por ociosidade (s)' },
    @{ Sub = 'SUB_SLEEP';   Setting = 'HIBERNATEIDLE'; Ac = 'HibernateIdleAC'; Dc = 'HibernateIdleDC'; Rotulo = 'hibernar por ociosidade (s)' },
    @{ Sub = 'SUB_VIDEO';   Setting = 'VIDEOIDLE';     Ac = 'VideoIdleAC';     Dc = 'VideoIdleDC';     Rotulo = 'desligar o painel (s)' }
)

if ($temModernStandby) {
    $aplicar += @{
        Sub     = 'SUB_NONE'
        Setting = 'F15576E8-98B7-4186-B944-EAFA664402D9'
        Ac      = 'ConnectivityInStandby'
        Dc      = 'ConnectivityInStandby'
        Rotulo  = 'conectividade de rede em espera'
    }
} else {
    $log += '[PULADO] conectividade em espera: a maquina nao tem Modern Standby.'
}

$mudou  = $false
$falhas = @()

foreach ($item in $aplicar) {
    $alvoAc = Get-Opt $item.Ac
    $alvoDc = Get-Opt $item.Dc
    if ($null -eq $alvoAc -and $null -eq $alvoDc) {
        $log += "[PULADO] $($item.Rotulo): sem valor no .psd1"
        continue
    }

    $antes = Read-PowerIndex -Sub $item.Sub -Setting $item.Setting
    if (-not $antes) {
        $log += "[PULADO] $($item.Rotulo): o plano ativo nao expoe $($item.Sub)/$($item.Setting)"
        continue
    }

    $de   = "AC=$($antes.Ac) DC=$($antes.Dc)"
    $para = "AC=$alvoAc DC=$alvoDc"
    if ($antes.Ac -eq $alvoAc -and $antes.Dc -eq $alvoDc) {
        $log += "[OK] $($item.Rotulo): ja em $para"
        continue
    }

    # Guarda propria: efeito colateral fora de modulo nao herda o -WhatIf.
    if (-not $PSCmdlet.ShouldProcess('plano de energia ativo', "$($item.Rotulo): $de -> $para")) {
        $log += "[SIMULACAO] $($item.Rotulo): $de -> $para"
        continue
    }

    & powercfg /setacvalueindex SCHEME_CURRENT $item.Sub $item.Setting $alvoAc 2>&1 | Out-Null
    & powercfg /setdcvalueindex SCHEME_CURRENT $item.Sub $item.Setting $alvoDc 2>&1 | Out-Null
    $mudou = $true
    $log += "[APLICADO] $($item.Rotulo): $de -> $para"
}

# --- 4) ativar o esquema ----------------------------------------------
# Sem esta linha o /setacvalueindex grava no esquema e o sistema segue usando o
# valor antigo: o script imprimiria sucesso e nada teria mudado de fato.
if ($mudou -and -not $simulando) {
    & powercfg /setactive SCHEME_CURRENT 2>&1 | Out-Null
    $log += 'esquema reativado (powercfg /setactive) - sem isto os valores nao valeriam'
}

# --- 5) confirmar em vez de afirmar -----------------------------------
# powercfg nao devolve exit code confiavel em todos os subvalores.
if (-not $simulando) {
    foreach ($item in $aplicar) {
        $alvoAc = Get-Opt $item.Ac
        $alvoDc = Get-Opt $item.Dc
        if ($null -eq $alvoAc -and $null -eq $alvoDc) { continue }
        $depois = Read-PowerIndex -Sub $item.Sub -Setting $item.Setting
        if (-not $depois) { continue }
        if ($depois.Ac -ne $alvoAc -or $depois.Dc -ne $alvoDc) {
            $falhas += "$($item.Rotulo): esperado AC=$alvoAc DC=$alvoDc, lido AC=$($depois.Ac) DC=$($depois.Dc)"
        }
    }
}

# --- 6) adaptador de rede ---------------------------------------------
# 'Permitir que o computador desligue este dispositivo' e a causa classica de
# voltar da suspensao com a rede fora do ar por minutos.
$mexerNic = (-not $NoNic) -and ((Get-Opt 'DisableNicPowerSaving') -eq $true)
if (-not $mexerNic) {
    $log += '[PULADO] gerenciamento de energia do adaptador: desligado no .psd1 ou -NoNic'
} else {
    $nics = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
    if ($nics.Count -eq 0) { $log += '[AVISO] nenhum adaptador fisico ativo encontrado' }

    foreach ($nic in $nics) {
        $pm = Get-NetAdapterPowerManagement -Name $nic.Name -ErrorAction SilentlyContinue
        if (-not $pm) {
            $log += "[PULADO] $($nic.Name): o driver nao expoe gerenciamento de energia"
            continue
        }
        # Estado anterior no log: e o que permite desfazer na mao depois.
        $log += "$($nic.Name): antes -> DeviceSleepOnDisconnect=$($pm.DeviceSleepOnDisconnect), WakeOnMagicPacket=$($pm.WakeOnMagicPacket)"

        # Sem esta guarda o script reescreve o adaptador a cada execucao e
        # reporta [APLICADO] sem ter mudado nada - escrita em hardware de graca
        # toda vez que o -All roda, e uma saida que mente.
        if ($pm.AllowComputerToTurnOffDevice -eq 'Disabled') {
            $log += "[OK] $($nic.Name): o Windows ja nao desliga este adaptador"
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($nic.Name, 'desligar o power saving do adaptador')) {
            $log += "[SIMULACAO] $($nic.Name): desligaria o power saving do adaptador"
            continue
        }
        try {
            Disable-NetAdapterPowerManagement -Name $nic.Name -Confirm:$false -ErrorAction Stop
            $log += "[APLICADO] $($nic.Name): power saving do adaptador desligado"
        } catch {
            $falhas += "$($nic.Name): nao foi possivel desligar o power saving - $($_.Exception.Message)"
        }
    }
}

# --- 7) resumo ---------------------------------------------------------
if ($simulando) {
    $log += ''
    $log += 'Simulacao: nada foi gravado. Confira com "powercfg /q SCHEME_CURRENT SUB_BUTTONS".'
}
if ($falhas.Count -gt 0) {
    $log += ''
    $log += 'FALHAS:'
    $falhas | ForEach-Object { $log += "  $_" }
}
$log | ForEach-Object { Write-Host "  $_" }

if ($falhas.Count -gt 0) {
    throw "$($falhas.Count) opcao(oes) de energia nao ficaram com o valor pedido. Veja acima."
}
