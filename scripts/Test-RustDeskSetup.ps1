<#
.SYNOPSIS
    Valida a stack inteira: RustDesk (binario, servico, watchdog, as DUAS
    configs) e Herdr (binario, config, servidor no ar, autostart).

.DESCRIPTION
    Cada verificacao vira uma linha PASS / FALHA / AVISO. Sai com codigo 1 se
    houver qualquer FALHA, para poder ser usado em automacao.

    Somente leitura: nao altera nada. Roda sem elevacao, mas as verificacoes
    da config do servico exigem Administrador (o diretorio e protegido) e
    aparecem como AVISO quando nao ha privilegio. A parte do Herdr mora no
    perfil do usuario e e verificada sem elevacao.

.PARAMETER ShowLogs
    Inclui as ultimas linhas dos logs do RustDesk e do Herdr.

.PARAMETER SkipHerdr
    Nao verifica a metade Herdr da stack.
#>
[CmdletBinding()]
param(
    [string]$ConfigFile,
    [string]$HerdrConfigFile,
    [switch]$SkipHerdr,
    [switch]$ShowLogs
)

$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot '..\lib\RustDeskCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\lib\RustDeskToml.psm1')   -Force

$script:falhas         = 0
$script:avisos         = 0
$script:senhaFaltando  = $false
$script:senhaFp        = @{}
$script:senhaMtime     = @{}

# Impressao digital de um campo do .toml: identifica o VALOR sem revela-lo, para
# poder comparar os dois perfis numa saida que o usuario pode colar em qualquer
# lugar. 12 hex chars bastam para comparar dois valores; nao servem para
# recuperar o original (que ja e hash+salt de qualquer forma).
function Get-FieldFingerprint([string]$Path, [string]$Key) {
    $linha = Select-String -LiteralPath $Path -Pattern "^\s*$Key\s*=" |
             Select-Object -First 1 -ExpandProperty Line
    if (-not $linha) { return '<ausente>' }
    $valor = ($linha -split '=', 2)[1].Trim()
    if ($valor -match "^''$|^`"`"$") { return '<vazio>' }
    $bytes = [Text.Encoding]::UTF8.GetBytes($valor)
    ([BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($bytes)) -replace '-', '').Substring(0, 12)
}

function Test-Item($nome, $ok, $detalhe = '') {
    if ($ok -eq $true) {
        Write-Host "  [PASS]  $nome" -ForegroundColor Green
    } elseif ($ok -eq 'aviso') {
        Write-Host "  [AVISO] $nome" -ForegroundColor Yellow
        $script:avisos++
    } else {
        Write-Host "  [FALHA] $nome" -ForegroundColor Red
        $script:falhas++
    }
    if ($detalhe) { Write-Host "          $detalhe" -ForegroundColor DarkGray }
}

$paths    = Get-RustDeskPaths
$elevated = Test-Elevated

Write-Host ''
Write-Host '=== Acesso remoto: verificacao do setup (RustDesk + Herdr) ===' -ForegroundColor Cyan
if (-not $elevated) {
    Write-Host '  (sem elevacao: a config do servico nao pode ser lida)' -ForegroundColor Yellow
}
Write-Host ''

# --- binario e servico ------------------------------------------------
Write-Host 'Instalacao' -ForegroundColor Cyan
Test-Item 'rustdesk.exe encontrado' $paths.Installed $paths.Exe

if ($paths.Installed) {
    $pin      = Get-RustDeskPin
    $instalada = Get-RustDeskVersion -Exe $paths.Exe
    if ($pin.Version -eq 'latest') {
        Test-Item 'versao fixada' 'aviso' "config pede 'latest' - instalada: $instalada"
    } else {
        # Divergencia aqui nao quebra o acesso remoto, mas desfaz o proposito do
        # pin: a maquina esta rodando algo diferente do que o repo promete.
        Test-Item "versao instalada bate com o pin ($($pin.Version))" `
            ($instalada -eq $pin.Version) "instalada: $instalada"
    }
}

