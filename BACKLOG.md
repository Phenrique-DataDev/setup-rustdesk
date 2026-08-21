# Backlog

O que ficou em aberto, e por quê. Escrito em 2026-08-07, ao fim da sessão que trouxe o
Herdr para o `-All` e abriu o suporte a Linux.

Revisado em **2026-08-11**: o repositório virou público com CI obrigatório, a versão do
RustDesk passou a ser fixada e as atualizações automáticas foram desligadas e verificadas na
máquina. O item 5 fechou — por um motivo que ninguém esperava.

Revisado em **2026-08-20**: entrou o suporte a notebook (energia, tampa fechada, daemon de
suspensão e trigger de resume no watchdog). Ele nasce inteiro no item 1 — a máquina de
referência é um desktop, então **nenhuma linha do passo de energia foi executada**.

Revisado em **2026-08-21**: fecharam os itens 4, 6, 8 e 9. Os três primeiros por decisão —
Linux fica documentado, o Sandbox saiu da rota de teste e os ~10 s já tinham decisão tomada.
O 9 por implementação: o CI passou a avisar quando o pin do RustDesk fica para trás.

Segunda revisão de **2026-08-21**: fecharam os itens **3** e **7**, ambos por decisão de quem
opera a máquina. Restam **0, 1 e 2** — o mesmo cenário sob dois ângulos —, e eles têm destino
definido: **recebem um relatório quando o `Setup.ps1 -All` for executado num notebook**. Até
lá não há trabalho a fazer neles; o que falta é a saída de uma execução real, não código.

Ordenado por **risco de morder**, não por esforço.

---

## 0. O suporte a notebook nunca rodou num notebook

Escrito em 2026-08-20. É o item de maior risco do repositório hoje, porque é código novo que
mexe em configuração de sistema e cujo caminho de execução ninguém percorreu.

O que **foi** verificado, na máquina de referência (desktop, Windows 11 Pro 26200 pt-BR):

- 44 testes estáticos e **30 testes de harness** passando. O harness
  (`tests/Power.Harness.ps1`) roda os scripts de verdade contra um `powercfg` e cmdlets de
  rede substituídos por stubs, numa cópia temporária do repositório — nada toca o sistema;
- **o daemon foi executado de ponta a ponta**, com a máquina de estados inteira encenada:
  sem sessão → com sessão → bateria abaixo do limiar → recuperação → fim de sessão;
- parser e checagem de ASCII em todos os arquivos novos;
- `Test-IsLaptop` devolvendo `$false`, o que faz o passo inteiro ser pulado em desktop;
- `Test-RemoteSessionActive` devolvendo `$true` com uma sessão RustDesk de fato aberta;
- `New-ScheduledTask` aceitando o array misto (boot + repetição + evento CIM) sem gravar
  no Agendador;
- o parser de índices do `powercfg` lendo corretamente a saída **traduzida** desta máquina.

O harness pagou por si: encontrou **dois defeitos que nenhum teste estático pegaria**.

| Defeito | Como aparecia |
|---|---|
| `[uint32]0x80000000` estoura em tempo de execução | O daemon **morria na partida, em qualquer máquina**. O parser aprovava. |
| O adaptador de rede era reescrito a cada execução | `[APLICADO]` sem ter mudado nada, e escrita em hardware a cada `-All`. |

Ainda assim, o essencial continua sem prova, e só um notebook fecha:

| O quê | Por que importa |
|---|---|
| Qualquer chamada de `powercfg` que grava **de verdade** | No harness quem respondeu foi um stub. Se o `powercfg` real recusar um valor ou o `/setactive` não bastar, só a máquina real diz. |
| O daemon segurando uma suspensão **real** | A chamada de API foi exercitada e o laço reage certo; que o Windows de fato *não suspenda* por causa dela, não. Confirmar com `powercfg /requests` durante uma sessão só de Terminal. |
| O limiar de bateria com bateria de verdade | No harness a carga veio de um arquivo. |
| Fechar a tampa e continuar alcançável | O teste que dá sentido ao resto. |
| O trigger de resume **disparando** | O objeto é montado e aceito; que o Agendador o acione ao acordar, não foi visto. |
| O carimbo de época destravando após suspensão real | A lógica de comparação foi testada; o resume real, não. |
| `Disable-NetAdapterPowerManagement` no hardware | Só o stub e o `-WhatIf` foram cobertos. |

