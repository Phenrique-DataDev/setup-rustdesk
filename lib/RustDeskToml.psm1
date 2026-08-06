<#
.SYNOPSIS
    Leitura e escrita dos arquivos RustDesk2.toml preservando o formato nativo.

.DESCRIPTION
    O RustDesk grava seus .toml em UTF-8 SEM BOM com quebras LF. O cmdlet
    Set-Content -Encoding UTF8 do Windows PowerShell 5.1 adiciona BOM e usa
    CRLF, desviando do formato original. Este modulo evita isso.

    As funcoes sao idempotentes: rodar duas vezes com os mesmos valores nao
    altera o arquivo.
#>

Set-StrictMode -Version Latest

function Write-TomlFile {
    <#
    .SYNOPSIS
        Grava um array de linhas como UTF-8 sem BOM com quebras LF.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        # AllowEmptyString e obrigatorio: um parametro Mandatory de string
        # rejeita elementos vazios, e o .toml tem linhas em branco.
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines
    )
    $text = ($Lines -join "`n") + "`n"
    [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function Test-TomlBom {
    <#
    .SYNOPSIS
        Retorna $true se o arquivo comeca com BOM UTF-8.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
}

function Get-TomlOption {
    <#
    .SYNOPSIS
        Le o valor de uma chave da secao [options]. Retorna $null se ausente.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Key
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $null }

    foreach ($line in @(Get-Content -LiteralPath $Path)) {
        if ($line -match "^\s*$([regex]::Escape($Key))\s*=\s*'?([^']*)'?\s*$") {
            return $Matches[1]
        }
    }
    return $null
}

function Set-TomlOption {
    <#
    .SYNOPSIS
        Garante que as chaves informadas existam com o valor certo em [options].

    .PARAMETER Options
        Hashtable chave -> valor. Os valores sao gravados entre aspas simples,
        que e como o RustDesk escreve as opcoes.

    .OUTPUTS
        PSCustomObject com Path, Changed (bool), BomRemoved (bool) e Actions.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Options,
        [switch]$NoBackup
    )

    $actions    = @()
    $bomRemoved = $false

    if (-not (Test-Path -LiteralPath $Path)) {
        return [PSCustomObject]@{
            Path = $Path; Changed = $false; BomRemoved = $false
            Actions = @('arquivo nao existe - nada a fazer'); Missing = $true
        }
    }

    if (Test-TomlBom -Path $Path) {
        $bomRemoved = $true
        $actions += 'BOM UTF-8 detectado - removido na regravacao'
    }

    $original = [System.IO.File]::ReadAllText($Path)

    if (-not $NoBackup) {
        Copy-Item -LiteralPath $Path -Destination "$Path.bak" -Force
        $actions += "backup: $Path.bak"
    }

    # Get-Content descarta o BOM na leitura; e a regravacao que o tira do disco.
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($l in @(Get-Content -LiteralPath $Path)) { [void]$lines.Add($l) }

    # localiza a secao [options]
    $idx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq '[options]') { $idx = $i; break }
    }
    if ($idx -lt 0) {
        $actions += 'AVISO: secao [options] ausente - criada no fim do arquivo'
        [void]$lines.Add('')
        [void]$lines.Add('[options]')
        $idx = $lines.Count - 1
    }

    foreach ($key in $Options.Keys) {
        $newLine = "$key = '$($Options[$key])'"
        $found   = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match "^\s*$([regex]::Escape($key))\s*=") { $found = $i; break }
        }
        if ($found -ge 0) {
            if ($lines[$found].Trim() -eq $newLine) { $actions += "ok (ja estava): $key" }
            else { $lines[$found] = $newLine; $actions += "atualizado: $key" }
        } else {
            $lines.Insert($idx + 1, $newLine)
            $actions += "inserido: $key"
        }
    }

    $newText = ($lines.ToArray() -join "`n") + "`n"
    $changed = ($newText -ne $original)

    if ($changed) {
        if ($PSCmdlet.ShouldProcess($Path, 'gravar RustDesk2.toml')) {
            Write-TomlFile -Path $Path -Lines $lines.ToArray()
        }
    } else {
        $actions += 'nenhuma alteracao necessaria - arquivo intacto'
    }

    return [PSCustomObject]@{
        Path = $Path; Changed = $changed; BomRemoved = $bomRemoved
        Actions = $actions; Missing = $false
    }
}

function ConvertTo-TomlLiteral {
    <#
    .SYNOPSIS
        Converte um valor do PowerShell para a sintaxe literal do TOML.

    .DESCRIPTION
        $true -> true | 123 -> 123 | 'texto' -> "texto"

        O .toml do RustDesk usa aspas simples em tudo (ver Set-TomlOption);
        outros arquivos, como o config.toml do Herdr, usam os tipos nativos
        do TOML. Esta funcao existe para o segundo caso.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()]$Value)

    if ($null -eq $Value) { throw 'valor nulo nao tem representacao em TOML' }

    if ($Value -is [bool])   { return $Value.ToString().ToLowerInvariant() }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return [string]::Format([cultureinfo]::InvariantCulture, '{0}', $Value)
    }

    $escapado = ([string]$Value).Replace('\', '\\').Replace('"', '\"')
    return '"' + $escapado + '"'
}

