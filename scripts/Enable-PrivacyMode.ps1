<#
.SYNOPSIS
    Deixa o privacy mode ligado por padrao na maquina que CONTROLA.

.DESCRIPTION
    O privacy mode e pedido pelo cliente: depois do primeiro quadro de video, o
    cliente envia TogglePrivacyMode{on:true, impl_key} ao host se a config do
    peer tiver 'privacy_mode = true' (src/client/io_loop.rs,
    send_toggle_privacy_mode_msg). Configurar so o host nao liga nada, e nao ha
    opcao do lado do host que ligue sozinha.

    Sem -PeerId, este script aplica o padrao do projeto: grava o padrao para
    peers novos e liga em todos os peers ja conhecidos. E o que Setup.ps1 -All
    roda. Com -PeerId, mexe so naquele peer.

    Sao tres chaves, em %APPDATA%\RustDesk\config:

      RustDesk_default.toml  [options] privacy_mode = 'Y'
                             Padrao para peers SEM a chave. E o mesmo que
                             Display > Other default options > Privacy mode.
      peers\<id>.toml        privacy_mode = true (no topo, fora de secao)
                             Toda sessao grava a chave no arquivo, entao um peer
                             que ja conectou nunca volta a ler o padrao.
      peers\<id>.toml        [options] privacy-mode-impl-key
                             Sem ela o cliente pede com chave vazia, o host
                             devolve vazia e o cliente salva _mag. Num host com
                             Mode 1 e Mode 2 a barra deixa de marcar o item
                             ligado, e o modo nao desliga por ali.

    Um pedido recusado grava privacy_mode = false no peer (io_loop.rs,
    update_privacy_mode), e o padrao nao o recupera. Rode de novo para religar;
    Test-RustDeskSetup.ps1 aponta os peers nesse estado.

    O modo vale a partir da proxima conexao e so para sessao de area de
    trabalho. Enquanto esta ligado, o host recusa outra sessao de area de
    trabalho e bloqueia o teclado e o mouse fisicos (Ctrl+P na maquina desliga).

.PARAMETER PeerId
    Mexe so neste peer (o nome do peers\<id>.toml) em vez de aplicar o padrao.

.PARAMETER SetDefault
    Com -PeerId, grava tambem o padrao para peers novos.

.PARAMETER Disable
    Desliga em vez de ligar.

.PARAMETER Force
    Grava mesmo que detecte sessao aberta para o peer.

.EXAMPLE
    .\Enable-PrivacyMode.ps1 -WhatIf
    .\Enable-PrivacyMode.ps1
    .\Enable-PrivacyMode.ps1 -PeerId 123456789
    .\Enable-PrivacyMode.ps1 -Disable
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidatePattern('^[A-Za-z0-9_.@-]+$')][string]$PeerId,
    [switch]$SetDefault,
    [switch]$Disable,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\lib\RustDeskToml.psm1') -Force

# Mode 1: janelas excluidas da captura. Nao usa driver e e o padrao do RustDesk
# do Windows 10 2004 em diante. O Mode 2 troca a topologia de video por um
# monitor virtual. Host que nao tem esta chave cai no padrao dele
# (privacy_mode.rs, get_supported_impl), entao ela e segura para qualquer peer.
$implKey = 'privacy_mode_impl_exclude_from_capture'

$cfgDir    = Join-Path $env:APPDATA 'RustDesk\config'
$peersDir  = Join-Path $cfgDir 'peers'
$defFile   = Join-Path $cfgDir 'RustDesk_default.toml'
$on        = -not $Disable
$aplicarPadrao = (-not $PeerId) -or $SetDefault
$simulando = [bool]$WhatIfPreference

# Por peer exige config existente. O padrao nao: numa maquina zerada e ele que
# faz a primeira conexao ja pedir o modo, e a lib cria o arquivo.
if ($PeerId -and -not (Test-Path -LiteralPath $cfgDir)) {
    throw "config do RustDesk nao encontrada: $cfgDir (este usuario nunca abriu o RustDesk?)"
}

function Set-PeerPrivacy([string]$Arquivo, [bool]$Ligar) {
    $r = Set-TomlTopLevelValue -Path $Arquivo -Key 'privacy_mode' -Value $Ligar -WhatIf:$simulando
    $r.Actions | ForEach-Object { Write-Host "    $_" }
    # Desligar nao apaga a chave do modo: ela so diz qual modo usar quando ligado.
    if ($Ligar) {
        $r = Set-TomlOption -Path $Arquivo -Options @{ 'privacy-mode-impl-key' = $implKey } -WhatIf:$simulando
        $r.Actions | ForEach-Object { Write-Host "    $_" }
    }
}

# Sessao aberta por linha de comando (--connect). As abertas pela UI vivem no
# processo principal, sem o ID na linha de comando: esta guarda nao as ve.
function Test-SessaoAberta([string]$Id) {
    if ($Force -or $simulando) { return $false }
    $abertas = @(Get-CimInstance Win32_Process -Filter "Name='rustdesk.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine -match [regex]::Escape($Id) })
    return ($abertas.Count -gt 0)
}

# --- peers -------------------------------------------------------------
if ($PeerId) {
    $alvos = @(Join-Path $peersDir "$PeerId.toml")
} elseif (Test-Path -LiteralPath $peersDir) {
    $alvos = @(Get-ChildItem -LiteralPath $peersDir -Filter '*.toml' -File | ForEach-Object { $_.FullName })
} else {
    $alvos = @()
}

foreach ($arquivo in $alvos) {
    $id = [System.IO.Path]::GetFileNameWithoutExtension($arquivo)
    Write-Host "  peer $id"
    if (-not (Test-Path -LiteralPath $arquivo)) {
        Write-Host '    [AVISO] o peer nunca conectou daqui. Use -SetDefault para a primeira conexao ja pedir o modo.'
        continue
    }
    if (Test-SessaoAberta $id) {
        if ($PeerId) { throw "ha sessao aberta para $id. Feche-a e rode de novo (ou use -Force)." }
        Write-Host '    [AVISO] sessao aberta: peer pulado. Feche-a e rode de novo.'
        continue
    }
    Set-PeerPrivacy -Arquivo $arquivo -Ligar $on
}

# --- padrao para peers sem a chave -------------------------------------
if ($aplicarPadrao) {
    Write-Host "  padrao: $defFile"
    $valor = if ($on) { 'Y' } else { 'N' }
    $r = Set-TomlSectionValue -Path $defFile -Sections @{ options = @{ privacy_mode = $valor } } `
        -CreateIfMissing -WhatIf:$simulando
    # A lib grava string com aspas duplas; o RustDesk grava com simples, mas o
    # parser TOML dele le as duas.
    $r.Actions | ForEach-Object { Write-Host "    $_" }
}

Write-Host ''
Write-Host 'Vale a partir da PROXIMA conexao, nesta maquina (a que controla). O host precisa permitir (enable-privacy-mode diferente de N).'
