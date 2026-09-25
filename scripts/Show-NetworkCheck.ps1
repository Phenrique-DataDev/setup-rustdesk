<#
.SYNOPSIS
    Abre no navegador uma pagina local com o botao "Verificar rede", que analisa
    a rede do dispositivo sob o ponto de vista do RustDesk e mostra o resultado.

.DESCRIPTION
    Uma pagina HTML sozinha nao pode pingar, resolver DNS nem ler o firewall: o
    navegador nao deixa. Por isso este script sobe um servidor minimo em
    127.0.0.1 (porta aleatoria, so aceita conexao local) e abre a pagina. O botao
    chama o proprio script, que roda as checagens e devolve o resultado para a
    caixa da pagina.

    O endereco leva um token aleatorio: outra pagina aberta no navegador nao
    consegue disparar a analise nem ler o resultado. Nada e alterado no sistema
    e nao precisa de Administrador.

    Checagens: adaptador e sinal do Wi-Fi, perfil de rede, IP/gateway/DNS, ping
    no gateway e na internet (latencia, perda, jitter), resolucao DNS do servidor
    do RustDesk, conexao TCP ao rendezvous e ao relay, trafego atual, firewall,
    servico, uso de portas efemeras e quedas de rede recentes.

    O servidor encerra pelo botao "Encerrar" da pagina, com Ctrl+C, ou sozinho
    depois de -IdleMinutes sem uso.

.PARAMETER Json
    Nao abre servidor: roda a analise uma vez e imprime o resultado em JSON.

.EXAMPLE
    .\scripts\Show-NetworkCheck.ps1

.EXAMPLE
    .\scripts\Show-NetworkCheck.ps1 -Json
