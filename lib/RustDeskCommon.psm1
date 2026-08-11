<#
.SYNOPSIS
    Descoberta de caminhos, checagem de elevacao e controle do servico RustDesk.
#>

Set-StrictMode -Version Latest

function Test-Elevated {
    <#
    .SYNOPSIS
        Verifica se a sessao atual roda como Administrador.
    .NOTES
        Usa o enum WindowsBuiltInRole, nao a string 'Administrator': em Windows
        localizado (pt-BR, de-DE...) o nome do grupo e traduzido e a comparacao
        por string retorna falso negativo.
    #>
    [CmdletBinding()] param()
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Elevated {
    [CmdletBinding()] param()
    if (-not (Test-Elevated)) {
        throw 'Este passo exige privilegios de Administrador. Abra o PowerShell como Administrador e rode de novo.'
    }
}

function Import-RustDeskConfigFile {
    <#
    .SYNOPSIS
        Le um .psd1 de opcoes e devolve a hashtable.
    .NOTES
        Import-PowerShellDataFile e o caminho normal, mas nem toda instalacao
        do PowerShell 5.1 o expoe. O fallback usa o AST e SafeGetValue(), que
        avalia apenas literais constantes - nao executa codigo do arquivo.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "arquivo de configuracao nao encontrado: $Path" }

    $cmd = Get-Command Import-PowerShellDataFile -ErrorAction SilentlyContinue
    if ($cmd) { return (& $cmd -LiteralPath $Path) }

    $errs = $null; $toks = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$toks, [ref]$errs)
    if ($errs) { throw "erro de sintaxe em ${Path}: $($errs[0].Message)" }

    $ht = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)
    if (-not $ht) { throw "nenhuma hashtable encontrada em $Path" }

    return $ht.SafeGetValue()
}

function Get-RustDeskPin {
    <#
    .SYNOPSIS
        Le a versao fixada de config/version.psd1 (ou version-custom.psd1).
    .OUTPUTS
        Hashtable mutavel com Version, Sha256, UrlTemplate e SignerSubject.
    #>
    [CmdletBinding()] param()

    $dir     = Join-Path (Split-Path -Parent $PSScriptRoot) 'config'
    $custom  = Join-Path $dir 'version-custom.psd1'
    $default = Join-Path $dir 'version.psd1'
    $file    = if (Test-Path -LiteralPath $custom) { $custom } else { $default }

    $pin = Import-RustDeskConfigFile -Path $file
    foreach ($k in 'Version', 'UrlTemplate') {
        if (-not $pin[$k]) { throw "config de versao sem a chave ${k}: $file" }
    }

    # SafeGetValue devolve hashtable somente-leitura em algumas versoes; uma
    # copia mutavel deixa o chamador sobrepor a versao sem tocar no arquivo.
    return @{
        Version       = [string]$pin['Version']
        Sha256        = [string]$pin['Sha256']
        UrlTemplate   = [string]$pin['UrlTemplate']
        SignerSubject = [string]$pin['SignerSubject']
        Source        = $file
    }
}

function Get-RustDeskVersion {
    <#
    .SYNOPSIS
        Versao do rustdesk.exe instalado, como '1.4.9'.
    .NOTES
        O ProductVersion do binario vem com sufixo de build ('1.4.9+67'), que
        nao existe nas tags de release - comparar sem cortar o sufixo faria
        toda instalacao parecer divergente do pin.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Exe)

    if (-not (Test-Path -LiteralPath $Exe)) { return $null }
    $v = (Get-Item -LiteralPath $Exe).VersionInfo.ProductVersion
    if (-not $v) { return $null }
    return ($v -split '[+ ]')[0].Trim()
}

function Resolve-RustDeskLatestVersion {
    <#
    .SYNOPSIS
        Ultima release estavel do RustDesk, pela API do GitHub.
    .NOTES
        /releases/latest ja exclui prerelease - e o que mantem o 'nightly'
        fora do caminho.
    #>
    [CmdletBinding()] param()

    $url = 'https://api.github.com/repos/rustdesk/rustdesk/releases/latest'
    try {
        $r = Invoke-RestMethod -Uri $url -UseBasicParsing -Headers @{ 'User-Agent' = 'setup-rustdesk' }
    } catch {
        throw "nao foi possivel consultar a ultima release: $($_.Exception.Message)"
    }
    if (-not $r.tag_name) { throw 'a API do GitHub respondeu sem tag_name' }
    return [string]$r.tag_name
}

