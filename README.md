# iotahelp

Installer di teleassistenza **iotatec**: un unico eseguibile con GUI che installa in modo **non presidiato** gli strumenti di controllo remoto, con password preimpostate e server già configurato.

Un solo consenso UAC all'avvio, poi procede da solo fino a "Installazione completata".

## Componenti

| Tool | Cosa fa | Default |
|------|---------|---------|
| **RustDesk** | Installa, registra il servizio in avvio automatico, applica ID server + relay + chiave e la password permanente | ✅ ON |
| **Supremo** | Imposta la password fissa per l'accesso non presidiato e il servizio all'avvio | ✅ ON |
| **TightVNC** | Installa il Server come servizio con eccezione firewall e password | ⬜ OFF |

I tool vengono **scaricati dai siti ufficiali** all'installazione. La build `-Offline` li incorpora nell'eseguibile per installare senza rete (checkbox "Installa offline", spenta di default).

## Credenziali

I valori reali **non sono versionati**. Il sorgente contiene segnaposto (`@@RD_PASSWORD@@`, `@@RD_KEY@@`, `@@VNC_PASSWORD@@`) che la build sostituisce leggendo `iotahelp.secrets.ps1`.

```powershell
Copy-Item iotahelp.secrets.example.ps1 iotahelp.secrets.ps1
# poi inserisci i valori reali
```

Senza quel file la build si ferma con un errore esplicito.

> Gli **eseguibili compilati contengono le credenziali** (ps2exe incorpora lo script: sono estraibili con `strings`). Per questo i binari sono esclusi da git e vanno distribuiti a parte.

## Build

Richiede il modulo [ps2exe](https://github.com/MScholtes/PS2EXE).

```powershell
.\build-iotahelp.ps1                    # iotatau-help.exe          (online, firmato)
.\build-iotahelp.ps1 -Offline -Latest   # iotatau-help-offline.exe  (tool incorporati, ultime versioni)
.\build-iotahelp.ps1 -Preview           # anteprima: mostra la GUI e simula, senza admin
```

- **`-Latest`** confronta le versioni remote con quelle in cache e riscarica solo ciò che è cambiato.
- `-Refresh` svuota la cache e riscarica tutto.
- La build stampa sempre le versioni incorporate, e la versione mostrata nella GUI è letta da `$AppVersion`.

## Note tecniche (trappole già pagate)

- **`RD` è un alias di `Remove-Item`** in PowerShell: una funzione con quel nome non viene mai invocata. Le funzioni interne si chiamano `RdRun`, `RdGetId`, … Stesso discorso per `sc` (alias di `Set-Content`): si usa `sc.exe`.
- **Mai redirigere lo stdout di rustdesk su una pipe.** Lancia processi figli che la ereditano e non la chiudono: `ReadToEnd()` resta bloccato per sempre, anche dopo `WaitForExit`, e nessun timeout può intervenire. L'output va su file tramite un `.bat`.
- **`rustdesk --config` scrive nel profilo di chi esegue il comando.** Eseguito da admin finirebbe in `%APPDATA%` dell'amministratore, mentre il servizio legge il proprio profilo. Si esegue quindi **come SYSTEM** (task pianificato temporaneo) e si scrive anche nei profili utente reali (letti da `ProfileList`).
- **La chiave di registro di TightVNC nega la scrittura anche all'admin**: la password si imposta solo tramite le proprietà dell'MSI, e quelle valgono solo a nuova installazione. Se la password memorizzata coincide già, l'installazione viene saltata.

## Log

Diagnostica su `C:\iotatec\iotahelp_deploy.log`. In caso di errore viene aperto automaticamente.
