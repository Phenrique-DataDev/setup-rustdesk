# Linux — suporte inicial

Este repositório nasceu para Windows e é lá que está validado de ponta a ponta. Este
documento é o **suporte inicial** para Linux: o que muda, o que já está automatizado e o
que ainda é manual.

Leia antes a seção correspondente do [README](../README.md) — o *porquê* de cada opção é o
mesmo nos dois sistemas. Aqui está só o que difere.

## O que está pronto, e o quanto foi testado

| Parte | Estado | Como foi verificado |
|---|---|---|
| **Herdr**: instalação, config, autostart | automatizado por `scripts/linux/setup-herdr.sh` | **executado** em Ubuntu 26.04 (WSL2, systemd), Herdr 0.8.0 |
| **RustDesk**: instalação, serviço, configs | **manual** — passos abaixo | **não executado**; vem da documentação oficial e do código-fonte |

Essa diferença é deliberada e vale registrar: o que está no script foi rodado; o que está
em prosa foi lido. Não trate as duas metades com a mesma confiança.

---

## O mapa Windows → Linux

| | Windows | Linux |
|---|---|---|
| Serviço RustDesk | serviço `rustdesk` (LocalService) | unit `rustdesk.service`, `User=root` |
| Config do serviço | `ServiceProfiles\LocalService\…\RustDesk2.toml` | `/root/.config/rustdesk/RustDesk2.toml` |
| Config do usuário | `%APPDATA%\RustDesk\config\RustDesk2.toml` | `~/.config/rustdesk/RustDesk2.toml` |
| Config do Herdr | `%APPDATA%\herdr\config.toml` | `~/.config/herdr/config.toml` |
| Autostart do Herdr | tarefa agendada `HerdrServer` | systemd **user unit** `herdr-server.service` |
| Acesso sem sessão | limitado — Terminal exige sessão de console | exige `loginctl enable-linger` (Herdr) e X11 (RustDesk) |

**As duas configs do RustDesk existem no Linux também**, com a mesma armadilha: o serviço
roda como `root` e lê a config de `root`; sua sessão gráfica lê a sua. Editar uma não
sincroniza a outra.

---

## Herdr no Linux (automatizado)

```bash
./scripts/linux/setup-herdr.sh          # instala, configura e habilita o autostart
./scripts/linux/setup-herdr.sh --check  # só relata o estado, não altera nada
```

Não precisa de root. O script instala pelo `herdr.dev/install.sh` (baixando para arquivo e
registrando o SHA-256 antes de executar, como no lado Windows), escreve o `config.toml`
**só se ele não existir**, e cria a user unit.

Duas diferenças em relação ao Windows que vale saber:

- **A versão estável é maior.** No Linux o canal estável entrega **0.8.0**; no Windows o
  Herdr ainda é *preview-only* (0.7.2 na máquina de referência).
- **O som funciona.** O bug do player descrito no README é específico do Windows (ele
  spawna um `powershell.exe` com `System.Windows.Media.MediaPlayer`). No Linux não há
  motivo para manter `[ui.sound] enabled = false`, e por isso o script **não** escreve essa
  chave — ao contrário do `config/herdr.psd1`.

### O passo que exige root: `linger`

```bash
sudo loginctl enable-linger "$USER"
```

Sem isso, o systemd encerra os serviços do usuário quando a última sessão dele fecha — e o
servidor Herdr morre junto, levando o trabalho. É o equivalente exato do problema que no
Windows aparece como `No active console user logged on`.

O script detecta e avisa, mas não executa: pedir root é decisão sua.

---

## RustDesk no Linux (manual)

> Nada nesta seção foi executado. Os caminhos e o unit vêm da documentação oficial e do
> repositório do RustDesk (`res/rustdesk.service`, `res/DEBIAN/postrm`).

### Instalar

```bash
# baixe o .deb da release oficial: https://github.com/rustdesk/rustdesk/releases
sudo apt install -fy ./rustdesk-<versao>-x86_64.deb
sudo systemctl enable --now rustdesk
systemctl status rustdesk
```

Há também `.rpm`, AppImage e Flatpak. Os pacotes nativos são os recomendados pela
documentação oficial.

### Aplicar as opções nas duas configs

As mesmas chaves de `config/default.psd1` valem aqui. O serviço **não** recarrega a config
sozinho — pare, edite, suba:

```bash
sudo systemctl stop rustdesk
sudo -e /root/.config/rustdesk/RustDesk2.toml   # config do serviço
$EDITOR ~/.config/rustdesk/RustDesk2.toml       # config da sua sessão
sudo systemctl start rustdesk
```

Mantenha o formato nativo: **UTF-8 sem BOM, quebras LF**, valores entre aspas simples na
seção `[options]`. É a mesma exigência do Windows.

A senha permanente tem o mesmo caminho de CLI, e exige root:

```bash
sudo rustdesk --password '<senha>'
```

Com a mesma ressalva do Windows: o argumento fica visível na lista de processos enquanto
roda. Definir pela interface não expõe nada.

### A armadilha que substitui a "tela bloqueada"

No Windows o problema é o Terminal sem sessão de console. **No Linux o problema é o
Wayland.**

- **Acesso à tela de logon exige X11.** Com Wayland, não funciona.
- Para usar X11 no GDM, descomente `WaylandEnable=false` em `/etc/gdm3/custom.conf`
  (ou `/etc/gdm/custom.conf`, conforme a distro) e reinicie.
- O **modo headless** do RustDesk no Linux requer um ambiente gráfico instalado, servidor
  Xorg e GDM — não é "sem gráfico nenhum".
- `allow-logon-screen-password` existe a partir do cliente **1.4.7**.

Em SELinux (Fedora, RHEL), erros `avc: denied` pedem ajuste de política — a documentação
oficial do RustDesk cobre o caso.

---

## O que falta para o Linux ficar no nível do Windows

Registrado como trabalho conhecido, não como promessa:

- Um `setup.sh` equivalente ao `Setup.ps1`, cobrindo o RustDesk (instalação, unit,
  as duas configs, verificação).
- Watchdog: no Linux o `Restart=on-failure` da unit já cobre quedas; falta o equivalente
  da vigilância de `stop-service = 'Y'`.
- Verificação automatizada (`Test-RustDeskSetup.ps1` não tem par aqui).
- Validação real numa máquina Linux com ambiente gráfico — o teste do Herdr rodou em WSL,
  que não tem display e portanto não exercita nada do RustDesk.
