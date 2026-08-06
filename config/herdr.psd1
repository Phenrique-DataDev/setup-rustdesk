<#
    Opcoes aplicadas no config.toml do Herdr (%APPDATA%\herdr\config.toml).

    Copie para herdr-custom.psd1 e edite: ele tem precedencia e esta no
    .gitignore, entao suas preferencias nao vao para o repositorio.

    Formato: secao = @{ chave = valor }. Diferente do .toml do RustDesk, os
    valores aqui usam os tipos nativos do TOML - $true vira true, numeros
    entram crus e strings ganham aspas duplas. Secoes aninhadas usam o nome
    com ponto: 'ui.toast' vira [ui.toast].

    O Herdr so aplica chaves que conhece; o resto do arquivo e preservado.

    --- Premissa deste arquivo -------------------------------------------
    O acesso e pelo Terminal embutido do RustDesk, de outras redes e tambem
    do Android. Nesse transporte a roda do mouse nao rola nada (ver README:
    e um widget xterm.dart com ring buffer de output, nao scrollback). Logo
    tudo aqui parte de: navegacao por teclado, tela pequena e conexao que
    cai.
#>
@{
    ui = @{
        # Captura de mouse pelo Herdr (default). No Terminal do RustDesk a
        # roda nao chega de qualquer forma; manter ligado preserva os cliques
        # na UI do Herdr quando voce usa area de trabalho remota ou esta
        # sentado na maquina.
        mouse_capture = $true

        # Linhas por entalhe da roda. Irrelevante pelo Terminal do RustDesk;
        # vale quando voce acessa pela area de trabalho remota ou localmente,
        # onde cada quadro custa caro e rolar de 3 em 3 linhas e lento.
        mouse_scroll_lines = 5

        # --- ganhar area util na tela ---------------------------------
        # Cada linha e cada coluna contam num celular ou numa janela remota
        # pequena, e o conteudo do agente e o que importa.

        # Esconde a barra de abas quando ha só uma. Ganha uma linha; novas
        # abas continuam em prefix+c.
        hide_tab_bar_when_single_tab = $true

        # Sem espacamento entre panes divididos - ganha linhas e colunas.
        # As bordas continuam ligadas, entao nao se perde a orientacao.
        pane_gaps = $false

        # Sidebar colapsada com largura zero em vez do trilho estreito.
        # Reabre com prefix+b quando precisar.
        sidebar_collapsed_mode = 'hidden'

        # Com a sidebar escondida, o rotulo do agente na borda do pane e o
        # que diz quem e quem sem precisar reabrir nada.
        show_agent_labels_on_pane_borders = $true

        # Abaixo desta largura o Herdr usa layout de coluna unica. O default
        # (64) e estreito demais para o cliente Android em paisagem, que fica
        # num meio-termo ruim: largo o bastante para o layout de desktop e
        # estreito demais para ele caber.
        mobile_width_threshold = 90

        # --- sobreviver ao transporte ---------------------------------
        # Redesenho completo ao reganhar foco. E o default, fixado de
        # proposito: numa sessao remota a superficie do terminal corrompe com
        # mais frequencia, e o custo do flash e menor que ficar com lixo na
        # tela sem saber se e o programa ou o transporte.
        redraw_on_focus_gained = $true
    }

    # Notificacoes: saber que o agente terminou sem ficar olhando a tela.
    'ui.toast' = @{
        # 'herdr' desenha o toast dentro da propria TUI, entao ele atravessa
        # o Terminal do RustDesk. 'system' e 'terminal' dependem do host
        # notificar o desktop - inutil quando voce nao esta vendo o desktop.
        delivery = 'herdr'
    }

    'ui.sound' = @{
        # Desligado porque nao funciona: o player de som do Herdr no Windows
        # esta quebrado (ver README, "Som do Herdr nao toca no Windows"). Ele
        # spawna um powershell.exe que usa System.Windows.Media.MediaPlayer, e
        # esse tipo do WPF depende de um dispatcher bombeando mensagens para
        # sinalizar MediaOpened/MediaEnded. Num console nao ha esse pump: a
        # espera consome os 15s do deadline, o Play() acontece com o prazo ja
        # vencido e o Close() vem logo atras - nao sai som. O log registra
        # 'sound playback failed ... exit code: 1'.
        #
        # Deixar ligado so gera WARN no log e promete um aviso que nao existe.
        # 'ui.sound.path' nao ajuda: troca o arquivo, nao o player.
        enabled = $false
    }

    session = @{
        # Retoma as sessoes nativas dos agentes depois de um restart do
        # servidor, em vez de abrir panes vazios. E o default; fixado porque
        # e exatamente o que se quer quando a conexao cai longe de casa.
        resume_agents_on_restore = $true
    }

    experimental = @{
        # Preserva o historico de tela dos panes entre restarts completos do
        # servidor. Experimental e desligado por default; vale o risco aqui
        # porque queda de conexao em rede alheia e o caso comum, nao a
        # excecao.
        pane_history = $true
    }

    advanced = @{
        # Historico por pane, em bytes (10 MB). Vale apenas para panes criados
        # depois: os existentes mantem o buffer que ja tinham.
        #
        # Nao ajuda a rolar o chat do agente (a TUI nao gera scrollback), mas
        # ajuda em panes de shell, onde 'prefix+e' abre o buffer num editor.
        scrollback_limit_bytes = 10485760
    }
}
