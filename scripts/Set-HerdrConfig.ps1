<#
.SYNOPSIS
    Aplica as opcoes do config/herdr*.psd1 no config.toml do Herdr.

.DESCRIPTION
    O Herdr e o terminal usado dentro da sessao remota: o cliente e
    descartavel e o servidor mantem os processos vivos quando a conexao cai,
    a tela bloqueia ou o terminal e fechado.

    A config fica em %APPDATA%\herdr\config.toml e NAO exige Administrador -
    diferente das configs do RustDesk, que moram em perfis protegidos.

    O arquivo e gravado em UTF-8 sem BOM com quebras LF, pela mesma
    biblioteca usada no .toml do RustDesk (lib/RustDeskToml.psm1). A
    diferenca de formato esta nos valores: aqui entram os tipos nativos do
    TOML (true, 10485760) em vez das aspas simples que o RustDesk usa.

    Ao contrario do servico do RustDesk, o Herdr recarrega sem reiniciar:
    'herdr server reload-config' aplica na sessao em andamento.

.EXAMPLE
    .\scripts\Set-HerdrConfig.ps1
    Aplica e recarrega.

.EXAMPLE
    .\scripts\Set-HerdrConfig.ps1 -WhatIf
    Mostra o que mudaria, sem gravar.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigFile,   # default: config/herdr-custom.psd1 se existir, senao config/herdr.psd1
    [switch]$NoReload,     # grava sem chamar 'herdr server reload-config'
    [switch]$NoBackup
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\lib\RustDeskCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\lib\RustDeskToml.psm1')   -Force

$log   = @()
$paths = Get-HerdrPaths

# --- carregar as opcoes ----------------------------------------------
if (-not $ConfigFile) {
    $custom  = Join-Path $PSScriptRoot '..\config\herdr-custom.psd1'
    $default = Join-Path $PSScriptRoot '..\config\herdr.psd1'
    $ConfigFile = if (Test-Path -LiteralPath $custom) { $custom } else { $default }
}
if (-not (Test-Path -LiteralPath $ConfigFile)) { throw "arquivo de configuracao nao encontrado: $ConfigFile" }

$sections = Import-RustDeskConfigFile -Path $ConfigFile
$log += "opcoes carregadas de: $(Resolve-Path $ConfigFile)"
$log += "secoes a aplicar: $(($sections.Keys | Sort-Object) -join ', ')"

if (-not $paths.Installed) {
    # o Herdr e opcional na stack; sem ele o passo nao se aplica
    $log += 'Herdr nao encontrado no PATH nem em %LOCALAPPDATA%\Programs\Herdr.'
    $log += 'Passo pulado - instale o Herdr (https://herdr.dev) se quiser usar este terminal.'
    $log | ForEach-Object { Write-Host "  $_" }
    return
}
$log += "herdr.exe: $($paths.Exe)"

# --- editar o config.toml ---------------------------------------------
$log += "--- config do Herdr: $($paths.Config) ---"
# -WhatIf explicito: $WhatIfPreference nao atravessa fronteira de modulo, entao
# sem isto a funcao de lib\RustDeskToml.psm1 gravaria mesmo em modo simulacao.
$r = Set-TomlSectionValue -Path $paths.Config -Sections $sections -CreateIfMissing:$true -NoBackup:$NoBackup -WhatIf:([bool]$WhatIfPreference)
$r.Actions | ForEach-Object { $log += "  $_" }
$log += "  alterado: $($r.Changed)"

# --- recarregar --------------------------------------------------------
if ($NoReload) {
    $log += 'AVISO: -NoReload usado. Rode "herdr server reload-config" para aplicar.'
} elseif (-not $r.Changed) {
    $log += 'nada mudou - reload dispensado'
} elseif ($PSCmdlet.ShouldProcess('herdr server', 'reload-config')) {
    try {
        $saida = & $paths.Exe server reload-config 2>&1 | Out-String
        $texto = $saida.Trim()
        if ($LASTEXITCODE -eq 0 -and $texto -match '"status"\s*:\s*"applied"') {
            $log += 'reload aplicado pelo servidor'
        } elseif ($LASTEXITCODE -ne 0) {
            # servidor parado nao e erro: a config vale no proximo start
            $log += "AVISO: reload falhou (exit $LASTEXITCODE). Se o servidor nao esta rodando,"
            $log += '  a configuracao ja esta gravada e vale quando ele subir.'
            if ($texto) { $log += "  saida: $texto" }
        } else {
            $log += "AVISO: resposta inesperada do reload: $texto"
        }
    } catch {
        $log += "AVISO: nao foi possivel recarregar: $($_.Exception.Message)"
    }
}

# --- lembretes que custam tempo ---------------------------------------
if ($r.Changed) {
    $log += ''
    $log += 'Lembre: scrollback_limit_bytes so vale para panes criados depois.'
    $log += 'Os panes existentes mantem o buffer que ja tinham - abra um novo para testar.'
}

$log | ForEach-Object { Write-Host "  $_" }
