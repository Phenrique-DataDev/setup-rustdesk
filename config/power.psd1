<#
    Opcoes de energia aplicadas por scripts/Set-PowerConfig.ps1 e lidas pelo
    daemon RustDeskAwake. So valem em maquina portatil: em desktop o passo
    inteiro e pulado.

    Copie para config/power-custom.psd1 para mudar - o custom TEM PRECEDENCIA e
    e ignorado pelo git. Nao edite este arquivo para preferencia local.

    O custom SUBSTITUI este arquivo, nao funde chave a chave: se criar um, ele
    precisa ter todas as chaves. E o mesmo comportamento de default.psd1 e
    herdr.psd1.
#>
@{
    # Acao ao fechar a tampa: 0 = nada, 1 = suspender, 2 = hibernar, 3 = desligar.
    # 0 nos dois porque a premissa deste repositorio e que a maquina fica
    # alcancavel; com a tampa fechada so o painel apaga.
    LidActionAC = 0
    LidActionDC = 0

    # Suspender por ociosidade, em segundos. 0 = nunca.
    # Na bateria continua existindo de proposito: quem impede a suspensao no
    # meio do trabalho e o daemon RustDeskAwake, enquanto ha sessao remota. Nao
    # dormir nunca custaria bateria em troca de nada nas horas sem ninguem.
    StandbyIdleAC = 0
    StandbyIdleDC = 1800

    # Hibernar por ociosidade, em segundos. 0 = nunca. Hibernar derruba o
    # servico e a sessao do Herdr - e o pior caso para acesso remoto.
    HibernateIdleAC = 0
    HibernateIdleDC = 0

    # Desligar o painel por ociosidade, em segundos. Economia gratuita: a
    # captura de tela do RustDesk continua funcionando com o monitor apagado, e
    # em notebook o painel e o maior consumidor isolado.
    VideoIdleAC = 600
    VideoIdleDC = 180

    # Conectividade de rede em espera moderna (S0ix): 0 = desligado,
    # 1 = ligado, 2 = gerenciado pelo Windows. So existe em maquina com Modern
    # Standby; onde nao existe, o passo e pulado sem erro.
    ConnectivityInStandby = 1

    # Desligar o "permitir que o computador desligue este dispositivo" do
    # adaptador de rede ativo. E causa classica de voltar da suspensao com a
    # rede fora do ar por alguns minutos. $null = nao mexer.
    DisableNicPowerSaving = $true

    # --- daemon RustDeskAwake -----------------------------------------
    # $false nao instala a tarefa.
    KeepAwakeWhileConnected = $true

    # De quanto em quanto tempo o daemon reavalia. Precisa ser bem menor que
    # StandbyIdleDC para reagir antes de a maquina dormir.
    KeepAwakePollSeconds = 30

    # Rede de seguranca: abaixo desta carga o bloqueio e solto mesmo com sessao
    # remota ativa. Sem isto, um agente esquecido rodando na bateria levaria a
    # maquina a desligar por carga zero, que e pior que suspender.
    KeepAwakeMinBatteryPercent = 15
}
