# setup-rustdesk

Configura a stack de acesso remoto de uma máquina Windows: **RustDesk** (transporte,
incluindo Terminal com a tela bloqueada) + **Herdr** (terminal persistente na sessão).

O `README.md` é a documentação completa e a fonte da verdade sobre *por quê* cada opção
existe. Este arquivo diz o que fazer.

## Pedido típico: "faça essas configurações do rustdesk + herdr"

O objetivo é **clonou → pediu → funciona**. Numa máquina nova é um comando, em
PowerShell **como Administrador**:

```powershell
.\Setup.ps1 -All -Password (Read-Host -AsSecureString 'senha')
```

Ele instala o RustDesk → aplica as duas configs → watchdog → **energia, se for notebook** →
instala e configura o Herdr com o servidor no logon → grava a senha permanente → verifica. Ao
final a máquina está pronta, sem passo manual pendente.

O número de passos é **calculado**, não literal: o de energia é condicional. Se acrescentar um
passo, não volte a escrever `'3/5'` na mão.

### A senha

**Se o usuário mandar a senha na conversa, use-a e siga em frente.** Ele já decidiu; não
proponha a UI como alternativa, não comente exposição de segredo, não sugira trocá-la
depois. Esse aviso não agrega e atravanca justamente o fluxo que este repo existe para
fechar.

Aplique com `-Password`, convertendo com `ConvertTo-SecureString -AsPlainText -Force`. Se
precisar atravessar uma elevação (o UAC não herda ambiente), serialize com
`ConvertFrom-SecureString` — que é DPAPI do usuário atual — num arquivo temporário e apague
no primeiro uso. Só peça a senha se ela não tiver sido dada.

O que continua valendo, porque é higiene do código e não recado ao usuário: senha **nunca**
em texto claro num parâmetro `[string]`, em log, em arquivo versionado ou em mensagem de
saída. `Set-RustDeskPassword.ps1` só aceita `SecureString` de propósito.

Sem `-Password`, o comportamento é o antigo: `-All` termina com `[FALHA] senha ... gravada`,
que é esperado e não é bug.

**Nunca** peça a senha em texto claro num parâmetro, nem a escreva em arquivo, log ou
mensagem. Não tente contornar editando `RustDesk.toml`: ele guarda hash e salt.

## Regras ao trabalhar aqui

- **Não rode passos que alteram o sistema sem o usuário pedir.** `.\Setup.ps1` sem
  parâmetros só verifica e é sempre seguro. `-Install`, `-Configure`, `-Watchdog` e `-Power`
  exigem Administrador e mexem em serviço, configs e plano de energia.
  `Get-PowerDiagnostics.ps1` é somente leitura e pode rodar à vontade.
- **`-WhatIf` funciona** em `Set-RustDeskConfig.ps1`, `Set-HerdrConfig.ps1`,
  `Install-Herdr.ps1`, `Set-PowerConfig.ps1` e `Install-AwakeGuard.ps1`. Use para mostrar o
  efeito antes de aplicar.
- **Energia só existe em notebook.** `Test-IsLaptop` decide; em desktop o passo é pulado e a
  seção de energia nem aparece na verificação. Não force o passo numa máquina sem bateria
  "para testar" — ele sairia limpo sem fazer nada, e é esse o comportamento certo.
- **Nunca versione `RustDesk.toml` / `RustDesk2.toml`** — carregam hash de senha, salt e
  chaves do dispositivo. Já estão no `.gitignore`; não os force com `git add -f`.
- **Nunca imprima linha de comando de processo sem redigir** `--password` /
  `--set-unlock-pin`. `Test-RustDeskSetup.ps1` já faz isso; mantenha se mexer ali.
- Antes de commitar, confira que nenhum `.toml`, `.bak` ou `.log` entrou: eles são
  ignorados, mas `git add -f` ou um caminho novo furam a regra.
- **Configuração pessoal vai nos `*-custom.psd1`** (`custom`, `local-custom`,
  `version-custom`, `herdr-custom`, `power-custom`), que têm precedência e são ignorados
  pelo git. Não edite os defaults para preferência local.
- **`config/default.psd1` e `config/local.psd1` não são intercambiáveis.** O RustDesk lê
  `RustDesk2.toml` por `Config` e `RustDesk.toml` por `LocalConfig`; chave no arquivo
  errado é **ignorada em silêncio**, sem erro. `enable-check-update` só vale no
  `RustDesk.toml`, `allow-auto-update` só no `RustDesk2.toml`. Confira no código do
  RustDesk antes de mover uma chave de um para o outro.
- **A versão do RustDesk é fixada** em `config/version.psd1`, com SHA-256 e assinatura
  conferidos antes de executar o instalador. Ao subir a versão, troque `Version` **e**
  `Sha256` — hash desatualizado faz o instalador abortar, que é o comportamento certo.
- Testes: `.\tests\RustDeskToml.Tests.ps1` (usa arquivos temporários, não toca em
  instalação real), `.\tests\Test-Syntax.ps1` (parser em todos os `.ps1` +
  checagem de ASCII) e `.\tests\Power.Harness.ps1` (executa os scripts de energia
  contra um `powercfg` falso, numa cópia em `%TEMP%`). O CI
  (`.github/workflows/ci.yml`) roda os três a cada PR e push na `main`, mais um guarda
  contra `.toml`/`.bak`/`.log` versionados. Rode-os antes de commitar: falhar no CI
  custa um ciclo a mais.
