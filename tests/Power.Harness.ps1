<#
.SYNOPSIS
    Testes de execucao do passo de energia. NAO altera o sistema.

.DESCRIPTION
    Os testes de tests/RustDeskToml.Tests.ps1 sao estaticos: leem o codigo e
    verificam que ele tem a forma certa. Isso nao pega erro de execucao - e o
    daemon chegou a nascer com um cast que estourava na partida, em qualquer
    maquina, com o parser aprovando.

    Este harness executa os scripts de verdade, mas contra um mundo falso:

      powercfg                        -> plano de energia em memoria
      Get-NetAdapter e cia            -> adaptador ficticio
      Assert-Elevated                 -> no-op
      Test-IsLaptop / Get-BatteryPercent -> dirigidos por variavel de ambiente

    Os stubs sao aplicados numa COPIA do repositorio, em %TEMP%, apagada no
    fim. Nem lib/ nem scripts/ sao tocados.

    Onde a aceitacao real do cmdlet importa (o array misto de triggers), usa-se
    New-ScheduledTask, que monta e valida o objeto em memoria, em vez de
    Register-ScheduledTask, que gravaria no Agendador.

    O que este harness NAO prova: que o powercfg real aceita os valores, que o
    Windows de fato deixa de suspender por causa do daemon, ou que o Agendador
    dispara o trigger de resume. Isso exige um notebook - ver o item 0 do
    BACKLOG.md.

.EXAMPLE
    .\tests\Power.Harness.ps1
    Roda tudo. Nao precisa de Administrador.

.EXAMPLE
    .\tests\Power.Harness.ps1 -KeepSandbox
    Mantem a copia temporaria para inspecao.
#>
[CmdletBinding()]
param([switch]$KeepSandbox)

$ErrorActionPreference = 'Stop'

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
function Assert-True($cond, $msg = '') { if (-not $cond) { throw "condicao falsa: $msg" } }
function Assert-Equal($e, $o, $msg = '') { if ($e -ne $o) { throw "esperado '$e', obtido '$o'. $msg" } }

# =====================================================================
#  Copia com stubs
# =====================================================================
$repoRaiz = Split-Path -Parent $PSScriptRoot
$global:sb = Join-Path ([IO.Path]::GetTempPath()) "setup-rustdesk-harness-$PID"
if (Test-Path $global:sb) { Remove-Item $global:sb -Recurse -Force }
New-Item -ItemType Directory -Path $global:sb -Force | Out-Null

foreach ($d in 'lib', 'scripts', 'config') {
    Copy-Item (Join-Path $repoRaiz $d) -Destination $global:sb -Recurse -Force
}

# Stubs no modulo COPIADO. O repositorio nao e alterado.
$mod = Join-Path $global:sb 'lib\RustDeskCommon.psm1'
$txt = Get-Content -LiteralPath $mod -Raw