$svc = Get-Service -Name $paths.ServiceName -ErrorAction SilentlyContinue
Test-Item 'servico rustdesk registrado' ([bool]$svc)
if ($svc) {
    Test-Item 'servico rodando'        ($svc.Status    -eq 'Running')   "status: $($svc.Status)"
    Test-Item 'inicializacao Automatic' ($svc.StartType -eq 'Automatic') "StartType: $($svc.StartType)"
}

if ($elevated -and $svc) {
    $qf = (& sc.exe qfailure $paths.ServiceName) -join ' '
    # a saida do sc.exe e localizada; o numero 5000 (ms) aparece em qualquer idioma
    Test-Item 'recovery do SCM configurado' ($qf -match '5000') 'reinicio automatico apos falha'
}

# --- configs -----------------------------------------------------------
Write-Host ''
Write-Host 'Configuracao' -ForegroundColor Cyan

if (-not $ConfigFile) {
    $custom  = Join-Path $PSScriptRoot '..\config\custom.psd1'
    $default = Join-Path $PSScriptRoot '..\config\default.psd1'
    $ConfigFile = if (Test-Path -LiteralPath $custom) { $custom } else { $default }
}
$esperado = Import-RustDeskConfigFile -Path $ConfigFile
Write-Host "  esperado conforme: $(Split-Path $ConfigFile -Leaf)" -ForegroundColor DarkGray

foreach ($alvo in @(
    @{ Nome = 'usuario'; Arquivo = $paths.UserConfig;    Protegido = $false },
    @{ Nome = 'servico'; Arquivo = $paths.ServiceConfig; Protegido = $true  }
)) {
    Write-Host "  --- config do $($alvo.Nome) ---" -ForegroundColor DarkGray

    if ($alvo.Protegido -and -not $elevated) {
        Test-Item "config do $($alvo.Nome) legivel" 'aviso' 'requer Administrador'
        continue
    }
    if (-not (Test-Path -LiteralPath $alvo.Arquivo)) {
        Test-Item "config do $($alvo.Nome) existe" $false $alvo.Arquivo
        continue
    }

    Test-Item "config do $($alvo.Nome) sem BOM" (-not (Test-TomlBom -Path $alvo.Arquivo)) `
        'o formato nativo do RustDesk e UTF-8 sem BOM'

    foreach ($k in $esperado.Keys) {
        $atual = Get-TomlOption -Path $alvo.Arquivo -Key $k
        Test-Item "$($alvo.Nome): $k = '$($esperado[$k])'" ($atual -eq $esperado[$k]) `
            $(if ($null -eq $atual) { 'ausente do arquivo' } elseif ($atual -ne $esperado[$k]) { "encontrado: '$atual'" } else { '' })
    }
}