**Próximo passo — combinado em 2026-08-21:** este item recebe um **relatório da execução num
notebook**. A ordem é: `.\scripts\Get-PowerDiagnostics.ps1` **antes** de aplicar (linha de
base, e é somente leitura), depois `.\Setup.ps1 -All` como Administrador, guardando a saída
das duas coisas. Com ela em mãos os itens 2 a 11 da seção *Verificação* do plano viram
conferência de evidência em vez de suposição. Até o relatório chegar não há trabalho a fazer
aqui, e nada deve ser construído por cima do passo de energia.

Duas perguntas em aberto que o diagnóstico deve responder, e que motivaram o coletor:

1. O que exatamente não volta ao sair do ocioso. A hipótese principal é o power saving do
   adaptador Wi-Fi, mas é hipótese — o coletor correlaciona os eventos de resume com o
   `watchdog.log` e o log do serviço justamente para trocar hipótese por evidência.
2. Se, em Modern Standby, a máquina realmente atende conexão nova enquanto está em espera.
   Ligar a conectividade em espera torna isso possível; não prova que acontece.

Também não medido: **quanto o setup custa de bateria em repouso**. O watchdog a cada 10 min e
o daemon a cada 30 s são baratos no papel; ninguém mediu.

---

## 1. Dois caminhos nunca executados (Windows zerado)

O repositório existe para máquina zerada, e são justamente estes dois trechos que nenhuma
execução exercitou:

| O quê | Por que não foi validado |
|---|---|
| `Install-Herdr.ps1`, caminho de **instalação** | a máquina de referência já tinha o Herdr |
| `Set-RustDeskPassword.ps1`, caminho de **escrita** | a senha já estava gravada lá |
| `Install-RustDesk.ps1`, o `msiexec` do pin (2026-08-11) | o RustDesk já estava instalado, e na versão fixada |

O terceiro entrou em 2026-08-11 junto com o pin de versão. O que **foi** exercitado nesta
máquina: o download do `.msi`, a conferência de SHA-256, a validação da assinatura
Authenticode, a resolução de `-Version latest` pela API do GitHub e a montagem da URL. O que
não: a chamada do `msiexec` em si, porque isso exige uma máquina sem RustDesk.

**A rota do Windows Sandbox não serve para o primeiro.** O instalador oficial do Herdr usa
`Expand-Archive`, e no Sandbox o módulo `Microsoft.PowerShell.Archive` não carrega:

```
The 'Expand-Archive' command was found in the module 'Microsoft.PowerShell.Archive',
but the module could not be loaded.
```

Isso é limitação do ambiente, não do repo — o `Install-Herdr.ps1` baixou, validou e chamou
o instalador corretamente. Testar de verdade exige **uma VM Windows com imagem completa**
(Hyper-V com ISO), não o Sandbox.

O segundo falhou no Sandbox com `os error 2`, mas por causa do item 2 abaixo, então não há
conclusão sobre ele.

**Próximo passo — combinado em 2026-08-21:** a próxima máquina Windows real configurada com
o repo fecha os três de graça, e ela já tem nome: é o **notebook do item 0**. A mesma
execução de `.\Setup.ps1 -All` que exercita o passo de energia também percorre a instalação
do Herdr, a escrita da senha e o `msiexec` do pin — desde que seja uma máquina sem RustDesk e
sem Herdr previamente instalados, que é o que dá valor ao teste. **O relatório dessa execução
fecha este item junto com o 0 e o 2.**

---

## 2. A correção da ordem do `-All` não foi validada em máquina zerada

Numa máquina zerada os `RustDesk2.toml` não existem — o RustDesk os cria na primeira vez
que roda em cada perfil. O `-Configure` não tinha o que editar e o `-All` terminava com 7
falhas. `Install-RustDesk.ps1` passou a aguardar as configs nascerem (subindo a bandeja via
`Start-RustDeskUI` quando a do usuário falta).

**A correção foi escrita a partir da evidência do teste, mas não reexecutada em Windows
zerado** — só sintaxe e os 27 testes da lib. É a mudança mais importante da sessão e a
menos provada.

**Próximo passo:** mesmo teste dos itens 0 e 1 — são o mesmo cenário, e o relatório da
execução no notebook responde pelos três. O sinal a procurar na saída é específico: numa
máquina zerada o `-All` **não** pode terminar com as 7 falhas de configuração; se terminar, a
espera pelas configs nascerem não funcionou.

---

