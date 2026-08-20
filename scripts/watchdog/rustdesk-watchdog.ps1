<#
.SYNOPSIS
    Watchdog do RustDesk: garante servico instalado, rodando e habilitado.

.DESCRIPTION
    Roda como SYSTEM via tarefa agendada, a cada N minutos. Verifica, nesta ordem:
      1. o binario existe;
      2. o servico existe (reinstala se sumiu);
      3. o servico esta Running (inicia se caiu);
      4. o StartType e Automatic;
      5. nenhuma das configs tem stop-service = 'Y';
      6. o servico enxerga o IPv6 (so quando a maquina tem IPv6 global).

    O item 5 importa porque um servico "OK" com stop-service = 'Y' na config
    recusa conexoes: o acesso remoto fica morto com todos os indicadores verdes.

    O item 6 existe por uma corrida no boot: o servico e AUTO_START e sobe
    antes de o Router Advertisement completar, entao falha ao resolver os STUN
    IPv6 e segue SEM IPv6 ate alguem reinicia-lo. Como IPv6 nao tem NAT, perder
    isso significa perder o caminho que dispensa hole punching.

    O reinicio e deliberadamente conservador - ele derruba sessao ativa:
      - so age se a maquina TEM IPv6 global agora (senao reiniciaria para
        sempre, a cada passada, numa rede que nunca vai ter IPv6);
      - no maximo UMA vez por epoca, marcado em disco. Epoca = ultimo boot
        MAIS ultimo resume de suspensao: num notebook, que suspende varias
        vezes por dia sem reiniciar, so o boot faria uma recusa gravada de
        manha valer ate o dia seguinte. Com Fast Startup ligado o problema e
        pior ainda - desligar e ligar nao avanca o LastBootUpTime;
      - nunca com sessao remota em curso (processo --cm no ar).

    Instalado por scripts/Install-Watchdog.ps1, que substitui os marcadores
    __TOKEN__ pelos caminhos reais da maquina.
#>

$exe       = '__EXE__'
$logFile   = '__LOGFILE__'
$cfgFiles  = @(__CFGFILES__)
$svcLogDir = '__SVCLOGDIR__'
$maxLogMB  = 1
$keepLines = 2000

function Write-Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $msg"
    # mutex nomeado: duas instancias do watchdog nao corrompem o log
    $mtx  = New-Object System.Threading.Mutex($false, 'Global\RustDeskWatchdogLog')
    $held = $false
    try {
        $held = $mtx.WaitOne(5000)
        Add-Content -Path $logFile -Value $line -Encoding UTF8
        $item = Get-Item $logFile -ErrorAction SilentlyContinue
        if ($item -and $item.Length -gt ($maxLogMB * 1MB)) {
            $old = Get-Content $logFile -Tail $keepLines
            $tmp = "$logFile.tmp"
            Set-Content $tmp -Value $old -Encoding UTF8
            Move-Item $tmp $logFile -Force
        }
    } finally {
        if ($held) { $mtx.ReleaseMutex() }
        $mtx.Dispose()
    }
}

function Get-LastResume {
    # Kernel-Power 107 e o resume; Power-Troubleshooter 1 e o fallback.
    # Devolve $null em maquina que nunca suspendeu.
    foreach ($f in @(
        @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power';         Id = 107 },
        @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Power-Troubleshooter'; Id = 1 }
    )) {
        try {
            $ev = Get-WinEvent -FilterHashtable $f -MaxEvents 1 -ErrorAction Stop
            if ($ev) { return $ev.TimeCreated }
        } catch { }
    }
    return $null
}