#>
[CmdletBinding()]
param(
    [int]$Port = 0,
    [int]$IdleMinutes = 15,
    [switch]$NoBrowser,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\lib\RustDeskCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\lib\RustDeskToml.psm1')   -Force

# --- checagens ---------------------------------------------------------

function New-Resultado($grupo, $item, $status, $detalhe) {
    # status: ok | aviso | falha | info
    [ordered]@{ grupo = $grupo; item = $item; status = $status; detalhe = [string]$detalhe }
}

function Measure-Ping([string]$Alvo, [int]$N = 10) {
    $ping = New-Object System.Net.NetworkInformation.Ping
    $tempos = @(); $perdas = 0
    for ($i = 0; $i -lt $N; $i++) {
        try {
            $r = $ping.Send($Alvo, 1000)
            if ($r.Status -eq 'Success') { $tempos += [int]$r.RoundtripTime } else { $perdas++ }
        } catch { $perdas++ }
        Start-Sleep -Milliseconds 100
    }
    $ping.Dispose()
    $jitter = 0
    if ($tempos.Count -gt 1) {
        $soma = 0
        for ($i = 1; $i -lt $tempos.Count; $i++) { $soma += [Math]::Abs($tempos[$i] - $tempos[$i - 1]) }
        $jitter = [Math]::Round($soma / ($tempos.Count - 1), 1)
    }
    [PSCustomObject]@{
        Perda  = [Math]::Round(100 * $perdas / $N)
        Media  = $(if ($tempos.Count) { [Math]::Round(($tempos | Measure-Object -Average).Average, 1) } else { $null })
        Max    = $(if ($tempos.Count) { ($tempos | Measure-Object -Maximum).Maximum } else { $null })
        Jitter = $jitter
    }
}

function Format-Ping($p) {
    if ($null -eq $p.Media) { return "sem resposta ($($p.Perda)% de perda)" }
    if ($p.Max -lt 1) { return "abaixo de 1 ms, perda $($p.Perda)%" }
    "media $($p.Media) ms, max $($p.Max) ms, jitter $($p.Jitter) ms, perda $($p.Perda)%"
}

function Measure-Tcp([string]$Ip, [int]$Porta, [int]$Tentativas = 3) {
    # Menor tempo de handshake entre as tentativas; $null se nenhuma conectou.
    $melhor = $null
    for ($i = 0; $i -lt $Tentativas; $i++) {
        $c = New-Object System.Net.Sockets.TcpClient
        try {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $t = $c.ConnectAsync($Ip, $Porta)
            if ($t.Wait(3000) -and $c.Connected) {
                $ms = $sw.ElapsedMilliseconds
                if ($null -eq $melhor -or $ms -lt $melhor) { $melhor = $ms }
            }
        } catch { } finally { $c.Dispose() }
    }
    return $melhor
}

function Invoke-NetworkCheck {
    $res = New-Object System.Collections.ArrayList
    $add = { param($r) [void]$res.Add($r) }
    $inicio = Get-Date

    # --- adaptador ---
    $cfg = $null; $ad = $null
    try {
        $cfg = @(Get-NetIPConfiguration -ErrorAction Stop |
                 Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
                 Sort-Object { $_.IPv4DefaultGateway.RouteMetric + $_.NetIPv4Interface.InterfaceMetric })[0]
        if (-not $cfg) { throw 'nenhum adaptador ativo com gateway padrao' }
        $ad = Get-NetAdapter -InterfaceIndex $cfg.InterfaceIndex
        $wifi = $ad.PhysicalMediaType -match '802\.11' -or $ad.InterfaceDescription -match 'Wi-?Fi|Wireless'
        & $add (New-Resultado 'Adaptador' 'adaptador em uso' 'info' `
            "$($ad.Name) - $($ad.InterfaceDescription) ($(if ($wifi) { 'Wi-Fi' } else { 'cabo' }))")

        $bps = [double]$ad.ReceiveLinkSpeed
        $st = if ($bps -gt 0 -and $bps -lt 100e6) { 'aviso' } else { 'ok' }
        $det = "$($ad.LinkSpeed)"
        if ($st -eq 'aviso') { $det += ' - abaixo de 100 Mbps; em cabo costuma ser cabo/porta ruim' }
        & $add (New-Resultado 'Adaptador' 'velocidade do link' $st $det)

        if ($wifi) {
            $sinal = $null
            foreach ($l in @(& netsh.exe wlan show interfaces 2>$null)) {
                if ($l -match ':\s*(\d{1,3})\s*%') { $sinal = [int]$Matches[1]; break }
            }
            if ($null -ne $sinal) {
                $st = if ($sinal -lt 60) { 'aviso' } else { 'ok' }
                $det = "$sinal%"
                if ($st -eq 'aviso') { $det += ' - sinal fraco: perda e jitter sobem, o video engasga' }
                & $add (New-Resultado 'Adaptador' 'sinal do Wi-Fi' $st $det)
            }
        }
    } catch {
        & $add (New-Resultado 'Adaptador' 'adaptador em uso' 'falha' $_.Exception.Message)
    }

    if ($cfg) {
        # --- enderecos ---
        try {
            $perfil = Get-NetConnectionProfile -InterfaceIndex $cfg.InterfaceIndex -ErrorAction Stop | Select-Object -First 1
            & $add (New-Resultado 'Enderecos' 'perfil de rede' 'info' `
                "$($perfil.Name): $($perfil.NetworkCategory); IPv4 $($perfil.IPv4Connectivity), IPv6 $($perfil.IPv6Connectivity)")
        } catch { }
        $ipv4 = @($cfg.IPv4Address | ForEach-Object { $_.IPAddress }) -join ', '
        & $add (New-Resultado 'Enderecos' 'IPv4 / gateway' 'info' "$ipv4 via $($cfg.IPv4DefaultGateway.NextHop)")
        $v6 = @(Get-NetIPAddress -InterfaceIndex $cfg.InterfaceIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue |
                Where-Object { $_.PrefixOrigin -ne 'WellKnown' -and $_.IPAddress -notmatch '^(fe80|fd|fc)' })
        & $add (New-Resultado 'Enderecos' 'IPv6 global' 'info' $(if ($v6.Count) {
            'presente - o RustDesk tambem tenta conexao direta por IPv6' } else { 'ausente - so IPv4 (normal em muitas redes)' }))
        $dns = @($cfg.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses }) -join ', '
        & $add (New-Resultado 'Enderecos' 'servidores DNS' 'info' $(if ($dns) { $dns } else { '(nenhum IPv4)' }))

        # --- latencia ---
        $gw = $cfg.IPv4DefaultGateway.NextHop
        $p = Measure-Ping $gw
        $st = if ($null -eq $p.Media) { 'falha' } elseif ($p.Perda -gt 0 -or $p.Media -ge 20 -or $p.Max -ge 100) { 'aviso' } else { 'ok' }
        & $add (New-Resultado 'Latencia' "ping no roteador ($gw)" $st (Format-Ping $p))
    }

    foreach ($alvo in '1.1.1.1', '8.8.8.8') {
        $p = Measure-Ping $alvo
        $st = if ($null -eq $p.Media) { 'falha' } elseif ($p.Perda -gt 0 -or $p.Jitter -ge 30) { 'aviso' } else { 'ok' }
        & $add (New-Resultado 'Latencia' "ping na internet ($alvo)" $st (Format-Ping $p))
    }

    # --- servidor do RustDesk ---
    $paths = Get-RustDeskPaths
    $rv = $null
    try { $rv = Get-TomlOption -Path $paths.UserConfig -Key 'custom-rendezvous-server' } catch { }
    $publico = -not $rv
    $hostRv = if ($publico) { 'rs-ny.rustdesk.com' } else { ($rv -split ':')[0] }
    $ip = $null
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = @(Resolve-DnsName -Name $hostRv -Type A -DnsOnly -NoHostsFile -ErrorAction Stop |
               Where-Object { $_.Type -eq 'A' })
        $ms = $sw.ElapsedMilliseconds
        if (-not $r.Count) { throw 'sem registro A' }
        $ip = $r[0].IPAddress
        $st = if ($ms -ge 300) { 'aviso' } else { 'ok' }
        & $add (New-Resultado 'RustDesk' "DNS resolve $hostRv" $st "$ip em $ms ms")
    } catch {
        & $add (New-Resultado 'RustDesk' "DNS resolve $hostRv" 'falha' `
            "$($_.Exception.Message) - sem isso o RustDesk nao registra e a maquina aparece offline")
    }
    if ($ip) {
        $ms = Measure-Tcp $ip 21116
        if ($null -eq $ms) {
            & $add (New-Resultado 'RustDesk' 'conexao ao rendezvous (TCP 21116)' 'falha' 'nao conectou - saida bloqueada por firewall/rede')
        } else {
            $det = "$ms ms ate $hostRv"
            if ($publico) { $det += ' (servidor publico)' }
            & $add (New-Resultado 'RustDesk' 'conexao ao rendezvous (TCP 21116)' 'ok' $det)
        }
    }
    # No servidor publico o relay e outro host, escolhido pelo rendezvous na hora;
    # so da para testar quando o servidor e proprio.
    if (-not $publico) {
        $rl = $null
        try { $rl = Get-TomlOption -Path $paths.UserConfig -Key 'relay-server' } catch { }
        $hostRl = if ($rl) { ($rl -split ':')[0] } else { $hostRv }
        $ms = Measure-Tcp $hostRl 21117 1
        & $add (New-Resultado 'RustDesk' "conexao ao relay ($hostRl, TCP 21117)" $(if ($null -eq $ms) { 'aviso' } else { 'ok' }) `
            $(if ($null -eq $ms) { 'nao conectou - se a conexao direta falhar, nao ha plano B' } else { "$ms ms" }))
    }

    $svc = Get-Service -Name $paths.ServiceName -ErrorAction SilentlyContinue
    if (-not $paths.Installed) {
        & $add (New-Resultado 'RustDesk' 'instalado' 'falha' 'rustdesk.exe nao encontrado')
    } else {
        & $add (New-Resultado 'RustDesk' 'servico rodando' $(if ($svc -and $svc.Status -eq 'Running') { 'ok' } else { 'falha' }) `
            $(if ($svc) { "$($svc.Status)" } else { 'servico nao existe' }))
        try {
            $fw = Get-RustDeskFirewallState -Exe $paths.Exe
            if ($fw.Covered) {
                $ativos = @('Domain', 'Private', 'Public' | Where-Object { $fw.DisabledProfiles -notcontains $_ })
                & $add (New-Resultado 'RustDesk' 'firewall libera a entrada' 'ok' "perfis: $($ativos -join ', ')")
            } else {
                $pp = @()
                if ($fw.Missing.Count) { $pp += "sem regra em: $($fw.Missing -join ', ')" }
                if ($fw.Blocked.Count) { $pp += "regra Block em: $($fw.Blocked -join ', ')" }
                & $add (New-Resultado 'RustDesk' 'firewall libera a entrada' 'falha' `
                    (($pp -join '; ') + ' - sessoes cairiam no relay. Setup.ps1 -Configure recria a regra'))
            }
        } catch {
            & $add (New-Resultado 'RustDesk' 'firewall libera a entrada' 'aviso' "nao foi possivel ler: $($_.Exception.Message)")
        }
    }

    # --- carga ---
    if ($ad) {
        try {
            $a = Get-NetAdapterStatistics -Name $ad.Name
            Start-Sleep -Seconds 1
            $b = Get-NetAdapterStatistics -Name $ad.Name
            $up   = [Math]::Round(($b.SentBytes     - $a.SentBytes)     * 8 / 1e6, 1)
            $down = [Math]::Round(($b.ReceivedBytes - $a.ReceivedBytes) * 8 / 1e6, 1)
            & $add (New-Resultado 'Carga' 'trafego agora' 'info' `
                "envio $up Mbps, recebimento $down Mbps - envio perto do limite do plano engasga a sessao")
        } catch { }
    }

    try {
        $faixa = @(& netsh.exe int ipv4 show dynamicport tcp 2>$null | ForEach-Object {
                     if ($_ -match ':\s*(\d+)\s*$') { [int]$Matches[1] } })
        $ini = 49152; $qtd = 16384
        if ($faixa.Count -ge 2) { $ini = $faixa[0]; $qtd = $faixa[1] }
        $tcp = @(Get-NetTCPConnection -ErrorAction SilentlyContinue)
        $udp = @(Get-NetUDPEndpoint   -ErrorAction SilentlyContinue)
        $emUso = @($tcp | Where-Object { $_.LocalPort -ge $ini -and $_.LocalPort -lt $ini + $qtd }).Count
        $pct = [Math]::Round(100 * $emUso / $qtd, 1)
        $procs = @{}
        Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $procs[$_.Id] = $_.ProcessName }
        $top = @(@($tcp) + @($udp) | Group-Object OwningProcess | Sort-Object Count -Descending |
                 Select-Object -First 3 | ForEach-Object {
                     $n = if ($_.Name -eq '0') { 'sistema (TIME_WAIT)' } else { $procs[[int]$_.Name] }
                     if (-not $n) { $n = "pid $($_.Name)" }; "$n $($_.Count)" }) -join ', '
        & $add (New-Resultado 'Carga' 'portas efemeras em uso agora' $(if ($pct -ge 50) { 'aviso' } else { 'ok' }) `
            "$emUso de $qtd TCP ($pct%); sockets TCP $($tcp.Count), UDP $($udp.Count); mais sockets: $top")
    } catch { }

    $esgot = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Tcpip'; Id = 4266, 4231
                                                StartTime = (Get-Date).AddDays(-7) } -ErrorAction SilentlyContinue)
    if ($esgot.Count) {
        $u = @($esgot | Where-Object Id -eq 4266).Count
        & $add (New-Resultado 'Historico' 'portas efemeras esgotadas (7 dias)' 'aviso' `
            ("$($esgot.Count)x (UDP $u, TCP $($esgot.Count - $u)); ultima em $($esgot[0].TimeCreated.ToString('yyyy-MM-dd HH:mm')). " +
             'Enquanto dura, a maquina parece offline no RustDesk'))
    } else {
        & $add (New-Resultado 'Historico' 'portas efemeras esgotadas (7 dias)' 'ok' 'nenhuma vez')
    }

    $quedas = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-NetworkProfile/Operational'; Id = 10001
                                                 StartTime = (Get-Date).AddDays(-1) } -ErrorAction SilentlyContinue)
    & $add (New-Resultado 'Historico' 'desconexoes de rede (24 h)' $(if ($quedas.Count -ge 3) { 'aviso' } else { 'ok' }) `
        $(if ($quedas.Count) { "$($quedas.Count)x; ultima em $($quedas[0].TimeCreated.ToString('yyyy-MM-dd HH:mm'))" } else { 'nenhuma' }))

    $dnsFalhas = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-DNS-Client'; Id = 1014
                                                    StartTime = (Get-Date).AddDays(-1) } -ErrorAction SilentlyContinue)
    & $add (New-Resultado 'Historico' 'timeouts de DNS (24 h)' $(if ($dnsFalhas.Count -ge 20) { 'aviso' } else { 'ok' }) `
        "$($dnsFalhas.Count)x - alguns por dia sao normais (nomes que nao existem, rede subindo)")

    [ordered]@{
        maquina  = $env:COMPUTERNAME
        inicio   = $inicio.ToString('yyyy-MM-dd HH:mm:ss')
        segundos = [Math]::Round(((Get-Date) - $inicio).TotalSeconds, 1)
        itens    = @($res)
    }
}

if ($Json) {
    Invoke-NetworkCheck | ConvertTo-Json -Depth 5
    return
}

# --- pagina ------------------------------------------------------------
# A pagina vive em network-check.html, ao lado deste script. Aberta direto no
# navegador ela so explica que precisa deste script: sem ele nao ha quem rode
# ping, DNS e firewall.

$pagina = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'network-check.html'), [Text.Encoding]::UTF8)

# --- servidor ----------------------------------------------------------
# TcpListener em vez de HttpListener: este nao exige reserva de URL (netsh http
# add urlacl) nem Administrador. So o loopback: ninguem na rede alcanca.

$token = -join ((1..32) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
$html  = [Text.Encoding]::UTF8.GetBytes($pagina.Replace('__TOKEN__', $token))

function Send-Resposta($stream, [int]$codigo, [string]$tipo, [byte[]]$corpo) {
    $motivo = @{ 200 = 'OK'; 403 = 'Forbidden'; 404 = 'Not Found'; 500 = 'Internal Server Error' }[$codigo]
    $cab = "HTTP/1.1 $codigo $motivo`r`nContent-Type: $tipo`r`nContent-Length: $($corpo.Length)`r`n" +
           "Cache-Control: no-store`r`nX-Content-Type-Options: nosniff`r`nConnection: close`r`n`r`n"
    $b = [Text.Encoding]::ASCII.GetBytes($cab)
    $stream.Write($b, 0, $b.Length)
    if ($corpo.Length) { $stream.Write($corpo, 0, $corpo.Length) }
    $stream.Flush()
}

$listener = New-Object System.Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), $Port
$listener.Start()
$porta = $listener.LocalEndpoint.Port
$url   = "http://127.0.0.1:$porta/?t=$token"
Write-Host "Pagina: $url"
Write-Host 'Encerre pelo botao da pagina ou com Ctrl+C.' -ForegroundColor DarkGray
if (-not $NoBrowser) { Start-Process $url }

$ultimoUso = Get-Date
$rodando   = $true
try {
    while ($rodando) {
        if (-not $listener.Pending()) {
            if (((Get-Date) - $ultimoUso).TotalMinutes -ge $IdleMinutes) {
                Write-Host "Sem uso ha $IdleMinutes min - encerrando."
                break
            }
            Start-Sleep -Milliseconds 100
            continue
        }
        $cli = $listener.AcceptTcpClient()
        try {
            $s = $cli.GetStream()
            # O navegador abre conexoes especulativas que nunca mandam nada;
            # sem este limite uma delas travaria o laco.
            $s.ReadTimeout = 1500
            $buf = New-Object byte[] 8192; $lido = 0; $req = ''
            while ($lido -lt $buf.Length) {
                $n = $s.Read($buf, $lido, $buf.Length - $lido)
                if ($n -le 0) { break }
                $lido += $n
                $req = [Text.Encoding]::ASCII.GetString($buf, 0, $lido)
                if ($req.Contains("`r`n`r`n")) { break }
            }
            if ($req -notmatch '^GET (\S+) HTTP/') { continue }
            $alvo = $Matches[1]
            # Host fixo barra DNS rebinding; o token barra outra pagina local.
            $hostOk  = $req -match "(?im)^Host:\s*127\.0\.0\.1:$porta\s*$"
            $tokenOk = $alvo -match "[?&]t=$token(&|$)"
            $rota    = ($alvo -split '\?')[0]
            if (-not $hostOk -or ($rota -ne '/favicon.ico' -and -not $tokenOk)) {
                Send-Resposta $s 403 'text/plain' ([Text.Encoding]::ASCII.GetBytes('forbidden'))
                continue
            }
            $ultimoUso = Get-Date
            switch ($rota) {
                '/' { Send-Resposta $s 200 'text/html; charset=utf-8' $html }
                '/check' {
                    Write-Host "$(Get-Date -Format HH:mm:ss) analisando..." -ForegroundColor DarkGray
                    try {
                        $j = Invoke-NetworkCheck | ConvertTo-Json -Depth 5 -Compress
                        Send-Resposta $s 200 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($j))
                    } catch {
                        Send-Resposta $s 500 'text/plain' ([Text.Encoding]::UTF8.GetBytes($_.Exception.Message))
                    }
                }
                '/quit' {
                    Send-Resposta $s 200 'text/plain' ([Text.Encoding]::ASCII.GetBytes('ok'))
                    $rodando = $false
                }
                default { Send-Resposta $s 404 'text/plain' ([Text.Encoding]::ASCII.GetBytes('not found')) }
            }
        } catch {
            # Conexao que caiu ou nao mandou nada: ignora e segue atendendo.
        } finally {
            $cli.Close()
        }
    }
} finally {
    $listener.Stop()
    Write-Host 'Servidor encerrado.'
}
