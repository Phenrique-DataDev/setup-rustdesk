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

# limpeza
$tmpFiles | Sort-Object -Unique | ForEach-Object { Remove-Item $_ -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($script:falhou -eq 0) {
    Write-Host "=== $script:passou teste(s), tudo passou ===" -ForegroundColor Green
} else {
    Write-Host "=== $script:passou passou, $script:falhou falhou ===" -ForegroundColor Red
    exit 1
}