function Get-EpochStamp {
    # Carimbo de "uma tentativa por epoca". Boot sozinho nao serve em portatil.
    $boot = try { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o') } catch { '-' }
    $r    = Get-LastResume
    $rs   = if ($r) { $r.ToString('o') } else { '-' }
    return "$boot|$rs"
}

Write-Log 'Watchdog iniciado.'

# Sem esta linha, ler o log depois de um problema nao permite distinguir
# "nunca dormiu" de "acordou tres vezes".
$ultimoResume = Get-LastResume
if ($ultimoResume) {
    $ha = [int]((Get-Date) - $ultimoResume).TotalMinutes
    Write-Log "Ultimo retorno de suspensao: $($ultimoResume.ToString('yyyy-MM-dd HH:mm:ss')) (ha $ha min)."
}

if (-not (Test-Path $exe)) {
    Write-Log "ERRO: $exe nao encontrado. Watchdog encerrado."
    exit 1
}

$svc = Get-Service -Name rustdesk -ErrorAction SilentlyContinue

if (-not $svc) {
    Write-Log 'Servico nao encontrado. Reinstalando...'
    $p = Start-Process -FilePath $exe -ArgumentList '--install-service' -Wait -PassThru
    Write-Log "install-service exit: $($p.ExitCode)"
    Start-Sleep -Seconds 5
    $svc = Get-Service -Name rustdesk -ErrorAction SilentlyContinue
}

if ($svc -and $svc.Status -ne 'Running') {
    Write-Log "Servico parado ($($svc.Status)). Iniciando..."
    Start-Service -Name rustdesk -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5
    $svc.Refresh()
    Write-Log "Status apos Start-Service: $($svc.Status)"
}

if ($svc -and $svc.StartType -ne 'Automatic') {
    Write-Log "StartType incorreto ($($svc.StartType)). Corrigindo..."
    Set-Service -Name rustdesk -StartupType Automatic -ErrorAction SilentlyContinue
    # Reconsultar em vez de anunciar: este script roda como SYSTEM, sem
    # ninguem olhando, e o log e a unica evidencia. Um "corrigido" que nao
    # corrigiu esconde justamente a falha que o watchdog existe para pegar.
    $novo = (Get-Service -Name rustdesk -ErrorAction SilentlyContinue).StartType
    if ($novo -eq 'Automatic') {
        Write-Log 'StartType corrigido para Automatic.'
    } else {
        Write-Log "ERRO: StartType continua $novo apos Set-Service."
    }
}

foreach ($cfg in $cfgFiles) {
    if (-not (Test-Path $cfg)) { continue }
    $linhas = Get-Content $cfg
    $achou  = $false
    $novo   = $linhas | ForEach-Object {
        if ($_ -match "^\s*stop-service\s*=\s*'Y'\s*$") { $achou = $true; "stop-service = 'N'" } else { $_ }
    }
    if ($achou) {
        Write-Log "AVISO: stop-service = 'Y' em $cfg (acesso remoto desabilitado). Corrigindo."
        Copy-Item $cfg "$cfg.watchdog.bak" -Force
        # UTF-8 SEM BOM com LF: e o formato nativo do RustDesk.
        # Set-Content -Encoding UTF8 no PS 5.1 gravaria BOM e CRLF.
        [System.IO.File]::WriteAllText($cfg, (($novo -join "`n") + "`n"),
            (New-Object System.Text.UTF8Encoding($false)))
        Write-Log "Config corrigida. Backup em $cfg.watchdog.bak"
    }
}

# --- 6. IPv6 visto pelo servico ---------------------------------------
# Ver o cabecalho para o porque. A ordem das guardas importa: cada uma sozinha
# ja evita um modo de falha diferente, e a mais barata vem primeiro.
if ($svcLogDir -and (Test-Path $svcLogDir)) {
    $temIPv6Global = [bool](Get-NetIPAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue |
        Where-Object { $_.PrefixOrigin -in @('RouterAdvertisement', 'Dhcp', 'Manual') -and
                       $_.IPAddress -notmatch '^(fe80|::1)' -and $_.AddressState -eq 'Preferred' })

    if ($temIPv6Global) {
        $serverDir = Join-Path $svcLogDir 'server'
        $ultimo = Get-ChildItem $serverDir -Filter *.log -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending | Select-Object -First 1

        if ($ultimo) {
            # Le so o log da inicializacao mais recente: um sucesso de tres dias
            # atras nao diz nada sobre o estado atual do servico.
            $linhas = Get-Content -LiteralPath $ultimo.FullName -ErrorAction SilentlyContinue
            $achouIPv6  = [bool]($linhas | Select-String -Pattern 'Found public IPv6 address' -Quiet)
            $falhouIPv6 = [bool]($linhas | Select-String -Pattern 'Failed to (get public IPv6|bind IPv6)' -Quiet)

            if ($falhouIPv6 -and -not $achouIPv6) {
                # Uma vez por epoca. Sem isto, um STUN fora do ar viraria um
                # reinicio a cada passada do watchdog, para sempre. A epoca
                # inclui o ultimo resume, e nao so o boot: num notebook a
                # guarda por boot viraria uma trava permanente ate reiniciar.
                $stamp      = "$logFile.ipv6-restart"
                $epocaAtual = Get-EpochStamp
                $jaTentou   = (Test-Path $stamp) -and
                              ((Get-Content $stamp -ErrorAction SilentlyContinue | Select-Object -First 1) -eq $epocaAtual)

                # Reiniciar derruba quem estiver conectado. O connection manager
                # (--cm) so existe enquanto ha sessao remota.
                $emSessao = [bool](Get-CimInstance Win32_Process -Filter "Name='rustdesk.exe'" -ErrorAction SilentlyContinue |
                                   Where-Object { $_.CommandLine -match '--cm' })

                if ($jaTentou) {
                    Write-Log 'Servico sem IPv6, mas ja foi reiniciado por isso nesta sessao (mesmo boot e mesmo resume). Nao insistindo.'
                } elseif ($emSessao) {
                    Write-Log 'Servico sem IPv6, mas ha sessao remota ativa. Adiando para a proxima passada.'
                } else {
                    Write-Log 'Servico subiu sem IPv6 (corrida no boot) e a maquina tem IPv6 global. Reiniciando.'
                    Set-Content -LiteralPath $stamp -Value $epocaAtual -Encoding ASCII
                    Restart-Service -Name rustdesk -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 12

                    $novoLog = Get-ChildItem $serverDir -Filter *.log -ErrorAction SilentlyContinue |
                               Sort-Object LastWriteTime -Descending | Select-Object -First 1
                    $ok = $novoLog -and (Select-String -LiteralPath $novoLog.FullName `
                            -Pattern 'Found public IPv6 address' -Quiet)
                    # Reconsultar em vez de anunciar, como no item 4.
                    if ($ok) { Write-Log 'IPv6 recuperado apos o reinicio.' }
                    else     { Write-Log 'AVISO: servico continua sem IPv6 apos o reinicio.' }
                }
            }
        }
    }
}

$svc    = Get-Service -Name rustdesk -ErrorAction SilentlyContinue
$status = if ($svc) { $svc.Status } else { 'NAO INSTALADO' }
Write-Log "Status final: $status"
