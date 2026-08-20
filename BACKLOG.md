# Backlog

O que ficou em aberto, e por quê. Escrito em 2026-08-07, ao fim da sessão que trouxe o
Herdr para o `-All` e abriu o suporte a Linux.

Revisado em **2026-08-11**: o repositório virou público com CI obrigatório, a versão do
RustDesk passou a ser fixada e as atualizações automáticas foram desligadas e verificadas na
máquina. O item 5 fechou — por um motivo que ninguém esperava.

Revisado em **2026-08-20**: entrou o suporte a notebook (energia, tampa fechada, daemon de
suspensão e trigger de resume no watchdog). Ele nasce inteiro no item 1 — a máquina de
referência é um desktop, então **nenhuma linha do passo de energia foi executada**.

Ordenado por **risco de morder**, não por esforço.

---

## 0. O suporte a notebook nunca rodou num notebook

Escrito em 2026-08-20. É o item de maior risco do repositório hoje, porque é código novo que
mexe em configuração de sistema e cujo caminho de execução ninguém percorreu.

O que **foi** verificado, na máquina de referência (desktop, Windows 11 Pro 26200):

- 43 testes estáticos passando, incluindo regressão de `-WhatIf` para `Set-PowerConfig.ps1`,
  do carimbo de época do watchdog e do release do bloqueio no daemon;
- parser e checagem de ASCII em todos os arquivos novos;
- `Test-IsLaptop` devolvendo `$false` corretamente, o que faz o passo inteiro ser pulado;
- `Test-RemoteSessionActive` devolvendo `$true` com uma sessão RustDesk de fato aberta;
- `New-RustDeskResumeTrigger` produzindo um `MSFT_TaskEventTrigger` com `Delay = PT20S`.

O que **não** foi, e só um notebook fecha:

| O quê | Por que importa |
|---|---|
| Qualquer chamada de `powercfg` que grava | O par `/setacvalueindex` + `/setactive` nunca rodou. Se a conferência por releitura estiver errada, o script anuncia sucesso sem ter mudado nada. |
| O daemon segurando uma suspensão de verdade | `SetThreadExecutionState` foi escrito, não observado. Confirmar com `powercfg /requests` durante uma sessão só de Terminal. |
| O limiar de bateria soltando o bloqueio | Exige bateria de verdade descendo abaixo de 15%. |
| Fechar a tampa e continuar alcançável | O teste que dá sentido ao resto. |
| O trigger de resume disparando | `Get-ScheduledTaskInfo` do `RustDeskWatchdog` logo após acordar. |
| O carimbo de época destravando | Suspender/acordar duas vezes e ver o watchdog tratar a segunda como época nova. |
| `Disable-NetAdapterPowerManagement` | Mudança de hardware; só o `-WhatIf` foi coberto por teste. |

**Próximo passo:** os itens 2 a 11 da seção *Verificação* do plano, num notebook real, com a
saída guardada. Rodar `.\scripts\Get-PowerDiagnostics.ps1` **antes** de aplicar, para ter
linha de base.

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

**Próximo passo:** a próxima máquina Windows real que for configurada com o repo fecha os
dois de graça. Vale rodar `.\Setup.ps1 -All` lá e guardar a saída.

---

## 2. A correção da ordem do `-All` não foi validada em máquina zerada

Numa máquina zerada os `RustDesk2.toml` não existem — o RustDesk os cria na primeira vez
que roda em cada perfil. O `-Configure` não tinha o que editar e o `-All` terminava com 7
falhas. `Install-RustDesk.ps1` passou a aguardar as configs nascerem (subindo a bandeja via
`Start-RustDeskUI` quando a do usuário falta).

**A correção foi escrita a partir da evidência do teste, mas não reexecutada em Windows
zerado** — só sintaxe e os 27 testes da lib. É a mudança mais importante da sessão e a
menos provada.

**Próximo passo:** mesmo teste do item 1. São o mesmo cenário.

---

## 3. `loginctl enable-linger` pendente (Linux)

```bash
sudo loginctl enable-linger "$USER"
```

Estado atual na máquina de referência: `Linger=no`. Sem isso o systemd encerra os serviços
do usuário quando a última sessão dele fecha, e o servidor Herdr morre junto — o análogo
exato do `No active console user logged on` do Windows.

Exige root e senha interativa; ficou para quem opera a máquina decidir.

---

## 4. RustDesk no Linux é só documentação

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

## 6. Windows Sandbox ficou instável

Depois de duas execuções bem-sucedidas, o `LogonCommand` do `.wsb` parou de disparar — dois
ciclos seguidos sem gravar nada, com o Sandbox de pé. Não foi investigado.

Os artefatos ficaram em `Documents\Claude\sandbox-teste-rustdesk\` (fora do repositório):
`teste.wsb`, `teste-no-sandbox.ps1`, `diagnostico-ordem.ps1` e `saida\resultado.txt` do
teste que completou. O `diagnostico-ordem.ps1` mediria quando cada config nasce e a partir
de que momento `--password` funciona — nunca chegou a rodar.

---

## 7. Teste manual que nenhuma verificação cobre

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

## 8. Os ~10 s pela internet: decidido não resolver

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

## 9. O pin de versão apodrece sozinho

Fechado em 2026-08-11, mas com uma dívida embutida.

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

**A dívida:** o pin é um número escrito à mão em `config/version.psd1`. Quando sair a
1.4.10, nada no repositório avisa — a máquina continua na 1.4.9 para sempre, que é
exatamente o que se pediu, até o dia em que uma correção de segurança importa. Não há
processo para isso hoje.

As saídas possíveis, em ordem de esforço:

- olhar as releases de vez em quando à mão (o que é o estado atual, e some da memória)
- um passo no CI que consulta a última estável e **falha ou avisa** quando o pin fica para
  trás — barato, mas transforma o CI em algo que quebra sem ninguém ter mexido no código
- um agente agendado que abre PR trocando `Version` e `Sha256` — o hash teria de ser
  calculado a partir do `.msi` baixado no runner, o que é fácil, mas passa a instalar o que
  um bot escolheu

Nada disso está decidido. O comportamento seguro (ficar parado na versão fixada) é o padrão
atual **de propósito**.

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
