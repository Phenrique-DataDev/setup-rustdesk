<#
.SYNOPSIS
    Liga o privacy mode para um peer sem clicar na barra de ferramentas.

.DESCRIPTION
    Roda na maquina que CONTROLA (a que abre a sessao), nao no host. O privacy
    mode e pedido pelo cliente: depois do primeiro quadro de video, o cliente
    envia TogglePrivacyMode{on:true} ao host se a config do peer tiver
    'privacy_mode = true' (src/client/io_loop.rs, send_toggle_privacy_mode_msg).
    E exatamente essa chave que o botao da barra grava; este script a grava
    direto, entao a proxima conexao ao peer liga o modo sozinha.

    Dois arquivos, ambos em %APPDATA%\RustDesk\config:
      peers\<id>.toml          chave 'privacy_mode' no topo do arquivo. Prevalece
                               sobre o padrao; existe se o peer ja conectou.
      RustDesk_default.toml    [options] privacy_mode = 'Y'. Padrao para peers
                               ainda sem a chave (use -SetDefault).

    Nao afeta uma sessao ja aberta: o cliente envia o pedido uma vez, na
    abertura. E o RustDesk regrava peers\<id>.toml quando a sessao fecha, por
    cima desta edicao - por isso o script recusa rodar com sessao aberta para
    o peer (use -Force para ignorar).

    O host precisa permitir: a opcao 'enable-privacy-mode' nao pode estar 'N'
    (o padrao do RustDesk permite).

.PARAMETER PeerId
    ID do host a ser controlado (o nome do peers\<id>.toml).

.PARAMETER SetDefault
    Grava tambem o padrao em RustDesk_default.toml, para peers novos.

.PARAMETER Disable
    Desliga em vez de ligar.

.EXAMPLE
    .\Enable-PrivacyMode.ps1 -PeerId 123456789 -WhatIf
    .\Enable-PrivacyMode.ps1 -PeerId 123456789 -SetDefault
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.@-]+$')][string]$PeerId,
    [switch]$SetDefault,
    [switch]$Disable,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\lib\RustDeskToml.psm1') -Force

$cfgDir   = Join-Path $env:APPDATA 'RustDesk\config'
$peerFile = Join-Path $cfgDir "peers\$PeerId.toml"
$defFile  = Join-Path $cfgDir 'RustDesk_default.toml'
$on       = -not $Disable
$simulando = [bool]$WhatIfPreference

if (-not (Test-Path -LiteralPath $cfgDir)) {
    throw "config do RustDesk nao encontrada: $cfgDir (este usuario nunca abriu o RustDesk?)"
}

# --- sessao aberta para este peer? ------------------------------------
# O app guarda o PeerConfig em memoria e o regrava ao fechar a sessao.
if (-not $Force -and -not $simulando) {
    $abertas = @(Get-CimInstance Win32_Process -Filter "Name='rustdesk.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine -match [regex]::Escape($PeerId) })
    if ($abertas.Count -gt 0) {
        throw "ha sessao aberta para $PeerId. Feche-a e rode de novo (ou use -Force; o app pode regravar por cima)."
    }
}

# --- peers\<id>.toml: chave de topo 'privacy_mode' ---------------------
$literal = if ($on) { 'true' } else { 'false' }
$novaLinha = "privacy_mode = $literal"

if (Test-Path -LiteralPath $peerFile) {
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($l in @(Get-Content -LiteralPath $peerFile)) { [void]$lines.Add($l) }

    # topo do arquivo = tudo antes do primeiro [secao]
    $fimTopo = $lines.Count
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\[[^\]]+\]\s*$') { $fimTopo = $i; break }
    }

    $acao  = $null
    $achou = -1
    for ($i = 0; $i -lt $fimTopo; $i++) {
        if ($lines[$i] -match '^\s*privacy_mode\s*=') { $achou = $i; break }
    }

    if ($achou -ge 0) {
        if ($lines[$achou].Trim() -eq $novaLinha) {
            Write-Host "  [OK] $PeerId ja estava com $novaLinha"
        } else {
            $lines[$achou] = $novaLinha
            $acao = "atualizado: $novaLinha"
        }
    } else {
        $ins = $fimTopo
        while ($ins - 1 -ge 0 -and $lines[$ins - 1].Trim() -eq '') { $ins-- }
        $lines.Insert($ins, $novaLinha)
        $acao = "inserido: $novaLinha"
    }

    if ($acao) {
        if ($PSCmdlet.ShouldProcess($peerFile, "gravar $novaLinha")) {
            Copy-Item -LiteralPath $peerFile -Destination "$peerFile.bak" -Force
            Write-TomlFile -Path $peerFile -Lines $lines.ToArray()
            Write-Host "  [APLICADO] $peerFile - $acao (backup: .bak)"
        } else {
            Write-Host "  [SIMULACAO] $peerFile - $acao"
        }
    }
} else {
    Write-Host "  [AVISO] $peerFile nao existe: o peer nunca conectou daqui. Use -SetDefault para a primeira conexao ja pedir o modo."
}

# --- padrao para peers sem a chave -------------------------------------
if ($SetDefault) {
    $valor = if ($on) { 'Y' } else { 'N' }
    $r = Set-TomlSectionValue -Path $defFile -Sections @{ options = @{ privacy_mode = $valor } } `
        -CreateIfMissing -WhatIf:$simulando
    # A lib grava string com aspas duplas; o RustDesk grava com simples, mas o
    # parser TOML dele le as duas.
    $r.Actions | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-Host 'Vale a partir da PROXIMA conexao ao peer. O host precisa permitir (enable-privacy-mode diferente de N).'
