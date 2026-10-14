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
- **msiexec: `"NOME=valore"` non è una forma valida, e non dà errore — si appende per sempre.** Se si racchiude fra virgolette l'intero token invece del solo valore, msiexec apre la finestra d'uso di Windows Installer *anche con `/quiet`* e non esce mai; chi lo ha lanciato va in timeout, uccide `cmd.exe` e si ritrova msiexec orfano con una finestra modale. Misurato: `/x {guid} /quiet "ADDLOCAL=Server"` → nessuna uscita in 120 s; `ADDLOCAL="Server"` → risposta in 0,07 s. Colpiva **solo TightVNC** perché è l'unico componente a passare parametri `NOME=valore` (RustDesk e Supremo usano solo switch con `-`), e spiegava sia "non si installa" sia "si blocca e non va avanti manco in timeout".
- **Mai redirigere lo stdout di rustdesk su una pipe.** Lancia processi figli che la ereditano e non la chiudono: `ReadToEnd()` resta bloccato per sempre, anche dopo `WaitForExit`, e nessun timeout può intervenire. L'output va su file tramite un `.bat`.
- **`rustdesk --config` scrive nel profilo di chi esegue il comando.** Eseguito da admin finirebbe in `%APPDATA%` dell'amministratore, mentre il servizio legge il proprio profilo. Si esegue quindi **come SYSTEM** (task pianificato temporaneo) e si scrive anche nei profili utente reali (letti da `ProfileList`).
- **TightVNC: le proprietà MSI della password valgono solo a installazione nuova.** La custom action che la scrive (`SetPasswordsActionSilently`) ha condizione `NOT (!Server=3)`, quindi su una macchina dove TightVNC c'è già l'MSI installa o ripara ma *non* tocca la password. Reinstallare la stessa versione sopra se stessa non è una via d'uscita: aborta con un errore fatale (`AlreadyUpdated`, condizione `SELFFOUND`). E `msiexec /x <percorso.msi>` disinstalla solo se il ProductCode di quel file è quello installato — con una versione diversa risponde 1605 e non rimuove niente.
  Quindi l'ordine è rovesciato: prima si scrive la password nel registro **come SYSTEM** (è esattamente ciò che fa l'MSI, con una custom action deferred/NoImpersonate: l'admin elevato da solo non basta), e solo se non funziona si passa a disinstalla-per-ProductCode + reinstalla. La password viene sempre **riletta e confrontata**: non si dichiara "OK" senza averla verificata.

## Log

Diagnostica su `C:\iotatec\iotahelp_deploy.log`. In caso di errore viene aperto automaticamente.
