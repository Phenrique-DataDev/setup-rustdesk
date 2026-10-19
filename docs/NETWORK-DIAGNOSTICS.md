# Diagnostico de rede

Este guia gera um retrato somente leitura da rede do Windows sob o ponto de
vista do RustDesk. O objetivo e produzir evidencia suficiente para responder:

- o adaptador, gateway, DNS e IPv4/IPv6 estao saudaveis;
- o firewall permite o RustDesk nos perfis ativos;
- o rendezvous e os caminhos TCP conhecidos estao acessiveis;
- o RustDesk esta rodando e escutando na porta direta;
- ha desconexoes, timeouts de DNS ou exaustao de portas efemeras;
- algum processo esta concentrando sockets;
- os logs mostram punch direto, IPv6 ou fallback para relay.

O procedimento **nao altera** firewall, DNS, adaptadores, rotas, servicos,
configuracao do RustDesk ou faixa de portas. Ele pode ser executado sem
Administrador, mas a leitura do log do servico e de tarefas SYSTEM pode ficar
incompleta sem elevacao.

## Execucao rapida

Abra PowerShell na raiz do repositorio e rode:

```powershell
New-Item -ItemType Directory -Path .\diagnostics -Force | Out-Null
.\scripts\Show-NetworkCheck.ps1 -Json |
    Tee-Object -FilePath .\diagnostics\network-check.json
```

O JSON e a fonte principal para latencia, DNS, rendezvous, firewall do
RustDesk, servico, trafego, portas efemeras e desconexoes recentes.

Para o relatorio amplo de energia, rede, tarefas e logs:

```powershell
.\scripts\Get-PowerDiagnostics.ps1 -NoHtmlReports |
    Tee-Object -FilePath .\diagnostics\power-network-diagnostics.txt
```

Os arquivos em `diagnostics\` sao artefatos locais e nao devem ser commitados.
Apague-os depois de compartilhar o resultado, se nao forem necessarios:

```powershell
Remove-Item .\diagnostics\network-check.json, .\diagnostics\power-network-diagnostics.txt -Force
```

## Coleta completa para uma LLM

Quando for necessario um resultado equivalente ao diagnostico operacional do
repositorio, execute os blocos abaixo em PowerShell. Eles nao devem ser
substituidos por `Setup.ps1 -All`, `-Configure`, `-Watchdog`, `-Power` ou
qualquer outro passo que altere o sistema.

### 1. Estado basico da rede

```powershell
Write-Output '=== ADAPTERS ==='
Get-NetAdapter -IncludeHidden |
    Sort-Object ifIndex |
    Format-Table ifIndex,Name,Status,LinkSpeed,MacAddress,InterfaceDescription -AutoSize

Write-Output '=== IP CONFIG ==='
Get-NetIPConfiguration | Format-List

Write-Output '=== PROFILES ==='
Get-NetConnectionProfile |
    Format-Table Name,InterfaceAlias,NetworkCategory,IPv4Connectivity,IPv6Connectivity -AutoSize

Write-Output '=== DNS ==='
Get-DnsClientServerAddress -AddressFamily IPv4,IPv6 |
    Format-Table InterfaceAlias,AddressFamily,ServerAddresses -AutoSize

Write-Output '=== DEFAULT ROUTES ==='
Get-NetRoute -AddressFamily IPv4,IPv6 -ErrorAction SilentlyContinue |
    Where-Object { $_.DestinationPrefix -in @('0.0.0.0/0','::/0') } |
    Format-Table ifIndex,InterfaceAlias,DestinationPrefix,NextHop,RouteMetric,State -AutoSize
