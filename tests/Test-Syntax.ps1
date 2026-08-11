<#
.SYNOPSIS
    Checagem estatica de todos os .ps1/.psm1/.psd1 do repositorio.

.DESCRIPTION
    Duas verificacoes, ambas sem tocar em nada do sistema:

    1. PARSER  - roda o parser do PowerShell em cada arquivo. Pega erro de
                 sintaxe que so apareceria na hora de executar o script - e
                 varios deles so executam com Administrador numa maquina real.
    2. ASCII   - o CLAUDE.md exige codigo, comentarios e mensagens sem acento,
                 porque os scripts rodam em consoles com code page variavel.
                 Um 'a' acentuado vira lixo em CP437/CP850.

    Sai com codigo 1 se algo falhar, para servir de gate no CI.

.EXAMPLE
    .\tests\Test-Syntax.ps1
#>
[CmdletBinding()] param()

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot

$arquivos = Get-ChildItem -LiteralPath $raiz -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1' |
            Where-Object { $_.FullName.Split([IO.Path]::DirectorySeparatorChar) -notcontains '.git' } |
            Sort-Object FullName

if ($arquivos.Count -eq 0) { throw 'nenhum arquivo PowerShell encontrado' }

$falhas = 0

Write-Host "=== Parser: $($arquivos.Count) arquivo(s) ==="
foreach ($arq in $arquivos) {
    $rel = $arq.FullName.Substring($raiz.Length + 1)
    $erros = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile(
        $arq.FullName, [ref]$null, [ref]$erros)

    if ($erros -and $erros.Count -gt 0) {
        Write-Host "  [FALHA] $rel" -ForegroundColor Red
        foreach ($e in $erros) {
            Write-Host "          linha $($e.Extent.StartLineNumber): $($e.Message)" -ForegroundColor DarkGray
        }
        $falhas++
    } else {
        Write-Host "  [PASS]  $rel" -ForegroundColor Green
    }
}

Write-Host ''
Write-Host '=== ASCII: codigo sem acentos ==='
$comAcento = 0
foreach ($arq in $arquivos) {
    $rel = $arq.FullName.Substring($raiz.Length + 1)
    $linhas = [System.IO.File]::ReadAllLines($arq.FullName)
    $ruins = @()

    for ($i = 0; $i -lt $linhas.Count; $i++) {
        foreach ($ch in $linhas[$i].ToCharArray()) {
            if ([int]$ch -gt 127) {
                $ruins += "linha $($i + 1): '$ch' em: $($linhas[$i].Trim())"
                break
            }
        }
    }

    if ($ruins.Count -gt 0) {
        Write-Host "  [FALHA] $rel" -ForegroundColor Red
        $ruins | ForEach-Object { Write-Host "          $_" -ForegroundColor DarkGray }
        $comAcento++
        $falhas++
    }
}
if ($comAcento -eq 0) {
    Write-Host "  [PASS]  nenhum caractere fora do ASCII em $($arquivos.Count) arquivo(s)" -ForegroundColor Green
}

Write-Host ''
if ($falhas -eq 0) {
    Write-Host '=== checagem estatica: tudo passou ===' -ForegroundColor Green
} else {
    Write-Host "=== checagem estatica: $falhas arquivo(s) com problema ===" -ForegroundColor Red
    exit 1
}