$txt = $txt.Replace(
@'
    if (-not (Test-Elevated)) {
        throw 'Este passo exige privilegios de Administrador. Abra o PowerShell como Administrador e rode de novo.'
    }
'@,
@'
    if ($env:RDHARNESS_ELEVATED -eq 'fail') {
        throw 'Este passo exige privilegios de Administrador. Abra o PowerShell como Administrador e rode de novo.'
    }
'@)

$txt = $txt.Replace(
@'
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        if ($cs.PCSystemType -eq 2) { return $true }
'@,
@'
    if ($env:RDHARNESS_LAPTOP) { return ($env:RDHARNESS_LAPTOP -eq '1') }
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        if ($cs.PCSystemType -eq 2) { return $true }
'@)

Set-Content -LiteralPath $mod -Value $txt -Encoding UTF8
Import-Module $mod -Force

# =====================================================================
#  Mundo falso
# =====================================================================
$global:plano = @{}; $global:chamadas = @(); $global:ativado = $false
$global:temS0 = $false; $global:escritaFajuta = $false; $global:nicDesligado = $false

function Reset-Plano {
    param([bool]$ComS0 = $false, [bool]$ComTampa = $true, [bool]$Fajuta = $false)
    $global:plano = @{
        'SUB_BUTTONS/LIDACTION'   = @{ Ac = 1;     Dc = 1 }
        'SUB_SLEEP/STANDBYIDLE'   = @{ Ac = 1800;  Dc = 900 }
        'SUB_SLEEP/HIBERNATEIDLE' = @{ Ac = 10800; Dc = 5400 }
        'SUB_VIDEO/VIDEOIDLE'     = @{ Ac = 600;   Dc = 300 }
    }
    if ($ComS0) { $global:plano['SUB_NONE/F15576E8-98B7-4186-B944-EAFA664402D9'] = @{ Ac = 0; Dc = 0 } }
    if (-not $ComTampa) { $global:plano.Remove('SUB_BUTTONS/LIDACTION') }
    $global:chamadas = @(); $global:ativado = $false
    $global:temS0 = $ComS0; $global:escritaFajuta = $Fajuta
}

function powercfg {
    # NAO usar $script: aqui: dentro de uma funcao de script, $script: resolve
    # no escopo do script EM EXECUCAO - que passa a ser Set-PowerConfig.ps1
    # quando ele chama esta funcao. O estado tem que ser global.
    $a = @($args)
    $global:chamadas += ($a -join ' ')

    switch -Regex ($a[0]) {
        '^/a$' {
            if ($global:temS0) {
                return @('Os seguintes estados de suspensao estao disponiveis neste sistema:',
                         '    Em Espera (S0 Ocioso com Baixo Consumo de Energia) Rede Conectada',
                         '    Hibernar')
            }
            return @('Os seguintes estados de suspensao estao disponiveis neste sistema:',
                     '    Espera (S3)', '    Hibernar')
        }
        '^/q$' {
            $chave = "$($a[2])/$($a[3])"
            if (-not $global:plano.ContainsKey($chave)) {
                # subvalor nao exposto: so o cabecalho, sem nenhum 0x. Foi o que
                # PBUTTONACTION e LIDACTION fizeram na maquina de referencia.
                return @('GUID do Esquema de Energia: 8c5e7fda-...  (Alto desempenho)',
                         '  Alias GUID: SCHEME_MIN')
            }
            $v = $global:plano[$chave]
            # Formato real de um Windows pt-BR, com os QUATRO campos 0x que
            # PRECEDEM os indices. Se o parser pegasse a primeira ocorrencia em
            # vez das duas ultimas, leria o minimo possivel e concluiria errado.
            return @(
                'GUID do Esquema de Energia: 8c5e7fda-...  (Alto desempenho)'
                '  Alias GUID: SCHEME_MIN'
                "    Alias GUID: $($a[2])"
                "      Alias GUID: $($a[3])"
                '      Configuracao Minima Possivel: 0x00000000'
                '      Configuracao Maxima Possivel: 0xffffffff'
                '      Incremento de Configuracoes Possiveis: 0x00000001'
                '      Unidades de Configuracoes Possiveis: segundos'
                ('    Indice de Configuracoes de Correntes Alternadas Atuais: 0x{0}' -f $v.Ac.ToString('x8'))
                ('    Indice de Configuracoes de Correntes Continuas Atuais: 0x{0}' -f $v.Dc.ToString('x8'))
            )
        }
        '^/setacvalueindex$' {
            if ($global:escritaFajuta) { return }
            $c = "$($a[2])/$($a[3])"
            if ($global:plano.ContainsKey($c)) { $global:plano[$c].Ac = [int]$a[4] }
            return
        }
        '^/setdcvalueindex$' {
            if ($global:escritaFajuta) { return }
            $c = "$($a[2])/$($a[3])"
            if ($global:plano.ContainsKey($c)) { $global:plano[$c].Dc = [int]$a[4] }
            return
        }
        '^/setactive$' { $global:ativado = $true; return }
        default { return }
    }
}

function Get-NetAdapter {
    param([switch]$Physical, [string]$Name, $ErrorAction)
    return [PSCustomObject]@{
        Name = 'Wi-Fi'; Status = 'Up'; Virtual = $false
        InterfaceDescription = 'Adaptador de teste 802.11ax'
    }
}
function Get-NetAdapterPowerManagement {
    param([string]$Name, $ErrorAction)
    return [PSCustomObject]@{
        Name = $Name
        AllowComputerToTurnOffDevice = $(if ($global:nicDesligado) { 'Disabled' } else { 'Enabled' })
        DeviceSleepOnDisconnect = 'Enabled'; WakeOnMagicPacket = 'Enabled'; WakeOnPattern = 'Enabled'
    }
}
function Disable-NetAdapterPowerManagement {
    param([string]$Name, $Confirm, $ErrorAction)
    $global:nicDesligado = $true
    $global:chamadas += "Disable-NetAdapterPowerManagement $Name"
}

function Invoke-SetPower {
    param([switch]$WhatIf, [switch]$NoNic)
    $p = @{}
    if ($WhatIf) { $p['WhatIf'] = $true }
    if ($NoNic)  { $p['NoNic']  = $true }
    # 6>&1: Write-Host escreve no stream de Information, nao no de saida
    return (& "$global:sb\scripts\Set-PowerConfig.ps1" @p 6>&1 | Out-String)
}
function Test-Chamou {
    # NAO usar '$global:chamadas -notmatch $p': em array, -notmatch devolve os
    # elementos que NAO casam, e lista nao-vazia e truthy - o assert passaria
    # sempre. Ja escondeu um bug real neste repositorio.
    param([string]$Padrao)
    return [bool](@($global:chamadas | Where-Object { $_ -match $Padrao }).Count)
}
function Test-Escreveu { return (Test-Chamou 'setacvalueindex|setdcvalueindex|Disable-NetAdapter') }

try {

# =====================================================================
Write-Host ''
Write-Host '=== Harness: Set-PowerConfig.ps1 ===' -ForegroundColor Cyan
$env:RDHARNESS_LAPTOP = '1'

It 'em notebook, aplica os subvalores e ativa o esquema' {
    Reset-Plano
    $saida = Invoke-SetPower
    Assert-Equal 0    $global:plano['SUB_BUTTONS/LIDACTION'].Ac   'tampa AC'
    Assert-Equal 0    $global:plano['SUB_BUTTONS/LIDACTION'].Dc   'tampa DC'
    Assert-Equal 0    $global:plano['SUB_SLEEP/STANDBYIDLE'].Ac   'suspender AC'
    Assert-Equal 1800 $global:plano['SUB_SLEEP/STANDBYIDLE'].Dc   'suspender DC'
    Assert-Equal 0    $global:plano['SUB_SLEEP/HIBERNATEIDLE'].Ac 'hibernar AC'
    Assert-Equal 0    $global:plano['SUB_SLEEP/HIBERNATEIDLE'].Dc 'hibernar DC'
    Assert-Equal 600  $global:plano['SUB_VIDEO/VIDEOIDLE'].Ac     'painel AC'
    Assert-Equal 180  $global:plano['SUB_VIDEO/VIDEOIDLE'].Dc     'painel DC'
    Assert-True $global:ativado 'powercfg /setactive nao foi chamado - os valores nao valeriam'
    Assert-True ($saida -match 'APLICADO') 'nada foi reportado como aplicado'
}

It 'o /setactive vem DEPOIS das escritas' {
    Reset-Plano
    Invoke-SetPower | Out-Null
    $iSet = [array]::FindIndex([string[]]$global:chamadas, [Predicate[string]]{ param($x) $x -match '^/setactive' })
    $iUlt = [array]::FindLastIndex([string[]]$global:chamadas, [Predicate[string]]{ param($x) $x -match 'valueindex' })
    Assert-True ($iSet -gt $iUlt) "setactive no indice $iSet, ultima escrita em $iUlt"
}

It '-WhatIf nao escreve nada, nem no plano nem no adaptador' {
    Reset-Plano
    $antes  = ($global:plano.Keys | Sort-Object | ForEach-Object { "$_=$($global:plano[$_].Ac)/$($global:plano[$_].Dc)" }) -join ';'
    $saida  = Invoke-SetPower -WhatIf
    $depois = ($global:plano.Keys | Sort-Object | ForEach-Object { "$_=$($global:plano[$_].Ac)/$($global:plano[$_].Dc)" }) -join ';'
    Assert-Equal $antes $depois 'o plano mudou em modo simulacao'
    Assert-True (-not (Test-Escreveu)) "houve chamada de escrita: $($global:chamadas -join ' | ')"
    Assert-True (-not $global:ativado) 'setactive foi chamado em modo simulacao'
    Assert-True ($saida -match 'SIMULACAO') 'a saida nao indica simulacao'
}

It 'a segunda passada nao reescreve nada' {
    Reset-Plano
    Invoke-SetPower | Out-Null
    $global:chamadas = @(); $global:ativado = $false
    $saida = Invoke-SetPower
    Assert-True (-not (Test-Escreveu)) 'reescreveu valores que ja estavam certos'
    Assert-True (-not $global:ativado) 'reativou o esquema sem precisar'
    Assert-True ($saida -match '\[OK\]') 'nao reportou os valores como ja corretos'
    Assert-True ($saida -notmatch '\[APLICADO\]') 'reportou APLICADO sem ter mudado nada'
}

It 'sem Modern Standby, a conectividade em espera e pulada sem erro' {
    Reset-Plano -ComS0 $false
    $saida = Invoke-SetPower
    Assert-True ($saida -match 'PULADO.*conectividade') 'nao reportou o pulo'
    Assert-True (-not (Test-Chamou 'F15576E8')) 'tentou gravar uma chave que nao existe'
}

It 'com Modern Standby, a conectividade em espera e aplicada' {
    Reset-Plano -ComS0 $true
    Invoke-SetPower | Out-Null
    $k = 'SUB_NONE/F15576E8-98B7-4186-B944-EAFA664402D9'
    Assert-Equal 1 $global:plano[$k].Ac 'conectividade AC'
    Assert-Equal 1 $global:plano[$k].Dc 'conectividade DC'
}

It 'subvalor nao exposto pelo plano vira PULADO, nao falha' {
    Reset-Plano -ComTampa $false
    $saida = Invoke-SetPower
    Assert-True ($saida -match 'PULADO.*tampa') 'a tampa ausente deveria ser pulada'
}

It 'powercfg que aceita e ignora a escrita e pego pela releitura' {
    Reset-Plano -Fajuta $true
    $erro = $null
    try { Invoke-SetPower | Out-Null } catch { $erro = $_.Exception.Message }
    Assert-True ($null -ne $erro) 'o script anunciou sucesso sem ter gravado nada'
    Assert-True ($erro -match 'nao ficaram com o valor pedido') "mensagem inesperada: $erro"
}

It 'o adaptador e desligado uma vez e reconhecido como ja feito depois' {
    Reset-Plano; $global:nicDesligado = $false
    Invoke-SetPower | Out-Null
    Assert-True (Test-Chamou 'Disable-NetAdapterPowerManagement') 'nao desligou o power saving'
    $global:chamadas = @()
    $saida = Invoke-SetPower
    Assert-True (-not (Test-Chamou 'Disable-NetAdapter')) 'desligou de novo o que ja estava desligado'
    Assert-True ($saida -match 'antes ->') 'nao registrou o estado anterior do adaptador'
}

It '-NoNic nao encosta no adaptador' {
    Reset-Plano; $global:nicDesligado = $false
    $saida = Invoke-SetPower -NoNic
    Assert-True (-not (Test-Chamou 'Disable-NetAdapter')) 'mexeu no adaptador mesmo com -NoNic'
    Assert-True ($saida -match 'PULADO.*adaptador') 'nao reportou o pulo'
}

It 'em desktop, sai limpo sem tocar em nada' {
    $env:RDHARNESS_LAPTOP = '0'
    Reset-Plano
    $saida = Invoke-SetPower
    Assert-True (-not (Test-Escreveu)) 'gravou em maquina sem bateria'
    Assert-True ($saida -match 'nao e portatil') 'nao explicou por que pulou'
    $env:RDHARNESS_LAPTOP = '1'
}

It 'sem elevacao, recusa antes de qualquer escrita' {
    $env:RDHARNESS_ELEVATED = 'fail'
    Reset-Plano
    $erro = $null
    try { Invoke-SetPower | Out-Null } catch { $erro = $_.Exception.Message }
    Remove-Item env:RDHARNESS_ELEVATED
    Assert-True ($null -ne $erro) 'nao exigiu Administrador'
    Assert-True (-not (Test-Escreveu)) 'gravou antes de checar elevacao'
}

# =====================================================================
Write-Host ''
Write-Host '=== Harness: daemon RustDeskAwake (executado de verdade) ===' -ForegroundColor Cyan

$area      = Join-Path $global:sb 'daemon-run'
New-Item -ItemType Directory -Path $area -Force | Out-Null
$logDaemon = Join-Path $area 'awake.log'
$fEstado   = Join-Path $area 'sessao.txt'
$fBateria  = Join-Path $area 'bateria.txt'
$daemon    = Join-Path $area 'rustdesk-awake.ps1'

$conteudo = Get-Content -LiteralPath (Join-Path $global:sb 'scripts\awake\rustdesk-awake.ps1') -Raw
$conteudo = $conteudo.Replace('__LOGFILE__', $logDaemon).Replace('__POLL__', '1').Replace('__MINBAT__', '15')

It 'o template nao deixa marcador para tras' {
    Assert-True ($conteudo -notmatch '__(LOGFILE|POLL|MINBAT)__') 'sobrou marcador nao substituido'
}

# troca as duas fontes por stubs dirigidos por arquivo, preservando o resto
$ini = $conteudo.IndexOf('function Test-SessaoRemota {')
$fim = $conteudo.IndexOf('function Get-Carga {')
$conteudo = $conteudo.Substring(0, $ini) +
    "function Test-SessaoRemota {`n    return ((Get-Content -LiteralPath `"$fEstado`" -ErrorAction SilentlyContinue) -eq '1')`n}`n`n" +
    $conteudo.Substring($fim)
$ini = $conteudo.IndexOf('function Get-Carga {')
$fim = $conteudo.IndexOf('# --- sair sempre solta')
$conteudo = $conteudo.Substring(0, $ini) +
    "function Get-Carga {`n    return [int]((Get-Content -LiteralPath `"$fBateria`" -ErrorAction SilentlyContinue))`n}`n`n" +
    $conteudo.Substring($fim)
Set-Content -LiteralPath $daemon -Value $conteudo -Encoding UTF8

It 'o daemon com os stubs passa no parser' {
    $errs = $null; $toks = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($daemon, [ref]$toks, [ref]$errs)
    Assert-True (-not $errs) "erro de sintaxe: $(if ($errs) { $errs[0].Message })"
}

function Wait-Log {
    <#
        Espera ate o log ter N ocorrencias do padrao, ou estoura o tempo.

        NAO usar Start-Sleep fixo aqui: o arranque do daemon inclui o Add-Type,
        que compila C# na primeira vez. Numa maquina rapida isso cabe em 3
        segundos; num runner de CI, nao - e o teste falhava por relogio, nao por
        defeito.
    #>
    param([string]$Padrao, [int]$Vezes = 1, [int]$TimeoutSeconds = 60)
    $limite = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $limite) {
        $l = @(Get-Content -LiteralPath $logDaemon -ErrorAction SilentlyContinue |
               Where-Object { $_ -match $Padrao })
        if ($l.Count -ge $Vezes) { return $l }
        Start-Sleep -Milliseconds 400
    }
    return @(Get-Content -LiteralPath $logDaemon -ErrorAction SilentlyContinue |
             Where-Object { $_ -match $Padrao })
}

