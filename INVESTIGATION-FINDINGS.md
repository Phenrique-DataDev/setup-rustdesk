# Achados verificaveis do setup-rustdesk

Investigacao somente leitura realizada em 2026-10-18 sobre a maquina Windows de referencia e o repositorio `setup-rustdesk`.

Este documento inclui apenas pontos que podem ser verificados, testados ou corrigidos neste projeto. Nao e uma confirmacao de bug do RustDesk ou do Herdr. Nenhuma alteracao de codigo, servico, energia, senha ou configuracao operacional foi feita durante a investigacao.

## Escopo e evidencias

- Repositorio: `C:\Users\Pedro\Documents\Claude\setup-rustdesk`
- Commit observado: `c2b2837176b1d69e1a20c561b019f6385c772fa0`
- RustDesk instalado: `C:\Program Files\RustDesk\RustDesk.exe`
- Versao observada: `1.5.0+68`
- RustDesk.exe SHA-256: `7f6d1e09e5a9924f567962aa57a6b126b409bed4775d98074c727420438768dc`
- librustdesk.dll SHA-256: `da4889603c26c6c29fdaa4bb3aec857f9e714e9e795a2c031184bff78fe7c597`
- Diagnostico somente leitura: `C:\ProgramData\RustDesk\power-diagnostics-20261018-170733.txt`
- Validacao `.\Setup.ps1`: 1 falha e 5 avisos, todos registrados abaixo.
- Testes do projeto: 48 testes da biblioteca passaram; parser e checagem ASCII passaram em 25 arquivos.

## 1. Versao instalada diferente da versao fixada

**Classificacao:** risco operacional confirmado; nao e bug confirmado do RustDesk.

### Observacao

O projeto fixa RustDesk `1.4.9` em `config/version.psd1:28`, com SHA-256 em `config/version.psd1:32`. A maquina executa `1.5.0+68`.

Saida observada:

```text
[FALHA] versao instalada bate com o pin (1.4.9)
        instalada: 1.5.0
```

O comportamento vem de `scripts/Install-RustDesk.ps1:51-53`, que registra a divergencia como aviso durante a instalacao, enquanto `scripts/Test-RustDeskSetup.ps1:86-95` a apresenta como falha na verificacao.

### Impacto

O mesmo repositorio pode validar uma maquina contra uma versao diferente daquela que esta em execucao. Isso enfraquece a validade de conclusoes sobre chaves TOML, comportamento do servico, tela bloqueada, rede e terminal.

### Como verificar

```powershell
.\Setup.ps1
```

Ou:

```powershell
$pin = Import-PowerShellDataFile .\config\version.psd1
& 'C:\Program Files\RustDesk\RustDesk.exe' --version
$pin.Version
```

### Correcao possivel no projeto

Escolher explicitamente uma politica e cobri-la por teste:

1. Atualizar `Version` e `Sha256` para uma release validada.
2. Criar `config/version-custom.psd1` localmente para nao alterar o pin versionado.
3. Ou transformar a divergencia em bloqueio durante `-Install`, se o objetivo for impedir que uma maquina permaneça fora do pin.

Nao atualizar o hash sem verificar o instalador correspondente, sua assinatura Authenticode e a compatibilidade das configuracoes.

### Validacao necessaria

- Confirmar a release alvo.
- Obter o MSI correspondente.
- Conferir SHA-256 e certificado.
- Executar os testes do instalador em ambiente descartavel.
- Confirmar novamente as duas configuracoes e a tela bloqueada.

## 2. Falhas no autostart do Herdr podem ser tratadas como sucesso

**Classificacao:** fragilidade de verificacao; reproducao ainda pendente.

### Observacao

Em `scripts/Install-Herdr.ps1:211-227`, a chamada de `Register-ScheduledTask` fica dentro de `try/catch`. Em caso de erro, o script apenas adiciona:

```text
FALHA ao registrar o autostart: ...
```

e continua. O `catch` nao relanca a excecao nem altera explicitamente o codigo de saida.

O `Setup.ps1 -All` executa uma verificacao posterior, mas uma chamada isolada de `Install-Herdr.ps1` pode terminar sem que o chamador veja falha pelo codigo de processo.

### Impacto

