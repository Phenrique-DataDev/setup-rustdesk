<#
.SYNOPSIS
    Descoberta de caminhos, checagem de elevacao e controle do servico RustDesk.
#>

Set-StrictMode -Version Latest

# Quando ESTA sessao e o 5.1 filho de um pwsh 7 (alguem digitou 'powershell
# -File Setup.ps1' num terminal do 7), Get-FileHash e Get-AuthenticodeSignature
# falham aqui mesmo, e sao eles que conferem o .msi do RustDesk antes de
# executar. Limpar na carga do modulo cobre todos os scripts de uma vez. A
# funcao e definida mais abaixo, entao a chamada fica no fim do arquivo.

function Get-WindowsPowerShellModulePath {
    <#
    .SYNOPSIS
        PSModulePath sem as pastas de modulos embutidos do PowerShell 7.
    .DESCRIPTION
        Um powershell.exe (5.1) iniciado de dentro do pwsh 7 herda o
        PSModulePath do pai, e nele a pasta de modulos do 7 vem ANTES da do
        5.1. O 5.1 entao tenta carregar Microsoft.PowerShell.Archive, .Utility
        e .Security na versao do 7, e falha:
          - Expand-Archive: 'Nao e possivel localizar uma sobrecarga para
            ExtractToDirectory';
          - Get-FileHash: 'nao e reconhecido como nome de cmdlet';
          - Get-AuthenticodeSignature: 'nao foi possivel carregar o modulo'.
        Reproduzido nesta ordem numa maquina com pwsh 7 da Store. O instalador
        oficial do Herdr usa Expand-Archive e roda num powershell.exe filho:
        com o setup partindo do pwsh 7, a instalacao morria ali.
    .NOTES
        O criterio e o conteudo, nao o nome: a pasta do 7 muda de lugar entre
        o MSI ('...\PowerShell\7\Modules') e a Store ('...\WindowsApps\...').
        E do 7 a pasta que tem Microsoft.PowerShell.Security e nao esta sob
        WindowsPowerShell. As pastas de modulos de usuario ficam.
    #>
    [CmdletBinding()] param()

    $limpas = foreach ($e in ($env:PSModulePath -split ';')) {
        if (-not $e) { continue }
        $doCore = ($e -notmatch '\\WindowsPowerShell\\') -and
                  (Test-Path -LiteralPath (Join-Path $e 'Microsoft.PowerShell.Security'))
        if (-not $doCore) { $e }
    }
    return (@($limpas) -join ';')
}