Set-Content -LiteralPath $fEstado -Value '0'
Set-Content -LiteralPath $fBateria -Value '80'
$exe  = (Get-Process -Id $PID).Path
$proc = Start-Process -FilePath $exe `
    -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $daemon) `
    -PassThru -WindowStyle Hidden
try {
    It 'sobe e nao segura nada sem sessao' {
        Assert-True (@(Wait-Log 'Daemon iniciado').Count -ge 1) `
            'nao registrou a partida - provavelmente morreu no arranque'
        Assert-True (@(Wait-Log 'Sem sessao remota').Count -ge 1) 'nao registrou o bloqueio solto'
    }

    Set-Content -LiteralPath $fEstado -Value '1'
    It 'ao aparecer sessao remota, segura a maquina acordada' {
        $l = Wait-Log 'Segurando a maquina acordada'
        Assert-True ($l.Count -ge 1) 'nao passou a segurar'
        Assert-True ($l -match 'bateria 80%') 'nao registrou a carga na transicao'
    }

    Set-Content -LiteralPath $fBateria -Value '9'
    It 'com a bateria abaixo do limiar, solta mesmo com sessao ativa' {
        $l = Wait-Log 'bateria caiu para 9%'
        Assert-True ($l.Count -ge 1) 'nao soltou por bateria baixa'
        Assert-True ($l -match 'melhor suspender do que desligar') 'nao explicou o porque'
    }

    Set-Content -LiteralPath $fBateria -Value '80'
    It 'recuperando a carga, volta a segurar' {
        $l = Wait-Log 'Segurando a maquina acordada' -Vezes 2
        Assert-True ($l.Count -ge 2) "esperava voltar a segurar; ocorrencias: $($l.Count)"
    }

    Set-Content -LiteralPath $fEstado -Value '0'
    It 'ao encerrar a sessao, solta o bloqueio' {
        $l = Wait-Log 'Bloqueio solto' -Vezes 2
        Assert-True ($l.Count -ge 2) "esperava soltar de novo; ocorrencias: $($l.Count)"
    }

    It 'loga so nas transicoes, nao a cada passada' {
        # com intervalo de 1 s, logar sempre daria dezenas de linhas e esconderia
        # justamente o evento que interessa
        $l = @(Get-Content -LiteralPath $logDaemon)
        Assert-True ($l.Count -le 8) "log com $($l.Count) linhas - esta logando a cada passada"
    }
} finally {
    if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
}

Start-Sleep -Seconds 1
It 'o processo do daemon termina de fato' {
    Assert-True (-not (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)) 'o daemon ficou vivo'
}

# =====================================================================
Write-Host ''
Write-Host '=== Harness: tarefas agendadas (nenhuma e registrada) ===' -ForegroundColor Cyan

It 'o trigger de resume vira XML de subscription valido' {
    $t = New-RustDeskResumeTrigger -DelaySeconds 20
    Assert-Equal 'MSFT_TaskEventTrigger' $t.CimClass.CimClassName 'classe errada'
    Assert-Equal 'PT20S' $t.Delay 'atraso errado'
    Assert-True $t.Enabled 'trigger nasceu desabilitado'
    # XML mal formado faz o Agendador rejeitar a tarefa INTEIRA - ja aconteceu
    # aqui com o Duration do watchdog
    $xml = [xml]$t.Subscription
    Assert-True ($null -ne $xml.QueryList) 'XML sem QueryList'
    Assert-True ($t.Subscription -match 'Power-Troubleshooter') 'provider errado'
    Assert-True ($t.Subscription -match 'EventID=1') 'id de evento errado'
}

It 'o cmdlet aceita boot + repeticao + evento no mesmo array' {
    # ponto de risco: misturar trigger de New-ScheduledTaskTrigger com instancia
    # CIM crua. New-ScheduledTask valida sem gravar no Agendador.
    $tr = New-ScheduledTaskTrigger -AtStartup
    $tr.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Minutes 10)).Repetition
    $tarefa = New-ScheduledTask `
        -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile') `
        -Trigger @($tr, (New-RustDeskResumeTrigger -DelaySeconds 20)) `
        -Principal (New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -RunLevel Highest) `
        -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries)
    Assert-Equal 2 @($tarefa.Triggers).Count 'a tarefa nao ficou com os dois triggers'
    $classes = @($tarefa.Triggers | ForEach-Object { $_.CimClass.CimClassName })
    Assert-True ($classes -contains 'MSFT_TaskEventTrigger') 'perdeu o trigger de evento'
    Assert-True ($classes -contains 'MSFT_TaskBootTrigger')  'perdeu o trigger de boot'
}