## 3. ~~`loginctl enable-linger` pendente (Linux)~~ — fechado em 2026-08-21

**Fechado por decisão de quem opera a máquina.** O item sempre foi exatamente isso: uma
decisão de operação, não trabalho de repositório. Ele fecha junto com o item 4 — o Linux
fica como está, com o Herdr automatizado e o RustDesk documentado —, e o comando continua
registrado aqui para quem quiser o servidor Herdr sobrevivendo ao fim da sessão:

```bash
sudo loginctl enable-linger "$USER"
```

Estado na máquina de referência quando o item foi escrito: `Linger=no`. Sem isso o systemd
encerra os serviços do usuário quando a última sessão dele fecha, e o servidor Herdr morre
junto — o análogo exato do `No active console user logged on` do Windows. Exige root e senha
interativa, e é o tipo de mudança que nenhum script deste repositório deve tomar por conta.

---

## 4. ~~RustDesk no Linux é só documentação~~ — fechado em 2026-08-21

**Fechado por decisão de escopo, não por implementação.** O Linux fica como está: o Herdr
automatizado e validado, o RustDesk documentado. Não há máquina Linux com ambiente gráfico
para validar nada disso, e escrever `setup.sh` sem poder executá-lo produziria o mesmo tipo
de código não exercitado que os itens 0 a 2 já custam caro. Se um dia houver a máquina,
o que falta continua registrado abaixo.

`docs/linux.md` descreve instalação, unit systemd, as duas configs e a armadilha do Wayland
— tudo vindo da documentação oficial e do código-fonte (`res/rustdesk.service`,
`res/DEBIAN/postrm`). **Nada disso foi executado.** O teste rodou em WSL, que não tem
display e portanto não exercita nada do RustDesk.

Para o Linux chegar ao nível do Windows falta:

- `setup.sh` equivalente ao `Setup.ps1` (instalação, unit, as duas configs, verificação)
- equivalente do watchdog — o `Restart=on-failure` da unit cobre quedas, mas não a
  vigilância de `stop-service = 'Y'`
- verificação automatizada (não há par do `Test-RustDeskSetup.ps1`)
- uma máquina Linux com ambiente gráfico para validar o caminho da tela de logon com X11

---

## 5. ~~O caminho do `winget` nunca rodou~~ — resolvido em 2026-08-11

Nunca rodou, e **nunca teria rodado**: ao implementar o pin de versão descobriu-se que o
pacote `RustDesk.RustDesk` não existe mais no repositório winget.

```
> winget search rustdesk
No package found matching input criteria.
```

O winget local está sadio (acha outros pacotes) — foi o pacote que saiu de lá. O ramo
inteiro estava morto.

`Install-RustDesk.ps1` passou a baixar o `.msi` da release do GitHub, conferindo SHA-256
contra o hash fixado em `config/version.psd1` e a assinatura Authenticode antes de
executar. Isso fecha o item e é o que torna o pin possível — o winget não instalaria uma
versão que ele nem lista.

**Continua valendo o teste em máquina zerada** (itens 1 e 2): o novo caminho de download +
`msiexec` foi exercitado em partes (download, hash, assinatura, resolução de `latest`), mas
a instalação completa numa máquina sem RustDesk ainda não.

---

## 6. ~~Windows Sandbox ficou instável~~ — fechado em 2026-08-21

**Fechado sem causa raiz, e é o desfecho certo.** A investigação do mesmo dia (registrada
abaixo) esgotou o que havia: a evidência expirou na retenção dos canais de evento e não é
bug deste repositório — é ambiente do Sandbox. Some disso, o Sandbox **deixou de ser a rota
de teste**: o item 1 já concluiu que validar o `Install-Herdr.ps1` exige uma VM Hyper-V com
imagem completa, porque `Expand-Archive` não carrega lá. Manter isto aberto era guardar um
item que nada destrava. As checagens sugeridas abaixo continuam valendo se alguém voltar a
usar o Sandbox por outro motivo.

Depois de duas execuções bem-sucedidas, o `LogonCommand` do `.wsb` parou de disparar — dois
ciclos seguidos sem gravar nada, com o Sandbox de pé.

