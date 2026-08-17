# Tutorial: deixe o seu PC acessível de qualquer lugar em ~20 minutos

Este é o caminho passo a passo para quem **nunca abriu o PowerShell**. Se você já usa
terminal e Git, o [`README.md`](../README.md) resolve em dois comandos — vá direto para
o *Início rápido* de lá.

## Overview

- **O que você vai construir:** o seu PC com Windows ligado em casa, acessível pelo
  celular ou por outro computador — inclusive **com a tela bloqueada**, sem precisar de
  ninguém sentado nele para clicar "aceitar".
- **Público-alvo:** qualquer pessoa que use Windows. Nenhum conhecimento de terminal,
  Git ou redes é assumido.
- **Tempo estimado:** 20 a 30 minutos, quase todo de download.

## Background

Duas ferramentas são instaladas, e elas fazem coisas diferentes:

| Ferramenta | Para que serve |
|---|---|
| **RustDesk** | O transporte. É por ele que você vê a tela e digita à distância. |
| **Herdr** | Um terminal que **continua rodando** quando a conexão cai. Opcional para quem só quer ver a tela; essencial se você deixa tarefas longas trabalhando. |

O motivo de este repositório existir: o RustDesk no Windows guarda **duas configurações
separadas** — uma para quando você está sentado na máquina, outra para quando a tela está
bloqueada. Configurar só pela janela do RustDesk mexe numa e esquece a outra, e o
resultado é o clássico "funciona quando estou lá, falha quando saio". Os scripts daqui
escrevem nas duas e conferem as duas.

Você não precisa entender isso para seguir o tutorial. Só precisa saber que é por isso
que existe um script em vez de "instale e pronto".

## Antes de começar

- [ ] Windows 10 ou 11 na máquina que você quer acessar
- [ ] Ser **administrador** dessa máquina (é a sua conta pessoal? então você é)
- [ ] Internet funcionando — o setup baixa dois instaladores
- [ ] Um segundo aparelho para testar depois: celular, tablet ou outro PC
- [ ] Uma senha em mente, só para o acesso remoto. Escolha uma **forte e diferente das
      suas outras** — qualquer pessoa na internet que descubra o seu ID vai poder tentar
      essa senha.

Não é preciso instalar Git, `winget` ou qualquer outra coisa antes. O passo 1 resolve.

---

## Passos

### 1. Baixe o repositório

Abra o link abaixo no navegador **da máquina que você quer acessar**:

```
https://github.com/Phenrique-DataDev/setup-rustdesk
```

Clique no botão verde **`Code`** e depois em **`Download ZIP`**.

Abra a pasta `Downloads`, clique com o botão direito no arquivo
`setup-rustdesk-main.zip` e escolha **`Extrair tudo…`** → **`Extrair`**.

**Resultado esperado:** uma pasta chamada `setup-rustdesk-main` dentro de `Downloads`,
com arquivos como `Setup.ps1`, `README.md` e as pastas `config` e `scripts` dentro dela.

> Se você já tem Git instalado e prefere o terminal:
> `git clone https://github.com/Phenrique-DataDev/setup-rustdesk.git`

### 2. Abra o PowerShell como Administrador

Este é o passo que mais confunde, e pular ele faz o setup parar na metade.

1. Aperte a tecla **Windows** e digite `powershell`.
2. Na lista, o primeiro resultado é **Windows PowerShell**. **Não clique nele.**
   Clique com o **botão direito** e escolha **`Executar como administrador`**.
3. O Windows vai perguntar "Deseja permitir que este aplicativo faça alterações no seu
   dispositivo?" — clique em **`Sim`**.

**Resultado esperado:** uma janela azul-escura (ou preta) de terminal, e o título da
janela começa com **`Administrador:`**. Se não começar, você abriu a versão comum —
feche e repita com o botão direito.

### 3. Entre na pasta que você baixou

Na janela do PowerShell, digite o comando abaixo e aperte **Enter**:

```powershell
cd "$env:USERPROFILE\Downloads\setup-rustdesk-main"
```

**Resultado esperado:** a linha de comando muda e passa a terminar com
`\Downloads\setup-rustdesk-main>`.

Se aparecer `Cannot find path` (caminho não encontrado), a pasta extraída tem outro
nome. Abra o `Downloads` no Explorador de Arquivos, veja o nome exato e troque no
comando.

### 4. Veja o estado atual (não muda nada)

Este comando só **olha** a máquina e relata. Ele não instala nada, não altera nada e é
seguro rodar a qualquer momento:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Setup.ps1
```

> O `-ExecutionPolicy Bypass` está aí porque o Windows bloqueia scripts baixados da
> internet por padrão. Ele vale **só para este comando** — não desliga a proteção do
> sistema.

**Resultado esperado:** uma lista de linhas começando com `[OK]`, `[FALHA]` ou
`[AVISO]`, e no fim um resumo do tipo `=== N falha(s), N aviso(s) ===`. Numa máquina que
ainda não tem nada, **é normal quase tudo estar em `[FALHA]`** — é exatamente isso que o
próximo passo vai resolver.

### 5. Rode o setup completo

Agora o comando que faz o trabalho. Digite exatamente assim:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Setup.ps1 -All -Password (Read-Host -AsSecureString 'senha')
```

Ao apertar Enter, aparece `senha:` e o cursor fica parado.