Uma maquina pode ficar sem servidor Herdr no logon mesmo que a automacao pareca concluida. Isso afeta a recuperacao da sessao depois de logoff, reinicio ou perda de conexao.

### Como verificar

Em uma VM ou ambiente de teste:

1. Provocar uma falha controlada de `Register-ScheduledTask`.
2. Executar `.\scripts\Install-Herdr.ps1`.
3. Registrar `$LASTEXITCODE`.
4. Consultar a tarefa `HerdrServer`.
5. Fazer logoff/logon e confirmar se o servidor sobe.

Nao provocar essa falha na maquina de referencia sem aprovacao explicita.

### Correcao possivel no projeto

Depois de capturar a falha, fazer o script retornar erro quando o registro ou a confirmacao posterior falhar. A correcao deve preservar o modo `-WhatIf` e manter a mensagem orientada a diagnostico.

Tambem e recomendavel que `Setup.ps1 -All` diferencie:

- falha de instalacao;
- falha de registro da tarefa;
- servidor iniciado com atraso;
- servidor confirmado como ativo.

### Validacao necessaria

- Teste unitario ou harness para a falha de `Register-ScheduledTask`.
- Verificacao do codigo de saida.
- Teste de logon em VM Windows.
- Confirmacao de que `HerdrServer` e executado no perfil do usuario correto.

## 3. Espera fixa de tres segundos para confirmar o servidor Herdr

**Classificacao:** fragilidade de espera e diagnostico; nao e bug confirmado.

### Observacao

Em `scripts/Install-Herdr.ps1:235-244`, depois de iniciar o servidor, o script espera tres segundos:

```powershell
Start-Sleep -Seconds 3
if (Test-HerdrServer) {
    ...
} else {
    ...
}
```

O resultado negativo e apenas um aviso. Nao ha polling, prazo total, backoff ou uma segunda verificacao antes do fim do script.

### Impacto

Em logon pesado, disco ocupado, restauracao de uma sessao grande ou notebook saindo de espera, o servidor pode estar saudavel mas ainda nao responder dentro de tres segundos. O operador recebe um falso negativo. O caso oposto tambem e possivel: um processo que falha depois dos tres segundos pode parecer valido.

### Como verificar

Em ambiente de teste:

1. Introduzir atraso controlado antes de o servidor responder.
2. Executar `Install-Herdr.ps1`.
3. Comparar o aviso emitido com `herdr status server` depois de 5, 10 e 15 segundos.

### Correcao possivel no projeto

Substituir a espera fixa por polling limitado, por exemplo:

- prazo total configuravel;
- intervalo curto inicial;
- limite de tentativas;
- registro do ultimo estado observado;
- falha explicita apenas depois do prazo total;
- mensagem separando “ainda iniciando” de “nao iniciou”.

A implementacao deve continuar sem reiniciar um servidor ja ativo.

### Validacao necessaria

- Teste com inicializacao imediata.
- Teste com atraso.
- Teste com processo que nunca fica saudavel.
- Teste em notebook e em desktop.

## 4. Verificacao sem elevacao nao consegue provar o estado do perfil do servico

**Classificacao:** limitacao de observabilidade; comportamento documentado, nao bug confirmado.

### Observacao

O projeto ja trata corretamente o acesso negado como aviso em `scripts/Test-RustDeskSetup.ps1`. Na execucao sem elevacao, nao foi possivel ler:

- `C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config\RustDesk2.toml`;
- `C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config\RustDesk.toml`;
- senha do perfil do servico;
- tarefa SYSTEM do watchdog.

Saidas observadas incluem:

```text
[AVISO] config do servico legivel
        requer Administrador
[AVISO] senha do servico
        requer Administrador
[AVISO] tarefa agendada registrada
        requer Administrador para consultar tarefas de SYSTEM
```

### Impacto

Uma execucao comum de `.\Setup.ps1` pode parecer majoritariamente saudavel sem provar a parte que atende conexoes com a tela bloqueada.

### Como verificar

Executar uma segunda verificacao em PowerShell elevado:

```powershell
.\Setup.ps1
```

Depois comparar especialmente:

- as duas `RustDesk2.toml`;
- os dois `RustDesk.toml`;
- as duas senhas gravadas;
- recovery actions do servico;
- tarefa do watchdog.

### Correcao possivel no projeto