Os artefatos ficaram em `Documents\Claude\sandbox-teste-rustdesk\` (fora do repositório):
`teste.wsb`, `teste-no-sandbox.ps1`, `diagnostico-ordem.ps1` e `saida\resultado.txt` do
teste que completou. O `diagnostico-ordem.ps1` mediria quando cada config nasce e a partir
de que momento `--password` funciona — nunca chegou a rodar.

**Investigado em 2026-08-21, sem causa raiz encontrada — a evidência já não existia.**

O que a apuração mostrou:

- `teste.wsb` e `diagnostico.wsb` são idênticos exceto pelo `<Command>` do
  `LogonCommand`. Não é problema de config — o primeiro provou que o `.wsb` funciona.
- Os dois scripts gravam no arquivo de saída como primeira instrução. `resultado.txt`
  existe e está completo até `=== FIM ===`; nenhum `diagnostico.txt` foi criado. Ou seja,
  quando parou de disparar, **nem a primeira linha do script chegou a rodar** — o
  `powershell.exe` nunca foi lançado pelo Sandbox, ou morreu antes de qualquer I/O. Não é
  bug no `diagnostico-ordem.ps1`.
- Os canais de evento relevantes (`Microsoft-Windows-Containers-Wcifs/Operational`,
  `...-BindFlt/Operational`) só retêm ~5 entradas nesta máquina; a mais antiga é de
  17/08. O incidente foi em 06/08 e já saiu da janela de retenção. Nenhum log de
  Application/System com "Sandbox" nos últimos 30 dias.
- `Get-ScheduledTask` para a tarefa de refresh da imagem base do Sandbox
  (`\Microsoft\Windows\ContainerManager\WimUpdate`) voltou vazia, mas a consulta não
  estava elevada — é a mesma armadilha já documentada no `CLAUDE.md` deste repo
  (`Get-ScheduledTask` sem elevação devolve vazio para tarefas de SYSTEM, falso
  negativo). Não dá para concluir que a tarefa não existe a partir disso.
- Nenhuma atualização do Windows caiu entre 06/08 e a data do teste (`Get-HotFix` mostra
  o KB mais recente anterior em 19/07) — descarta reinício por Windows Update como causa.

Hipóteses que seguem em aberto, sem como confirmar ou descartar agora: a imagem base do
Sandbox sendo atualizada em segundo plano, contenção de memória, ou uma corrida entre a
montagem das pastas mapeadas e o disparo do logon.

**Próximo passo:** só se resolve ao vivo, na próxima vez que acontecer — retroativamente
não há mais nada a apurar.

- Antes de abrir o Sandbox, checar elevado:
  `Get-ScheduledTaskInfo -TaskName WimUpdate -TaskPath '\Microsoft\Windows\ContainerManager\'`
- Ao ver o `LogonCommand` falhar, checar o Gerenciador de Tarefas por `vmwp.exe`/`vmmem`
  (sinal de contenção) antes de fechar o Sandbox.
- Trocar o `LogonCommand` por algo que grave fora do PowerShell primeiro (ex.:
  `cmd /c echo cheguei > C:\saida\heartbeat.txt`), para diferenciar "não disparou" de
  "disparou e morreu dentro do PowerShell".

Não é um problema de código deste repositório — é ambiente/ferramenta do Sandbox.

---

## 7. ~~Teste manual que nenhuma verificação cobre~~ — fechado em 2026-08-21

**Fechado por decisão.** O cenário já foi exercitado por completo três vezes (07/08 nas duas
metades, 10/08 contra a config de conexão direta) e nunca falhou. O que mantinha o item
aberto era a política de revalidar a cada mudança de config, e a mudança que ficou sem
revalidação — `enable-check-update` nos dois `RustDesk.toml`, em 11/08 — é uma chave de
checagem de atualização, sem relação plausível com autenticação na tela de logon. Continuar
carregando o item por causa dela custava mais atenção do que o risco justifica.

Fica valendo o de sempre, agora como recomendação e não como pendência: **é um ponto de dado
de uma máquina**. Ao configurar outra, faça o teste lá (`Win+L`, conectar de outro
dispositivo, abrir o Terminal). O histórico completo do que já foi provado segue abaixo.

Conectar de outra máquina **com a tela bloqueada** e abrir o Terminal.

**Parcialmente fechado em 2026-08-07**: com a sessão já conectada, `LockWorkStation` não
derrubou a conexão nem o Terminal (console `Ativo`, serviço `Running` ao fim). Feito depois
da verificação elevada em 51 PASS / 0 avisos.

**Fechado por completo em 2026-08-07.** A outra metade — desconectar, bloquear, e então
**conectar do zero** contra a tela de logon — também foi exercitada: tela de logon exibida,
senha permanente aceita, Terminal aberto e operante. A evidência é objetiva: durante a
sessão de Terminal, `Get-Process LogonUI` seguia ativo na sessão 1, então a tela continuava
bloqueada enquanto os comandos rodavam.

