# setup-rustdesk

[![CI](https://github.com/Phenrique-DataDev/setup-rustdesk/actions/workflows/ci.yml/badge.svg)](https://github.com/Phenrique-DataDev/setup-rustdesk/actions/workflows/ci.yml)

Configura a stack de acesso remoto no Windows — [RustDesk](https://rustdesk.com) para o
transporte e [Herdr](https://herdr.dev) para o terminal — incluindo o uso da função
**Terminal com a tela bloqueada**, que é onde a configuração padrão costuma falhar.

Clone, rode um comando, e a máquina fica pronta: instalação dos dois, configuração das
**duas** configs do RustDesk, watchdog, servidor do Herdr subindo no logon e verificação
automatizada de tudo.

O escopo é o **acesso remoto de ponta a ponta**, não apenas o RustDesk. O RustDesk entrega
o transporte; o Herdr é o que mantém o trabalho vivo quando a conexão cai. `-All` cobre os
dois. Veja [O terminal dentro da sessão](#o-terminal-dentro-da-sessão-herdr).

---

## Início rápido

```powershell
git clone https://github.com/Phenrique-DataDev/setup-rustdesk.git
cd setup-rustdesk

# 1. Ver o estado atual (não altera nada, não precisa de Administrador)
.\Setup.ps1

# 2. Setup completo, já com a senha — PowerShell como Administrador
.\Setup.ps1 -All -Password (Read-Host -AsSecureString 'senha')
```

São 6 passos e ao final não sobra passo manual. Sem `-Password` o setup roda igual mas
termina apontando que a senha falta — veja abaixo.

Se o Windows bloquear a execução dos scripts:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Setup.ps1 -All
```

### A senha permanente

Com a tela bloqueada quem autentica é o serviço, e sem senha gravada a conexão falha mesmo
com todas as opções corretas. Nenhum script inventa a sua senha: ou você passa `-Password`,
ou o setup termina com `[FALHA] senha ... gravada` — o que é esperado, não é bug.

Três rotas, com trade-off diferente:

| Rota | Comando | Exposição do segredo |
|---|---|---|
| **No setup** (fluxo padrão) | `.\Setup.ps1 -All -Password (Read-Host -AsSecureString 'senha')` | breve, na linha de comando do processo |
| **UI** (exposição zero) | RustDesk → **Senha** | nenhuma |
| **Avulsa** (trocar depois) | `.\scripts\Set-RustDeskPassword.ps1` | breve, na linha de comando do processo |

O script pergunta a senha **sem eco**, nunca a escreve em disco, log ou histórico do
PowerShell, e aplica via `rustdesk --password` — que grava por IPC, o mesmo caminho da UI,
então os **dois** perfis ficam sincronizados. Exige Administrador.

A ressalva honesta: `--password` recebe o segredo como argumento, e argumentos são visíveis
a outros processos (`Win32_Process.CommandLine`) enquanto o processo roda. A janela é curta
e o RustDesk não expõe API alternativa, mas se você quer exposição zero, use a UI. (A
verificação deste repositório **redige** `--password` e `--set-unlock-pin` antes de imprimir
linhas de comando, para não vazar num log de execução.)

Depois, rode `.\Setup.ps1` de novo como Administrador para conferir também o perfil do
serviço. A verificação avisa explicitamente quando é só a senha que falta.

Editar o `RustDesk.toml` na mão **não** funciona: ele guarda hash e salt, não a senha.

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
| `.\Setup.ps1 -All` | RustDesk + watchdog + Herdr + verifica | **sim** |
| `.\Setup.ps1 -Install` | Instala o RustDesk e registra o serviço | **sim** |
| `.\Setup.ps1 -Configure` | Reaplica as opções nas duas configs do RustDesk | **sim** |
| `.\Setup.ps1 -Watchdog` | Instala o watchdog e a tarefa agendada | **sim** |
| `.\Setup.ps1 -Herdr` | Instala o Herdr, aplica a config e põe o servidor no logon | não |
| `.\scripts\Set-RustDeskPassword.ps1` | Define a senha permanente (sem eco) | **sim** |
| `.\Setup.ps1 -Test -ShowLogs` | Verifica e mostra os logs recentes | não* |
| `.\tests\RustDeskToml.Tests.ps1` | Testes da biblioteca (em arquivos temporários) | não |
| `.\tests\Test-Syntax.ps1` | Parser em todos os `.ps1` + checagem de ASCII | não |

\* a verificação roda sem elevação, mas as checagens da config do serviço aparecem como
`[AVISO] requer Administrador` — o diretório é protegido. A parte do Herdr mora no perfil
do usuário e é verificada por completo sem elevação.

Opções úteis: `-IntervalMinutes 5` (frequência do watchdog), `-ConfigFile caminho.psd1`
(RustDesk), `-HerdrConfigFile caminho.psd1`, `-SkipHerdrInstall` (só configura um Herdr já
instalado).

O passo do Herdr **não** eleva: ele instala no perfil do usuário e registra uma tarefa do
próprio usuário. Rodar `-All` como Administrador funciona porque o UAC eleva o *mesmo*
usuário — mas "executar como outro usuário administrador" instalaria o Herdr no perfil
errado.

---

## Personalizando

São quatro arquivos de configuração, e a diferença entre eles não é cosmética:

| Arquivo | Governa | Vai parar em |
|---|---|---|
| `config/default.psd1` | opções do RustDesk | `RustDesk2.toml` (as duas) |
| `config/local.psd1` | opções de `LocalConfig` | `RustDesk.toml` (as duas) |
| `config/version.psd1` | versão fixada e hash do `.msi` | nada — é lido na instalação |
| `config/herdr.psd1` | opções do Herdr | `config.toml` do Herdr |

**`default.psd1` e `local.psd1` não são intercambiáveis.** O RustDesk lê `RustDesk2.toml`
por `Config` e `RustDesk.toml` por `LocalConfig`; uma chave escrita no arquivo errado é
ignorada em silêncio, sem erro nenhum. `enable-check-update` é uma dessas — só vale no
`RustDesk.toml`.

Para mudar sem sujar o repositório:

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

### Conexão direta: o que dá para fazer contra a demora de ~10 s

Por padrão **toda** conexão passa pelo servidor de rendezvous público. O RustDesk tenta
furar o NAT e, quando não consegue, espera o timeout antes de pedir relay. Nos logs desta
máquina o padrão é sempre o mesmo:

```
00:11:03  Punch tcp hole to <peer>:1531
00:11:04  Failed to connect                       ← o P2P morre em 0,3 s
00:11:14  create_relay requested ... ovh-da1      ← relay só 10 s depois
```

Esses ~10 segundos de "carregando" são o **timeout do punch**, não lentidão do relay — e
nenhuma opção do RustDesk encurta esse timeout. O que a configuração pode fazer é abrir um
caminho que não passa por lá:

| Chave | Valor | Por quê |
|---|---|---|
| `direct-server` | `Y` | Aceita conexão direta por IP. Quem conecta digita o IP em vez do ID: sem rendezvous, sem punch, sem relay. |
| `direct-access-port` | `21118` | Porta dessa conexão direta (padrão do RustDesk). |
| `enable-lan-discovery` | `Y` | A máquina aparece sozinha na aba de descoberta dos clientes da mesma rede. |

O ID continua funcionando: isto **adiciona** um caminho, não substitui o existente.

- **Mesma rede:** resolvido, e confirmado na prática — pelo IP local a sessão abre
  visivelmente mais rápido (validado em 2026-08-10).
- **Pela internet:** exige encaminhar a porta `21118/TCP` no roteador para esta máquina.
  Não há configuração do RustDesk que substitua o port forward. **Na máquina de referência
  isso foi descartado por decisão** — não se mexe em portas do roteador aqui, então a espera
  de ~10 s continua valendo para conexões de fora.

Ligar `direct-server` **não interfere** no caminho autenticado pelo serviço: a conexão com a
tela bloqueada foi revalidada com essas opções ativas e segue funcionando.

Sobra o **IPv6**, que é o caminho mais promissor de todos justamente por não ter NAT: com
IPv6 nos dois lados não há o que furar, e o timeout do punch deixa de existir. Esta máquina
tem IPv6 global funcional — o que faltava era o serviço enxergá-lo, e isso o watchdog agora
corrige (veja acima). Não depende do roteador.

Fora isso, resta hospedar `hbbs`/`hbbr` próprios, o que também tiraria o `rs-ny` — a
~188 ms daqui.

### Versão fixada e atualizações desligadas

A versão instalada é **fixada** em `config/version.psd1`, hoje a `1.4.9` (última estável em
2026-08-11). Sem pin, duas máquinas montadas com este repo em semanas diferentes acabam em
versões diferentes — o oposto de *clonou, pediu, funciona*.

O instalador baixa o `.msi` da release do GitHub e **só executa depois de duas conferências**:

1. **SHA-256** contra o hash fixado no `version.psd1`
2. **Assinatura Authenticode**, que precisa estar válida e conter `CN=PURSLANE`

Se qualquer uma falhar, o arquivo é apagado sem ser executado e o script para com erro. Um
pin com hash errado falha alto, em vez de instalar algo inesperado em silêncio.

Para subir de versão: escolha uma release **não** marcada como *prerelease*, troque
`Version` e `Sha256`, e rode `.\Setup.ps1 -Install`. Para escapar do pin pontualmente:

```powershell
.\Setup.ps1 -Install -Version 1.4.8      # outra versão fixa
.\Setup.ps1 -Install -Version latest     # última estável, sem verificação de hash
```

`latest` resolve pela API do GitHub, que já exclui prerelease — o `nightly` nunca entra.
Como a versão só é conhecida em tempo de execução, não há hash a conferir; a assinatura
continua sendo verificada.

**As atualizações automáticas ficam desligadas**, e são duas chaves em dois arquivos
diferentes:

| Chave | Arquivo | O que desliga |
|---|---|---|
| `allow-auto-update = 'N'` | `RustDesk2.toml` (`Config`) | a atualização automática em si |
| `enable-check-update = 'N'` | `RustDesk.toml` (`LocalConfig`) | a checagem por nova versão |

A primeira é o que importa: uma atualização no meio de um acesso remoto derruba a sessão e
mexe no serviço. A segunda evita até a consulta.

Cuidado com o prefixo, porque a semântica **inverte** (é o `option2bool` do RustDesk):
chaves `allow-*` só ligam com `'Y'` — o padrão é desligado; chaves `enable-*` ligam com
qualquer coisa **diferente** de `'N'` — o padrão é ligado, e só o `'N'` explícito desliga.

A verificação confere as duas chaves nos quatro arquivos e compara a versão instalada com
o pin. Divergência vira `[FALHA]`, não silêncio.

### Segurança

`allow-remote-config-modification` vem como `'N'` no default: com `'Y'`, quem conecta
pode alterar a configuração da máquina. Se a sua instalação atual usa `'Y'`, a
verificação vai acusar — é intencional, decida conscientemente.

Vale considerar também, pela UI do RustDesk: senha permanente forte, PIN de bloqueio
das configurações (*unlock_pin*) e 2FA/TOTP. Este repositório não mexe nesses itens.

---

## O que é instalado

```
C:\Program Files\RustDesk\           binário (.msi da release fixada, escopo de máquina)
serviço "rustdesk"                   Automatic + recovery: reiniciar 3× a cada 5s
C:\ProgramData\RustDesk\
  rustdesk-watchdog.ps1              watchdog materializado do template
  watchdog.log                       rotaciona em 1 MB, mantém 2000 linhas
Tarefa "RustDeskWatchdog"            SYSTEM, no boot + a cada 10 min

%LOCALAPPDATA%\Programs\Herdr\       binário (instalador oficial do herdr.dev)
%APPDATA%\herdr\config.toml          config aplicada de config/herdr*.psd1
%APPDATA%\herdr\start-herdr-server.ps1   launcher materializado (não editar)
Tarefa "HerdrServer"                 usuário, no logon, sem limite de duração
```

Duas camadas de proteção, de propósito: as **recovery actions do SCM** cobrem quedas do
serviço em segundos; o **watchdog** cobre o que o SCM não vê — serviço desinstalado,
desabilitado, `stop-service = 'Y'` na config (que deixa o acesso remoto morto com todos os
indicadores verdes), ou o serviço **sem IPv6**.

O caso do IPv6 é uma corrida no boot: o serviço é `AUTO_START` e sobe antes de o Router
Advertisement completar, então falha ao resolver os STUN IPv6 e segue sem IPv6 até alguém
reiniciá-lo. Como **IPv6 não tem NAT**, perder isso custa justamente o caminho que dispensa
hole punching.

O reinício é deliberadamente conservador, porque derruba sessão ativa:

- só age se a máquina **tem** IPv6 global naquele momento — numa rede sem IPv6 ele nunca
  dispara, em vez de reiniciar para sempre;
- no máximo **uma vez por boot**, marcado em disco (um STUN fora do ar não vira reinício a
  cada 10 min);
- nunca com **sessão remota em curso** (processo `--cm` no ar) — adia para a próxima passada.

Tudo o que ele decide vai para `watchdog.log`, inclusive as recusas.

---

## Tela bloqueada não é o mesmo que logoff

Esta é a distinção mais fácil de errar do repositório, e ela decide se o Terminal funciona.

| Estado da máquina | Área de trabalho | Terminal do RustDesk |
|---|---|---|
| **Tela bloqueada** (`Win+L`) | funciona | **funciona** |
| **Logoff / ninguém logado** | funciona (tela de logon) | **recusa** |

Com `Win+L` a sessão do usuário continua existindo (`SessionId 1`), apenas bloqueada — o
Terminal se anexa a ela normalmente. Com **logoff** a sessão deixa de existir, e o Terminal
não tem a que se anexar. O erro é explícito:

```
Erro de login
No active console user logged on, please connect and logon first.
```

Isso **não é defeito de configuração**: nenhuma opção deste repositório, do RustDesk ou do
Herdr faz o Terminal funcionar sem sessão. O caminho é conectar pela **área de trabalho
remota**, fazer logon na tela de logon (é para isso que serve
`allow-logon-screen-password = 'Y'`) e só então usar o Terminal.

Consequência prática para o Herdr: como a tarefa `HerdrServer` dispara **no logon**, uma
máquina recém-iniciada e sem ninguém logado não tem servidor Herdr no ar — e nem teria como
alcançá-lo pelo Terminal. Faça o logon primeiro; o servidor sobe junto.

**Verificado em 2026-08-06** (Windows 11 Pro 26200, RustDesk 1.4.9, cliente Android): após
`shutdown /l`, a conexão de vídeo subiu normalmente e o Terminal recusou com a mensagem
acima. Depois do logon, ambos funcionaram.

---

## O que o Terminal consegue fazer com a tela bloqueada

Com a tela bloqueada você perde **os olhos e as mãos** da máquina, não o resto. O
processo do Terminal continua na sessão interativa do usuário (`SessionId 1`) e a sessão
não é derrubada — mas o desktop de entrada passa a ser inacessível.

| Funciona | Não funciona |
|---|---|
| Shell, arquivos, scripts, rede | Captura de tela (`CopyFromScreen` → *Identificador inválido*) |
| `git`, `gh`, chamadas de API | Teclado (`SendKeys` → **Acesso negado**) |
| Iniciar e parar serviços | Apps da Microsoft Store (Notepad, Calc) |
| Docker: subir o Docker Desktop e rodar containers | Automação de GUI em geral |
| Ollama: subir o serviço e inferir na GPU | |
| Registrar e remover tarefas agendadas | |
| Apps Win32 clássicos — iniciam e criam janela (invisível) | |

Duas pegadinhas:

- **Apps da Store falham com uma mensagem enganosa**: *"o sistema não pode encontrar
  todas as informações necessárias"*. Não é caminho errado — é o desktop indisponível. O
  mesmo comando funciona com a tela desbloqueada. Executáveis Win32 clássicos
  (`charmap.exe`, por exemplo) iniciam normalmente e até recebem um `MainWindowHandle`
  válido; a janela simplesmente não é exibida.
- **`SetCursorPos` retorna `True` e a coordenada realmente muda**, mas não há desktop de
  entrada onde isso produza efeito. É um falso positivo — não use como prova de que a
  automação de mouse está funcionando.

Na prática: quase toda tarefa de engenharia (build, deploy, dados, containers, LLM local)
roda igual com a tela bloqueada. O que não roda é **validar o resultado visualmente**.

### Não consigo rolar a tela nem subir o histórico — é o RustDesk?

Quase sempre **não**. O RustDesk transporta a imagem e repassa os eventos de mouse; ele
não decide o que rola. O culpado costuma estar na pilha de terminais do outro lado.

O caso concreto que motivou esta nota: um agente de IA rodando dentro de um multiplexador
(Herdr), que por sua vez roda dentro do Windows Terminal — três camadas disputando o mesmo
evento de roda:

```
WindowsTerminal.exe -> pwsh -> herdr (client) -> herdr server -> powershell -> agente
```

A causa é o **alternate screen**. Aplicações de tela cheia (vim, htop, TUIs de agentes)
desenham na tela alternativa: não geram scrollback e recebem os eventos de roda
diretamente. Não é que a rolagem falhe — não existe histórico para rolar.

Como confirmar em vez de adivinhar (exemplo com Herdr, mas todo multiplexador tem
equivalente):

```powershell
herdr api snapshot | jq '.. | objects | select(.scroll != null) | .scroll'
# {"max_offset_from_bottom": 0, "offset_from_bottom": 0, "viewport_rows": 42}
```

`max_offset_from_bottom: 0` prova que o buffer está vazio — o problema não está no
transporte, e mexer na configuração do RustDesk não vai resolver.

Saídas, na ordem em que valem a pena:

| Ação | Efeito |
|---|---|
| `pwsh -File .\scripts\Show-AgentTranscript.ps1` | Abre o histórico do chat num pager navegável por teclado — **a única rota que funciona para o chat do agente** |
| `[advanced] scrollback_limit_bytes` | Aumenta o histórico — **só para panes criados depois**; os existentes mantêm o buffer atual |
| `[ui] mouse_capture = false` | Devolve a roda ao terminal em vez de o multiplexador capturá-la |
| `prefix` + `e` (`edit_scrollback`) | Abre o scrollback do pane num editor — serve para shells, **não** para o chat |

#### Por que o modo cópia não resolve o chat do agente

Vale separar dois sintomas que parecem o mesmo:

- **Shell comum sem rolagem** → é scrollback de verdade. `mouse_capture`, `scrollback_limit_bytes`
  e `prefix` + `e` resolvem.
- **Chat do agente sem rolagem** → não existe buffer para copiar. A TUI ocupa a tela
  alternativa e o Herdr só retém o buffer primário. Verificável:

```powershell
herdr pane read <pane_id> --source recent --lines 20
# devolve apenas o prompt do shell ("❯") — o chat inteiro está fora do buffer
```

Nenhum modo cópia, nenhum aumento de `scrollback_limit_bytes` e nenhuma configuração do
RustDesk recupera esse conteúdo, porque ele nunca chegou ao terminal. O histórico real
vive no `.jsonl` da sessão, e é isso que o `Show-AgentTranscript.ps1` lê.

Duas pegadinhas de ambiente ao rodar o script:

- **Use `pwsh` (PowerShell 7), não o 5.1.** No 5.1 a `ExecutionPolicy` de `LocalMachine`
  costuma estar `Undefined` — equivale a `Restricted` e bloqueia o script com
  `UnauthorizedAccess`. Alternativa: `powershell -ExecutionPolicy Bypass -File ...`.
- **O `less` do Git não está no PATH do PowerShell**, só no Git Bash. O script procura
  nos caminhos de instalação do Git; sem isso, o fallback seria o `more.com`, que não
  rola para trás nem exibe acentos — ou seja, não resolveria nada.

Duas correções em relação a versões anteriores desta nota: o Herdr 0.7.2 **não tem** modo
cópia estilo tmux em `prefix` + `[` (o equivalente é `edit_scrollback`, em `prefix` + `e`),
e **não há** bypass com `Shift` — o `right_click_passthrough_modifier` documenta que Shift
é intencionalmente não suportado, porque terminais costumam reservá-lo.

#### Quando o RustDesk *está* na equação: o Terminal embutido

A ressalva acima vale para a **área de trabalho remota**. Ela não vale para o **Terminal
do RustDesk** (o recurso `enable-terminal`), e foi aí que este repositório errou.

O Terminal do RustDesk não é o Windows Terminal transportado: é um widget `xterm.dart`
dentro do cliente Flutter, com um *ring buffer* de ~1 MB de output por sessão — buffer de
saída, não scrollback de terminal. Com um multiplexador ocupando a tela inteira, não há
conteúdo nesse buffer e a roda não tem o que rolar. Nenhuma configuração do host
(`mouse_capture`, `scrollback_limit_bytes`) ou do serviço RustDesk alcança isso: a decisão
é do cliente.

O teste que separa os dois casos:

| Onde você roda | Rola? | Conclusão |
|---|---|---|
| Sentado na máquina | sim | o terminal e o multiplexador estão bem |
| Área de trabalho remota via RustDesk | sim | transporte ok |
| **Terminal do RustDesk** | **não** | limitação do widget de terminal do cliente |

Saídas, quando é este o caso:

- **`Show-AgentTranscript.ps1`** — lê o histórico do `.jsonl` e pagina no `less`. Independe
  do transporte, funciona inclusive pelo cliente Android.
- **Área de trabalho remota** em vez do Terminal — mais pesada, mas a roda funciona.
- **`herdr --remote <ssh-target>`** — o cliente Herdr roda no *seu* terminal local e fala
  com o servidor por SSH. Exige um servidor SSH no host (OpenSSH Server, requer
  Administrador e abre porta — decisão consciente).

Antes de culpar o acesso remoto, reproduza sentado na máquina. Se o comportamento é o
mesmo, o RustDesk está fora da equação — mas se só falha pelo Terminal embutido, ele é
exatamente a causa.

---

## O terminal dentro da sessão (Herdr)

O RustDesk resolve o transporte; ele não resolve o que acontece com o seu trabalho quando
a conexão cai. Por isso o terminal usado dentro da sessão é o [Herdr](https://herdr.dev),
um gerenciador de workspaces que mantém os processos vivos num servidor próprio:

```
WindowsTerminal.exe -> pwsh -> herdr (client) -> herdr server -> shell -> processo
```

O cliente é descartável. Se a conexão RustDesk cair, se a tela bloquear ou se você fechar
o terminal, o `herdr server` continua rodando na sessão do usuário e os processos seguem
com ele — ao reconectar, é só reatachar e o trabalho está no ponto em que parou. É o
mesmo motivo pelo qual se usa `tmux` sobre SSH, com a diferença de que aqui isso vale
também para a conexão gráfica.

Combinado com a configuração da tela bloqueada deste repositório, o resultado é: a máquina
aceita a conexão com a **tela bloqueada**, e o que estava rodando continua rodando.

Note o limite, que é preciso: *tela bloqueada*, não *sem ninguém logado*. Veja
[Tela bloqueada não é o mesmo que logoff](#tela-bloqueada-não-é-o-mesmo-que-logoff).

### O que sobrevive a quê

A pergunta que decide se você pode confiar um trabalho longo a esta stack. A regra é uma
só: **o trabalho continua enquanto o `herdr server` estiver vivo**, e ele vive na sessão do
Windows do usuário.

| Acontece | Servidor | Seu trabalho |
|---|---|---|
| A conexão RustDesk cai | vive | **continua rodando** |
| Você fecha o cliente Herdr ou o terminal | vive | **continua rodando** |
| Você bloqueia a tela (`Win+L`) | vive | **continua rodando** |
| Você desanexa (`prefix` + `q`) | vive | **continua rodando** |
| **Logoff** | morre | **morre junto** |
| **Reboot / shutdown** | morre | **morre junto** |
| `herdr server stop` | morre | **morre junto** |

Na primeira metade da tabela você reconecta e o build que estava a 40% está a 70%. É o caso
de uso que justifica o Herdr aqui, e cobre tudo que é falha de rede ou de cliente — o
comum quando se acessa de fora.

#### O que `resume_agents_on_restore` e `pane_history` realmente fazem

Eles atuam na segunda metade da tabela, e é fácil esperar demais deles:

- **Retomam a sessão do agente e a tela do pane.** Na prática o agente é reaberto com
  `--resume`, então a conversa volta e você pode escrever de novo.
- **Não ressuscitam processo nenhum.** Um `npm run build` interrompido pelo logoff não
  recomeça sozinho; um agente que estava trabalhando volta parado, não trabalhando.

Restaurar o histórico não é o mesmo que retomar a execução — a distinção só aparece quando
você precisa dela, geralmente no pior momento.

**Verificado em 2026-08-06**: após um logoff com três sessões de agente abertas, as três
voltaram pelo `--resume`, disponíveis para escrever. Nenhuma retomou trabalho em andamento.

**Consequência prática:** para atravessar um reboot ou logoff, o trabalho precisa ser
retomável por conta própria — script idempotente, job com checkpoint, fila que reprocessa.
Estar dentro do Herdr não basta. Contra queda de conexão, basta e sobra.

### Instalação e autostart

`.\Setup.ps1 -Herdr` (incluído no `-All`) faz os três passos: instala o Herdr se faltar,
aplica a configuração e registra o servidor para subir no logon.

**A instalação usa o instalador oficial** (`https://herdr.dev/install.ps1`), não o winget.
O winget tem um pacote `herdr`, mas é `khanhtd36.herdr-khanhtd36` — um fork de terceiro que
se declara *"Unofficial fork… Not affiliated with or endorsed by the original project"*.
Binário de terceiro numa máquina configurada para acesso remoto irrestrito é uma decisão
que este repositório não toma por você.

#### O que isso significa em confiança

Instalar assim é **download-and-execute**: o que `herdr.dev` servir, roda. Vale saber
exatamente o que protege e o que não protege:

- O `install.ps1` **não é assinado** (Authenticode: `NotSigned`), então não há assinatura a
  validar.
- Ele **exige e confere o SHA-256 do binário** que baixa, com o digest vindo de
  `herdr.dev/latest.json`. O binário final não é aceito sem checksum.
- Logo, a confiança se concentra em **TLS + o domínio herdr.dev**.

O script baixa para um arquivo temporário, registra o SHA-256 do que baixou e só então
executa — em vez de `irm | iex`, que não deixa rastro do que rodou. O hash **não vem
pinado** de propósito: `install.ps1` é um script rolling, e um hash fixo quebraria a
instalação em toda máquina nova a cada release do Herdr. Quem opera uma frota e quer esse
controle usa `-ExpectedSha256 <hash>` e assume atualizar o valor.

**O autostart é uma tarefa agendada `HerdrServer`**, no logon do usuário, `Interactive` /
`Limited`, sem limite de duração (o default de 3 dias mataria o servidor numa máquina que
fica ligada). Ela chama um launcher materializado em
`%APPDATA%\herdr\start-herdr-server.ps1` — fora do repositório de propósito, como o
watchdog: uma tarefa apontando para o clone quebra quando a pasta é movida. O launcher
checa `herdr status server` antes de subir, então disparar a tarefa com um servidor já no
ar não faz nada.

Por que `Interactive` e não SYSTEM: o servidor precisa viver na sessão do usuário
(`SessionId 1`) para os agentes herdarem esse contexto. Na sessão 0 ele não serviria para
nada aqui.

### Configuração recomendada

As opções vivem em `config/herdr.psd1` e são aplicadas por
`scripts\Set-HerdrConfig.ps1` (não precisa de Administrador). O destino é
`%APPDATA%\herdr\config.toml`. Copie para `herdr-custom.psd1` para personalizar sem sujar
o repositório — ele tem precedência e está no `.gitignore`.

A configuração deste repositório parte de uma premissa concreta: **acesso pelo Terminal
embutido do RustDesk, de outras redes, incluindo Android.** Nesse transporte a roda do
mouse não rola nada, então tudo é orientado a teclado, tela pequena e conexão que cai.

```toml
[ui]
hide_tab_bar_when_single_tab = true   # ganha uma linha
pane_gaps = false                     # ganha linhas e colunas entre panes
sidebar_collapsed_mode = "hidden"     # largura zero ao colapsar (prefix+b reabre)
show_agent_labels_on_pane_borders = true  # sem sidebar, é o que diz quem é quem
mobile_width_threshold = 90           # layout de coluna única no celular
redraw_on_focus_gained = true         # a superfície corrompe mais em sessão remota

[ui.toast]
delivery = "herdr"                    # toast dentro da TUI — atravessa o transporte

[ui.sound]
enabled = false                       # o player de som do Herdr no Windows está quebrado (ver abaixo)

[session]
resume_agents_on_restore = true       # retoma os agentes após restart do servidor

[experimental]
pane_history = true                   # preserva a tela dos panes entre restarts

[advanced]
scrollback_limit_bytes = 10485760     # 10 MB de histórico por pane
```

Sobre `[experimental] pane_history`: é experimental e vem desligado. Ligamos aqui porque
queda de conexão em rede alheia é o caso comum, não a exceção — se preferir o
comportamento oficial, remova a seção.

Aplique (só a config, sem mexer em instalação nem autostart):

```powershell
pwsh -File .\scripts\Set-HerdrConfig.ps1
```

Ou, editando o `config.toml` na mão, sem reiniciar a sessão:

```powershell
herdr server reload-config
```

O comando responde `"status":"applied"` com `diagnostics` vazio quando o arquivo é válido
— se houver erro de sintaxe, ele aparece ali em vez de derrubar o servidor.

#### Som do Herdr não toca no Windows

`[ui.sound] enabled` está `false` de propósito: **não é preferência, é um bug do Herdr.**
Verificado no Herdr 0.7.2-preview, Windows 11.

O Herdr não toca o mp3 no próprio processo — ele spawna

```
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command <script>
```

e esse script usa `System.Windows.Media.MediaPlayer`. Esse tipo é do WPF e sinaliza
`MediaOpened`/`MediaEnded` através de um *dispatcher*, que só entrega eventos enquanto
alguém bombeia a fila de mensagens. Num PowerShell de console ninguém bombeia: o laço de
espera roda até o deadline de 15 s, o `Play()` é chamado com o prazo já vencido e o
`Close()` vem em seguida — o som é cortado antes de sair. O script termina com
`throw 'sound playback timed out'`, e o Herdr registra:

```
WARN herdr::sound: sound playback failed sound=Done err=player exited with exit code: 1
```

Onde conferir, se quiser reproduzir: `%APPDATA%\herdr\herdr-client.log`. O log do
*servidor* mostra a notificação como `outcome="ok"` — quem falha é o cliente, então olhar
só o servidor engana.

Isso é independente do RustDesk: o áudio da transmissão funciona (confirmado com áudio de
navegador na mesma sessão). Nenhuma opção de configuração contorna — `ui.sound.path` troca
o arquivo, não o player. Também não é ExecutionPolicy: o script já roda com `Bypass`.

Se quiser aviso sonoro assim mesmo, a rota que funciona em console é o `SoundPlayer`, que
é síncrono e não depende de dispatcher — chamado por fora do Herdr, por exemplo num hook
`Stop` do Claude Code:

```powershell
[System.Media.SoundPlayer]::new('C:\Windows\Media\Alarm01.wav').PlaySync()
```

Verificado tocando de verdade e chegando pelo loopback do RustDesk. Este repositório não
instala esse hook — fica registrado como opção.

Duas ressalvas que custam tempo:

- **`scrollback_limit_bytes` só vale para panes criados depois.** Os existentes mantêm o
  buffer que já tinham. Abra um pane novo para testar.
- **Grave o `config.toml` como UTF-8 sem BOM**, mesma armadilha do `.toml` do RustDesk
  descrita em [Armadilhas conhecidas](#armadilhas-conhecidas). Faça um backup antes de
  editar: com `config.toml.bak` ao lado, reverter é copiar por cima e recarregar.

### Operando sem a roda do mouse

Pelo Terminal do RustDesk, estes atalhos são o que substitui o mouse. O prefixo é
`ctrl+b` — pressione e solte, depois a tecla da ação.

| Atalho | Ação | Por que importa aqui |
|---|---|---|
| `prefix` + `z` | Zoom no pane (alterna) | O melhor uso de tela pequena: um pane ocupa tudo |
| `prefix` + `b` | Mostra/esconde a sidebar | Recupera colunas quando precisa do conteúdo |
| `prefix` + `e` | Abre o scrollback do pane num editor | Rolagem por teclado em panes de **shell** |
| `prefix` + `h` `j` `k` `l` | Move o foco entre panes | Navegação sem clique |
| `prefix` + `tab` | Alterna para o próximo pane | Ida e volta rápida |
| `prefix` + `c` / `prefix` + `1..9` | Nova aba / vai para a aba N | Com a barra de abas escondida, é como se navega |
| `prefix` + `v` / `prefix` + `-` | Divide vertical / horizontal | |
| `prefix` + `q` | Desanexa (deixa tudo rodando) | Sair sem matar nada |
| `prefix` + `?` | Ajuda com todos os atalhos | |

O `prefix` + `e` **não** serve para o chat do agente — a TUI não gera scrollback. Para ler
o histórico da conversa, use o `Show-AgentTranscript.ps1`.

---

## Estrutura

```
Setup.ps1                       orquestrador
config/default.psd1             opções do RustDesk (copie para custom.psd1)
config/local.psd1               opções do RustDesk.toml (copie para local-custom.psd1)
config/version.psd1             versão fixada + SHA-256 do instalador
config/herdr.psd1               opções do Herdr (copie para herdr-custom.psd1)
lib/RustDeskCommon.psm1         caminhos, elevação, controle do serviço
lib/RustDeskToml.psm1           leitura/escrita do .toml preservando o formato
scripts/Install-RustDesk.ps1    baixa o .msi fixado, verifica, serviço + recovery
scripts/Set-RustDeskConfig.ps1  aplica as opções nas duas configs
scripts/Set-RustDeskPassword.ps1  senha permanente, sem eco e sem histórico
scripts/Install-Watchdog.ps1    watchdog + tarefa agendada
scripts/Install-Herdr.ps1       instalador oficial + servidor no logon
scripts/Set-HerdrConfig.ps1     aplica as opções no config.toml do Herdr
scripts/Show-AgentTranscript.ps1  lê o histórico do agente num pager
scripts/Test-RustDeskSetup.ps1  verificação (PASS/FALHA/AVISO, exit 1 se falhar)
scripts/watchdog/               template do watchdog
tests/RustDeskToml.Tests.ps1    30 testes, sem tocar em instalação real
tests/Test-Syntax.ps1           parser + ASCII em todos os scripts
.github/workflows/ci.yml        roda os dois a cada PR e push na main
```

---

## Linux

Este repositório é validado no Windows. Há **suporte inicial** para Linux em
[`docs/linux.md`](docs/linux.md): o Herdr (instalação, config e autostart por systemd user
unit) está automatizado em `scripts/linux/setup-herdr.sh` e foi executado em Ubuntu 26.04;
o RustDesk está documentado passo a passo, mas ainda é manual.

A armadilha equivalente à "tela bloqueada" lá é outra: **acesso à tela de logon exige X11**,
não Wayland.

---

## Requisitos

- Windows 10/11
- Windows PowerShell 5.1 (já vem no Windows) ou PowerShell 7+
- Privilégios de Administrador para instalar e configurar o RustDesk (o passo do Herdr não
  eleva)
- Acesso à internet para os dois instaladores (`github.com` para o `.msi` do RustDesk,
  `herdr.dev` para o Herdr). Sem ele, use `-SkipInstall` / `-SkipHerdrInstall` sobre
  instalações existentes.
- **`winget` não é mais necessário.** O pacote `RustDesk.RustDesk` foi retirado do
  repositório winget, então a instalação baixa o `.msi` direto da release — o que também é
  o que torna o pin de versão possível

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
- **`$WhatIfPreference` não atravessa fronteira de módulo.** Uma função exportada de
  `lib/*.psm1` roda com o preference do escopo *dela*, não o do script que a chamou. Por
  isso `Set-RustDeskConfig.ps1 -WhatIf` chegou a **gravar de verdade** (e a parar o
  serviço) enquanto imprimia uma simulação convincente na tela. Quem chama `Set-TomlOption`
  ou `Set-TomlSectionValue` precisa repassar `-WhatIf:$WhatIfPreference` explicitamente, e
  efeitos colaterais fora do módulo (parar/subir serviço) precisam de guarda própria. Há
  teste de regressão para as duas coisas.
- **`IsInRole('Administrator')` com string falha em Windows localizado.** Em pt-BR o nome
  do grupo é traduzido e a checagem dá falso negativo. Use o enum `WindowsBuiltInRole`.
- **`Get-ScheduledTask` sem elevação devolve vazio** para tarefas de SYSTEM, em vez de
  negar acesso — um falso negativo silencioso.
- **`Start-Process explorer.exe` com argumentos não lança a UI.** O explorer trata a
  string inteira como caminho a abrir. Para lançar sem elevação a partir de um console
  elevado, use uma tarefa agendada temporária (`Interactive` / `Limited`).
- **Detectar "a tela está bloqueada" é mais difícil do que parece.** Duas técnicas comuns
  mentem no Windows 11 (26200): `quser` reporta a sessão como `Ativo` mesmo bloqueada, e
  `OpenInputDesktop` + `UOI_NAME` devolve `Default` em vez de `Winlogon`. `Get-Process
  LogonUI` acertou nos testes — nenhum script deste repositório depende disso hoje, mas
  fica o registro para quem for escrever uma checagem.
- **Logo após o bloqueio existe uma janela de corrida de alguns segundos.** Cerca de 6s
  depois de `LockWorkStation`, o `LogonUI` já estava no ar e a captura de tela **ainda
  funcionava**, devolvendo a imagem da própria lock screen; só depois o acesso gráfico
  caiu de vez. Quem checar estado imediatamente após o lock lê um resultado inconsistente
  — aguarde a transição terminar.

---

## Limite conhecido

**O autostart do Herdr foi validado em 2026-08-06**, com logoff real. Registrado aqui
porque a evidência é o que dá confiança, não a afirmação:

| | Antes do logoff | Depois do logon |
|---|---|---|
| Logon da sessão | — | 20:00:50 |
| `HerdrServer` disparou | 16:38:46 (manual) | **20:00:50** |
| PID do servidor | 2908 (15:06) | **22912 (20:00:51)** |
| `herdr status server` | — | `running` |

O servidor antigo morreu com o logoff e um novo nasceu **1s após a tarefa disparar**,
antes de qualquer cliente ser aberto.

Sobre o `LastTaskResult` dessa tarefa: `267009` (`0x41301`, `SCHED_S_TASK_RUNNING`) é o
valor **saudável** — `herdr server` roda em foreground, então a tarefa fica ativa enquanto
o servidor vive. Um `0` ali significaria que ele saiu.

Nenhuma verificação automatizada cobre o caminho real de ponta a ponta: **conectar de
outra máquina com a tela bloqueada e abrir o Terminal**. As checagens confirmam que a
configuração está correta nos dois perfis, não que a conexão funciona. Faça esse teste
manualmente — `Win+L` e conecte de outro dispositivo.

**Validado manualmente em 2026-08-04** (Windows 11 Pro 26200, RustDesk 1.4.9): com a
sessão já conectada por RustDesk, bloquear a tela via `LockWorkStation` **não derrubou o
Terminal** — a sessão console permaneceu `Ativo`, o serviço `rustdesk` seguiu `Running` e
os comandos continuaram executando sem reconexão. É um único ponto de dado, de uma
máquina configurada por este repositório; repita na sua.

**Revalidado em 2026-08-06**, na mesma máquina, depois de a configuração passar a ser
aplicada por `-All` (as 28 chaves do RustDesk — 14 × 2 perfis — verificadas com elevação,
`allow-remote-config-modification` corrigido para `'N'` nos dois): o teste de tela
bloqueada **voltou a funcionar**. Continua sendo um ponto de dado de uma única máquina.

**Revalidado em 2026-08-07**, depois do merge do backlog e com a verificação elevada em
51 PASS / 0 avisos. O bloqueio foi disparado por `LockWorkStation` a partir da própria
sessão remota (o `Win+L` do cliente não chega à máquina): a conexão **não caiu**, o
Terminal seguiu executando e nada travou. Ao fim, `query session` continuava com o console
`Ativo` e o serviço `Running`.

Vale o registro preciso do que esse ponto de dado cobre: uma sessão **já conectada**
sobrevivendo ao bloqueio. Ele não exercita a conexão *nova* contra a tela de logon — para
isso é preciso desconectar antes de bloquear, e é o caminho que o `allow-logon-screen-password`
serve. O teste de 2026-08-06 cobriu esse outro caminho.

Na mesma data, o **caminho completo** também foi exercitado: desconectar, bloquear a tela
com a máquina sem ninguém conectado, e então **conectar do zero**. A tela de logon apareceu,
a senha permanente autenticou e o Terminal abriu normalmente. A evidência que fecha o ponto
é objetiva — durante a sessão de Terminal, `Get-Process LogonUI` seguia ativo na sessão 1,
ou seja, **a tela continuava bloqueada enquanto os comandos rodavam**. Não houve desbloqueio.

Como bloquear a tela quando não há ninguém na máquina para apertar `Win+L`, e a própria
conexão será encerrada:

```powershell
Start-Sleep -Seconds 45; rundll32.exe user32.dll,LockWorkStation
```

Desconecte durante os 45 segundos. O processo sobrevive à queda da conexão, porque
desconectar **não** encerra a sessão do Windows.

O que este teste **não** cobriu, para não se confundir depois: houve bloqueio e
desbloqueio de tela, não logoff. O processo do servidor Herdr seguiu sendo o mesmo de
antes do teste e a tarefa `HerdrServer` não foi disparada por ele — então o autostart
continua sem observação real, como descrito acima.

Se falhar mesmo com tudo verde, olhe os logs:

```powershell
.\Setup.ps1 -Test -ShowLogs      # como Administrador, para incluir os logs do serviço
```

Um sintoma já visto: `Failed to start ipc_cm server at path \\.\pipe\RustDesk\query_cm:
Acesso negado`. Indica um processo `--cm` órfão segurando o named pipe. A verificação
avisa quando encontra mais de um.

Não tente isolar isso com **logoff**: sem sessão de usuário o Terminal recusa a conexão de
saída (ver [Tela bloqueada não é o mesmo que logoff](#tela-bloqueada-não-é-o-mesmo-que-logoff)),
e você troca um sintoma por outro em vez de isolar. Para limpar um `--cm` órfão, feche a
sessão remota, confirme com a verificação que sobrou só um, e reconecte.

---

## Licença

[MIT](LICENSE). Os scripts e a documentação deste repositório são livres para usar,
modificar e redistribuir.

O que este repositório **não** licencia: ele não redistribui binário nenhum. O
`Install-RustDesk.ps1` baixa o `.msi` da release oficial e o Herdr vem do instalador
do projeto dele — cada um sob a licença do seu próprio projeto
([RustDesk](https://github.com/rustdesk/rustdesk), [Herdr](https://herdr.dev)).
