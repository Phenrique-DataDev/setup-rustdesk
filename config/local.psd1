<#
    Opcoes aplicadas nos DOIS RustDesk.toml (usuario e servico).

    ATENCAO - este arquivo NAO e o default.psd1. O RustDesk tem duas configs de
    nomes quase iguais e semanticas diferentes:

        RustDesk2.toml  ->  Config       ->  config/default.psd1
        RustDesk.toml   ->  LocalConfig  ->  este arquivo

    Uma opcao lida por LocalConfig nao tem efeito nenhum se for escrita no
    RustDesk2.toml, e vice-versa - e nao ha erro, ela simplesmente e ignorada.
    Antes de mover uma chave de um arquivo para o outro, confira no codigo do
    RustDesk qual das duas a le.

    O RustDesk.toml tambem guarda hash de senha, salt e as chaves do
    dispositivo. Nunca versione esse arquivo nem o .bak que a gravacao cria.

    Copie para local-custom.psd1 para mudar sem tocar no repo: ele tem
    precedencia e esta no .gitignore.
#>
@{
    # Desliga a checagem de nova versao - o aviso de "ha uma atualizacao".
    # Lida por LocalConfig em src/common.rs, check_software_update().
    #
    # A chave comeca com 'enable-', e para esse prefixo o RustDesk trata
    # qualquer valor diferente de 'N' como ligado (option2bool no hbb_common).
    # Ou seja: o default e ligado, e so o 'N' explicito desliga.
    #
    # A atualizacao automatica em si e barrada por 'allow-auto-update', que
    # vive na outra config - veja config/default.psd1.
    'enable-check-update' = 'N'
}
