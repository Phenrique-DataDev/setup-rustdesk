# setup-rustdesk

Configura a stack de acesso remoto de uma máquina Windows: **RustDesk** (transporte,
incluindo Terminal com a tela bloqueada) + **Herdr** (terminal persistente na sessão).

O `README.md` é a documentação completa e a fonte da verdade sobre *por quê* cada opção
existe. Este arquivo diz o que fazer.

## Pedido típico: "faça essas configurações do rustdesk + herdr"

Numa máquina nova, é **um comando**, em PowerShell **como Administrador**:

```powershell
.\Setup.ps1 -All
```

Ele executa 5 passos: instala o RustDesk → aplica as duas configs → watchdog → instala e
configura o Herdr com o servidor no logon → verifica.

Depois diga ao usuário para fazer o passo manual:

> **Defina uma senha permanente na UI do RustDesk** (abrir RustDesk → Senha). Sem ela a
> conexão com a tela bloqueada falha, e não existe caminho de linha de comando para isso.
> Depois rode `.\Setup.ps1` de novo para confirmar.

Numa máquina zerada `-All` **termina com `[FALHA] senha ... gravada`** — isso é esperado,
não é bug. Não tente contornar editando `RustDesk.toml`: ele guarda hash e salt.

## Regras ao trabalhar aqui

- **Não rode passos que alteram o sistema sem o usuário pedir.** `.\Setup.ps1` sem
  parâmetros só verifica e é sempre seguro. `-Install`, `-Configure`, `-Watchdog` exigem
  Administrador e mexem em serviço e configs.
- **`-WhatIf` funciona** em `Set-RustDeskConfig.ps1`, `Set-HerdrConfig.ps1` e
  `Install-Herdr.ps1`. Use para mostrar o efeito antes de aplicar.
- **Nunca versione `RustDesk.toml` / `RustDesk2.toml`** — carregam senha, salt e chaves do
  dispositivo. Já estão no `.gitignore`; não os force.
- **Configuração pessoal vai em `config/custom.psd1` e `config/herdr-custom.psd1`**, que
  têm precedência e são ignorados pelo git. Não edite os defaults para preferência local.
- Testes: `.\tests\RustDeskToml.Tests.ps1` (usa arquivos temporários, não toca em
  instalação real).

## Armadilhas que já custaram tempo

Estão todas documentadas em detalhe no README (seção *Armadilhas conhecidas*). As que mais
afetam quem edita este repo:

- **Gravar `.toml` com `Set-Content -Encoding UTF8` adiciona BOM.** O formato nativo é
  UTF-8 **sem** BOM com LF. Use sempre `lib/RustDeskToml.psm1`, nunca `Set-Content` direto.
- **O serviço do RustDesk não recarrega a config sozinho** e pode regravar por cima ao
  sair. Edite com ele parado, via `Stop-RustDeskClean` (que passa pelo SCM — `Stop-Process`
  dispara as recovery actions e ele volta em 5s).
- **`IsInRole('Administrator')` com string falha em Windows pt-BR.** Use `Test-Elevated`.
- **`Get-ScheduledTask` sem elevação devolve vazio** para tarefas de SYSTEM em vez de negar
  acesso — falso negativo silencioso. Tarefas do próprio usuário (como `HerdrServer`) são
  consultáveis sem elevação.
- **O Herdr recarrega sem reiniciar** (`herdr server reload-config`), diferente do RustDesk.

## Limites reais

- A rolagem no **Terminal embutido do RustDesk** não é configurável — é um widget
  `xterm.dart` com ring buffer no cliente. Para ler o histórico de um agente use
  `scripts\Show-AgentTranscript.ps1`. Não sugira mexer em config do RustDesk ou do Herdr
  para "consertar" isso.
- **O som do Herdr no Windows está quebrado** (bug do player, não preferência).
  `[ui.sound] enabled = $false` é intencional — não "conserte" ligando de volta.
- Nenhuma verificação cobre conectar de outra máquina com a tela bloqueada. Peça o teste
  manual (`Win+L` + conectar de outro dispositivo).

## Idioma

Código, comentários e mensagens de saída **sem acentos** (ASCII) — os scripts rodam em
consoles com code page variável. O `README.md` e este arquivo usam pt-BR acentuado normal.