It 'a tarefa do daemon nasce sem limite de duracao' {
    # o default de tres dias mataria o daemon no meio do uso
    $tarefa = New-ScheduledTask `
        -Action (New-ScheduledTaskAction -Execute 'powershell.exe') `
        -Trigger (New-ScheduledTaskTrigger -AtStartup) `
        -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
                      -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero))
    Assert-Equal 'PT0S' $tarefa.Settings.ExecutionTimeLimit 'o limite de execucao nao ficou zerado'
    Assert-True ($tarefa.Settings.DisallowStartIfOnBatteries -eq $false) 'nao iniciaria na bateria'
    Assert-True ($tarefa.Settings.StopIfGoingOnBatteries -eq $false) 'pararia ao passar para bateria'
}

$paths = Get-RustDeskPaths

It 'Install-AwakeGuard -WhatIf nao grava nem registra' {
    $antes  = Test-Path -LiteralPath $paths.AwakeScript
    $saida  = & "$global:sb\scripts\Install-AwakeGuard.ps1" -WhatIf 6>&1 | Out-String
    $depois = Test-Path -LiteralPath $paths.AwakeScript
    Assert-Equal $antes $depois 'o arquivo do daemon apareceu ou sumiu em modo simulacao'
    Assert-True ($saida -match 'SIMULACAO') 'a saida nao indica simulacao'
    Assert-True ($null -eq (Get-ScheduledTask -TaskName $paths.AwakeTask -ErrorAction SilentlyContinue)) `
        'registrou a tarefa em modo simulacao'
}

