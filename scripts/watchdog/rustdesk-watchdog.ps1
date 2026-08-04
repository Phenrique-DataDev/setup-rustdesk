<#
.SYNOPSIS
    Watchdog do RustDesk: garante servico instalado, rodando e habilitado.

.DESCRIPTION
    Roda como SYSTEM via tarefa agendada, a cada N minutos. Verifica, nesta ordem:
      1. o binario existe;
      2. o servico existe (reinstala se sumiu);
      3. o servico esta Running (inicia se caiu);
      4. o StartType e Automatic;
      5. nenhuma das configs tem stop-service = 'Y'.

    O item 5 importa porque um servico "OK" com stop-service = 'Y' na config
    recusa conexoes: o acesso remoto fica morto com todos os indicadores verdes.

    Instalado por scripts/Install-Watchdog.ps1, que substitui os marcadores
    __TOKEN__ pelos caminhos reais da maquina.
#>

$exe       = '__EXE__'
$logFile   = '__LOGFILE__'
$cfgFiles  = @(__CFGFILES__)
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

Write-Log 'Watchdog iniciado.'

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
    Set-Service -Name rustdesk -StartupType Automatic
    Write-Log 'StartType corrigido para Automatic.'
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

$svc    = Get-Service -Name rustdesk -ErrorAction SilentlyContinue
$status = if ($svc) { $svc.Status } else { 'NAO INSTALADO' }
Write-Log "Status final: $status"
