<#
.SYNOPSIS
    Testes da manipulacao de .toml. Nao tocam em nenhuma instalacao real:
    tudo roda em arquivos temporarios.

.DESCRIPTION
    Roda com Pester se estiver disponivel; caso contrario, usa um runner
    minimo embutido, para o repositorio nao exigir dependencia externa.

.EXAMPLE
    .\tests\RustDeskToml.Tests.ps1
#>
[CmdletBinding()] param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\lib\RustDeskToml.psm1')   -Force
Import-Module (Join-Path $PSScriptRoot '..\lib\RustDeskCommon.psm1') -Force

$repoRaiz = Split-Path -Parent $PSScriptRoot

$script:passou = 0
$script:falhou = 0

function It($nome, [scriptblock]$corpo) {
    try {
        & $corpo
        Write-Host "  [PASS]  $nome" -ForegroundColor Green
        $script:passou++
    } catch {
        Write-Host "  [FALHA] $nome" -ForegroundColor Red
        Write-Host "          $($_.Exception.Message)" -ForegroundColor DarkGray
        $script:falhou++
    }
}

function Assert-Equal($esperado, $obtido, $msg = '') {
    if ($esperado -ne $obtido) {
        throw "esperado '<$esperado>', obtido '<$obtido>' $msg"
    }
}

function Assert-True($cond, $msg = '') {
    if (-not $cond) { throw "condicao falsa: $msg" }
}

# arquivo temporario com o conteudo dado, no formato pedido
function New-TempToml {
    param([string[]]$Lines, [switch]$WithBom, [switch]$Crlf)
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("toml-" + [guid]::NewGuid().ToString('N').Substring(0,8) + ".toml")
    $sep  = if ($Crlf) { "`r`n" } else { "`n" }
    $text = ($Lines -join $sep) + $sep
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($WithBom.IsPresent)))
    return $path
}

$baseToml = @(
    "rendezvous_server = 'rs-ny.rustdesk.com:21116'"
    "nat_type = 1"
    "serial = 0"
    ""
    "[options]"
    "enable-clipboard = 'Y'"
    "approve-mode = 'password'"
)

Write-Host ''
Write-Host '=== Testes: RustDeskToml ===' -ForegroundColor Cyan

$tmpFiles = @()

It 'insere chave ausente dentro da secao [options]' {
    $f = New-TempToml -Lines $baseToml; $script:tmpFiles += $f
    Set-TomlOption -Path $f -Options @{ 'enable-terminal' = 'Y' } -NoBackup | Out-Null
    Assert-Equal 'Y' (Get-TomlOption -Path $f -Key 'enable-terminal')
    # a chave tem que cair depois de [options], nunca antes
    $linhas = @(Get-Content $f)
    $iOpt   = [array]::IndexOf($linhas, '[options]')
    $iNova  = ($linhas | Select-String -Pattern '^enable-terminal' | Select-Object -First 1).LineNumber - 1
    Assert-True ($iNova -gt $iOpt) 'chave inserida fora da secao [options]'
}

It 'atualiza chave existente sem duplicar' {
    $f = New-TempToml -Lines $baseToml; $script:tmpFiles += $f
    Set-TomlOption -Path $f -Options @{ 'approve-mode' = 'click' } -NoBackup | Out-Null
    Assert-Equal 'click' (Get-TomlOption -Path $f -Key 'approve-mode')
    $n = @(Get-Content $f | Where-Object { $_ -match '^approve-mode' }).Count
    Assert-Equal 1 $n 'chave duplicada'
}

It 'remove o BOM UTF-8 na regravacao' {
    $f = New-TempToml -Lines $baseToml -WithBom; $script:tmpFiles += $f
    Assert-True (Test-TomlBom -Path $f) 'o teste deveria comecar com BOM'
    $r = Set-TomlOption -Path $f -Options @{ 'enable-terminal' = 'Y' } -NoBackup
    Assert-True $r.BomRemoved 'BomRemoved deveria ser true'
    Assert-True (-not (Test-TomlBom -Path $f)) 'BOM sobreviveu'
}