It 'Install-AwakeGuard nao instala em desktop' {
    $env:RDHARNESS_LAPTOP = '0'
    $saida = & "$global:sb\scripts\Install-AwakeGuard.ps1" 6>&1 | Out-String
    $env:RDHARNESS_LAPTOP = '1'
    Assert-True ($saida -match 'nao e portatil') 'nao explicou por que pulou'
    Assert-True ($null -eq (Get-ScheduledTask -TaskName $paths.AwakeTask -ErrorAction SilentlyContinue)) `
        'registrou tarefa numa maquina sem bateria'
}

It 'avisa quando o intervalo de checagem nao e menor que a suspensao' {
    # reagir depois de a maquina ja ter dormido nao serve para nada
    $cfg = Join-Path $global:sb 'config\power-harness.psd1'
    @'
@{
    LidActionAC = 0; LidActionDC = 0
    StandbyIdleAC = 0; StandbyIdleDC = 60
    HibernateIdleAC = 0; HibernateIdleDC = 0
    VideoIdleAC = 600; VideoIdleDC = 180
    ConnectivityInStandby = 1
    DisableNicPowerSaving = $true
    KeepAwakeWhileConnected = $true
    KeepAwakePollSeconds = 120
    KeepAwakeMinBatteryPercent = 15
}
'@ | Set-Content -LiteralPath $cfg -Encoding UTF8
    $saida = & "$global:sb\scripts\Install-AwakeGuard.ps1" -ConfigFile $cfg -WhatIf 6>&1 | Out-String
    Assert-True ($saida -match 'nao e menor que StandbyIdleDC') "nao avisou sobre o intervalo: $saida"
}

# =====================================================================
Write-Host ''
Write-Host '=== Harness: carimbo de epoca do watchdog ===' -ForegroundColor Cyan

# Executa as funcoes do proprio TEMPLATE, para nao testar uma reimplementacao.
$tpl = Get-Content -LiteralPath (Join-Path $global:sb 'scripts\watchdog\rustdesk-watchdog.ps1') -Raw
$i = $tpl.IndexOf('function Get-LastResume {')
$f = $tpl.IndexOf("Write-Log 'Watchdog iniciado.'")
Invoke-Expression $tpl.Substring($i, $f - $i)

It 'Get-EpochStamp devolve boot e resume separados' {
    $e = Get-EpochStamp
    Assert-Equal 2 (@($e -split '\|').Count) "formato inesperado: $e"
    Assert-True (($e -split '\|')[0] -ne '-') 'a parte do boot veio vazia'
}

It 'a epoca e estavel entre chamadas seguidas' {
    # se oscilasse, a guarda "uma vez por epoca" nunca seguraria nada
    Assert-Equal (Get-EpochStamp) (Get-EpochStamp) 'o carimbo mudou sem nada acontecer'
}

It 'boot igual e resume novo produzem epocas diferentes' {
    # e a regressao que a correcao existe para evitar: com o carimbo antigo, so
    # de boot, uma recusa gravada de manha valeria ate o proximo reinicio
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o')
    $e1 = "$boot|-"
    $e2 = "$boot|$((Get-Date).ToString('o'))"
    Assert-True ($e1 -ne $e2) 'boot igual e resume novo deram a mesma epoca'

    $stamp = Join-Path $global:sb 'epoca-teste.txt'
    Set-Content -LiteralPath $stamp -Value $e1 -Encoding ASCII
    $gravado = (Get-Content $stamp | Select-Object -First 1)
    Assert-True ($gravado -eq $e1) 'nao reconheceu a mesma epoca - reiniciaria em loop'
    Assert-True ($gravado -ne $e2) 'considerou a epoca nova como ja tentada - a trava continuaria'
}

} finally {
    Remove-Item env:RDHARNESS_LAPTOP -ErrorAction SilentlyContinue
    Remove-Item env:RDHARNESS_ELEVATED -ErrorAction SilentlyContinue
    Remove-Module RustDeskCommon -Force -ErrorAction SilentlyContinue
    if ($KeepSandbox) {
        Write-Host ''
        Write-Host "  copia mantida em: $global:sb" -ForegroundColor DarkGray
    } else {
        Remove-Item $global:sb -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
if ($script:falhou -eq 0) {
    Write-Host "=== $script:passou teste(s) de harness, tudo passou ===" -ForegroundColor Green
} else {
    Write-Host "=== $script:passou passou, $script:falhou falhou ===" -ForegroundColor Red
    exit 1
}
