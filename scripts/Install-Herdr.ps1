<#
.SYNOPSIS
    Instala o Herdr e registra o servidor para subir no logon do usuario.

.DESCRIPTION
    O Herdr e a metade "terminal" da stack: o RustDesk entrega o transporte e o
    Herdr mantem os processos vivos quando a conexao cai, a tela bloqueia ou o
    terminal e fechado. Sem o servidor no ar, reconectar nao devolve o trabalho
    no ponto em que parou - e esse e o motivo de o Herdr estar aqui.

    Instala pelo instalador OFICIAL (https://herdr.dev/install.ps1). O winget
    tem um pacote 'herdr', mas e um fork nao-oficial de terceiro
    (khanhtd36.herdr-khanhtd36), que se declara sem afiliacao com o projeto -
    binario de terceiro numa maquina de acesso remoto e uma decisao que este
    script nao toma por voce.

    NAO exige Administrador: o Herdr instala no perfil do usuario e a tarefa
    agendada e registrada para o proprio usuario. Se voce rodar isto de um
    console elevado, o alvo continua sendo o seu perfil (o UAC eleva o mesmo
    usuario) - mas rodar como OUTRO usuario administrador instalaria no perfil
    errado, e o script avisa nesse caso.

.PARAMETER SkipInstall
    Nao baixa nada: so registra o autostart de uma instalacao existente.

.PARAMETER NoAutostart
    Instala sem registrar a tarefa de logon.

.PARAMETER NoStart
    Nao sobe o servidor agora; ele subira no proximo logon.

.EXAMPLE
    .\scripts\Install-Herdr.ps1
    Instala se faltar, registra o autostart e sobe o servidor.

.EXAMPLE
    .\scripts\Install-Herdr.ps1 -SkipInstall
    So garante o autostart de um Herdr ja instalado.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$SkipInstall,
    [switch]$NoAutostart,
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\lib\RustDeskCommon.psm1') -Force

$log   = @()
$paths = Get-HerdrPaths

# O perfil alvo e o de quem esta rodando. Elevar pelo UAC preserva o usuario;
# "executar como outro usuario" nao - e ai a instalacao iria para o perfil errado.
if ((Test-Elevated) -and -not (Test-Path -LiteralPath $env:APPDATA)) {
    throw "APPDATA inacessivel ($env:APPDATA). Rode este passo na sessao do usuario que vai usar o Herdr."
}

# --- 1) instalar o binario -------------------------------------------
if ($paths.Installed) {
    $versao = try { (& $paths.Exe --version 2>&1 | Out-String).Trim() } catch { '(versao nao lida)' }
    $log += "Herdr ja instalado: $($paths.Exe)"
    $log += "  $versao"
} elseif ($SkipInstall) {
    throw 'Herdr nao encontrado e -SkipInstall foi usado. Instale antes de continuar.'
} else {
    $log += 'instalando o Herdr pelo instalador oficial (https://herdr.dev/install.ps1)...'
    if ($PSCmdlet.ShouldProcess('herdr.dev/install.ps1', 'baixar e executar o instalador')) {
        # O instalador e executado em um powershell.exe separado, como a
        # documentacao do Herdr descreve: ele mexe no PATH do usuario e no
        # layout de %LOCALAPPDATA%\Programs\Herdr, e um processo proprio
        # mantem isso fora do escopo desta sessao.
        $p = Start-Process -FilePath 'powershell.exe' -Wait -PassThru -NoNewWindow -ArgumentList @(
            '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-Command', 'irm https://herdr.dev/install.ps1 | iex'
        )
        if ($p.ExitCode -ne 0) { throw "o instalador do Herdr retornou codigo $($p.ExitCode)" }

        $paths = Get-HerdrPaths
        if (-not $paths.Installed) {
            throw @'
o instalador terminou mas herdr.exe nao foi encontrado.
Procurado no PATH e em %LOCALAPPDATA%\Programs\Herdr\bin\herdr.exe.
Instale manualmente por https://herdr.dev e rode de novo com -SkipInstall.
'@
        }
        $log += "instalado: $($paths.Exe)"
        # o instalador altera o PATH do usuario; esta sessao ainda tem o antigo
        $log += 'AVISO: abra um terminal novo para que "herdr" resolva pelo PATH nesta sessao.'
    }
}

# --- 2) autostart no logon -------------------------------------------
# Sem isto, o servidor so existe depois de alguem abrir o Herdr a mao - o que
# ninguem faz com a tela bloqueada, que e exatamente quando ele mais importa.
if ($NoAutostart) {
    $log += 'autostart pulado (-NoAutostart)'
} else {
    $usuario = "$env:USERDOMAIN\$env:USERNAME"
    if ($PSCmdlet.ShouldProcess($paths.TaskName, "registrar tarefa de logon para $usuario")) {
        try {
            # O launcher e materializado fora do repositorio, como o watchdog:
            # uma tarefa que aponta para o clone quebra quando a pasta e movida
            # ou apagada. Ele checa antes de subir - 'herdr server' com um
            # servidor ja no ar disputaria o mesmo socket.
            $launcher = Join-Path $paths.ConfigDir 'start-herdr-server.ps1'
            if (-not (Test-Path -LiteralPath $paths.ConfigDir)) {
                New-Item -ItemType Directory -Path $paths.ConfigDir -Force | Out-Null
            }
            @"
# Gerado por setup-rustdesk (scripts\Install-Herdr.ps1). Editar aqui e perder
# na proxima execucao - mude o script do repositorio.
#
# Sobe o servidor headless do Herdr, e so se nao houver um no ar: no logon a
# situacao normal e nao haver, mas um logon rapido apos logoff pode pegar o
# anterior ainda encerrando.
`$exe = '$($paths.Exe)'
if (-not (Test-Path -LiteralPath `$exe)) { exit 1 }

`$status = & `$exe status server 2>&1 | Out-String
if (`$status -match '(?m)^\s*status:\s*running') { exit 0 }

& `$exe server
"@ | Set-Content -LiteralPath $launcher -Encoding UTF8
            $log += "launcher materializado: $launcher"

            # 'herdr server' roda em foreground. A tarefa o embrulha num
            # powershell oculto para nao deixar uma janela de console no
            # desktop a cada logon (pisca por instantes, e o custo conhecido).
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
                '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden ' +
                "-ExecutionPolicy Bypass -File `"$launcher`"")

            # Interactive/Limited: o servidor precisa viver na sessao do
            # usuario (SessionId 1) para os agentes herdarem esse contexto.
            # SYSTEM subiria na sessao 0 e nao serviria para nada aqui.
            $principal = New-ScheduledTaskPrincipal -UserId $usuario `
                            -LogonType Interactive -RunLevel Limited
            $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $usuario

            # ExecutionTimeLimit 0 = sem limite. O default de 3 dias mataria o
            # servidor no meio do uso numa maquina que fica ligada.
            $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
                            -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) `
                            -RestartCount 3 -RestartInterval ([TimeSpan]::FromMinutes(1))

            Register-ScheduledTask -TaskName $paths.TaskName -Action $action `
                -Principal $principal -Trigger $trigger -Settings $settings `
                -Description 'Sobe o servidor headless do Herdr no logon (setup-rustdesk).' `
                -Force | Out-Null

            $log += "tarefa '$($paths.TaskName)' registrada: 'herdr server' no logon de $usuario"
        } catch {
            $log += "FALHA ao registrar o autostart: $($_.Exception.Message)"
            $log += '  o Herdr continua utilizavel abrindo "herdr" a mao.'
        }
    }
}

# --- 3) subir o servidor agora ---------------------------------------
# Sem isto, a stack so ficaria completa depois de um logoff/logon.
if ($NoStart) {
    $log += 'servidor nao iniciado (-NoStart) - subira no proximo logon'
} elseif (Test-HerdrServer) {
    $log += 'servidor ja esta rodando - nada a fazer'
} elseif ($PSCmdlet.ShouldProcess('herdr server', 'iniciar o servidor headless')) {
    try {
        Start-Process -FilePath $paths.Exe -ArgumentList 'server' -WindowStyle Hidden | Out-Null
        Start-Sleep -Seconds 3
        if (Test-HerdrServer) {
            $log += 'servidor iniciado'
        } else {
            $log += 'AVISO: o servidor nao respondeu em 3s. Verifique com "herdr status server".'
            $log += "  log do servidor: $($paths.ServerLog)"
        }
    } catch {
        $log += "AVISO: nao foi possivel iniciar o servidor: $($_.Exception.Message)"
    }
}

$log | ForEach-Object { Write-Host "  $_" }