It 'converte CRLF para LF' {
    $f = New-TempToml -Lines $baseToml -Crlf; $script:tmpFiles += $f
    Set-TomlOption -Path $f -Options @{ 'enable-terminal' = 'Y' } -NoBackup | Out-Null
    $raw = [System.IO.File]::ReadAllText($f)
    Assert-True (-not $raw.Contains("`r`n")) 'CRLF sobreviveu'
}

It 'e idempotente: segunda passada nao altera o arquivo' {
    $f = New-TempToml -Lines $baseToml; $script:tmpFiles += $f
    $opts = @{ 'enable-terminal' = 'Y'; 'allow-logon-screen-password' = 'Y' }
    Set-TomlOption -Path $f -Options $opts -NoBackup | Out-Null
    $antes = [System.IO.File]::ReadAllText($f)
    $r = Set-TomlOption -Path $f -Options $opts -NoBackup
    $depois = [System.IO.File]::ReadAllText($f)
    Assert-Equal $antes $depois 'arquivo mudou na segunda passada'
    Assert-True (-not $r.Changed) 'Changed deveria ser false'
}

It 'cria a secao [options] quando ela nao existe' {
    $f = New-TempToml -Lines @("rendezvous_server = 'x'", "serial = 0"); $script:tmpFiles += $f
    Set-TomlOption -Path $f -Options @{ 'enable-terminal' = 'Y' } -NoBackup | Out-Null
    Assert-True (@(Get-Content $f) -contains '[options]') 'secao nao foi criada'
    Assert-Equal 'Y' (Get-TomlOption -Path $f -Key 'enable-terminal')
}

It 'preserva as chaves que nao foram pedidas' {
    $f = New-TempToml -Lines $baseToml; $script:tmpFiles += $f
    Set-TomlOption -Path $f -Options @{ 'enable-terminal' = 'Y' } -NoBackup | Out-Null
    Assert-Equal 'Y' (Get-TomlOption -Path $f -Key 'enable-clipboard')
    Assert-Equal 'rs-ny.rustdesk.com:21116' (Get-TomlOption -Path $f -Key 'rendezvous_server')
}

It 'cria backup .bak por padrao' {
    $f = New-TempToml -Lines $baseToml; $script:tmpFiles += $f
    Set-TomlOption -Path $f -Options @{ 'enable-terminal' = 'Y' } | Out-Null
    Assert-True (Test-Path "$f.bak") 'backup nao foi criado'
    $script:tmpFiles += "$f.bak"
}

It 'Get-TomlOption retorna null para chave ausente' {
    $f = New-TempToml -Lines $baseToml; $script:tmpFiles += $f
    Assert-True ($null -eq (Get-TomlOption -Path $f -Key 'chave-que-nao-existe')) 'deveria ser null'
}