O projeto ja distingue `PASS`, `FALHA` e `AVISO`. Melhorias possiveis, sem mudar o comportamento operacional:

- imprimir no cabecalho quais verificacoes ficaram inconclusivas;
- emitir uma instrucao curta para repetir como Administrador;
- retornar um codigo de saida distinto para “falha” e “evidencia insuficiente”, se isso for compativel com o CI e automacoes existentes;
- incluir no relatorio uma lista explicita dos caminhos nao lidos.

Nao transformar automaticamente esse aviso em falha sem avaliar usos existentes de `Setup.ps1` sem elevacao.

### Validacao necessaria

- Execucao elevada na maquina de referencia.
- Execucao sem elevacao.
- Confirmacao de que nenhum segredo e impresso.
- Confirmacao de que tarefas SYSTEM nao sao classificadas como ausentes.

## 5. Eventos de esgotamento de portas efemeras precisam de triagem

**Classificacao:** sinal operacional observado; nao e bug confirmado do projeto.

### Observacao

A verificacao encontrou quatro eventos nos ultimos sete dias:

```text
4x (UDP 2, TCP 2)
ultima em 2026-10-17 15:50
```

O proprio projeto associa esses eventos a `Tcpip` IDs 4266 e 4231 em `scripts/Test-RustDeskSetup.ps1`.

### Impacto possivel

Durante o esgotamento, o RustDesk pode aparentar estar offline ou falhar ao abrir novas conexoes. O evento pode ser causado por outro processo e nao demonstra, sozinho, falha do RustDesk.

### Como verificar

1. Correlacionar o horario dos eventos com logs do RustDesk.
2. Consultar processos que abrem muitos sockets.
3. Comparar com falhas ou atrasos reais de conexao.
4. Verificar se a condicao se repete no desktop e no notebook.

O diagnostico somente leitura gerado em `C:\ProgramData\RustDesk\power-diagnostics-20261018-170733.txt` deve ser preservado como evidencia.

### Correcao possivel no projeto

Melhorar a mensagem para separar:

- evento observado;
- impacto confirmado;
- impacto ainda desconhecido;
- proximo comando de diagnostico.

O projeto nao deve declarar que o RustDesk falhou apenas porque encontrou um evento de esgotamento.

## 6. Cobertura de testes ainda nao exercita todos os caminhos de instalacao real

**Classificacao:** lacuna de teste confirmada pela documentacao do repositorio.

### Observacao

`BACKLOG.md` registra que alguns caminhos nao foram executados em uma maquina Windows zerada, incluindo:

- instalacao real do Herdr;
- escrita real da senha;
- execucao do `msiexec` do pin do RustDesk;
- ordem completa do `Setup.ps1 -All` com configs inicialmente inexistentes.

Os testes atuais cobrem parser, idempotencia, `-WhatIf`, sintaxe, ASCII e o harness de energia, mas nao substituem uma instalacao real.

### Impacto

Uma regressao pode permanecer invisivel em:

- criacao inicial dos dois perfis do RustDesk;
- permissao do perfil `LocalService`;
- instalacao do MSI;
- criacao da tarefa `HerdrServer`;
- escrita e sincronizacao da senha;
- ordem de inicializacao do servico e da UI.

### Correcao possivel no projeto

Adicionar ou documentar um roteiro de validacao em VM descartavel, sem colocar segredos ou arquivos `.toml`, `.bak` ou `.log` no repositorio. O roteiro deve registrar:

- versao do Windows;
- arquitetura;
- versoes antes e depois;
- codigos de saida;
- hashes dos instaladores;
- saida de `Setup.ps1 -All`;
- resultado da verificacao elevada;
- resultado apos reinicio e logon;
- teste manual separado com a tela bloqueada.

## Pontos explicitamente fora deste documento

- Comparacao com RustDesk celular: pendente por falta do APK.
- Alteracoes nos scripts ou configuracoes do projeto: nao realizadas.
- Issues ou PRs: nenhum foi publicado.
- Bug confirmado no Herdr: nenhum foi estabelecido nesta fase.
- Conclusoes dinamicas sobre a `librustdesk.dll`: a importacao Ghidra excedeu o limite de tempo; a limitacao nao foi tratada como evidencia de ausencia.