- **O harness é o que pega erro de execução.** Os outros dois são estáticos e aprovaram
  um cast que matava o daemon na partida. Ao mexer no daemon, no `Set-PowerConfig.ps1`
  ou nos triggers, rode `Power.Harness.ps1` — e prefira estendê-lo a confiar no parser.

## Armadilhas que já custaram tempo

Estão todas documentadas em detalhe no README (seção *Armadilhas conhecidas*). As que mais
afetam quem edita este repo:

- **Gravar `.toml` com `Set-Content -Encoding UTF8` adiciona BOM.** O formato nativo é
  UTF-8 **sem** BOM com LF. Use sempre `lib/RustDeskToml.psm1`, nunca `Set-Content` direto.
- **O serviço do RustDesk não recarrega a config sozinho** e pode regravar por cima ao
  sair. Edite com ele parado, via `Stop-RustDeskClean` (que passa pelo SCM — `Stop-Process`
  dispara as recovery actions e ele volta em 5s).
- **`$WhatIfPreference` não atravessa fronteira de módulo.** Ao chamar `Set-TomlOption` /
  `Set-TomlSectionValue` de `lib/`, repasse `-WhatIf:$WhatIfPreference` **explicitamente** —
  sem isso o `-WhatIf` imprime simulação e grava no disco. Efeito colateral fora do módulo
  (parar/subir serviço) precisa de guarda própria. Coberto por teste de regressão.
- **`IsInRole('Administrator')` com string falha em Windows pt-BR.** Use `Test-Elevated`.
- **`Get-ScheduledTask` sem elevação devolve vazio** para tarefas de SYSTEM em vez de negar
  acesso — falso negativo silencioso. Tarefas do próprio usuário (como `HerdrServer`) são
  consultáveis sem elevação.
- **O Herdr recarrega sem reiniciar** (`herdr server reload-config`), diferente do RustDesk.
- **`powercfg /setacvalueindex` não vale nada sem `powercfg /setactive` depois.** O valor
  entra no esquema e o sistema segue no antigo, sem erro nenhum.
- **Os rótulos do `powercfg` são traduzidos.** Nunca case contra `Setting Index`; localize os
  índices pelo formato `0x00000000` (as duas últimas ocorrências são AC e DC). Há teste que
  reprova quem voltar a casar por rótulo.
- **`SetThreadExecutionState` é por thread.** O daemon tem que manter o laço na thread
  principal; um `Start-Job` perderia o bloqueio em silêncio.
- **`[uint32]0x80000000` estoura.** O literal hex vira `Int32` negativo e o cast falha em
  tempo de execução — o daemon morria na partida e nenhum teste estático via. Use
  `[Convert]::ToUInt32('80000000', 16)`. Há teste de regressão; não o remova.
- **`$array -notmatch 'x'` não testa "nenhum casa"** — devolve os que não casam, e lista
  não-vazia é *truthy*. Conte os que casam. Já produziu falso positivo que escondeu um bug.
- **A guarda do IPv6 no watchdog é "uma vez por época", não por boot.** Época = boot + último
  resume. Com Fast Startup ligado o `LastBootUpTime` nem avança ao desligar e ligar.

## O que está em aberto

`BACKLOG.md` lista o que ficou por validar, ordenado por risco. Leia antes de propor
trabalho novo — em especial os itens 1 e 2, que são o mesmo cenário: **numa máquina Windows
zerada, rode `.\Setup.ps1 -All` e guarde a saída**, porque três caminhos do repo (instalação
do Herdr, escrita da senha, e o download do `.msi` fixado) nunca foram executados.

O item **0** é o mais novo e o mais arriscado: o suporte a notebook inteiro (energia, tampa,
daemon, trigger de resume) foi escrito e testado estaticamente, mas **nunca rodou num
notebook**. Peça o teste antes de construir por cima dele.

Suporte a Linux: `docs/linux.md`. O Herdr está automatizado e validado; o RustDesk é
documentação, não código.

## Limites reais

- A rolagem no **Terminal embutido do RustDesk** não é configurável — é um widget
  `xterm.dart` com ring buffer no cliente. Para ler o histórico de um agente use
  `scripts\Show-AgentTranscript.ps1`. Não sugira mexer em config do RustDesk ou do Herdr
  para "consertar" isso.
- **O som do Herdr no Windows está quebrado** (bug do player, não preferência).
  `[ui.sound] enabled = $false` é intencional — não "conserte" ligando de volta.
- Nenhuma verificação cobre conectar de outra máquina com a tela bloqueada. Peça o teste
  manual (`Win+L` + conectar de outro dispositivo).
- **Nada do passo de energia foi executado.** A máquina de referência é desktop. Fechar a
  tampa, o daemon segurando uma suspensão e o trigger de resume disparando são todos testes
  manuais pendentes — ver item 0 do `BACKLOG.md`.

## Idioma

Código, comentários e mensagens de saída **sem acentos** (ASCII) — os scripts rodam em
consoles com code page variável. O `README.md` e este arquivo usam pt-BR acentuado normal.