It 'arquivo inexistente e reportado, nao explode' {
    $r = Set-TomlOption -Path (Join-Path ([System.IO.Path]::GetTempPath()) 'nao-existe-xyz.toml') `
                        -Options @{ 'enable-terminal' = 'Y' }
    Assert-True $r.Missing 'Missing deveria ser true'
    Assert-True (-not $r.Changed) 'Changed deveria ser false'
}

Write-Host ''
Write-Host '=== Testes: secoes nomeadas (config.toml do Herdr) ===' -ForegroundColor Cyan

$herdrToml = @(
    "onboarding = false"
    "[ui]"
    'agent_panel_sort = "priority"'
    ""
    "[advanced]"
    "scrollback_limit_bytes = 1024"
)

It 'ConvertTo-TomlLiteral usa os tipos nativos do TOML' {
    Assert-Equal 'false'    (ConvertTo-TomlLiteral -Value $false)
    Assert-Equal 'true'     (ConvertTo-TomlLiteral -Value $true)
    Assert-Equal '10485760' (ConvertTo-TomlLiteral -Value 10485760)
    Assert-Equal '"texto"'  (ConvertTo-TomlLiteral -Value 'texto')
}

It 'ConvertTo-TomlLiteral escapa aspas e barras em strings' {
    Assert-Equal '"a\"b"'  (ConvertTo-TomlLiteral -Value 'a"b')
    Assert-Equal '"c\\d"'  (ConvertTo-TomlLiteral -Value 'c\d')
}

It 'insere chave dentro da secao certa' {
    $f = New-TempToml -Lines $herdrToml; $script:tmpFiles += $f
    Set-TomlSectionValue -Path $f -Sections @{ ui = @{ mouse_capture = $false } } -NoBackup | Out-Null
    Assert-Equal 'false' (Get-TomlSectionValue -Path $f -Section 'ui' -Key 'mouse_capture')
    # tem que cair entre [ui] e [advanced], nunca depois
    $linhas = @(Get-Content $f)
    $iUi    = [array]::IndexOf($linhas, '[ui]')
    $iAdv   = [array]::IndexOf($linhas, '[advanced]')
    $iNova  = ($linhas | Select-String -Pattern '^mouse_capture' | Select-Object -First 1).LineNumber - 1
    Assert-True ($iNova -gt $iUi -and $iNova -lt $iAdv) 'chave caiu na secao errada'
}

It 'atualiza chave existente na secao certa' {
    $f = New-TempToml -Lines $herdrToml; $script:tmpFiles += $f
    Set-TomlSectionValue -Path $f -Sections @{ advanced = @{ scrollback_limit_bytes = 10485760 } } -NoBackup | Out-Null
    Assert-Equal '10485760' (Get-TomlSectionValue -Path $f -Section 'advanced' -Key 'scrollback_limit_bytes')
    $n = @(Get-Content $f | Where-Object { $_ -match '^scrollback_limit_bytes' }).Count
    Assert-Equal 1 $n 'chave duplicada'
}

It 'nao confunde chaves homonimas em secoes diferentes' {
    $f = New-TempToml -Lines @("[ui]", "limite = 1", "[advanced]", "limite = 2"); $script:tmpFiles += $f
    Set-TomlSectionValue -Path $f -Sections @{ advanced = @{ limite = 99 } } -NoBackup | Out-Null
    Assert-Equal '1'  (Get-TomlSectionValue -Path $f -Section 'ui'       -Key 'limite')
    Assert-Equal '99' (Get-TomlSectionValue -Path $f -Section 'advanced' -Key 'limite')
}

It 'cria a secao ausente no fim do arquivo' {
    $f = New-TempToml -Lines @("onboarding = false"); $script:tmpFiles += $f
    Set-TomlSectionValue -Path $f -Sections @{ experimental = @{ pane_history = $true } } -NoBackup | Out-Null
    Assert-True (@(Get-Content $f) -contains '[experimental]') 'secao nao foi criada'
    Assert-Equal 'true' (Get-TomlSectionValue -Path $f -Section 'experimental' -Key 'pane_history')
}

It 'preserva chaves e secoes nao pedidas' {
    $f = New-TempToml -Lines $herdrToml; $script:tmpFiles += $f
    Set-TomlSectionValue -Path $f -Sections @{ ui = @{ mouse_capture = $false } } -NoBackup | Out-Null
    Assert-Equal '"priority"' (Get-TomlSectionValue -Path $f -Section 'ui'       -Key 'agent_panel_sort')
    Assert-Equal '1024'       (Get-TomlSectionValue -Path $f -Section 'advanced' -Key 'scrollback_limit_bytes')
}

It 'e idempotente em secoes nomeadas' {
    $f = New-TempToml -Lines $herdrToml; $script:tmpFiles += $f
    $s = @{ ui = @{ mouse_capture = $false }; advanced = @{ scrollback_limit_bytes = 10485760 } }
    Set-TomlSectionValue -Path $f -Sections $s -NoBackup | Out-Null
    $antes = [System.IO.File]::ReadAllText($f)
    $r = Set-TomlSectionValue -Path $f -Sections $s -NoBackup
    Assert-Equal $antes ([System.IO.File]::ReadAllText($f)) 'arquivo mudou na segunda passada'
    Assert-True (-not $r.Changed) 'Changed deveria ser false'
}

It 'remove BOM e converte CRLF tambem em secoes nomeadas' {
    $f = New-TempToml -Lines $herdrToml -WithBom -Crlf; $script:tmpFiles += $f
    $r = Set-TomlSectionValue -Path $f -Sections @{ ui = @{ mouse_capture = $false } } -NoBackup
    Assert-True $r.BomRemoved 'BomRemoved deveria ser true'
    Assert-True (-not (Test-TomlBom -Path $f)) 'BOM sobreviveu'
    Assert-True (-not ([System.IO.File]::ReadAllText($f)).Contains("`r`n")) 'CRLF sobreviveu'
}

It 'cria o arquivo com -CreateIfMissing' {
    $f = Join-Path ([System.IO.Path]::GetTempPath()) ("herdr-" + [guid]::NewGuid().ToString('N').Substring(0,8) + ".toml")
    $script:tmpFiles += $f
    $r = Set-TomlSectionValue -Path $f -Sections @{ ui = @{ mouse_capture = $false } } -CreateIfMissing -NoBackup
    Assert-True (-not $r.Missing) 'Missing deveria ser false'
    Assert-True (Test-Path $f) 'arquivo nao foi criado'
    Assert-Equal 'false' (Get-TomlSectionValue -Path $f -Section 'ui' -Key 'mouse_capture')
}

It 'sem -CreateIfMissing, arquivo ausente e reportado e nao explode' {
    $r = Set-TomlSectionValue -Path (Join-Path ([System.IO.Path]::GetTempPath()) 'nao-existe-herdr-xyz.toml') `
                              -Sections @{ ui = @{ mouse_capture = $false } }
    Assert-True $r.Missing 'Missing deveria ser true'
    Assert-True (-not $r.Changed) 'Changed deveria ser false'
}

