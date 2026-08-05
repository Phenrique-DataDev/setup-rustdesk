<#
    Opcoes aplicadas no config.toml do Herdr (%APPDATA%\herdr\config.toml).

    Copie para herdr-custom.psd1 e edite: ele tem precedencia e esta no
    .gitignore, entao suas preferencias nao vao para o repositorio.

    Formato: secao = @{ chave = valor }. Diferente do .toml do RustDesk, os
    valores aqui usam os tipos nativos do TOML - $true vira true, numeros
    entram crus e strings ganham aspas duplas.

    O Herdr so aplica chaves que conhece; o resto do arquivo e preservado.
#>
@{
    ui = @{
        # Mantem a captura de mouse pelo Herdr (default). E o que faz as TUIs
        # de tela cheia - lazygit, btop, o chat do agente - RECEBEREM os
        # eventos de roda: a doc do Herdr diz que "pane apps can still receive
        # mouse when they request it" justamente com a captura ligada.
        #
        # Com $false o Herdr nao intercepta e a roda vai para o terminal
        # hospedeiro, que dentro do Herdr nao tem scrollback nenhum para rolar
        # - a roda simplesmente nao faz nada. Foi o erro da versao anterior
        # deste arquivo.
        mouse_capture = $true

        # Linhas por entalhe da roda. 3 e o default; suba se a rolagem parecer
        # lenta na sessao remota, onde cada quadro custa mais.
        mouse_scroll_lines = 3
    }

    advanced = @{
        # Historico por pane, em bytes (10 MB). Vale apenas para panes criados
        # depois: os existentes mantem o buffer que ja tinham.
        scrollback_limit_bytes = 10485760
    }
}
