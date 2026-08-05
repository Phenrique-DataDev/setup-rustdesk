<#
.SYNOPSIS
    Abre a transcricao do chat do agente num pager navegavel por teclado.

.DESCRIPTION
    O chat do agente roda em alternate screen: nao gera scrollback no Herdr,
    entao nao ha o que rolar nem o que ler com 'herdr pane read'. O historico
    real vive em disco, no .jsonl da sessao:

        %USERPROFILE%\.claude\projects\<slug-do-cwd>\<session-id>.jsonl

    Este script converte esse arquivo em texto e joga num pager. A rolagem
    passa a ser do pager - teclado puro, sem depender da roda do mouse e sem
    depender do transporte do RustDesk.

    Navegacao no less: setas/PgUp/PgDn rolam, 'g'/'G' vao ao inicio/fim,
    '/texto' busca, 'q' sai.

.EXAMPLE
    .\scripts\Show-AgentTranscript.ps1
    Abre a sessao mais recente do projeto atual.

.EXAMPLE
    .\scripts\Show-AgentTranscript.ps1 -Raw | Select-String 'erro'
    Emite o texto no stdout em vez de paginar.

.EXAMPLE
    .\scripts\Show-AgentTranscript.ps1 -List
    Lista as sessoes disponiveis do projeto, da mais recente para a mais antiga.
#>
[CmdletBinding()]
param(
    [string]$ProjectPath = (Get-Location).Path,  # cwd usado para achar o slug do projeto
    [string]$SessionId,                          # default: a sessao mais recente
    [switch]$List,                               # so lista as sessoes e sai
    [switch]$Raw,                                # stdout em vez de pager
    [switch]$NoToolOutput                        # omite os resultados de ferramenta (so a conversa)
)

$ErrorActionPreference = 'Stop'

# O .jsonl e UTF-8; sem isto os acentos saem quebrados no console do Windows.
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
try { [Console]::OutputEncoding = $OutputEncoding } catch { }

# --- localizar o diretorio da sessao ----------------------------------
# O Claude Code deriva o slug do caminho absoluto: separadores e ':' viram '-'.
$full = [System.IO.Path]::GetFullPath($ProjectPath)
$slug = $full -replace '[\\/:]', '-'
$dir  = Join-Path $env:USERPROFILE ".claude\projects\$slug"

if (-not (Test-Path -LiteralPath $dir)) {
    throw "nenhuma transcricao encontrada para '$full' (procurei em $dir)"
}

$sessions = Get-ChildItem -LiteralPath $dir -Filter '*.jsonl' | Sort-Object LastWriteTime -Descending
if (-not $sessions) { throw "diretorio existe mas nao tem sessao: $dir" }

if ($List) {
    $sessions | Select-Object @{n='Sessao';e={$_.BaseName}},
                              @{n='Atualizada';e={$_.LastWriteTime}},
                              @{n='KB';e={[math]::Round($_.Length / 1KB)}}
    return
}

$file = if ($SessionId) {
    $match = $sessions | Where-Object BaseName -eq $SessionId
    if (-not $match) { throw "sessao '$SessionId' nao encontrada em $dir" }
    $match
} else {
    $sessions[0]
}

# --- renderizar ---------------------------------------------------------
# Um bloco de conteudo pode ser string ou array de partes (text, tool_use,
# tool_result). Linhas de controle (mode, snapshot...) nao viram texto.
function Format-Content {
    param($Content)

    if ($Content -is [string]) { return $Content }

    $partes = foreach ($bloco in $Content) {
        switch ($bloco.type) {
            'text'     { $bloco.text }
            'thinking' { "[pensamento omitido]" }
            'tool_use' { "  -> $($bloco.name) $($bloco.input | ConvertTo-Json -Compress -Depth 3)" }
            'tool_result' {
                if ($NoToolOutput) { continue }
                $texto = if ($bloco.content -is [string]) { $bloco.content } else { ($bloco.content | ForEach-Object { $_.text }) -join "`n" }
                ($texto -split "`n" | ForEach-Object { "  | $_" }) -join "`n"
            }
        }
    }
    ($partes | Where-Object { $_ }) -join "`n"
}

$linhas = foreach ($linha in [System.IO.File]::ReadLines($file.FullName, [System.Text.Encoding]::UTF8)) {
    if (-not $linha.Trim()) { continue }
    try { $ev = $linha | ConvertFrom-Json } catch { continue }
    if ($ev.type -notin 'user', 'assistant') { continue }
    if ($ev.isSidechain) { continue }   # subagentes poluem a leitura da conversa principal

    $corpo = Format-Content $ev.message.content
    if (-not $corpo.Trim()) { continue }

    # turno de 'user' que so carrega tool_result e saida de ferramenta, nao fala sua
    $soFerramenta = $ev.message.content -isnot [string] -and
                    -not ($ev.message.content | Where-Object { $_.type -eq 'text' })

    $quem = if ($ev.type -ne 'user') { 'CLAUDE' }
            elseif ($soFerramenta)   { 'SAIDA'  }
            else                     { 'VOCE'   }
    $hora  = if ($ev.timestamp) { ([datetime]$ev.timestamp).ToLocalTime().ToString('HH:mm:ss') } else { '' }

    ''
    "===== $quem  $hora ".PadRight(72, '=')
    $corpo
}

$cabecalho = @(
    "sessao:  $($file.BaseName)"
    "projeto: $full"
    "arquivo: $($file.FullName)"
    "(setas/PgUp/PgDn rolam - g/G inicio/fim - /texto busca - q sai)"
    ''
)
$saida = $cabecalho + $linhas

if ($Raw) { $saida; return }

$pager = Get-Command less -ErrorAction SilentlyContinue
if ($pager) {
    # -R preserva cores, +G abre no fim (a parte mais recente da conversa)
    $saida | & $pager.Source -R +G
} else {
    Write-Warning "less nao encontrado - usando 'more'. Sem busca e sem rolagem pra tras."
    $saida | more.com
}