function Get-RustDeskPaths {
    <#
    .SYNOPSIS
        Devolve os caminhos relevantes da instalacao, sem hardcode de usuario.
    .DESCRIPTION
        UserConfig  - config da sessao interativa; vale para a maquina desbloqueada.
        ServiceConfig - config lida pelo servico (LocalService); e ela que vale
                        quando a tela esta bloqueada ou nao ha sessao logada.
    #>
    [CmdletBinding()] param()

    $exe = $null
    foreach ($c in @(
        (Join-Path $env:ProgramFiles        'RustDesk\rustdesk.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'RustDesk\rustdesk.exe')
    )) {
        if ($c -and (Test-Path -LiteralPath $c)) { $exe = $c; break }
    }
    if (-not $exe) {
        $cmd = Get-Command rustdesk.exe -ErrorAction SilentlyContinue
        if ($cmd) { $exe = $cmd.Source }
    }

    $serviceRoot = Join-Path $env:SystemRoot 'ServiceProfiles\LocalService\AppData\Roaming\RustDesk'

    return [PSCustomObject]@{
        Exe               = $exe
        Installed         = [bool]$exe
        UserConfigDir     = Join-Path $env:APPDATA 'RustDesk\config'
        UserConfig        = Join-Path $env:APPDATA 'RustDesk\config\RustDesk2.toml'
        UserPassword      = Join-Path $env:APPDATA 'RustDesk\config\RustDesk.toml'
        UserLogDir        = Join-Path $env:APPDATA 'RustDesk\log'
        ServiceConfigDir  = Join-Path $serviceRoot 'config'
        ServiceConfig     = Join-Path $serviceRoot 'config\RustDesk2.toml'
        ServicePassword   = Join-Path $serviceRoot 'config\RustDesk.toml'
        ServiceLogDir     = Join-Path $serviceRoot 'log'
        WatchdogDir       = Join-Path $env:ProgramData 'RustDesk'
        WatchdogScript    = Join-Path $env:ProgramData 'RustDesk\rustdesk-watchdog.ps1'
        WatchdogLog       = Join-Path $env:ProgramData 'RustDesk\watchdog.log'
        ServiceName       = 'rustdesk'
        TaskName          = 'RustDeskWatchdog'
    }
}

function Get-HerdrPaths {
    <#
    .SYNOPSIS
        Caminhos do Herdr, o terminal usado dentro da sessao remota.
    .DESCRIPTION
        O Herdr nao e requisito do RustDesk: se nao estiver instalado, Installed
        vem $false e os passos que dependem dele devem ser pulados, nao falhar.
        A config fica no perfil do usuario - nada aqui exige elevacao.
    #>
    [CmdletBinding()] param()

    $exe = $null
    $cmd = Get-Command herdr.exe -ErrorAction SilentlyContinue
    if ($cmd) { $exe = $cmd.Source }
    if (-not $exe) {
        $c = Join-Path $env:LOCALAPPDATA 'Programs\Herdr\bin\herdr.exe'
        if (Test-Path -LiteralPath $c) { $exe = $c }
    }

    return [PSCustomObject]@{
        Exe        = $exe
        Installed  = [bool]$exe
        ConfigDir  = Join-Path $env:APPDATA 'herdr'
        Config     = Join-Path $env:APPDATA 'herdr\config.toml'
        Socket     = Join-Path $env:APPDATA 'herdr\herdr.sock'
        ServerLog  = Join-Path $env:APPDATA 'herdr\herdr-server.log'
        ClientLog  = Join-Path $env:APPDATA 'herdr\herdr-client.log'
        TaskName   = 'HerdrServer'
    }
}

function Test-HerdrServer {
    <#
    .SYNOPSIS
        Retorna $true se o servidor do Herdr esta no ar.
    .NOTES
        A pergunta e respondida pelo proprio Herdr ('herdr status server'), nao
        pela existencia do .sock: o socket sobrevive a uma queda do servidor e
        daria falso positivo.
    #>
    [CmdletBinding()] param()

    $paths = Get-HerdrPaths
    if (-not $paths.Installed) { return $false }
    try {
        $saida = & $paths.Exe status server 2>&1 | Out-String
        return [bool]($saida -match '(?m)^\s*status:\s*running')
    } catch {
        return $false
    }
}

function Stop-RustDeskClean {
    <#
    .SYNOPSIS
        Para o servico de forma limpa e encerra processos de sessao interativa.
    .DESCRIPTION
        NAO usa Stop-Process no processo de sessao 0. Mata-lo conta como falha
        para o SCM e as recovery actions religam o servico em segundos, no meio
        da edicao da config. A parada tem que passar pelo SCM.
    #>
    [CmdletBinding()]
    param([int]$TimeoutSeconds = 30)

    Assert-Elevated
    $log = @()

    $svc = Get-Service -Name rustdesk -ErrorAction SilentlyContinue
    if (-not $svc) { return @('servico rustdesk nao instalado - nada a parar') }

    if ($svc.Status -ne 'Stopped') {
        Stop-Service -Name rustdesk -Force -ErrorAction SilentlyContinue
        try {
            $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds($TimeoutSeconds))
            $log += 'servico parado de forma limpa (recovery do SCM nao disparou)'
        } catch {
            $log += "AVISO: servico nao parou em ${TimeoutSeconds}s (status: $((Get-Service rustdesk).Status))"
        }
    } else {
        $log += 'servico ja estava parado'
    }

    Start-Sleep -Seconds 2

    # processos fora da sessao 0 sao UI e connection managers orfaos, nao o servico
    Get-Process -Name rustdesk -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -ne 0 } |
        ForEach-Object {
            $log += "encerrando processo interativo PID $($_.Id) (sessao $($_.SessionId))"
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }

    Start-Sleep -Seconds 1
    $alive = @(Get-Process -Name rustdesk -ErrorAction SilentlyContinue)
    $log += "processos rustdesk vivos: $($alive.Count)"
    return $log
}