function Start-WindowsPowerShellFile {
    <#
    .SYNOPSIS
        Roda um .ps1 num powershell.exe (5.1) separado, com a saida em arquivo.
    .DESCRIPTION
        E como os instaladores de terceiros sao executados aqui: processo
        proprio, para o que eles fazem com PATH e variaveis nao vazar para esta
        sessao, e saida capturada, para uma falha nao virar so "codigo 1".
        O PSModulePath do filho e limpo antes - ver Get-WindowsPowerShellModulePath.
    .OUTPUTS
        O processo, ja encerrado (ExitCode disponivel).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][string]$StdOut,
        [Parameter(Mandatory)][string]$StdErr
    )

    $antes = $env:PSModulePath
    try {
        $env:PSModulePath = Get-WindowsPowerShellModulePath
        # aspas no caminho: Start-Process junta os argumentos com espaco e um
        # perfil com espaco no nome partiria o -File em dois
        return Start-Process -FilePath 'powershell.exe' -Wait -PassThru -NoNewWindow `
                    -RedirectStandardOutput $StdOut -RedirectStandardError $StdErr `
                    -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$File`"")
    } finally {
        $env:PSModulePath = $antes
    }
}

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
        AwakeScript       = Join-Path $env:ProgramData 'RustDesk\rustdesk-awake.ps1'
        AwakeLog          = Join-Path $env:ProgramData 'RustDesk\awake.log'
        DiagnosticsDir    = Join-Path $env:ProgramData 'RustDesk'
        ServiceName       = 'rustdesk'
        TaskName          = 'RustDeskWatchdog'
        AwakeTask         = 'RustDeskAwake'
    }
}

function Get-HerdrStableCandidates {
    <#
    .SYNOPSIS
        Caminhos do herdr.exe que sobrevivem a um 'herdr update', em ordem.
    .NOTES
        As duas sao juncoes gerenciadas pelo instalador oficial
        (distribution/install.ps1: visibleBinDir e currentDir). O launcher do
        autostart carrega uma copia desta lista - ha teste que as mantem iguais.
    #>
    [CmdletBinding()] param()
    return @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Herdr\bin\herdr.exe'),
        (Join-Path $env:USERPROFILE  '.herdr\packages\standalone\current\herdr.exe')
    )
}

function Get-HerdrServerVersion {
    <#
    .SYNOPSIS
        Versao do servidor do Herdr que esta no ar, ou $null se nao ha servidor.
    .NOTES
        Diferente de 'herdr --version': esta e a do PROCESSO em execucao. As duas
        divergem quando o servidor subiu de um binario antigo.
    #>
    [CmdletBinding()] param()

    $paths = Get-HerdrPaths
    if (-not $paths.Installed) { return $null }
    try {
        $saida = & $paths.Exe status server 2>&1 | Out-String
        if ($saida -notmatch '(?m)^\s*status:\s*running') { return $null }
        if ($saida -match '(?m)^\s*version:\s*(\S+)') { return $Matches[1] }
    } catch { }
    return $null
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

    # Caminho ESTAVEL primeiro, PATH por ultimo. O instalador oficial guarda cada
    # versao em ~\.herdr\packages\standalone\releases\<versao>\ e mantem duas
    # juncoes apontando para a atual; 'herdr update' so as redireciona. Dentro de
    # um pane do Herdr, e as vezes no PATH do usuario, o que resolve primeiro e a
    # pasta VERSIONADA - e quem guarda esse caminho (o launcher do autostart)
    # continua subindo a versao antiga depois de cada update, sem erro nenhum.
    $exe = $null
    foreach ($c in (Get-HerdrStableCandidates)) {
        if (Test-Path -LiteralPath $c) { $exe = $c; break }
    }
    if (-not $exe) {
        $cmd = Get-Command herdr.exe -ErrorAction SilentlyContinue
        if ($cmd) { $exe = $cmd.Source }
    }

    return [PSCustomObject]@{
        Exe        = $exe
        Installed  = [bool]$exe
        Launcher   = Join-Path $env:APPDATA 'herdr\start-herdr-server.ps1'
        ConfigDir  = Join-Path $env:APPDATA 'herdr'
        Config     = Join-Path $env:APPDATA 'herdr\config.toml'
        Socket     = Join-Path $env:APPDATA 'herdr\herdr.sock'
        ServerLog  = Join-Path $env:APPDATA 'herdr\herdr-server.log'
        ClientLog  = Join-Path $env:APPDATA 'herdr\herdr-client.log'
        TaskName   = 'HerdrServer'
    }
}

function Get-HerdrAppPaths {
    <#
    .SYNOPSIS
        Caminhos do Herdr app (janela) e do herdr-core (hc) que ele usa.
    .DESCRIPTION
        Produto SEPARADO do 'herdr' de terminal que o resto deste repositorio
        instala: outro binario, outro runtime (herdr-core), outro estado. Um nao
        enxerga os terminais do outro. E opcional - Installed $false significa
        apenas que o passo -HerdrApp nunca rodou.
    .NOTES
        A pasta do app segue a regra dele: HERDR_APP_HOME, senao
        XDG_CONFIG_HOME\herdr-app, senao ~\.config\herdr-app (tambem no Windows).
    #>
    [CmdletBinding()] param()

    $appExe  = Join-Path $env:LOCALAPPDATA 'Programs\herdr-app\herdr-app.exe'
    $coreExe = Join-Path $env:LOCALAPPDATA 'Programs\herdr-core\herdr-core.exe'
    if (-not (Test-Path -LiteralPath $coreExe)) {
        $cmd = Get-Command herdr-core.exe -ErrorAction SilentlyContinue
        if ($cmd) { $coreExe = $cmd.Source }
    }

    $appHome = if ($env:HERDR_APP_HOME)      { $env:HERDR_APP_HOME }
               elseif ($env:XDG_CONFIG_HOME) { Join-Path $env:XDG_CONFIG_HOME 'herdr-app' }
               else                          { Join-Path $env:USERPROFILE '.config\herdr-app' }

    return [PSCustomObject]@{
        AppExe        = $appExe
        Installed     = (Test-Path -LiteralPath $appExe)
        CoreExe       = $coreExe
        CoreInstalled = (Test-Path -LiteralPath $coreExe)
        AppHome       = $appHome
        Settings      = Join-Path $appHome 'settings.json'
        # o certificado que assina app e core nas releases oficiais
        SignerSubject = 'CN=herdr,'
    }
}

function Test-HerdrAppSignature {
    <#
    .SYNOPSIS
        Confere a assinatura Authenticode de um binario do Herdr app/core.
    .OUTPUTS
        Objeto com Ok e Detalhe. Nunca lanca: quem chama decide o que fazer.
    .NOTES
        O instalador oficial so confere SHA-256 contra um manifesto do MESMO
        servidor - isso pega download corrompido, nao troca de binario. A
        assinatura e a unica verificacao independente do servidor de release.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$SignerSubject = 'CN=herdr,'
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return [PSCustomObject]@{ Ok = $false; Detalhe = "nao encontrado: $Path" }
    }
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    if ($sig.Status -ne 'Valid') {
        return [PSCustomObject]@{ Ok = $false; Detalhe = "assinatura $($sig.Status)" }
    }
    $sujeito = [string]$sig.SignerCertificate.Subject
    if ($sujeito -notlike "*$SignerSubject*") {
        return [PSCustomObject]@{ Ok = $false; Detalhe = "assinado por quem nao se esperava: $sujeito" }
    }
    return [PSCustomObject]@{ Ok = $true; Detalhe = $sujeito }
}

function Disable-HerdrAppTelemetry {
    <#
    .SYNOPSIS
        Grava "telemetry": false no settings.json do Herdr app.
    .DESCRIPTION
        So essa chave: o resto do arquivo e de quem usa o app e e preservado.
    .OUTPUTS
        'ja' | 'desligada' | 'simulado' | 'ilegivel'
    .NOTES
        Um arquivo que nao se consegue ler NAO e regravado: perder as
        preferencias de alguem para desligar um contador nao compensa.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Settings)

    $atual = $null
    if (Test-Path -LiteralPath $Settings) {
        try {
            $atual = [System.IO.File]::ReadAllText($Settings, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        } catch {
            return 'ilegivel'
        }
        # 'null', numero ou lista sao JSON valido e nao sao um settings.json
        if ($null -eq $atual -or $atual -isnot [System.Management.Automation.PSCustomObject]) { return 'ilegivel' }
    }

    if ($atual -and ($atual.PSObject.Properties.Name -contains 'telemetry') -and $atual.telemetry -eq $false) {
        return 'ja'
    }
    if (-not $PSCmdlet.ShouldProcess($Settings, 'gravar telemetry = false')) { return 'simulado' }

    if (-not $atual) { $atual = [PSCustomObject]@{} }
    $atual | Add-Member -NotePropertyName telemetry -NotePropertyValue $false -Force
    $dir = Split-Path -Parent $Settings
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # UTF-8 sem BOM: Set-Content -Encoding UTF8 no PS 5.1 gravaria BOM.
    [System.IO.File]::WriteAllText($Settings, (($atual | ConvertTo-Json -Depth 20) + "`n"),
        (New-Object System.Text.UTF8Encoding($false)))
    return 'desligada'
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