**Revalidado em 2026-08-10**, agora contra uma configuração diferente: `direct-server`,
`direct-access-port` e `enable-lan-discovery` ligados, e senha permanente regravada no
mesmo dia. Segue funcionando com a tela bloqueada. É o que importava saber — as opções de
conexão direta **adicionam** um caminho sem interferir no caminho autenticado pelo serviço.

Sobra apenas o de sempre: é um ponto de dado de **uma** máquina, esta. Repita na sua.

**Não revalidado após 2026-08-11.** A config mudou de novo naquele dia (`enable-check-update`
nos dois `RustDesk.toml`, e o serviço parou e subiu no processo). É uma chave de checagem de
atualização, sem relação plausível com autenticação na tela de logon — mas o histórico deste
item é justamente o de revalidar a cada mudança de config, e essa não foi.

Lembrar da distinção: `Win+L` funciona, **logoff não** — o Terminal exige sessão de
console. Está no README.

---

## 8. ~~Os ~10 s pela internet~~ — fechado em 2026-08-21

**Fechado: a decisão já estava tomada e não sobrou trabalho.** Os ~10 s são o timeout do
hole punching TCP, nenhuma opção do RustDesk os encurta, e a única rota que os elimina
(encaminhar `21118/TCP`) está fora de cogitação nesta máquina — decisão de 2026-08-10, que
não se reabre. Na rede local o problema já não existe (`direct-server` +
`direct-access-port`). O que restava era observação oportunista, não tarefa: olhar o log do
serviço na próxima conexão externa para ver se o IPv6 corrigido fez o punch sumir. Fica
registrado abaixo como nota, não como pendência.

Medido em 2026-08-10 (logs do serviço): o hole punching TCP falha em 0,3 s e o RustDesk só
pede relay ~10 s depois. Esses 10 s são o timeout do punch — nenhuma opção do RustDesk os
encurta.

`direct-server` + `direct-access-port=21118` resolveram **na mesma rede**, e isso foi
confirmado na prática: conectando pelo IP local a sessão abre visivelmente mais rápido.

**Pela internet o problema continua, por decisão.** Fechar exigiria encaminhar `21118/TCP`
no roteador, e ficou definido que **não se mexe em portas do roteador nesta máquina**. Não
proponha essa rota de novo.

Restava o IPv6, e ele foi investigado em 2026-08-10 — **não estava quebrado**. A máquina
tem IPv6 global (`2804:…` via Router Advertisement), resolução AAAA funciona e o IPv6 real
responde em 4 ms. O que havia era uma **corrida no boot**: o serviço sobe antes do RA
completar, falha ao resolver os STUN e segue sem IPv6 até ser reiniciado. O watchdog passou
a detectar e corrigir isso (item 6 dele).

Isso importa porque **IPv6 não tem NAT**: com IPv6 nos dois lados não há hole punching, e
os ~10 s deixariam de existir sem tocar no roteador.

**O que ainda não foi medido:** se uma conexão real de fora passa a usar IPv6 agora que o
serviço o enxerga. Depende também do cliente ter IPv6. Vale olhar o log do serviço na
próxima conexão externa e ver se o punch some.

A alternativa restante, se nada disso bastar: hospedar `hbbs`/`hbbr` próprios, que também
tirariam o `rs-ny` (~188 ms daqui). Também não envolve o roteador.

---

## 9. ~~O pin de versão apodrece sozinho~~ — fechado em 2026-08-21

O pin em si é de 2026-08-11; a dívida que ele deixou fechou em 2026-08-21.

**O que foi feito e verificado nesta máquina** (verificação elevada, `0 falhas / 0 avisos`):

| Chave | Arquivo | Estado |
|---|---|---|
| `allow-auto-update = 'N'` | `RustDesk2.toml` (usuário e serviço) | PASS |
| `enable-check-update = 'N'` | `RustDesk.toml` (usuário e serviço) | PASS |
| versão instalada `1.4.9` | — | bate com o pin |

O `-Configure` inseriu a seção `[options]` nos dois `RustDesk.toml`, que antes não a tinham,
e a senha permanente sobreviveu à gravação — que era o risco real de mexer nesse arquivo
(ele guarda hash, salt e as chaves do dispositivo). Estrutura conferida depois: nada movido,
nada duplicado.

