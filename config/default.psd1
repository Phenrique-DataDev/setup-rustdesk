<#
    Opcoes aplicadas nas DUAS configs do RustDesk (usuario e servico).

    Copie para custom.psd1 e edite: custom.psd1 tem precedencia e esta no
    .gitignore, entao suas preferencias nao vao para o repositorio.

    Formato: chave = valor. Os valores viram 'texto' no .toml.
#>
@{
    # --- necessarias para terminal com a tela bloqueada ---------------

    # Habilita a funcao Terminal (RustDesk 1.4.0+). Explicito de proposito:
    # o default pode mudar entre versoes.
    'enable-terminal'                  = 'Y'

    # Permite autenticar na tela de logon/bloqueio. Sem isso ha relatos de a
    # conexao travar em "Waiting for remote approval" com a maquina bloqueada.
    'allow-logon-screen-password'      = 'Y'

    # Autenticacao por senha permanente, sem depender de alguem clicar
    # "aceitar" na ponta remota - impossivel com a tela bloqueada.
    'verification-method'              = 'use-permanent-password'
    'approve-mode'                     = 'password'

    # 'Y' aqui desliga o acesso remoto inteiro. Fixado em 'N' de proposito;
    # o watchdog tambem vigia esta chave.
    'stop-service'                     = 'N'

    # --- caminho de conexao rapido ------------------------------------
    # Sem isto, TODA conexao passa pelo servidor de rendezvous publico: o
    # RustDesk tenta furar o NAT (hole punching) e, quando falha, espera o
    # timeout antes de pedir relay. Sao ~10 segundos de "carregando" antes de
    # qualquer imagem aparecer, e o relay publico ainda fica longe.
    #
    # Com direct-server, quem conecta pode digitar o IP da maquina em vez do
    # ID: a sessao abre direto, sem rendezvous, sem punch e sem relay. Na mesma
    # rede e imediato. De fora, exige encaminhar a porta abaixo no roteador -
    # nenhuma config do RustDesk substitui isso.
    #
    # O ID continua funcionando normalmente: isto ADICIONA um caminho, nao
    # troca o existente.
    'direct-server'                    = 'Y'
    'direct-access-port'               = '21118'

    # Deixa a maquina aparecer sozinha na aba de descoberta dos clientes da
    # mesma rede, sem precisar decorar o IP.
    'enable-lan-discovery'             = 'Y'

    # --- recursos gerais ----------------------------------------------
    'enable-keyboard'                  = 'Y'
    'enable-clipboard'                 = 'Y'
    'enable-file-transfer'             = 'Y'
    'enable-audio'                     = 'Y'

    # Fonte do audio transmitido. Vazio = loopback da saida padrao do Windows,
    # ou seja, o som do sistema. Preencher com o nome de um dispositivo troca a
    # captura para aquele microfone - e, se o nome nao bater exatamente com um
    # endpoint de captura ('Microfone (Fulano)', nao 'Fulano'), a captura nao
    # sobe e a sessao fica muda sem erro visivel.
    'audio-input'                      = ''
    'enable-tunnel'                    = 'Y'
    'enable-remote-restart'            = 'Y'

    # --- seguranca ----------------------------------------------------
    # 'Y' deixa quem conecta alterar a configuracao desta maquina.
    # O default aqui e 'N'; mude com consciencia.
    'allow-remote-config-modification' = 'N'

    # Atualizacao automatica desligada: uma atualizacao no meio de um acesso
    # remoto derruba a sessao e pode mexer no servico.
    'allow-auto-update'                = 'N'
}