function Wait-HerdrServer {
    <#
    .SYNOPSIS
        Aguarda o servidor do Herdr ficar disponivel ate um prazo limitado.
    .DESCRIPTION
        O processo pode demorar mais durante logon, restauracao de sessao ou
        saida de espera. Polling evita tanto o falso negativo de uma espera
        fixa quanto uma espera indefinida quando o servidor nao sobe.
    #>
    [CmdletBinding()]
    param(
        [ValidateRange(1, 300)]
        [int]$TimeoutSeconds = 15,
        [ValidateRange(50, 5000)]
        [int]$PollMilliseconds = 250
    )

    $limite = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (Test-HerdrServer) { return $true }

        $restante = ($limite - (Get-Date)).TotalMilliseconds
        if ($restante -le 0) { break }
        Start-Sleep -Milliseconds ([Math]::Max(1, [int][Math]::Min($PollMilliseconds, $restante)))
    } while ((Get-Date) -lt $limite)

    return $false
}

function Test-IsLaptop {
    <#
    .SYNOPSIS
        Retorna $true se a maquina e portatil (tem bateria propria).
    .DESCRIPTION
        E esta funcao que decide se o passo de energia entra no -All. Em desktop
        ela devolve $false e nada relacionado a bateria roda nem aparece na
        verificacao.
    .NOTES
        Duas fontes, de proposito:
        - PCSystemType 2 (Mobile) e a resposta autoritativa quando o firmware a
          preenche direito, e decide sozinha.
        - Win32_Battery e o fallback, porque ha portateis que reportam
          PCSystemType errado. Sozinha ela nao serviria: desktop com nobreak
          USB tambem expoe Win32_Battery.
        Nenhuma das duas exige elevacao.
    #>
    [CmdletBinding()] param()

    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        if ($cs.PCSystemType -eq 2) { return $true }
    } catch {
        # sem WMI nao da para decidir pelo tipo; segue para o fallback
    }

    try {
        $bat = @(Get-CimInstance Win32_Battery -ErrorAction Stop)
        return ($bat.Count -gt 0)
    } catch {
        return $false
    }
}

