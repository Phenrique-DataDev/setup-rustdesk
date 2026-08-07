# Backlog

O que ficou em aberto, e por quê. Escrito em 2026-08-07, ao fim da sessão que trouxe o
Herdr para o `-All` e abriu o suporte a Linux.

Ordenado por **risco de morder**, não por esforço.

---

## 1. Dois caminhos nunca executados (Windows zerado)

O repositório existe para máquina zerada, e são justamente estes dois trechos que nenhuma
execução exercitou:

| O quê | Por que não foi validado |
|---|---|
| `Install-Herdr.ps1`, caminho de **instalação** | a máquina de referência já tinha o Herdr |
| `Set-RustDeskPassword.ps1`, caminho de **escrita** | a senha já estava gravada lá |

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

## 5. O caminho do `winget` nunca rodou

`Install-RustDesk.ps1` instala via `winget install --id RustDesk.RustDesk --scope machine`.
Em toda execução desta sessão o RustDesk já estava instalado, então esse ramo nunca
executou. O Sandbox não tem winget, então também não ajudou.

Mesmo cenário dos itens 1 e 2: fecha na próxima máquina real.

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

Continua em aberto a outra metade: **conexão nova contra a tela de logon** — desconectar,
bloquear, e só então conectar. É o caminho que `allow-logon-screen-password` serve, e o
único coberto pelo teste de 2026-08-06, anterior às mudanças no `Install-RustDesk.ps1`.

Lembrar da distinção: `Win+L` funciona, **logoff não** — o Terminal exige sessão de
console. Está no README.

---

## Ideias, não compromissos

- `Setup.ps1 -Uninstall` que reverta tudo (hoje só o watchdog tem `-Uninstall`).
- Hook de som no Windows via `SoundPlayer`, já que o do Herdr é quebrado lá — o README
  registra a rota que funciona, o repo não a instala.
- CI que rode `tests\RustDeskToml.Tests.ps1` e o parser em todos os `.ps1` a cada PR.
  Hoje isso é feito à mão e já pegou erro.