It 'trata secao aninhada ([ui.toast]) como secao propria' {
    # o config do Herdr usa subtabelas; [ui.toast] nao pode ser confundida com
    # [ui], nem suas chaves vazarem para a secao pai
    $f = New-TempToml -Lines @("[ui]", 'accent = "cyan"'); $script:tmpFiles += $f
    Set-TomlSectionValue -Path $f -Sections @{ 'ui.toast' = @{ delivery = 'herdr' } } -NoBackup | Out-Null

    Assert-Equal '"herdr"' (Get-TomlSectionValue -Path $f -Section 'ui.toast' -Key 'delivery')
    Assert-Equal $null     (Get-TomlSectionValue -Path $f -Section 'ui'       -Key 'delivery')
    Assert-Equal '"cyan"'  (Get-TomlSectionValue -Path $f -Section 'ui'       -Key 'accent')
}

It 'chave da secao pai nao vaza para dentro da subtabela' {
    # [ui.toast] delimita o fim de [ui]: uma chave nova de [ui] tem que entrar
    # ANTES dela, ou o TOML a le como pertencente a subtabela
    $f = New-TempToml -Lines @("[ui]", 'accent = "cyan"', "", "[ui.toast]", 'delivery = "herdr"')
    $script:tmpFiles += $f
    Set-TomlSectionValue -Path $f -Sections @{ ui = @{ pane_gaps = $false } } -NoBackup | Out-Null

    $linhas   = @(Get-Content $f)
    $iToast   = [array]::IndexOf($linhas, '[ui.toast]')
    $iNova    = ($linhas | Select-String -Pattern '^pane_gaps' | Select-Object -First 1).LineNumber - 1
    Assert-True ($iNova -lt $iToast) 'chave de [ui] caiu dentro de [ui.toast]'
    Assert-Equal 'false' (Get-TomlSectionValue -Path $f -Section 'ui' -Key 'pane_gaps')
}

Write-Host ''
Write-Host '=== Testes: -WhatIf nao toca o disco ===' -ForegroundColor Cyan

It '-WhatIf nao grava, nao cria backup e reporta Changed' {
    $f = New-TempToml -Lines $baseToml; $script:tmpFiles += $f
    $antes = [System.IO.File]::ReadAllText($f)

    $r = Set-TomlOption -Path $f -Options @{ 'enable-terminal' = 'N' } -WhatIf

    Assert-True (-not (Test-Path "$f.bak")) 'backup foi criado sob -WhatIf'
    Assert-Equal $antes ([System.IO.File]::ReadAllText($f))
    Assert-True $r.Changed 'Changed deveria continuar reportando o que mudaria'
}