```

Identifique o adaptador ativo com gateway padrão. Registre velocidade do link,
perfil (`Public`, `Private` ou `Domain`), conectividade IPv4/IPv6, gateway e
servidores DNS. Um perfil `Public` nao e falha por si so; o que importa e a
regra explicita do RustDesk cobrir os perfis ativos.

### 2. Firewall efetivo do RustDesk

Use a associação pelo filtro de aplicação. Fazer `Get-NetFirewallRule |
Where-Object` nao e suficiente para provar que a regra vale para o executavel.

```powershell
$rustDeskExe = 'C:\Program Files\RustDesk\RustDesk.exe'
$appFilters = @(Get-NetFirewallApplicationFilter -Program $rustDeskExe -ErrorAction SilentlyContinue)
$rustDeskRules = @(
    foreach ($filter in $appFilters) {
        Get-NetFirewallRule -AssociatedNetFirewallApplicationFilter $filter `
            -ErrorAction SilentlyContinue
    }
)

Write-Output '=== FIREWALL PROFILES ==='
Get-NetFirewallProfile |
    Format-Table Name,Enabled,DefaultInboundAction,DefaultOutboundAction,
        AllowInboundRules,AllowLocalFirewallRules -AutoSize

Write-Output '=== RUSTDESK RULES ==='
$rustDeskRules |
    Select-Object DisplayName,Enabled,Direction,Action,Profile,
        PolicyStoreSource,PrimaryStatus,Status |
    Sort-Object DisplayName,Direction |
    Format-Table -AutoSize

Write-Output '=== RUSTDESK BLOCK RULES ==='
Get-NetFirewallRule -Enabled True -Direction Inbound,Outbound -Action Block `
    -ErrorAction SilentlyContinue |
    ForEach-Object {
        $rule = $_
        $filters = @($rule | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue)
        if ($filters.Program -contains $rustDeskExe) {
            $rule | Select-Object DisplayName,Direction,Profile,PolicyStoreSource
        }
    } |
    Format-Table -AutoSize
```

Resultado saudavel: regra `RustDesk Service` ativa, `Allow`, `Inbound` e
`Outbound`, com perfil `Any` ou cobrindo todos os perfis ativos. Uma regra
`Block` efetiva para o executavel vence o `Allow` e precisa ser investigada.

### 3. DNS, gateway e rendezvous

```powershell
Write-Output '=== PING GATEWAY/INTERNET ==='
$gateway = (Get-NetIPConfiguration |
    Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
    Select-Object -First 1).IPv4DefaultGateway.NextHop
foreach ($hostName in @($gateway,'1.1.1.1','8.8.8.8')) {
    if ($hostName) {
        Test-Connection -ComputerName $hostName -Count 10 -ErrorAction SilentlyContinue
    }
}

Write-Output '=== RUSTDESK DNS ==='
Resolve-DnsName rs-ny.rustdesk.com -Type A_AAAA -DnsOnly -ErrorAction Continue |
    Select-Object Name,Type,IPAddress,TTL |
    Format-Table -AutoSize

Write-Output '=== RUSTDESK TCP ==='
foreach ($port in 21116,21117,21118) {
    Test-NetConnection rs-ny.rustdesk.com -Port $port `
        -InformationLevel Detailed -WarningAction SilentlyContinue |
        Select-Object ComputerName,RemoteAddress,RemotePort,
            TcpTestSucceeded,PingSucceeded,Latency
}
```

O teste TCP 21116 comprova alcance ao rendezvous público. A porta 21117 pode
nao aceitar conexao no host publico escolhido e isso, sozinho, nao prova
bloqueio: o relay e escolhido pelo rendezvous. A porta 21118 e relevante para
WebSocket/direto conforme o endpoint consultado, mas nao substitui o teste de
conexao real entre dois clientes.

### 4. Servico, porta direta e configuracao instalada

```powershell
Write-Output '=== RUSTDESK SERVICE ==='
Get-Service rustdesk -ErrorAction SilentlyContinue |
    Format-List Name,Status,StartType

Write-Output '=== RUSTDESK PROCESS ==='
Get-Process rustdesk -ErrorAction SilentlyContinue |
    Select-Object Id,ProcessName,Path,StartTime |
    Format-Table -AutoSize

Write-Output '=== RUSTDESK LISTENERS ==='
$rustDeskPids = @(Get-Process rustdesk -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty Id)
Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
    Where-Object { $_.OwningProcess -in $rustDeskPids } |
    Format-Table LocalAddress,LocalPort,RemoteAddress,OwningProcess -AutoSize

Write-Output '=== INSTALLED NETWORK OPTIONS ==='
foreach ($file in @(
    "$env:APPDATA\RustDesk\config\RustDesk.toml",
    "$env:APPDATA\RustDesk\config\RustDesk2.toml"
)) {
    Write-Output "--- $file ---"
    if (Test-Path -LiteralPath $file) {
        Select-String -LiteralPath $file -Pattern `
            'enable-tcp-punch|enable-udp-punch|enable-ipv6-punch|disable-udp|allow-insecure-tls-fallback|direct-server|direct-access-port|enable-lan-discovery|custom-rendezvous-server|relay-server'
    } else {
        Write-Output 'missing'
    }
}
```

No setup deste repositorio, as opcoes de NAT punch pertencem ao
`RustDesk.toml` (`LocalConfig`), enquanto `direct-server`,
`direct-access-port` e `enable-lan-discovery` pertencem ao `RustDesk2.toml`
(`Config`). Uma chave no arquivo errado pode ser ignorada sem erro.

### 5. Portas efemeras e processos

```powershell
Write-Output '=== TCP STATES ==='
Get-NetTCPConnection -ErrorAction SilentlyContinue |
    Group-Object State |
    Sort-Object Count -Descending |
    Format-Table Count,Name -AutoSize

Write-Output '=== TCP BY PROCESS ==='
Get-NetTCPConnection -ErrorAction SilentlyContinue |
    Group-Object OwningProcess,State |
    Sort-Object Count -Descending |
    Select-Object -First 30 |
    ForEach-Object {
        $parts = $_.Name -split ', '
        $process = Get-Process -Id ([int]$parts[0]) -ErrorAction SilentlyContinue
        [pscustomobject]@{
            Count = $_.Count
            PID = $parts[0]
            Process = if ($process) { $process.ProcessName } else { '?' }
            State = $parts[1]
        }
    } |
    Format-Table -AutoSize

Write-Output '=== UDP BY PROCESS ==='
Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
    Group-Object OwningProcess |
    Sort-Object Count -Descending |
    Select-Object -First 25 |
    ForEach-Object {
        $process = Get-Process -Id ([int]$_.Name) -ErrorAction SilentlyContinue
        [pscustomobject]@{
            Count = $_.Count
            PID = $_.Name
            Process = if ($process) { $process.ProcessName } else { '?' }
        }
    } |
    Format-Table -AutoSize

Write-Output '=== DYNAMIC PORTS ==='
netsh int ipv4 show dynamicport tcp
netsh int ipv4 show dynamicport udp
netsh int ipv4 show excludedportrange protocol=tcp
netsh int ipv4 show excludedportrange protocol=udp

Write-Output '=== EXHAUSTION EVENTS ==='
Get-WinEvent -FilterHashtable @{
    LogName = 'System'
    ProviderName = 'Tcpip'
    Id = 4231,4266
    StartTime = (Get-Date).AddDays(-30)
} -ErrorAction SilentlyContinue |
    Sort-Object TimeCreated |
    Select-Object TimeCreated,Id,Message |
    Format-List
```

O ID `4231` indica exaustao TCP; `4266`, UDP. Nao conclua pelo snapshot atual:
o processo causador pode ja ter fechado os sockets. O dado decisivo e um
snapshot capturado durante o evento.

## Monitoramento do proximo evento

Quando houver eventos recorrentes, mantenha este coletor somente leitura em
uma janela administrativa. Ele cria snapshots locais quando aparece um novo
`4231` ou `4266`:

```powershell
$out = Join-Path $env:TEMP "rustdesk-port-watch-$((Get-Date).ToString('yyyyMMdd-HHmmss'))"
New-Item -ItemType Directory -Path $out -Force | Out-Null
$last = 0
while ($true) {
    $events = @(Get-WinEvent -FilterHashtable @{
        LogName = 'System'; ProviderName = 'Tcpip'; Id = 4231,4266
    } -MaxEvents 20 -ErrorAction SilentlyContinue | Sort-Object RecordId)
    $new = @($events | Where-Object { $_.RecordId -gt $last })
    if ($new.Count) {
        $last = ($events | Select-Object -Last 1).RecordId
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $new | Select-Object TimeCreated,Id,Message |
            Out-File (Join-Path $out "$stamp-events.txt") -Encoding utf8
        Get-NetTCPConnection -ErrorAction SilentlyContinue |
            Export-Csv (Join-Path $out "$stamp-tcp.csv") -NoTypeInformation
        Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
            Export-Csv (Join-Path $out "$stamp-udp.csv") -NoTypeInformation
        Write-Host "snapshot gravado: $stamp"
    }
    Start-Sleep -Seconds 5
}
```

Interrompa com `Ctrl+C`. Compare os CSVs por `OwningProcess`, resolva os PIDs
com `Get-Process -Id <PID>` e ajuste primeiro os limites da aplicação que
causar o pico. Nao aumente a faixa global de portas antes dessa correlação.

## Como a LLM deve interpretar o resultado

Ao enviar os resultados para uma LLM, inclua:

1. o JSON de `Show-NetworkCheck.ps1 -Json`;
2. o texto de `Get-PowerDiagnostics.ps1 -NoHtmlReports`;
3. os blocos de firewall, DNS, servico/listeners e portas efemeras;
4. todos os eventos `4231/4266` dos ultimos 30 dias;
5. snapshots do monitor, se existirem;
6. data, hora, se o PowerShell estava elevado e qual conexao estava em uso.

Peça a resposta nesta ordem:

1. fatos observados, separados de hipoteses;
2. bloqueios efetivos de firewall ou DNS;
3. evidencia de P2P, IPv6, relay e latencia;
4. processo provavelmente responsavel por exaustao de portas;
5. correcoes reversiveis e especificas da aplicacao;
6. mudancas globais do Windows somente se houver evidencia;
7. comandos de alteracao separados e explicitamente marcados como
   **nao executar sem aprovacao**.

Nunca inclua senhas, `RustDesk.toml`, `RustDesk2.toml` completos, tokens ou
arquivos `.bak`/`.log` integrais. Para o RustDesk, envie apenas as linhas de
opcoes de rede e trechos de log sem credenciais.