function Start-RustDeskClean {
    <#
    .SYNOPSIS
        Sobe o servico e aguarda o estado Running.
    #>
    [CmdletBinding()]
    param([int]$TimeoutSeconds = 30)

    Assert-Elevated
    $log = @()
    Start-Service -Name rustdesk
    try {
        (Get-Service rustdesk).WaitForStatus('Running', [TimeSpan]::FromSeconds($TimeoutSeconds))
        Start-Sleep -Seconds 5   # o servico ainda esta lendo config e subindo filhos
        $log += "servico: $((Get-Service rustdesk).Status) / $((Get-Service rustdesk).StartType)"
    } catch {
        $log += "FALHA: servico nao subiu em ${TimeoutSeconds}s"
    }
    return $log
}

function Start-RustDeskUI {
    <#
    .SYNOPSIS
        Sobe a bandeja do RustDesk na sessao interativa, sem elevacao.
    .DESCRIPTION
        Rodando a partir de um console elevado, lancar a UI diretamente faria
        ela herdar o token de admin. O atalho comum (Start-Process explorer.exe
        com o exe como argumento) nao funciona quando ha parametros: o explorer
        trata a string inteira como caminho a abrir. A via confiavel e uma
        tarefa agendada temporaria com LogonType Interactive e RunLevel Limited.
    #>
    [CmdletBinding()] param()

    $paths = Get-RustDeskPaths
    if (-not $paths.Installed) { return @('rustdesk.exe nao encontrado - UI nao iniciada') }

    $log      = @()
    $taskName = 'RustDeskUITemp'
    try {
        $action    = New-ScheduledTaskAction -Execute $paths.Exe -Argument '--tray'
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
                                                -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName
        Start-Sleep -Seconds 6
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        $log += 'UI lancada via tarefa temporaria (removida em seguida)'
    } catch {
        $log += "FALHA ao lancar a UI: $($_.Exception.Message)"
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }

    $tray = @(Get-CimInstance Win32_Process -Filter "Name='rustdesk.exe'" |
              Where-Object { $_.CommandLine -like '*--tray*' })
    if ($tray.Count -gt 0) { $log += "UI (--tray) rodando: PID $($tray[0].ProcessId)" }
    else { $log += 'AVISO: UI nao subiu. Abra o RustDesk pelo menu Iniciar (nao e obrigatorio para receber conexoes).' }

    return $log
}

Export-ModuleMember -Function Test-Elevated, Assert-Elevated, Get-RustDeskPaths, Get-HerdrPaths,
                              Test-HerdrServer, Import-RustDeskConfigFile,
                              Get-RustDeskPin, Get-RustDeskVersion, Resolve-RustDeskLatestVersion,
                              Stop-RustDeskClean, Start-RustDeskClean, Start-RustDeskUI