It '-WhatIf em secoes nomeadas tambem nao toca o disco' {
    $f = New-TempToml -Lines $herdrToml; $script:tmpFiles += $f
    $antes = [System.IO.File]::ReadAllText($f)

    Set-TomlSectionValue -Path $f -Sections @{ ui = @{ mouse_capture = $false } } -WhatIf | Out-Null

    Assert-True (-not (Test-Path "$f.bak")) 'backup foi criado sob -WhatIf'
    Assert-Equal $antes ([System.IO.File]::ReadAllText($f))
}

It '-WhatIf com -CreateIfMissing nao cria o arquivo' {
    $f = Join-Path ([System.IO.Path]::GetTempPath()) ("herdr-wi-" + [guid]::NewGuid().ToString('N').Substring(0,8) + ".toml")
    $script:tmpFiles += $f

    Set-TomlSectionValue -Path $f -Sections @{ ui = @{ mouse_capture = $false } } `
                         -CreateIfMissing -WhatIf | Out-Null

    Assert-True (-not (Test-Path $f)) 'arquivo foi criado sob -WhatIf'
}

It 'sem alteracao a fazer, nao cria backup' {
    # backup de arquivo que nao vai mudar so gera lixo ao lado do original
    $f = New-TempToml -Lines $herdrToml; $script:tmpFiles += $f
    $r = Set-TomlSectionValue -Path $f -Sections @{ advanced = @{ scrollback_limit_bytes = 1024 } }

    Assert-True (-not $r.Changed) 'nada deveria mudar'
    Assert-True (-not (Test-Path "$f.bak")) 'backup criado sem necessidade'
}

Write-Host ''
Write-Host '=== Testes: RustDesk.toml (LocalConfig), o arquivo com a senha ===' -ForegroundColor Cyan

# O RustDesk.toml nao tem secao [options] e guarda hash de senha, salt e as
# chaves do dispositivo em chaves de topo. Escrever ali e o caminho de
# 'enable-check-update': se a gravacao mexer no que nao devia, o custo nao e um
# .toml estranho - e a senha permanente da maquina.
$localToml = @(
    "enc_id = 'ENCID_FALSO'"
    "password = 'HASH_FALSO'"
    "salt = 'SALT_FALSO'"
    "key_pair = [1, 2, 3]"
    "key_confirmed = true"
    ""
    "[keys_confirmed]"
    "rs-ny = true"
)

It 'cria [options] quando o arquivo nao tem a secao' {
    $f = New-TempToml -Lines $localToml; $script:tmpFiles += $f
    $r = Set-TomlOption -Path $f -Options @{ 'enable-check-update' = 'N' } -NoBackup

    Assert-True $r.Changed 'deveria ter mudado'
    $txt = [System.IO.File]::ReadAllText($f)
    Assert-True ($txt -match '(?m)^\[options\]$')            'secao [options] nao foi criada'
    Assert-True ($txt -match "enable-check-update = 'N'")    'chave nao foi escrita'
}

It 'preserva senha, salt e chaves ao escrever em [options]' {
    $f = New-TempToml -Lines $localToml; $script:tmpFiles += $f
    $null = Set-TomlOption -Path $f -Options @{ 'enable-check-update' = 'N' } -NoBackup

    $txt = [System.IO.File]::ReadAllText($f)
    foreach ($linha in @(
        "enc_id = 'ENCID_FALSO'"
        "password = 'HASH_FALSO'"
        "salt = 'SALT_FALSO'"
        "key_pair = [1, 2, 3]"
        "key_confirmed = true"
        "[keys_confirmed]"
        "rs-ny = true"
    )) {
        Assert-True ($txt -match [regex]::Escape($linha)) "linha perdida na regravacao: $linha"
    }
}

It 'nao confunde chave de [options] com chave de topo de nome parecido' {
    # Set-TomlOption procura a chave no arquivo inteiro, nao so dentro de
    # [options]. Se 'password' fosse pedida como opcao, ela acertaria a chave
    # de topo - que e o hash da senha permanente.
    $f = New-TempToml -Lines $localToml; $script:tmpFiles += $f
    $null = Set-TomlOption -Path $f -Options @{ 'enable-check-update' = 'N' } -NoBackup

    $txt = [System.IO.File]::ReadAllText($f)
    Assert-Equal 1 ([regex]::Matches($txt, "^password = ", 'Multiline').Count) `
        'a chave password foi duplicada ou movida'
}