**A dívida era:** o pin é um número escrito à mão em `config/version.psd1`. Quando sair a
1.4.10, nada no repositório avisava — a máquina continuaria na 1.4.9 para sempre, que é
exatamente o que se pediu, até o dia em que uma correção de segurança importa.

**Endereçada em 2026-08-21**, com a mais barata das três saídas que estavam na mesa: um
passo no `ci.yml` (*Pin do RustDesk ainda e a ultima estavel?*) consulta
`/repos/rustdesk/rustdesk/releases/latest` e emite `::warning` apontando para
`config/version.psd1` quando o pin fica para trás, com a versão nova e o que trocar.

Três decisões de projeto, porque cada uma podia ter ido para o outro lado:

- **avisa, não falha.** Um `exit 1` quebraria o PR de quem não encostou no pin, e ficar
  parado na versão fixada continua sendo o comportamento seguro **de propósito**;
- **erro de rede ou rate limit não tinge o job.** Sem release não há comparação, e um aviso
  perdido custa menos que um falso alarme recorrente;
- **nada de bot que abre PR com o bump.** O hash é fácil de calcular no runner, mas isso
  passaria a instalar a versão que um agente escolheu. A troca de `Version` e `Sha256`
  segue sendo à mão.

**Os quatro caminhos foram executados** em 2026-08-21, extraindo o passo do YAML e rodando-o
contra a API real:

| Caminho | Como foi forçado | Saída |
|---|---|---|
| em dia | pin `1.4.9`, última estável `1.4.9` (`prerelease=False`) | `ok: pin 1.4.9 esta na ultima estavel` |
| atrasado | cópia do `version.psd1` com `Version = '1.4.0'` | `::warning file=config/version.psd1::pin em 1.4.0, ultima estavel e 1.4.9` |
| `latest` | cópia com `Version = 'latest'` | `ok: pin em latest, nada a comparar`, `exit 0` |
| API indisponível | token vazio devolvendo `401` | `::warning::nao foi possivel consultar...`, `exit 0` |

Foi o quarto teste que pagou o exercício: o header `Authorization` era montado sempre, e com
`GITHUB_TOKEN` vazio a API devolve **401** em vez de atender anônimo. No Actions o token
existe, então isso nunca apareceria lá — mas o passo ficaria mudo fora do CI. O header passou
a ser condicional; o token só serve para escapar do rate limit, a release é pública.

**O limite conhecido:** o aviso só existe quando o CI roda, ou seja em PR, push na `main` e
`workflow_dispatch`. Repositório parado por meses = ninguém vê. Foi aceito: um cron abrindo
issue resolveria isso, e continua sendo a saída se o aviso passar a chegar tarde demais.

---

## Ideias, não compromissos

- ~~O repositório virou público sem LICENSE.~~ **Feito em 2026-08-11**: sem arquivo de
  licença o default legal é "todos os direitos reservados" — ninguém podia clonar nem
  forkar, o oposto do que o README promete no primeiro parágrafo. Adicionado `LICENSE`
  (MIT) e a seção *Licença*, que registra também o que este repositório **não** licencia:
  ele não redistribui binário nenhum, só baixa os oficiais. Na mesma passada,
  `git clone <url-do-repo>` virou a URL real — o placeholder só fazia sentido enquanto o
  repo era privado — e o README ganhou o badge do CI.

  Uma revisão de contexto limpo varreu o **histórico completo** (`git log --all -p`, 50
  commits), não só a árvore de trabalho, atrás de segredo, `.toml` versionado em algum
  momento e caminho de máquina pessoal: nada. Os `RustDesk*.toml` estão no `.gitignore`
  desde o primeiro commit dele, então nunca houve janela de exposição.
- `Setup.ps1 -Uninstall` que reverta tudo (hoje só o watchdog tem `-Uninstall`).
- Hook de som no Windows via `SoundPlayer`, já que o do Herdr é quebrado lá — o README
  registra a rota que funciona, o repo não a instala.
- ~~CI que rode os testes e o parser a cada PR.~~ **Feito em 2026-08-11**:
  `.github/workflows/ci.yml` roda `tests/Test-Syntax.ps1` (parser + ASCII em todos os
  scripts) e `tests/RustDeskToml.Tests.ps1`, mais um guarda contra `.toml`/`.bak`/`.log`
  versionados. O gate foi verificado com um script propositalmente quebrado.
