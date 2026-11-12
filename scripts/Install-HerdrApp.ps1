<#
.SYNOPSIS
    Instala o Herdr app (a janela) e o herdr-core (hc) que ele usa. Opcional.

.DESCRIPTION
    O Herdr app e um produto SEPARADO do 'herdr' de terminal que o resto deste
    repositorio instala. Outro binario, outro runtime (herdr-core, comando
    'hc'), outro estado: os terminais de um nao aparecem no outro.

    Para que serve nesta stack:
      - pela AREA DE TRABALHO remota, a janela tem o que o Terminal embutido do
        RustDesk nao tem: rolagem de verdade, selecao e varios terminais lado a
        lado;
      - pelo TERMINAL do RustDesk (inclusive com a tela bloqueada) a janela nao
        existe, mas os terminais dela continuam alcancaveis por 'hc ls' e
        'hc attach <t>' - o core os mantem vivos sem janela.

    Por isso este passo NAO entra no -All e nao substitui o -Herdr: quem acessa
    so pelo Terminal continua precisando do 'herdr' de terminal, que desenha
    abas e panes dentro do proprio terminal. O 'hc' nao desenha nada.

    Instala pelo instalador OFICIAL (https://releases.herdr.dev/app/install.ps1),
    que tambem instala o herdr-core se faltar. Tudo no perfil do usuario:
    NAO exige Administrador.

    -- Cadeia de confianca -------------------------------------------------
    O instalador oficial so confere o SHA-256 do download contra um manifesto
    servido pelo MESMO host. Isso pega arquivo corrompido, nao binario trocado.
    Este script acrescenta o que falta: depois de instalar, confere a assinatura
    Authenticode do herdr-app.exe e do herdr-core.exe, e falha se nao for a do
    Herdr. Limite declarado: o instalador do core executa '--version' do binario
    baixado ANTES de este script poder conferir a assinatura.

    -- O que este script NAO controla --------------------------------------
    O app se atualiza sozinho em segundo plano, e atualiza o core junto. Nao ha
    opcao para desligar isso - e o oposto do pin de versao do RustDesk, e vale
    saber antes de instalar numa maquina de acesso remoto.

.PARAMETER Update
    Roda o instalador mesmo com o app ja instalado (atualiza no lugar; um app
    aberto continua rodando ate ser fechado, e os terminais seguem no core).

.PARAMETER KeepTelemetry
    Nao mexe na telemetria. Por padrao este script grava "telemetry": false no
    settings.json do app: ela vem LIGADA de fabrica e manda um relatorio diario
    de uso. Numa maquina de acesso remoto o padrao daqui e nao mandar.

.EXAMPLE
    .\scripts\Install-HerdrApp.ps1
    Instala se faltar, confere as assinaturas e desliga a telemetria.

.EXAMPLE
    .\scripts\Install-HerdrApp.ps1 -WhatIf
    Mostra o que faria, sem baixar nem gravar nada.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Update,
    [switch]$KeepTelemetry
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\lib\RustDeskCommon.psm1') -Force

$log   = @()
$paths = Get-HerdrAppPaths
$url   = 'https://releases.herdr.dev/app/install.ps1'

# Elevar pelo UAC preserva o usuario; "executar como outro usuario" nao - e ai a
# instalacao iria para o perfil errado. Mesma guarda do Install-Herdr.ps1.
if ((Test-Elevated) -and -not (Test-Path -LiteralPath $env:APPDATA)) {
    throw "APPDATA inacessivel ($env:APPDATA). Rode este passo na sessao do usuario que vai usar o Herdr app."
}

# --- 1) instalar ------------------------------------------------------
if ($paths.Installed -and -not $Update) {
    $log += "Herdr app ja instalado: $($paths.AppExe)"
    $log += '  para atualizar agora: -Update (ele tambem se atualiza sozinho)'
} elseif ($PSCmdlet.ShouldProcess($url, 'baixar e executar o instalador do Herdr app')) {
    $log += "instalando o Herdr app pelo instalador oficial ($url)..."
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "herdr-app-install-$([guid]::NewGuid().ToString('N')).ps1"
    try {
        # Em disco antes de executar, em vez de 'irm | iex': o que rodou fica
        # auditavel e uma pagina de erro nao e executada como script.
        $pp = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try { Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing }
        finally { $ProgressPreference = $pp }

        $log += "  instalador baixado, sha256: $((Get-FileHash -Algorithm SHA256 -LiteralPath $tmp).Hash)"
        if ((Get-Content -LiteralPath $tmp -Raw) -notmatch 'herdr-app') {
            throw 'o conteudo baixado nao parece o instalador do Herdr app. Verifique a rede (portal cativo/proxy).'
        }

        # Processo separado e saida capturada, como no Install-Herdr.ps1: o
        # instalador usa 'throw' para tudo, e sem a saida toda falha vira
        # "retornou codigo 1".
        $outFile = "$tmp.out"; $errFile = "$tmp.err"
        $p = Start-WindowsPowerShellFile -File $tmp -StdOut $outFile -StdErr $errFile

        $saida = @()
        foreach ($f in @($outFile, $errFile)) {
            if (Test-Path -LiteralPath $f) {
                $saida += (Get-Content -LiteralPath $f -ErrorAction SilentlyContinue)
                Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
            }
        }
        $saida = @($saida | Where-Object { "$_".Trim() })
        if ($p.ExitCode -ne 0) {
            $det = if ($saida) { "`n  " + ($saida -join "`n  ") } else { ' (o instalador nao produziu saida)' }
            throw "o instalador do Herdr app retornou codigo $($p.ExitCode):$det"
        }
        $saida | Select-Object -Last 6 | ForEach-Object { $log += "  | $_" }
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }

    $paths = Get-HerdrAppPaths
    if (-not $paths.Installed) {
        throw "o instalador terminou mas herdr-app.exe nao foi encontrado em $($paths.AppExe)."
    }
    $log += 'AVISO: abra um terminal novo para que "herdr-app" e "hc" resolvam pelo PATH.'
}

# --- 2) assinatura ----------------------------------------------------
# Depois de instalar e ANTES de este script executar qualquer um dos dois.
# Vale tambem para instalacao que ja existia: o app se atualiza sozinho, entao
# o binario de hoje pode nao ser o que foi conferido na instalacao.
if ($paths.Installed) {
    foreach ($alvo in @(
        @{ Nome = 'herdr-app';  Exe = $paths.AppExe;  Existe = $true },
        @{ Nome = 'herdr-core'; Exe = $paths.CoreExe; Existe = $paths.CoreInstalled }
    )) {
        if (-not $alvo.Existe) {
            $log += "AVISO: $($alvo.Nome) nao encontrado - o app oferece instalar ao abrir."
            continue
        }
        $s = Test-HerdrAppSignature -Path $alvo.Exe -SignerSubject $paths.SignerSubject
        if (-not $s.Ok) {
            throw @"
$($alvo.Nome): $($s.Detalhe)
  $($alvo.Exe)
O binario ficou no disco mas NAO foi executado por este script. Nao o abra antes
de entender o motivo: a assinatura e a unica verificacao que nao depende do
servidor de release.
"@
        }
        $versao = try { (& $alvo.Exe --version 2>&1 | Out-String).Trim() } catch { '(versao nao lida)' }
        $log += "$($alvo.Nome): $versao"
        $log += "  assinatura valida: $($s.Detalhe)"
    }
}

# --- 3) telemetria ----------------------------------------------------
# So a chave 'telemetry': o resto do settings.json e de quem usa o app.
if ($KeepTelemetry) {
    $log += 'telemetria: nao alterada (-KeepTelemetry)'
} elseif ($paths.Installed -or $WhatIfPreference) {
    # -WhatIf explicito: $WhatIfPreference nao atravessa fronteira de modulo.
    $r = Disable-HerdrAppTelemetry -Settings $paths.Settings -WhatIf:([bool]$WhatIfPreference)
    switch ($r) {
        'ja'        { $log += 'telemetria: ja estava desligada' }
        'desligada' { $log += "telemetria: desligada em $($paths.Settings)" }
        'simulado'  { $log += "telemetria: (WhatIf) gravaria telemetry = false em $($paths.Settings)" }
        'ilegivel'  {
            $log += "AVISO: $($paths.Settings) nao e JSON valido - telemetria NAO alterada."
            $log += '  Desligue em Settings > Privacy dentro do app.'
        }
    }
}

# --- 4) como isto se encaixa no acesso remoto --------------------------
if ($paths.Installed) {
    $log += ''
    $log += 'Nada foi posto para subir no logon: o herdr-core sobe sozinho na primeira'
    $log += 'chamada de "hc" ou quando a janela abre, e mantem os terminais sem janela.'
    $log += 'Pelo Terminal do RustDesk:  hc ls   e   hc attach <t>   (Ctrl+\ solta).'
    $log += 'Depois de um reboot os terminais voltam como shells novos, nao os programas.'
}

$log | ForEach-Object { Write-Host "  $_" }