function Get-TomlSectionValue {
    <#
    .SYNOPSIS
        Le uma chave de uma secao nomeada. Retorna $null se ausente.

    .DESCRIPTION
        Diferente de Get-TomlOption, respeita o escopo da secao: uma chave em
        [ui] nao e confundida com a chave homonima em [advanced].
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $null }

    $atual = ''
    foreach ($line in @(Get-Content -LiteralPath $Path)) {
        if ($line -match '^\s*\[([^\]]+)\]\s*$') { $atual = $Matches[1].Trim(); continue }
        if ($atual -eq $Section -and $line -match "^\s*$([regex]::Escape($Key))\s*=\s*(.+?)\s*$") {
            return $Matches[1]
        }
    }
    return $null
}

function Set-TomlSectionValue {
    <#
    .SYNOPSIS
        Garante chaves com valor certo em secoes nomeadas, preservando o
        formato nativo (UTF-8 sem BOM, LF).

    .PARAMETER Sections
        Hashtable de secao -> hashtable de chave -> valor. Exemplo:
            @{ ui = @{ mouse_capture = $false }
               advanced = @{ scrollback_limit_bytes = 10485760 } }

        Os valores passam por ConvertTo-TomlLiteral: booleanos e numeros
        entram crus, strings entram entre aspas duplas.

    .OUTPUTS
        PSCustomObject com Path, Changed, BomRemoved, Actions e Missing.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Sections,
        [switch]$NoBackup,
        # cria o arquivo se ele nao existir, em vez de reportar Missing
        [switch]$CreateIfMissing
    )

    $actions    = @()
    $bomRemoved = $false

    if (-not (Test-Path -LiteralPath $Path)) {
        if (-not $CreateIfMissing) {
            return [PSCustomObject]@{
                Path = $Path; Changed = $false; BomRemoved = $false
                Actions = @('arquivo nao existe - nada a fazer'); Missing = $true
            }
        }
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $actions += "diretorio criado: $dir"
        }
        Write-TomlFile -Path $Path -Lines @()
        $actions += 'arquivo criado'
    }

    if (Test-TomlBom -Path $Path) {
        $bomRemoved = $true
        $actions += 'BOM UTF-8 detectado - removido na regravacao'
    }

    $original = [System.IO.File]::ReadAllText($Path)

    if (-not $NoBackup) {
        Copy-Item -LiteralPath $Path -Destination "$Path.bak" -Force
        $actions += "backup: $Path.bak"
    }

    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($l in @(Get-Content -LiteralPath $Path)) { [void]$lines.Add($l) }

    foreach ($secao in $Sections.Keys) {
        # limites da secao: do cabecalho ate o proximo [algo] ou o fim
        $inicio = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*\[([^\]]+)\]\s*$' -and $Matches[1].Trim() -eq $secao) { $inicio = $i; break }
        }

        if ($inicio -lt 0) {
            if ($lines.Count -gt 0 -and $lines[$lines.Count - 1].Trim() -ne '') { [void]$lines.Add('') }
            [void]$lines.Add("[$secao]")
            $inicio = $lines.Count - 1
            $actions += "secao criada: [$secao]"
        }

        $fim = $lines.Count
        for ($i = $inicio + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*\[[^\]]+\]\s*$') { $fim = $i; break }
        }

        foreach ($key in $Sections[$secao].Keys) {
            $literal = ConvertTo-TomlLiteral -Value $Sections[$secao][$key]
            $newLine = "$key = $literal"

            $found = -1
            for ($i = $inicio + 1; $i -lt $fim; $i++) {
                if ($lines[$i] -match "^\s*$([regex]::Escape($key))\s*=") { $found = $i; break }
            }

            if ($found -ge 0) {
                if ($lines[$found].Trim() -eq $newLine) { $actions += "ok (ja estava): [$secao] $key" }
                else { $lines[$found] = $newLine; $actions += "atualizado: [$secao] $key" }
            } else {
                # insere no fim da secao, ignorando as linhas em branco finais
                $ins = $fim
                while ($ins - 1 -gt $inicio -and $lines[$ins - 1].Trim() -eq '') { $ins-- }
                $lines.Insert($ins, $newLine)
                $fim++
                $actions += "inserido: [$secao] $key"
            }
        }
    }

    $newText = ($lines.ToArray() -join "`n") + "`n"
    $changed = ($newText -ne $original)

    if ($changed) {
        if ($PSCmdlet.ShouldProcess($Path, 'gravar config.toml')) {
            Write-TomlFile -Path $Path -Lines $lines.ToArray()
        }
    } else {
        $actions += 'nenhuma alteracao necessaria - arquivo intacto'
    }

    return [PSCustomObject]@{
        Path = $Path; Changed = $changed; BomRemoved = $bomRemoved
        Actions = $actions; Missing = $false
    }
}

Export-ModuleMember -Function Write-TomlFile, Test-TomlBom, Get-TomlOption, Set-TomlOption, `
                              ConvertTo-TomlLiteral, Get-TomlSectionValue, Set-TomlSectionValue
