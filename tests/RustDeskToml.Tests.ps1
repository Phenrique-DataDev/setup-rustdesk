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
Import-Module (Join-Path $PSScriptRoot '..\lib\RustDeskToml.psm1') -Force

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

# limpeza
$tmpFiles | Sort-Object -Unique | ForEach-Object { Remove-Item $_ -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($script:falhou -eq 0) {
    Write-Host "=== $script:passou teste(s), tudo passou ===" -ForegroundColor Green
} else {
    Write-Host "=== $script:passou passou, $script:falhou falhou ===" -ForegroundColor Red
    exit 1
}