function Test-ModernStandbyAvailable {
    <#
    .SYNOPSIS
        Retorna $true se a saida de 'powercfg /a' lista o S0 (espera moderna)
        entre os estados DISPONIVEIS.
    .DESCRIPTION
        Recebe o texto em vez de chamar o powercfg: quem chama ja o tem, e
        assim a funcao e testavel com a saida de qualquer maquina.
    .NOTES
        Procurar 'S0' na saida inteira da falso positivo em notebook S3: o
        powercfg /a lista TAMBEM os estados indisponiveis, com o motivo, e o
        S0 aparece la ('Em Espera (S0 Ocioso com Baixo Consumo de Energia) -
        o firmware do sistema nao da suporte'). Num notebook S3 real isso fez
        o passo de energia anunciar 'Modern Standby (S0) presente' e gravar a
        conectividade em espera numa maquina que nao tem espera moderna.

        Os rotulos sao traduzidos, entao nao da para casar pelo cabecalho. O
        que nao muda e a forma: o primeiro bloco (ate a primeira linha em
        branco) e o dos estados disponiveis.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$PowercfgOutput)

    $bloco = @()
    foreach ($linha in ($PowercfgOutput -split "`r?`n")) {
        if ($linha.Trim() -eq '') {
            if ($bloco.Count -gt 0) { break }
            continue
        }
        $bloco += $linha
    }
    return [bool](@($bloco | Where-Object { $_ -match '\bS0\b' }).Count)
}

function Get-BatteryPercent {
    <#
    .SYNOPSIS
        Carga da bateria em porcentagem, ou 100 quando nao ha bateria em uso.
    .NOTES
        Devolve 100 (e nao $null) para desktop e para maquina na tomada sem
        bateria: quem chama usa este valor como limiar, e um $null viraria
        comparacao com zero - soltando o bloqueio de suspensao justamente onde
        nao ha risco nenhum de acabar a carga.
    #>
    [CmdletBinding()] param()

    try {
        $bat = @(Get-CimInstance Win32_Battery -ErrorAction Stop |
                 Where-Object { $null -ne $_.EstimatedChargeRemaining })
        if ($bat.Count -eq 0) { return 100 }
        return [int]($bat | Measure-Object -Property EstimatedChargeRemaining -Minimum).Minimum
    } catch {
        return 100
    }
}

