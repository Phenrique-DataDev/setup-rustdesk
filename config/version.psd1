<#
    Versao do RustDesk que este repositorio instala.

    Fixada de proposito. Sem pin, cada maquina configurada recebe o que estiver
    publicado no dia, e duas maquinas montadas com o mesmo repo em semanas
    diferentes ficam em versoes diferentes - o oposto de "clonou, pediu,
    funciona".

    Para subir a versao:
      1. escolha uma release NAO marcada como prerelease em
         https://github.com/rustdesk/rustdesk/releases
      2. baixe o rustdesk-<versao>-x86_64.msi
      3. troque Version e Sha256 aqui

    O instalador recusa o arquivo se o hash nao bater, entao um pin com hash
    errado falha alto em vez de instalar algo inesperado.

    Voce nao precisa vigiar as releases: o CI (.github/workflows/ci.yml) compara
    este Version com a ultima estavel e avisa quando ele fica para tras. E aviso,
    nao falha - ficar parado na versao fixada e o comportamento seguro.

    Copie para version-custom.psd1 para fixar outra versao sem tocar no repo:
    ele tem precedencia e esta no .gitignore.
#>
@{
    # Ultima estavel em 2026-08-11. Releases 'nightly' sao prerelease e ficam
    # fora de proposito.
    Version = '1.4.9'

    # SHA-256 do rustdesk-1.4.9-x86_64.msi publicado na release 1.4.9.
    # Conferido no arquivo baixado em 2026-08-11 (24.825.856 bytes).
    Sha256 = 'C87D2F4CEF2A5ACD6003B6507DCFBF5D5168A256DB082CD90B54D35193224AAA'

    # {0} = versao. O nome do arquivo segue o mesmo padrao em toda release.
    UrlTemplate = 'https://github.com/rustdesk/rustdesk/releases/download/{0}/rustdesk-{0}-x86_64.msi'

    # Assunto esperado no certificado do instalador. A verificacao de
    # Authenticode roda alem do hash: o hash prova que o arquivo e o mesmo que
    # foi fixado aqui, a assinatura prova de quem ele veio.
    SignerSubject = 'CN=PURSLANE'
}
