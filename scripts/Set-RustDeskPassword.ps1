<#
.SYNOPSIS
    Define a senha permanente do RustDesk sem deixa-la no historico do shell.

.DESCRIPTION
    Com a tela bloqueada quem autentica e o servico, e sem senha permanente
    gravada a conexao falha mesmo com todas as opcoes corretas. Este e o unico
    passo obrigatorio do setup que depende de um segredo, e por isso ele nao
    entra em -All: nenhum script deve inventar a sua senha.

    O RustDesk aceita 'rustdesk.exe --password <senha>' (src/core_main.rs). A
    chamada exige instalacao E privilegios de Administrador, e grava via IPC -
    o mesmo caminho que a UI usa, entao os DOIS perfis (usuario e servico)
    ficam sincronizados. Editar o RustDesk.toml na mao nao substitui isto: o
    arquivo guarda hash e salt, nao a senha.

    -- Sobre exposicao do segredo -----------------------------------------
    Passar a senha como argumento a expoe na linha de comando do processo
    enquanto ele roda, visivel a outros processos (Win32_Process.CommandLine).
    A janela e curta, mas existe, e nao ha API alternativa exposta pelo
    RustDesk. Este script reduz o que pode: le a senha como SecureString (sem
    eco na tela) e nunca a escreve em disco, log ou historico do PowerShell.

    Quem quer exposicao zero define a senha pela UI do RustDesk. Este script
    existe para quem precisa automatizar - e o custo esta declarado.

.PARAMETER Password
    SecureString com a senha. Omitido, o script pergunta sem eco.
    Nao aceita string em claro de proposito: um parametro [string] apareceria
    no historico do PSReadLine de quem chamasse com valor literal.

.EXAMPLE
    .\scripts\Set-RustDeskPassword.ps1
    Pergunta a senha sem eco e aplica. Exige Administrador.

.EXAMPLE
    $s = Read-Host -AsSecureString 'senha'
    .\scripts\Set-RustDeskPassword.ps1 -Password $s
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [System.Security.SecureString]$Password
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\lib\RustDeskCommon.psm1') -Force

$paths = Get-RustDeskPaths
if (-not $paths.Installed) { throw 'rustdesk.exe nao encontrado. Rode .\Setup.ps1 -Install antes.' }

# is_root() no lado do RustDesk: sem elevacao ele responde
# "Installation and administrative privileges required!" e sai com sucesso,
# o que passaria por "deu certo" se ninguem lesse a saida.
Assert-Elevated

if (-not $Password) {
    Write-Host ''
    Write-Host 'Senha permanente do RustDesk (nao aparece na tela).' -ForegroundColor Cyan
    Write-Host 'Ela autentica as conexoes com a tela bloqueada - use uma senha forte.' -ForegroundColor DarkGray
    $Password  = Read-Host -AsSecureString 'senha'
    $confirma  = Read-Host -AsSecureString 'confirme'

    # comparacao feita em texto claro na memoria, pelo tempo minimo necessario
    $b1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    $b2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($confirma)
    try {
        $p1 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b1)
        $p2 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b2)
        if ($p1 -ne $p2)      { throw 'as senhas nao conferem.' }
        if ($p1.Length -lt 8) { throw 'senha curta demais (minimo 8 caracteres).' }
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b1)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b2)
        Remove-Variable p1, p2 -ErrorAction SilentlyContinue
    }
}

if (-not $PSCmdlet.ShouldProcess('rustdesk --password', 'definir a senha permanente')) { return }

$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
try {
    $claro = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)

    # Start-Process, nao '& rustdesk --password $claro': o operador de chamada
    # deixaria a linha montada no historico de comandos desta sessao.
    $saidaFile = [System.IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath $paths.Exe -ArgumentList @('--password', $claro) `
                -Wait -PassThru -NoNewWindow -RedirectStandardOutput $saidaFile
        $saida = (Get-Content -LiteralPath $saidaFile -Raw -ErrorAction SilentlyContinue)
    } finally {
        Remove-Item -LiteralPath $saidaFile -Force -ErrorAction SilentlyContinue
    }
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    Remove-Variable claro -ErrorAction SilentlyContinue
}

$texto = if ($saida) { $saida.Trim() } else { '' }

# O RustDesk sai com 0 mesmo recusando: e a saida que diz o que houve.
if ($texto -match 'Done!') {
    Write-Host '  senha permanente definida (gravada via IPC nos dois perfis)' -ForegroundColor Green
    Write-Host '  confira com: .\Setup.ps1 -Test   (como Administrador)' -ForegroundColor DarkGray
} elseif ($texto -match 'disabled') {
    throw "o RustDesk recusou: $texto (a alteracao de senha esta desabilitada na config)"
} elseif ($texto -match 'privileges required') {
    throw "o RustDesk recusou: $texto"
} else {
    Write-Host "  AVISO: resposta inesperada do RustDesk: '$texto'" -ForegroundColor Yellow
    Write-Host '  verifique com: .\Setup.ps1 -Test' -ForegroundColor Yellow
}
