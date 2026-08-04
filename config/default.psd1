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

    # --- recursos gerais ----------------------------------------------
    'enable-keyboard'                  = 'Y'
    'enable-clipboard'                 = 'Y'
    'enable-file-transfer'             = 'Y'
    'enable-audio'                     = 'Y'
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