function Test-RemoteSessionActive {
    <#
    .SYNOPSIS
        Retorna $true se ha sessao remota do RustDesk em curso.
    .DESCRIPTION
        O connection manager (--cm) so existe enquanto alguem esta conectado.
        E o mesmo sinal que o watchdog usa para adiar um reinicio do servico e
        que o daemon RustDeskAwake usa para segurar a suspensao.
    .NOTES
        Devolve [bool] de proposito, nunca a linha de comando: CommandLine e o
        campo que carrega --password e --set-unlock-pin, e que a verificacao
        redige antes de imprimir. Nada aqui deve vazar para log.
    #>
    [CmdletBinding()] param()

    try {
        $procs = @(Get-CimInstance Win32_Process -Filter "Name='rustdesk.exe'" -ErrorAction Stop |
                   Where-Object { $_.CommandLine -match '--cm' })
        return ($procs.Count -gt 0)
    } catch {
        return $false
    }
}

function Get-LastResumeTime {
    <#
    .SYNOPSIS
        Data do ultimo retorno de suspensao, ou $null se nunca suspendeu.
    .DESCRIPTION
        Usada como parte do carimbo de "uma tentativa por epoca" do watchdog.
        Sem ela, o carimbo seria so LastBootUpTime - e num notebook, que
        suspende varias vezes por dia sem reiniciar, uma recusa gravada de
        manha valeria ate o proximo boot.
    .NOTES
        Tres fontes, e vale a MAIS RECENTE entre elas:
          - Kernel-Power 107: resume de S3/S4;
          - Power-Troubleshooter 1: o mesmo resume, com o motivo do wake;
          - Kernel-Power 507: saida da espera moderna (S0ix).
        Num notebook com Modern Standby o ciclo real e S0 <-> espera moderna,
        e 107/1 quase nao aparecem: numa maquina real o ultimo 107 tinha 9 dias
        enquanto havia dezenas de 507 por dia. Devolver a primeira fonte que
        respondesse, como antes, congelava a epoca nesse 107 antigo.
        Sem elevacao os canais sao legiveis.
    #>
    [CmdletBinding()] param()

    $ultimo = $null
    foreach ($f in @(
        @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power';         Id = 107 },
        @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Power-Troubleshooter'; Id = 1 },
        @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power';         Id = 507 }
    )) {
        try {
            $ev = Get-WinEvent -FilterHashtable $f -MaxEvents 1 -ErrorAction Stop
            if ($ev -and ($null -eq $ultimo -or $ev.TimeCreated -gt $ultimo)) { $ultimo = $ev.TimeCreated }
        } catch {
            # 'No events were found' e o caso normal em maquina que nunca
            # suspendeu - segue para a proxima fonte em vez de falhar
        }
    }
    return $ultimo
}

function Get-PowerEpochStamp {
    <#
    .SYNOPSIS
        Carimbo de epoca: ultimo boot e ultimo resume, numa string so.
    .DESCRIPTION
        O watchdog grava este valor para nao repetir a mesma correcao
        indefinidamente. Incluir o resume faz a epoca avancar ao acordar, que e
        o que destrava o caso do notebook sem afrouxar a protecao original.
    .NOTES
        Com Fast Startup ligado, desligar e ligar NAO avanca LastBootUpTime - o
        que seria um desligamento vira hibernacao. Por isso o resume nao e
        opcional aqui.
    #>
    [CmdletBinding()] param()

    $boot = try { (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToString('o') }
            catch { '-' }
    $resume = Get-LastResumeTime
    $r = if ($resume) { $resume.ToString('o') } else { '-' }
    return "$boot|$r"
}

function New-RustDeskResumeTrigger {
    <#
    .SYNOPSIS
        Trigger de tarefa agendada que dispara quando a maquina acorda.
    .DESCRIPTION
        A repeticao de N minutos do watchdog nao sabe o que e acordar: depois de
        uma suspensao a maquina pode ficar ate um intervalo inteiro com o
        servico em estado ruim. Este trigger fecha essa janela.
    .NOTES
        New-ScheduledTaskTrigger nao expoe triggers de evento - por isso a
        instancia CIM crua. Power-Troubleshooter 1 e o evento de resume
        completo, e o que carrega o motivo do wake. Kernel-Power 507 e a saida
        da espera moderna: sem ele, num notebook com Modern Standby, o trigger
        nunca dispara, porque ali quase nao ha S3.

        O Delay nao e cosmetico: sem ele a checagem roda antes de o Wi-Fi
        reassociar e conclui que a rede esta fora do ar.
    .OUTPUTS
        Instancia CIM de MSFT_TaskEventTrigger, pronta para Register-ScheduledTask.
    #>
    [CmdletBinding()]
    param([int]$DelaySeconds = 20)

    $xml = @"
<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]]</Select><Select Path="System">*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and EventID=507]]</Select></Query></QueryList>
"@
    return New-RustDeskEventTrigger -Subscription $xml -DelaySeconds $DelaySeconds
}

