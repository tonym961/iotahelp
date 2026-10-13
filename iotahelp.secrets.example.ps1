<#
    ESEMPIO - copia questo file come 'iotahelp.secrets.ps1' e metti i valori reali.
    Il file reale NON e' versionato (vedi .gitignore): contiene le credenziali di accesso
    alle macchine installate. La build lo legge e inietta i valori nell'exe.
#>
@{
    RD_PASSWORD  = 'password-rustdesk-e-supremo'
    RD_KEY       = 'chiave-pubblica-del-tuo-server-rustdesk='
    VNC_PASSWORD = 'maxotto'        # TightVNC: massimo 8 caratteri (limite dello standard VNC)
}