# --- opcoes do RustDesk.toml (LocalConfig) ----------------------------
# Arquivo diferente do RustDesk2.toml acima. Uma chave de LocalConfig escrita
# no arquivo errado e ignorada em silencio, entao vale conferir onde ela caiu.
$localFile = Join-Path $PSScriptRoot '..\config\local-custom.psd1'
if (-not (Test-Path -LiteralPath $localFile)) {
    $localFile = Join-Path $PSScriptRoot '..\config\local.psd1'
}
if (Test-Path -LiteralPath $localFile) {
    $esperadoLocal = Import-RustDeskConfigFile -Path $localFile
    if ($esperadoLocal.Count -gt 0) {
        Write-Host "  --- RustDesk.toml (conforme $(Split-Path $localFile -Leaf)) ---" -ForegroundColor DarkGray
        foreach ($alvo in @(
            @{ Nome = 'usuario'; Arquivo = $paths.UserPassword;    Protegido = $false },
            @{ Nome = 'servico'; Arquivo = $paths.ServicePassword; Protegido = $true  }
        )) {
            if ($alvo.Protegido -and -not $elevated) {
                Test-Item "RustDesk.toml do $($alvo.Nome) legivel" 'aviso' 'requer Administrador'
                continue
            }
            if (-not (Test-Path -LiteralPath $alvo.Arquivo)) {
                Test-Item "RustDesk.toml do $($alvo.Nome) existe" 'aviso' 'nasce na primeira execucao naquele perfil'
                continue
            }
            foreach ($k in $esperadoLocal.Keys) {
                $atual = Get-TomlOption -Path $alvo.Arquivo -Key $k
                Test-Item "$($alvo.Nome): $k = '$($esperadoLocal[$k])'" ($atual -eq $esperadoLocal[$k]) `
                    $(if ($null -eq $atual) { 'ausente do arquivo' } elseif ($atual -ne $esperadoLocal[$k]) { "encontrado: '$atual'" } else { '' })
            }
        }
    }
}

# --- senha permanente --------------------------------------------------
# Quem autentica com a tela bloqueada e o servico. Sem senha gravada no perfil
# dele, a conexao bloqueada falha mesmo com todas as opcoes corretas.
Write-Host ''
Write-Host 'Senha permanente' -ForegroundColor Cyan
foreach ($alvo in @(
    @{ Nome = 'usuario'; Arquivo = $paths.UserPassword;    Protegido = $false },
    @{ Nome = 'servico'; Arquivo = $paths.ServicePassword; Protegido = $true  }
)) {
    if ($alvo.Protegido -and -not $elevated) {
        Test-Item "senha do $($alvo.Nome)" 'aviso' 'requer Administrador'
        continue
    }
    if (-not (Test-Path -LiteralPath $alvo.Arquivo)) {
        $script:senhaFaltando = $true
        Test-Item "senha do $($alvo.Nome) gravada" $false 'RustDesk.toml nao existe'
        continue
    }
    $temSenha = [bool](Select-String -LiteralPath $alvo.Arquivo -Pattern "^\s*password\s*=\s*'.+'" -Quiet)
    if (-not $temSenha) { $script:senhaFaltando = $true }
    Test-Item "senha do $($alvo.Nome) gravada" $temSenha `
        $(if (-not $temSenha) { 'defina uma senha permanente na UI do RustDesk' } else { '' })
    if (-not $temSenha) { continue }

    # Presenca nao basta: os dois perfis podem ter senhas DIFERENTES e cada um
    # passar isolado. Quem autentica e o servico, entao divergir significa que a
    # senha que a UI mostra nao e a que valida a conexao. Guarda a impressao
    # digital (SHA-256 truncado do valor gravado, que ja e hash+salt) para
    # comparar depois sem nunca imprimir o segredo.
    $script:senhaFp[$alvo.Nome] = Get-FieldFingerprint -Path $alvo.Arquivo -Key 'password'
    $script:senhaMtime[$alvo.Nome] = (Get-Item -LiteralPath $alvo.Arquivo).LastWriteTime
}

# So da para comparar quando os dois lados foram lidos (exige Administrador).
if ($script:senhaFp.Count -eq 2) {
    $iguais = $script:senhaFp['usuario'] -eq $script:senhaFp['servico']
    Test-Item 'senha identica nos dois perfis' $iguais `
        $(if ($iguais) { "impressao digital: $($script:senhaFp['usuario'])" }
          else { "usuario=$($script:senhaFp['usuario'])  servico=$($script:senhaFp['servico']) - regrave com .\scripts\Set-RustDeskPassword.ps1, que grava via IPC nos dois" })
}

# A data nao e um teste - e o dado que falta quando a senha "esta certa" e mesmo
# assim e recusada. Uma senha de meses atras costuma ser uma que ninguem lembra.
if ($script:senhaMtime.Count -gt 0) {
    $ts   = ($script:senhaMtime.Values | Measure-Object -Maximum -Property Ticks).Maximum
    $data = [datetime]::new($ts)
    $dias = [int]((Get-Date) - $data).TotalDays
    Write-Host "          senha alterada pela ultima vez em $($data.ToString('yyyy-MM-dd HH:mm')) ($dias dia(s) atras)" -ForegroundColor DarkGray
}

# --- watchdog ----------------------------------------------------------
Write-Host ''
Write-Host 'Watchdog' -ForegroundColor Cyan
Test-Item 'script do watchdog instalado' (Test-Path -LiteralPath $paths.WatchdogScript) $paths.WatchdogScript

# Sem elevacao, Get-ScheduledTask devolve vazio para tarefas de SYSTEM em vez
# de negar acesso - um falso negativo silencioso. So afirma ausencia se elevado.
$task = Get-ScheduledTask -TaskName $paths.TaskName -ErrorAction SilentlyContinue
if (-not $task -and -not $elevated) {
    Test-Item 'tarefa agendada registrada' 'aviso' 'requer Administrador para consultar tarefas de SYSTEM'
} else {
    Test-Item 'tarefa agendada registrada' ([bool]$task)
}
if ($task) {
    Test-Item 'tarefa habilitada' ($task.State -ne 'Disabled') "estado: $($task.State)"
    $info = Get-ScheduledTaskInfo -TaskName $paths.TaskName -ErrorAction SilentlyContinue
    if ($info) {
        Write-Host "          ultima execucao: $($info.LastRunTime) (resultado: $($info.LastTaskResult))" -ForegroundColor DarkGray
    }
}

# --- processos ---------------------------------------------------------
Write-Host ''
Write-Host 'Processos' -ForegroundColor Cyan
$procs = @(Get-CimInstance Win32_Process -Filter "Name='rustdesk.exe'" -ErrorAction SilentlyContinue)
Test-Item 'processo do servico (sessao 0) ativo' ([bool](@($procs | Where-Object { $_.SessionId -eq 0 }).Count))
foreach ($p in $procs) {
    $cmd = if ($p.CommandLine) { $p.CommandLine } else { '(sem acesso a linha de comando)' }
    # 'rustdesk --password <senha>' e 'rustdesk --set-unlock-pin <pin>' carregam
    # o segredo em claro na linha de comando. A janela e curta (o processo sai
    # logo), mas se a verificacao cair dentro dela o segredo iria para a tela e
    # para qualquer log que capture esta saida. Redigido antes de imprimir.
    $cmd = $cmd -replace '(--password|--set-unlock-pin)\s+\S+', '$1 <REDIGIDO>'
    Write-Host "          PID $($p.ProcessId) sessao $($p.SessionId)  $cmd" -ForegroundColor DarkGray
}

# um --cm anterior pendurado segura o pipe query_cm e faz o proximo morrer
# com "Acesso negado", o que pode derrubar conexoes novas
$cm = @($procs | Where-Object { $_.CommandLine -like '*--cm*' })
if ($cm.Count -gt 1) {
    Test-Item 'connection managers concorrentes' 'aviso' `
        "$($cm.Count) processos --cm ativos; um deles pode estar orfao segurando o pipe query_cm"
}

# --- Herdr -------------------------------------------------------------
# O RustDesk entrega o transporte; o Herdr e o que mantem o trabalho vivo
# quando ele cai. Uma stack com metade verde nao entrega o que se quer.
$hPaths = Get-HerdrPaths
if (-not $SkipHerdr) {
    Write-Host ''
    Write-Host 'Herdr (terminal da sessao)' -ForegroundColor Cyan
    Test-Item 'herdr.exe encontrado' $hPaths.Installed `
        $(if ($hPaths.Installed) { $hPaths.Exe } else { 'rode .\Setup.ps1 -Herdr' })

    if ($hPaths.Installed) {
        if (-not $HerdrConfigFile) {
            $hCustom  = Join-Path $PSScriptRoot '..\config\herdr-custom.psd1'
            $hDefault = Join-Path $PSScriptRoot '..\config\herdr.psd1'
            $HerdrConfigFile = if (Test-Path -LiteralPath $hCustom) { $hCustom } else { $hDefault }
        }
        Write-Host "  esperado conforme: $(Split-Path $HerdrConfigFile -Leaf)" -ForegroundColor DarkGray

        if (-not (Test-Path -LiteralPath $hPaths.Config)) {
            Test-Item 'config.toml do Herdr existe' $false $hPaths.Config
        } else {
            Test-Item 'config.toml do Herdr sem BOM' (-not (Test-TomlBom -Path $hPaths.Config)) `
                'mesma armadilha do .toml do RustDesk'

            $hEsperado = Import-RustDeskConfigFile -Path $HerdrConfigFile
            foreach ($secao in ($hEsperado.Keys | Sort-Object)) {
                foreach ($k in ($hEsperado[$secao].Keys | Sort-Object)) {
                    # o arquivo guarda o literal TOML (true, 10485760, "hidden"),
                    # entao a comparacao e feita no literal, nao no valor do psd1
                    $lit   = ConvertTo-TomlLiteral -Value $hEsperado[$secao][$k]
                    $atual = Get-TomlSectionValue -Path $hPaths.Config -Section $secao -Key $k
                    Test-Item "[$secao] $k = $lit" ($atual -eq $lit) `
                        $(if ($null -eq $atual) { 'ausente do arquivo' } elseif ($atual -ne $lit) { "encontrado: $atual" } else { '' })
                }
            }
        }

        # o servidor e o ponto inteiro do Herdr aqui: sem ele, a queda da
        # conexao leva o trabalho junto
        Test-Item 'servidor do Herdr no ar' $(if (Test-HerdrServer) { $true } else { 'aviso' }) `
            $(if (Test-HerdrServer) { '' } else { 'suba com "herdr server" ou faca logoff/logon' })

        # Get-ScheduledTask so enxerga tarefas do proprio usuario sem elevacao -
        # esta e do usuario, entao a consulta e confiavel aqui.
        $hTask = Get-ScheduledTask -TaskName $hPaths.TaskName -ErrorAction SilentlyContinue
        Test-Item 'autostart do servidor no logon' $(if ($hTask) { $true } else { 'aviso' }) `
            $(if ($hTask) { "tarefa '$($hPaths.TaskName)': $($hTask.State)" } else { "tarefa '$($hPaths.TaskName)' ausente - rode .\Setup.ps1 -Herdr" })
    }
}

# --- logs --------------------------------------------------------------
if ($ShowLogs) {
    Write-Host ''
    Write-Host 'Logs recentes' -ForegroundColor Cyan
    $dirs = @($paths.UserLogDir)
    if ($elevated) { $dirs += $paths.ServiceLogDir }
    if (-not $SkipHerdr -and (Test-Path -LiteralPath $hPaths.ConfigDir)) { $dirs += $hPaths.ConfigDir }
    foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        Get-ChildItem -LiteralPath $d -Recurse -Filter '*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-2) } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 3 | ForEach-Object {
                Write-Host "  >>> $($_.FullName)" -ForegroundColor DarkGray
                Get-Content -LiteralPath $_.FullName -Tail 8 |
                    ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
            }
    }
}

# --- resumo ------------------------------------------------------------
Write-Host ''
if ($script:falhas -eq 0) {
    Write-Host "=== OK: nenhuma falha ($script:avisos aviso(s)) ===" -ForegroundColor Green
    Write-Host ''
    Write-Host 'Teste manual que falta: bloqueie a tela (Win+L) e conecte de outra maquina,' -ForegroundColor Cyan
    Write-Host 'abrindo o Terminal. Nenhuma verificacao automatica cobre esse caminho.'      -ForegroundColor Cyan
} elseif ($script:falhas -gt 0 -and $script:senhaFaltando) {
    # a senha permanente e o unico passo obrigatorio que nenhum script aplica:
    # ela e definida pela UI e sem ela a conexao com a tela bloqueada falha
    Write-Host "=== $script:falhas falha(s), $script:avisos aviso(s) ===" -ForegroundColor Red
    Write-Host ''
    Write-Host 'Falta a senha permanente. Abra a UI do RustDesk, defina uma senha fixa em' -ForegroundColor Yellow
    Write-Host '"Senha" e rode a verificacao de novo. Sem ela nao ha como autenticar com a' -ForegroundColor Yellow
    Write-Host 'tela bloqueada - e nenhum script pode faze-lo por voce.'                    -ForegroundColor Yellow
    exit 1
} else {
    Write-Host "=== $script:falhas falha(s), $script:avisos aviso(s) ===" -ForegroundColor Red
    exit 1
}