function New-RustDeskNetworkTrigger {
    <#
    .SYNOPSIS
        Trigger de tarefa agendada que dispara quando o Windows conecta numa rede.
    .DESCRIPTION
        No cabo a rede ja esta pronta quando o watchdog roda no boot. No Wi-Fi
        ela associa depois: a passada do boot ve a maquina sem IPv6 global, nao
        faz nada, e o servico - que subiu com o DNS fora do ar - ficaria ate um
        intervalo inteiro sem IPv6. Este trigger poe a checagem logo depois de a
        rede subir, e tambem cobre troca de rede sem suspensao no meio.
    .NOTES
        NetworkProfile 10000 dispara varias vezes por boot ('Identificando...',
        adaptadores virtuais do Hyper-V/WSL). Nao ha filtro de proposito: o
        campo State nao tem semantica documentada, e filtrar errado perderia
        justamente a conexao do Wi-Fi. A rajada e contida pelo
        MultipleInstances IgnoreNew da tarefa, e cada passada custa ~1 s.
    .OUTPUTS
        Instancia CIM de MSFT_TaskEventTrigger, pronta para Register-ScheduledTask.
    #>
    [CmdletBinding()]
    param([int]$DelaySeconds = 30)

    $log = 'Microsoft-Windows-NetworkProfile/Operational'
    $xml = @"
<QueryList><Query Id="0" Path="$log"><Select Path="$log">*[System[Provider[@Name='Microsoft-Windows-NetworkProfile'] and EventID=10000]]</Select></Query></QueryList>
"@
    return New-RustDeskEventTrigger -Subscription $xml -DelaySeconds $DelaySeconds
}