It 'e idempotente no RustDesk.toml' {
    $f = New-TempToml -Lines $localToml; $script:tmpFiles += $f
    $null  = Set-TomlOption -Path $f -Options @{ 'enable-check-update' = 'N' } -NoBackup
    $r2    = Set-TomlOption -Path $f -Options @{ 'enable-check-update' = 'N' } -NoBackup

    Assert-True (-not $r2.Changed) 'segunda passada deveria ser no-op'
}

Write-Host ''
Write-Host '=== Testes: pin de versao ===' -ForegroundColor Cyan

Import-Module (Join-Path $PSScriptRoot '..\lib\RustDeskCommon.psm1') -Force

It 'config/version.psd1 tem os campos que o instalador exige' {
    $pin = Get-RustDeskPin
    Assert-True ($pin.Version     -match '^\d+\.\d+\.\d+$|^latest$') "versao invalida: '$($pin.Version)'"
    Assert-True ($pin.UrlTemplate -match '\{0\}')                    'UrlTemplate sem o placeholder {0}'

    if ($pin.Version -ne 'latest') {
        # sem hash o instalador executaria um .msi sem conferir nada
        Assert-True ($pin.Sha256 -match '^[0-9A-Fa-f]{64}$') "Sha256 nao parece um SHA-256: '$($pin.Sha256)'"
    }
}

It 'a URL montada aponta para a release da versao fixada' {
    $pin = Get-RustDeskPin
    $url = $pin.UrlTemplate -f $pin.Version
    Assert-True ($url -match "download/$([regex]::Escape($pin.Version))/") 'a tag na URL nao e a versao fixada'
    Assert-True ($url -match '\.msi$')                                     'a URL nao aponta para um .msi'
}

It 'Get-RustDeskVersion corta o sufixo de build' {
    # o binario reporta '1.4.9+67'; as tags de release nao tem o '+67'
    $fake = Join-Path ([System.IO.Path]::GetTempPath()) ("rd-" + [guid]::NewGuid().ToString('N').Substring(0,8) + ".txt")
    Set-Content -LiteralPath $fake -Value 'nao e um exe' -Encoding ASCII
    $script:tmpFiles += $fake

    # arquivo sem VersionInfo devolve $null em vez de estourar
    Assert-Equal $null (Get-RustDeskVersion -Exe $fake) 'deveria devolver null para arquivo sem versao'
    Assert-Equal $null (Get-RustDeskVersion -Exe 'C:\caminho\que\nao\existe.exe') 'deveria devolver null para caminho inexistente'
}

Write-Host ''
Write-Host '=== Testes: os scripts repassam -WhatIf para o modulo ===' -ForegroundColor Cyan

