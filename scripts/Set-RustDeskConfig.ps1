<#
.SYNOPSIS
    Aplica as opcoes do config/*.psd1 nas DUAS configs do RustDesk.

.DESCRIPTION
    O RustDesk mantem configuracoes separadas para a sessao do usuario e para
    o servico. Com a tela desbloqueada quem atende a conexao e o processo da
    sessao interativa; com a tela bloqueada, ou sem ninguem logado, quem
    atende e o servico, que le a propria config. Editar o .toml na mao nao
    sincroniza as duas (a sincronia acontece via IPC, disparada pela UI), por
    isso este script escreve nos dois arquivos.

    O servico e parado antes da edicao: com ele no ar, o arquivo pode ser
    regravado por cima ao sair.

.NOTES
    Exige Administrador.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigFile,      # default: config/custom.psd1 se existir, senao config/default.psd1
    [string]$LocalConfigFile, # default: config/local-custom.psd1 se existir, senao config/local.psd1
    [switch]$NoRestart        # edita sem parar/subir o servico (ele nao recarrega sozinho)
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\lib\RustDeskCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\lib\RustDeskToml.psm1')   -Force

Assert-Elevated
$log   = @()
$paths = Get-RustDeskPaths

# --- carregar as opcoes ----------------------------------------------
if (-not $ConfigFile) {
    $custom  = Join-Path $PSScriptRoot '..\config\custom.psd1'
    $default = Join-Path $PSScriptRoot '..\config\default.psd1'
    $ConfigFile = if (Test-Path -LiteralPath $custom) { $custom } else { $default }
}
if (-not (Test-Path -LiteralPath $ConfigFile)) { throw "arquivo de configuracao nao encontrado: $ConfigFile" }

$options = Import-RustDeskConfigFile -Path $ConfigFile
$log += "opcoes carregadas de: $(Resolve-Path $ConfigFile)"
$log += "chaves a aplicar: $($options.Count)"

# --- opcoes do OUTRO arquivo de config --------------------------------
# RustDesk2.toml e RustDesk.toml sao lidos por objetos diferentes (Config e
# LocalConfig). Uma chave escrita no arquivo errado nao da erro: e ignorada
# em silencio. 'enable-check-update' e uma dessas - so vale no RustDesk.toml.
if (-not $LocalConfigFile) {
    $lcustom  = Join-Path $PSScriptRoot '..\config\local-custom.psd1'
    $ldefault = Join-Path $PSScriptRoot '..\config\local.psd1'
    $LocalConfigFile = if (Test-Path -LiteralPath $lcustom) { $lcustom } else { $ldefault }
}
$localOptions = @{}
if (Test-Path -LiteralPath $LocalConfigFile) {
    $localOptions = Import-RustDeskConfigFile -Path $LocalConfigFile
    $log += "opcoes locais carregadas de: $(Resolve-Path $LocalConfigFile)"
    $log += "chaves locais a aplicar: $($localOptions.Count)"
}

if (-not $paths.Installed) { throw 'RustDesk nao esta instalado. Rode Setup.ps1 -Install antes.' }

# $WhatIfPreference NAO atravessa fronteira de modulo: as funcoes de
# lib\*.psm1 sao chamadas com o preference do escopo DELAS, nao o deste script.
# Sem repassar -WhatIf explicitamente, '-WhatIf' aqui gravava de verdade - e
# ainda derrubava o servico, que e o oposto de simular.
$simulando = [bool]$WhatIfPreference

# --- parar antes de editar -------------------------------------------
if (-not $NoRestart -and -not $simulando) {
    $log += '--- parando o RustDesk ---'
    $log += Stop-RustDeskClean
} elseif ($simulando) {
    $log += '--- (WhatIf) o RustDesk seria parado aqui ---'
}

# --- editar as duas configs ------------------------------------------
foreach ($target in @(
    @{ Nome = 'USUARIO'; Arquivo = $paths.UserConfig },
    @{ Nome = 'SERVICO'; Arquivo = $paths.ServiceConfig }
)) {
    $log += "--- config do $($target.Nome): $($target.Arquivo) ---"
    if (-not (Test-Path -LiteralPath $target.Arquivo)) {
        # o arquivo so nasce depois que o RustDesk roda uma vez naquele perfil
        $log += '  ARQUIVO NAO EXISTE. Abra o RustDesk uma vez (usuario) ou deixe o servico'
        $log += '  rodar alguns segundos (servico) para ele ser criado, e repita este passo.'
        continue
    }
    $r = Set-TomlOption -Path $target.Arquivo -Options $options -WhatIf:$simulando
    $r.Actions | ForEach-Object { $log += "  $_" }
    $log += "  alterado: $($r.Changed)"
}

# --- editar os DOIS RustDesk.toml (LocalConfig) -----------------------
# Mesmo par usuario/servico, arquivo diferente. Estes guardam hash de senha,
# salt e as chaves do dispositivo: a lib so mexe nas chaves pedidas dentro de
# [options] e preserva o resto, e o .bak que ela cria carrega os mesmos
# segredos - por isso *.bak esta no .gitignore.
if ($localOptions.Count -gt 0) {
    foreach ($target in @(
        @{ Nome = 'USUARIO'; Arquivo = $paths.UserPassword },
        @{ Nome = 'SERVICO'; Arquivo = $paths.ServicePassword }
    )) {
        $log += "--- RustDesk.toml do $($target.Nome): $($target.Arquivo) ---"
        if (-not (Test-Path -LiteralPath $target.Arquivo)) {
            $log += '  ARQUIVO NAO EXISTE - o RustDesk o cria na primeira execucao naquele perfil.'
            continue
        }
        $r = Set-TomlOption -Path $target.Arquivo -Options $localOptions -WhatIf:$simulando
        $r.Actions | ForEach-Object { $log += "  $_" }
        $log += "  alterado: $($r.Changed)"
    }
}

# --- subir de novo ----------------------------------------------------
if ($simulando) {
    $log += '--- (WhatIf) o RustDesk seria reiniciado aqui ---'
    $log += 'nada foi gravado e o servico nao foi tocado.'
} elseif (-not $NoRestart) {
    $log += '--- iniciando o RustDesk ---'
    $log += Start-RustDeskClean
    $log += Start-RustDeskUI
} else {
    $log += 'AVISO: -NoRestart usado. O servico so aplica as mudancas apos reiniciar.'
}

$log | ForEach-Object { Write-Host "  $_" }