function New-RustDeskEventTrigger {
    <#
    .SYNOPSIS
        Monta um trigger de evento a partir de uma subscription XPath.
    .NOTES
        New-ScheduledTaskTrigger nao expoe triggers de evento - por isso a
        instancia CIM crua.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Subscription,
        [int]$DelaySeconds = 20
    )

    $classe = Get-CimClass -ClassName MSFT_TaskEventTrigger `
                           -Namespace Root/Microsoft/Windows/TaskScheduler -ErrorAction Stop
    $t = New-CimInstance -CimClass $classe -ClientOnly
    $t.Enabled      = $true
    $t.Subscription = $Subscription
    $t.Delay        = "PT${DelaySeconds}S"
    return $t
}

function Get-RustDeskFirewallCoverage {
    <#
    .SYNOPSIS
        Diz quais perfis de rede deixam o RustDesk receber conexao direta.
    .DESCRIPTION
        Funcao pura: recebe as regras (Direction, Action, Enabled, Profile) ja
        filtradas pelo programa e os perfis em que o firewall esta desligado.
        Um perfil esta coberto se o firewall dele esta desligado ou se ha regra
        de entrada Allow ativa nele - e nenhuma Block ativa, que no Windows
        vence o Allow.
    .NOTES
        Profile chega como enum (Any, 'Private, Public'), como inteiro ou como
        texto disso. Any e 0, nao 7: tratar 0 como "nenhum perfil" reprovaria
        justamente a regra que o instalador do RustDesk cria.
        Uma copia desta logica vive no watchdog (template isolado, sem modulo).
        Power.Harness.ps1 roda os mesmos casos nas duas.
    #>
    [CmdletBinding()]
    param(
        [object[]]$Rules = @(),
        [string[]]$DisabledProfiles = @()
    )

    $bits = @{ Domain = 1; Private = 2; Public = 4 }
    function ConvertTo-Bits($p) {
        $s = ([string]$p).Trim()
        if ($s -match '^\d+$') { $n = [int]$s; if ($n -eq 0) { return 7 }; return ($n -band 7) }
        if ($s -eq '' -or $s -eq 'Any') { return 7 }
        $b = 0
        foreach ($nome in $s -split '\s*,\s*') { if ($bits.ContainsKey($nome)) { $b = $b -bor $bits[$nome] } }
        return $b
    }

    $allow = 0; $block = 0
    foreach ($r in $Rules) {
        if ([string]$r.Direction -ne 'Inbound' -or [string]$r.Enabled -ne 'True') { continue }
        if     ([string]$r.Action -eq 'Allow') { $allow = $allow -bor (ConvertTo-Bits $r.Profile) }
        elseif ([string]$r.Action -eq 'Block') { $block = $block -bor (ConvertTo-Bits $r.Profile) }
    }

    $faltando = @(); $bloqueados = @()
    foreach ($nome in 'Domain', 'Private', 'Public') {
        if ($DisabledProfiles -contains $nome) { continue }
        if ($block -band $bits[$nome])       { $bloqueados += $nome }
        elseif (-not ($allow -band $bits[$nome])) { $faltando += $nome }
    }
    return [PSCustomObject]@{
        Covered  = ($faltando.Count -eq 0 -and $bloqueados.Count -eq 0)
        Missing  = $faltando
        Blocked  = $bloqueados
    }
}

function Get-RustDeskFirewallState {
    <#
    .SYNOPSIS
        Le as regras do firewall que citam o executavel do RustDesk e avalia a cobertura.
    .DESCRIPTION
        Sem regra de entrada, o hole punching TCP e o acesso direto na LAN
        morrem no firewall do host, e toda sessao cai no relay publico - mais
        lenta para abrir e com o atraso de ida e volta ate o servidor de relay
        somado a cada quadro. O instalador .exe cria 'RustDesk Service'; nada
        garante que o .msi, uma politica ou um antivirus a mantenham.
    .NOTES
        ActiveStore: e o que vale de fato, inclusive regras de GPO. Nao exige
        elevacao. O Program das regras pode vir com variavel de ambiente.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Exe)

    $alvo    = [IO.Path]::GetFullPath($Exe)
    $filtros = @(Get-NetFirewallApplicationFilter -PolicyStore ActiveStore -ErrorAction Stop |
                 Where-Object { $_.Program -and
                     [Environment]::ExpandEnvironmentVariables($_.Program) -ieq $alvo })
    $regras  = @($filtros | Get-NetFirewallRule -ErrorAction SilentlyContinue)
    $off     = @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction SilentlyContinue |
                 Where-Object { [string]$_.Enabled -eq 'False' } | ForEach-Object { [string]$_.Name })

    $c = Get-RustDeskFirewallCoverage -Rules $regras -DisabledProfiles $off
    $c | Add-Member -NotePropertyName Rules -NotePropertyValue $regras
    $c | Add-Member -NotePropertyName DisabledProfiles -NotePropertyValue $off
    return $c
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

if ($PSVersionTable.PSVersion.Major -lt 6) {
    $env:PSModulePath = Get-WindowsPowerShellModulePath
}

Export-ModuleMember -Function Test-Elevated, Assert-Elevated, Get-RustDeskPaths, Get-HerdrPaths,
                              Get-WindowsPowerShellModulePath, Start-WindowsPowerShellFile,
                              Get-HerdrStableCandidates, Get-HerdrServerVersion,
                              Get-HerdrAppPaths, Test-HerdrAppSignature, Disable-HerdrAppTelemetry,
                              Test-HerdrServer, Wait-HerdrServer, Import-RustDeskConfigFile,
                              Get-RustDeskPin, Get-RustDeskVersion, Resolve-RustDeskLatestVersion,
                              Stop-RustDeskClean, Start-RustDeskClean, Start-RustDeskUI,
                              Test-IsLaptop, Test-ModernStandbyAvailable,
                              Get-BatteryPercent, Test-RemoteSessionActive,
                              Get-LastResumeTime, Get-PowerEpochStamp, New-RustDeskResumeTrigger,
                              New-RustDeskNetworkTrigger, New-RustDeskEventTrigger,
                              Get-RustDeskFirewallCoverage, Get-RustDeskFirewallState