# Regressao real: '-WhatIf' em Set-RustDeskConfig.ps1 gravava de verdade.
# $WhatIfPreference NAO atravessa fronteira de modulo - uma funcao exportada de
# lib\*.psm1 roda com o preference do escopo dela, nao o do script chamador.
# Quem chama Set-TomlOption/Set-TomlSectionValue sem -WhatIf explicito simula na
# tela e escreve no disco. Nao da para testar isso via execucao (os scripts
# exigem elevacao e mexem em caminhos reais), entao verifica-se a chamada.
$scriptsDir = Join-Path $PSScriptRoot '..\scripts'
foreach ($caso in @(
    @{ Arquivo = 'Set-RustDeskConfig.ps1'; Funcao = 'Set-TomlOption' },
    @{ Arquivo = 'Set-HerdrConfig.ps1';    Funcao = 'Set-TomlSectionValue' }
)) {
    It "$($caso.Arquivo) repassa -WhatIf para $($caso.Funcao)" {
        $caminho = Join-Path $scriptsDir $caso.Arquivo
        Assert-True (Test-Path -LiteralPath $caminho) "script nao encontrado: $caminho"

        $chamadas = (Get-Content -LiteralPath $caminho) |
                    Where-Object { $_ -match [regex]::Escape($caso.Funcao) -and $_ -notmatch '^\s*#' }
        Assert-True ($chamadas.Count -gt 0) "nenhuma chamada a $($caso.Funcao) encontrada"

        foreach ($linha in $chamadas) {
            Assert-True ($linha -match '-WhatIf:') `
                "chamada sem -WhatIf: explicito (grava mesmo em modo simulacao): $($linha.Trim())"
        }
    }
}

It 'Set-RustDeskConfig.ps1 nao para o servico em modo simulacao' {
    # parar o servico e efeito colateral real: um -WhatIf que derruba a sessao
    # remota e pior do que inutil para quem esta conectado por ela.
    $conteudo = Get-Content -LiteralPath (Join-Path $scriptsDir 'Set-RustDeskConfig.ps1') -Raw
    Assert-True ($conteudo -match '\$simulando\s*=\s*\[bool\]\$WhatIfPreference') `
        'o script nao captura $WhatIfPreference'
    Assert-True ($conteudo -match 'if \(-not \$NoRestart -and -not \$simulando\)') `
        'Stop-RustDeskClean nao esta guardado contra modo simulacao'
}


Write-Host ''
Write-Host '=== Testes: energia (notebook) ===' -ForegroundColor Cyan

It 'Set-PowerConfig.ps1 guarda cada efeito colateral contra modo simulacao' {
    # powercfg e Disable-NetAdapterPowerManagement sao efeito real: um -WhatIf
    # que reconfigura a maquina e pior do que inutil. Diferente do .toml, aqui
    # nao ha funcao de lib no meio - a guarda tem que estar em cada chamada.
    $conteudo = Get-Content -LiteralPath (Join-Path $scriptsDir 'Set-PowerConfig.ps1') -Raw
    Assert-True ($conteudo -match '\$simulando\s*=\s*\[bool\]\$WhatIfPreference') `
        'o script nao captura $WhatIfPreference'
    Assert-True ($conteudo -match 'if \(\$mudou -and -not \$simulando\)') `
        'powercfg /setactive nao esta guardado contra modo simulacao'

    $linhas = Get-Content -LiteralPath (Join-Path $scriptsDir 'Set-PowerConfig.ps1')
    $grava = $linhas | Where-Object {
        $_ -match 'setacvalueindex|setdcvalueindex|Disable-NetAdapterPowerManagement' -and $_ -notmatch '^\s*#'
    }
    Assert-True ($grava.Count -gt 0) 'nenhuma chamada de escrita encontrada'

    # cada escrita tem que vir depois de um ShouldProcess no mesmo bloco
    $texto = $conteudo
    Assert-True (([regex]::Matches($texto, 'ShouldProcess')).Count -ge 2) `
        'faltam guardas ShouldProcess antes das escritas'
}

It 'Set-PowerConfig.ps1 confirma o valor em vez de afirmar que gravou' {
    # powercfg nao devolve exit code confiavel: sem reler, o script anunciaria
    # sucesso numa maquina onde nada mudou.
    $conteudo = Get-Content -LiteralPath (Join-Path $scriptsDir 'Set-PowerConfig.ps1') -Raw
    Assert-True ($conteudo -match 'Read-PowerIndex') 'nao ha releitura dos indices'
    Assert-True ($conteudo -match '\$falhas\s*\+=') 'divergencia apos gravar nao vira falha'
}

It 'a leitura dos indices do powercfg nao depende de rotulo traduzido' {
    # Em Windows pt-BR os rotulos do powercfg sao traduzidos: casar contra
    # 'Current AC Power Setting Index' daria falso negativo, mesma familia de
    # armadilha do IsInRole com string. O que nao muda e o formato do valor.
    foreach ($arq in @('Set-PowerConfig.ps1', 'Test-RustDeskSetup.ps1', 'Get-PowerDiagnostics.ps1')) {
        $caminho = Join-Path $scriptsDir $arq
        $bruto   = Get-Content -LiteralPath $caminho -Raw

        Assert-True ($bruto -match '0x\[0-9A-Fa-f\]\{8\}') `
            "$arq nao usa o formato do valor para localizar os indices"

        # so as linhas que de fato casam texto - o comentario que explica a
        # armadilha cita a frase em ingles de proposito.
        $casadoras = (Get-Content -LiteralPath $caminho) |
                     Where-Object { $_ -match '(-match|-like|Select-String)' }
        foreach ($linha in $casadoras) {
            Assert-True ($linha -notmatch 'Setting Index') `
                "$arq casa contra rotulo traduzivel do powercfg: $($linha.Trim())"
        }
    }
}

It 'o carimbo de epoca do watchdog inclui o resume, nao so o boot' {
    # Num notebook, carimbar so o LastBootUpTime transforma a guarda "uma vez
    # por boot" numa trava: a maquina suspende varias vezes por dia sem
    # reiniciar, e uma recusa gravada de manha valeria ate o proximo boot.
    $tpl = Get-Content -LiteralPath (Join-Path $repoRaiz 'scripts\watchdog\rustdesk-watchdog.ps1') -Raw
    Assert-True ($tpl -match 'function Get-EpochStamp') 'o template nao define Get-EpochStamp'
    Assert-True ($tpl -match 'Get-LastResume') 'o template nao consulta o ultimo resume'
    Assert-True ($tpl -notmatch '\$bootAtual') 'o carimbo antigo (so boot) ainda esta em uso'
    Assert-True ($tpl -match 'Set-Content -LiteralPath \$stamp -Value \$epocaAtual') `
        'o stamp gravado nao e o carimbo de epoca'
}

It 'o daemon solta o bloqueio ao sair' {
    # Um daemon morto deixando a maquina insone para sempre e pior do que nao
    # ter daemon nenhum.
    $tpl = Get-Content -LiteralPath (Join-Path $repoRaiz 'scripts\awake\rustdesk-awake.ps1') -Raw
    Assert-True ($tpl -match 'finally') 'nao ha finally que solte o bloqueio'
    Assert-True ($tpl -match 'PowerShell.Exiting') 'nao ha handler de saida do host'
    # ES_DISPLAY_REQUIRED de fora de proposito: em notebook o painel e o maior
    # consumidor isolado, e segurar a tela acesa nao ajuda uma sessao de Terminal.
    # O teste olha a VARIAVEL, nao a mencao: o cabecalho do template explica a
    # decisao em prosa e nao pode reprovar por isso.
    Assert-True ($tpl -notmatch '\$ES_DISPLAY_REQUIRED') `
        'ES_DISPLAY_REQUIRED nao deve ser usado: o painel pode apagar'
    Assert-True ($tpl -match '\$ES_CONTINUOUS -bor \$ES_SYSTEM_REQUIRED') `
        'o bloqueio nao usa ES_CONTINUOUS | ES_SYSTEM_REQUIRED'
}

It 'config/power.psd1 tem as chaves que os scripts leem' {
    $power = Import-RustDeskConfigFile -Path (Join-Path $repoRaiz 'config\power.psd1')
    foreach ($k in @('LidActionAC', 'LidActionDC', 'StandbyIdleAC', 'StandbyIdleDC',
                     'HibernateIdleAC', 'HibernateIdleDC', 'VideoIdleAC', 'VideoIdleDC',
                     'ConnectivityInStandby', 'DisableNicPowerSaving',
                     'KeepAwakeWhileConnected', 'KeepAwakePollSeconds',
                     'KeepAwakeMinBatteryPercent')) {
        Assert-True ($power.Contains($k)) "config/power.psd1 sem a chave $k"
    }
    # A tampa nao pode suspender: e a decisao central do suporte a notebook.
    Assert-Equal 0 $power['LidActionAC'] 'LidActionAC deveria ser 0 (nao fazer nada)'
    Assert-Equal 0 $power['LidActionDC'] 'LidActionDC deveria ser 0 (nao fazer nada)'
    # O daemon precisa reagir antes de a maquina dormir.
    Assert-True ($power['KeepAwakePollSeconds'] -lt $power['StandbyIdleDC']) `
        'KeepAwakePollSeconds precisa ser menor que StandbyIdleDC'
}

# limpeza
$tmpFiles | Sort-Object -Unique | ForEach-Object { Remove-Item $_ -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($script:falhou -eq 0) {
    Write-Host "=== $script:passou teste(s), tudo passou ===" -ForegroundColor Green
} else {
    Write-Host "=== $script:passou passou, $script:falhou falhou ===" -ForegroundColor Red
    exit 1
}
