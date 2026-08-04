# setup-rustdesk

Configura o [RustDesk](https://rustdesk.com) no Windows para acesso remoto confiável —
incluindo o uso da função **Terminal com a tela bloqueada**, que é onde a configuração
padrão costuma falhar.

Clone, rode um comando, e a máquina fica pronta: instalação, configuração das **duas**
configs, watchdog e verificação automatizada.

---

## Início rápido

```powershell
git clone <url-do-repo> setup-rustdesk
cd setup-rustdesk

# 1. Ver o estado atual (não altera nada, não precisa de Administrador)
.\Setup.ps1

# 2. Setup completo — PowerShell como Administrador
.\Setup.ps1 -All
```

Se o Windows bloquear a execução dos scripts:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Setup.ps1 -All
```

---

## O problema que este repositório resolve

O RustDesk no Windows mantém **duas configurações independentes**:

| Config | Caminho | Quando vale |
|---|---|---|
| Usuário | `%APPDATA%\RustDesk\config\RustDesk2.toml` | Tela desbloqueada, sessão ativa |
| Serviço | `C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config\RustDesk2.toml` | **Tela bloqueada** ou ninguém logado |

Com a tela desbloqueada, quem atende a conexão é o processo da sessão interativa. Com a
tela **bloqueada**, quem atende é o serviço — e ele lê a própria config.

Editar o `.toml` na mão **não sincroniza as duas** (a sincronia acontece via IPC,
disparada pela UI). O resultado clássico: tudo funciona com a máquina desbloqueada e
falha com ela bloqueada, sem mensagem de erro que explique por quê.

Este repositório escreve nos dois arquivos e valida os dois.

---

## Comandos

| Comando | O que faz | Admin |
|---|---|---|
| `.\Setup.ps1` | Só verifica. Não altera nada. | não |
| `.\Setup.ps1 -All` | Instala + configura + watchdog + verifica | **sim** |
| `.\Setup.ps1 -Install` | Instala o RustDesk e registra o serviço | **sim** |
| `.\Setup.ps1 -Configure` | Reaplica as opções nas duas configs | **sim** |
| `.\Setup.ps1 -Watchdog` | Instala o watchdog e a tarefa agendada | **sim** |
| `.\Setup.ps1 -Test -ShowLogs` | Verifica e mostra os logs recentes | não* |
| `.\tests\RustDeskToml.Tests.ps1` | Testes da biblioteca (em arquivos temporários) | não |

\* a verificação roda sem elevação, mas as checagens da config do serviço aparecem como
`[AVISO] requer Administrador` — o diretório é protegido.

Opções úteis: `-IntervalMinutes 5` (frequência do watchdog), `-ConfigFile caminho.psd1`.

---

## Personalizando

`config/default.psd1` traz os padrões. Para mudar sem sujar o repositório:

```powershell
Copy-Item config\default.psd1 config\custom.psd1
notepad config\custom.psd1
.\Setup.ps1 -Configure
```

`custom.psd1` tem precedência automática e está no `.gitignore`.

### Opções que importam para a tela bloqueada

| Chave | Valor | Por quê |
|---|---|---|
| `enable-terminal` | `Y` | Habilita a função Terminal (RustDesk 1.4.0+). Explícito para não depender do default, que muda entre versões. |
| `allow-logon-screen-password` | `Y` | Permite autenticar na tela de logon/bloqueio. Sem isso há relatos de a conexão travar em *Waiting for remote approval*. |
| `verification-method` | `use-permanent-password` | Autenticação por senha, sem depender de alguém clicar "aceitar" — impossível com a tela bloqueada. |
| `approve-mode` | `password` | Idem. |
| `stop-service` | `N` | `Y` aqui desliga o acesso remoto inteiro. O watchdog também vigia esta chave. |

### Segurança

`allow-remote-config-modification` vem como `'N'` no default: com `'Y'`, quem conecta
pode alterar a configuração da máquina. Se a sua instalação atual usa `'Y'`, a
verificação vai acusar — é intencional, decida conscientemente.

Vale considerar também, pela UI do RustDesk: senha permanente forte, PIN de bloqueio
das configurações (*unlock_pin*) e 2FA/TOTP. Este repositório não mexe nesses itens.

---

## O que é instalado

```
C:\Program Files\RustDesk\           binário (via winget, --scope machine)
serviço "rustdesk"                   Automatic + recovery: reiniciar 3× a cada 5s
C:\ProgramData\RustDesk\
  rustdesk-watchdog.ps1              watchdog materializado do template
  watchdog.log                       rotaciona em 1 MB, mantém 2000 linhas
Tarefa "RustDeskWatchdog"            SYSTEM, no boot + a cada 10 min
```

Duas camadas de proteção, de propósito: as **recovery actions do SCM** cobrem quedas do
serviço em segundos; o **watchdog** cobre o que o SCM não vê — serviço desinstalado,
desabilitado, ou `stop-service = 'Y'` na config (que deixa o acesso remoto morto com
todos os indicadores verdes).

---

## Estrutura

```
Setup.ps1                       orquestrador
config/default.psd1             opções aplicadas (copie para custom.psd1)
lib/RustDeskCommon.psm1         caminhos, elevação, controle do serviço
lib/RustDeskToml.psm1           leitura/escrita do .toml preservando o formato
scripts/Install-RustDesk.ps1    winget + serviço + recovery do SCM
scripts/Set-RustDeskConfig.ps1  aplica as opções nas duas configs
scripts/Install-Watchdog.ps1    watchdog + tarefa agendada
scripts/Test-RustDeskSetup.ps1  verificação (PASS/FALHA/AVISO, exit 1 se falhar)
scripts/watchdog/               template do watchdog
tests/RustDeskToml.Tests.ps1    10 testes, sem tocar em instalação real
```

---

## Requisitos

- Windows 10/11
- Windows PowerShell 5.1 (já vem no Windows) ou PowerShell 7+
- Privilégios de Administrador para instalar e configurar
- `winget` para a instalação automática — sem ele, instale o RustDesk manualmente e use
  `.\Setup.ps1 -Install -SkipInstall` para só registrar o serviço

---

## Armadilhas conhecidas

Coisas que custaram tempo para descobrir e estão codificadas aqui:

- **Gravar o `.toml` com `Set-Content -Encoding UTF8` adiciona BOM.** O formato nativo do
  RustDesk é UTF-8 **sem** BOM com quebras LF. `lib/RustDeskToml.psm1` grava no formato
  certo e remove BOM existente; a verificação acusa se aparecer.
- **`Stop-Process` no processo de sessão 0 não para o serviço.** O SCM entende como falha
  e as recovery actions o religam em 5 segundos — no meio da edição da config. A parada
  precisa passar pelo SCM (`Stop-Service` + `WaitForStatus('Stopped')`).
- **O serviço não recarrega a config sozinha.** Editar o arquivo com ele no ar não tem
  efeito, e ele ainda pode regravar por cima ao sair. Edite com o serviço parado.
- **`IsInRole('Administrator')` com string falha em Windows localizado.** Em pt-BR o nome
  do grupo é traduzido e a checagem dá falso negativo. Use o enum `WindowsBuiltInRole`.
- **`Get-ScheduledTask` sem elevação devolve vazio** para tarefas de SYSTEM, em vez de
  negar acesso — um falso negativo silencioso.
- **`Start-Process explorer.exe` com argumentos não lança a UI.** O explorer trata a
  string inteira como caminho a abrir. Para lançar sem elevação a partir de um console
  elevado, use uma tarefa agendada temporária (`Interactive` / `Limited`).

---

## Limite conhecido

Nenhuma verificação automatizada cobre o caminho real de ponta a ponta: **conectar de
outra máquina com a tela bloqueada e abrir o Terminal**. As checagens confirmam que a
configuração está correta nos dois perfis, não que a conexão funciona. Faça esse teste
manualmente — `Win+L` e conecte de outro dispositivo.

Se falhar mesmo com tudo verde, olhe os logs:

```powershell
.\Setup.ps1 -Test -ShowLogs      # como Administrador, para incluir os logs do serviço
```

Um sintoma já visto: `Failed to start ipc_cm server at path \\.\pipe\RustDesk\query_cm:
Acesso negado`. Indica um processo `--cm` órfão segurando o named pipe. A verificação
avisa quando encontra mais de um. Testar com **logoff** em vez de apenas bloquear ajuda
a isolar: sem sessão de usuário não existe `--cm` concorrente.