> **A senha não aparece na tela enquanto você digita.** Nem asteriscos, nem pontinhos —
> nada. Isso é proposital, não é travamento. Digite a senha escolhida e aperte
> **Enter** normalmente.

A partir daí o script trabalha sozinho por alguns minutos, imprimindo blocos numerados
(`1/6`, `2/6`, …). Ele baixa o instalador do RustDesk (versão fixada **1.4.9**, com o
hash e a assinatura conferidos antes de executar), instala, aplica as configurações,
instala o vigia que garante que o serviço não morre, instala o Herdr e grava a senha.

**Resultado esperado:** no fim, o bloco `6/6 Verificando` e a linha verde:

```
=== OK: nenhuma falha (N aviso(s)) ===
```

Avisos (`[AVISO]`) são aceitáveis — são checagens que não se aplicam à sua máquina ou
que dependem de algo externo. **Falhas** (`[FALHA]`) não. Se aparecer alguma, veja
[Se algo deu errado](#se-algo-deu-errado) no fim.

### 6. Anote o seu ID

Aperte a tecla **Windows**, digite `rustdesk` e abra o **RustDesk**.

Na janela, do lado esquerdo, há um campo com um número de 9 ou 10 dígitos — esse é o
**ID** da máquina.

**Resultado esperado:** você tem em mãos duas informações: o **ID** (o número) e a
**senha** que digitou no passo 5. É só isso que o outro aparelho precisa.

> O ID é público por natureza; a senha é o que protege. Guarde a senha num gerenciador
> de senhas, não num papel colado no monitor.

### 7. Teste do outro aparelho — com a tela bloqueada

O teste que importa não é conectar com você sentado na máquina. É este:

1. No **outro** aparelho, instale o RustDesk: no celular, procure "RustDesk" na loja de
   aplicativos; noutro PC, baixe em <https://rustdesk.com>.
2. Volte à máquina configurada e aperte **`Windows` + `L`** para **bloquear a tela**.
   Não faça logoff nem desligue — só bloquear.
3. No outro aparelho, digite o **ID** e conecte. Quando pedir a senha, use a do passo 5.

**Resultado esperado:** você vê a tela de bloqueio do Windows a partir do outro
aparelho, digita a senha da sua conta Windows ali mesmo e entra na sessão — **sem
ninguém tocar na máquina**. Se conectou com a tela desbloqueada mas falha bloqueada, é
exatamente o problema que este repositório resolve: rode o passo 4 de novo como
Administrador e veja qual linha está em `[FALHA]`.

---

## Resumo

Você tem uma máquina Windows que atende conexões remotas sozinha, autenticando por senha
permanente, com a tela bloqueada — o cenário em que a configuração padrão do RustDesk
falha calada. O serviço tem duas camadas de proteção contra ficar fora do ar (as
*recovery actions* do Windows e um vigia que roda a cada 10 minutos), as atualizações
automáticas estão desligadas para a versão não mudar debaixo de você, e o Herdr está
instalado com o servidor subindo sozinho a cada logon.

O comando que você mais vai usar daqui pra frente é o do passo 4: ele só verifica e
nunca altera nada.

---

## Se algo deu errado

| O que apareceu | O que fazer |
|---|---|
| `Este modo exige privilegios de Administrador.` | A janela do PowerShell não é a de Administrador. Refaça o passo 2 — o título tem que começar com `Administrador:`. |
| `Cannot find path` no `cd` | O nome da pasta extraída é outro. Confira no Explorador de Arquivos. |
| A senha não aparece enquanto digito | Correto, é assim mesmo. Digite e aperte Enter. |
| Terminou com `[FALHA] senha ... gravada` | Você rodou sem o `-Password`. Rode `powershell.exe -ExecutionPolicy Bypass -File .\scripts\Set-RustDeskPassword.ps1` como Administrador. |
| Falha no download do instalador | Antivírus ou rede bloqueando `github.com`. Tente de outra rede. |
| Outra `[FALHA]` qualquer | Confira a seção *Armadilhas conhecidas* do [`README.md`](../README.md); se não resolver, copie a saída inteira e abra uma *issue* no repositório. |

> **Aviso honesto:** o caminho "máquina Windows recém-formatada" ainda tem trechos que
> nunca foram executados de ponta a ponta (veja os itens 1 e 2 do
> [`BACKLOG.md`](../BACKLOG.md)). Se você é a primeira pessoa a rodar isto numa máquina
> zerada e algo falhar, a saída do comando é informação valiosa — mande.

---

## Próximos passos

- **Está lento para conectar de fora de casa?** É esperado: sem configuração extra, a
  primeira conexão passa por um servidor público e demora ~10 s. O `README.md` explica
  o que dá (e o que não dá) para fazer a respeito, na seção *Conexão direta*.
- **Quer deixar tarefas longas rodando e voltar depois?** É para isso que serve o Herdr.
  Comece pela seção *O terminal dentro da sessão (Herdr)* do `README.md` — o atalho que
  resolve boa parte do uso é `ctrl+b` seguido de `q`, que desanexa deixando tudo rodando.
- **Quer mudar alguma configuração?** Não edite os arquivos de `config/` direto: copie
  para `custom.psd1` e edite a cópia. A seção *Personalizando* do `README.md` explica
  por quê.

---

*Mantido junto com o `README.md` — ao mudar um passo do `Setup.ps1`, revise este arquivo.
Os comandos aqui refletem o repositório em 2026-08-17 (RustDesk fixado em 1.4.9).*
