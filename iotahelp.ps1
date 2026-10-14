<#
    iotahelp.ps1  ->  iotahelp.exe   (iotatec - assistenza remota)
    ------------------------------------------------------------------
    Launcher di teleassistenza con GUI a checkbox. Installa in modo
    NON PRESIDIATO (unattended) i tool selezionati:

      [x] RustDesk  - controllo remoto (server + servizio + password)
      [x] Supremo   - password fissa + servizio all'avvio
      [ ] TightVNC  - server + servizio + password (max 8 char)   (OFF di default)

    - Un solo UAC all'avvio (-requireAdmin), poi procede da solo.
    - Scarica sempre l'ULTIMA versione di ciascun tool (niente exe incorporati).
    - FIX password RustDesk: imposta la password SOLO dopo che il servizio
      risponde via IPC (--get-id), poi VERIFICA sul profilo del SERVIZIO e RIPROVA.

    Build:  .\build-iotahelp.ps1   (vedi build-iotahelp.ps1)
    ------------------------------------------------------------------
#>

# ==================== CONFIGURAZIONE (modifica qui) ====================
# --- PASSWORD per RustDesk e Supremo ---
$Password = '@@RD_PASSWORD@@'                          # apici SINGOLI (nessuna interpolazione)

# --- RustDesk ---
$RD_Host     = 'iotadesks.myftp.org'
$RD_Relay    = 'iotadesks.myftp.org'
$RD_Key      = '@@RD_KEY@@'

# --- Supremo (hai la Console Professional: puoi mettere l'URL del TUO Supremo personalizzato) ---
$SUP_Url      = 'https://www.nanosystems.it/public/download/Supremo.exe'
$SUP_Service  = $true                               # $true = installa servizio all'avvio

# --- TightVNC ---
$VNC_MsiUrl   = 'https://www.tightvnc.com/download/2.8.90/tightvnc-2.8.90-gpl-setup-64bit.msi'  # fallback
$VNC_Password = '@@VNC_PASSWORD@@'                          # password VNC (MAX 8 caratteri standard VNC)

# --- Default delle checkbox ---
$Def_Rust = $true
$Def_Sup  = $true
$Def_Vnc  = $false

$AppVersion       = '1.6.1'                         # <<< versione mostrata nella GUI e nell'exe.
#                                                   #     SI INCREMENTA L'ULTIMA CIFRA: 1.6.0 -> 1.6.1 -> 1.6.2 ...
#                                                   #     Niente salti alla cifra di mezzo.
$PreviewMode      = $false                          # $true = build ANTEPRIMA (simula, non installa, senza admin)
$OfflineBuild     = $false                          # $true = build con file incorporati (impostato da build -Offline)
$DownloadDir      = 'C:\iotatec'
$AutoCloseSeconds = 10
# ======================================================================

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$SelfExe = try { [System.Reflection.Assembly]::GetExecutingAssembly().Location } catch { $null }
if (-not $SelfExe) { $SelfExe = $MyInvocation.MyCommand.Path }

# ---- file offline incorporati (estratti qui dall'exe all'avvio, se build -Offline) ----
$OfflineDir = Join-Path $env:TEMP 'iotatec_offline'
$OfflineAvailable = ($OfflineBuild -and (Test-Path (Join-Path $OfflineDir 'rustdesk_installer.exe')) -and (Test-Path (Join-Path $OfflineDir 'Supremo.exe')) -and (Test-Path (Join-Path $OfflineDir 'tightvnc.msi')))

# ---- logo in-finestra (PNG base64 iniettato in build) + icona dall'exe come fallback ----
$LogoPngB64 = '@@LOGO_B64@@'
function Get-LogoImage {
    try {
        if ($LogoPngB64 -and $LogoPngB64 -notmatch '^@@') {
            $bytes = [Convert]::FromBase64String($LogoPngB64)
            $ms = New-Object System.IO.MemoryStream(,$bytes)
            return [System.Drawing.Image]::FromStream($ms)
        }
    } catch {}
    try { return ([System.Drawing.Icon]::ExtractAssociatedIcon($SelfExe)).ToBitmap() } catch {}
    return $null
}
function Get-FormIcon { try { return [System.Drawing.Icon]::ExtractAssociatedIcon($SelfExe) } catch { return $null } }

# ---- configurazione condivisa (sola lettura nel worker) ----
$cfg = @{
    rdHost = $RD_Host; rdRelay = $RD_Relay; rdKey = $RD_Key; rdPassword = $Password
    supUrl = $SUP_Url; supPassword = $Password; supService = [bool]$SUP_Service
    vncMsiUrl = $VNC_MsiUrl; vncPassword = $VNC_Password
    downloadDir = $DownloadDir
    preview = [bool]$PreviewMode
    offlineDir = $OfflineDir
}

# ---- stato condiviso worker <-> GUI ----
$sync = [hashtable]::Synchronized(@{
    doRust = $false; doSup = $false; doVnc = $false; offline = $false
    state  = [hashtable]::Synchronized(@{ rust = 'pending'; sup = 'pending'; vnc = 'pending' })
    status = 'Pronto.'
    target = 0
    rustId = ''; supId = ''
    done = $false
    error = $null
})

# ==================== WORKER ====================
$worker = {
    param($sync, $cfg)

    $dir = $cfg.downloadDir
    $LogFile = Join-Path $dir 'iotahelp_deploy.log'
    function Log($m) { try { Add-Content -LiteralPath $LogFile -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -ErrorAction SilentlyContinue } catch {} }
    function St($msg) { $sync.status = $msg; Log $msg }

    # Termina un processo E TUTTI I SUOI DISCENDENTI (prima i figli, poi il padre).
    # Serve perche' qui si lancia sempre tramite cmd.exe: uccidere solo cmd lascerebbe orfano il
    # programma vero, e se quello ha aperto una finestra modale (msiexec lo fa, e lo fa anche con
    # /quiet quando la riga di comando non gli piace) la finestra resterebbe sullo schermo
    # dell'utente per sempre, con l'installazione apparentemente ferma.
    function Stop-ProcTree([int]$procId) {
        try {
            foreach ($c in (Get-CimInstance Win32_Process -Filter ("ParentProcessId=" + $procId) -EA SilentlyContinue)) {
                Stop-ProcTree ([int]$c.ProcessId)
            }
        }
        catch {}
        try { Stop-Process -Id $procId -Force -EA SilentlyContinue } catch {}
    }
    # esegue un processo (nascosto) catturando stdout/stderr; ritorna @{Code;Out}
    function Invoke-Proc([string]$file, [string[]]$argList, [int]$timeoutSec = 120) {
        # MAI usare pipe (RedirectStandardOutput/Error) con rustdesk: lancia processi FIGLI che
        # ereditano la pipe e non la chiudono mai -> ReadToEnd() resta bloccato PER SEMPRE, anche
        # dopo che WaitForExit e' gia' ritornato (il timeout non puo' piu' intervenire).
        # Qui si redirige su FILE tramite un .bat: nessuna pipe, quindi nessun blocco possibile.
        if (-not (Test-Path -LiteralPath $dir)) { try { New-Item -ItemType Directory -Force -Path $dir | Out-Null } catch {} }
        $tag = [guid]::NewGuid().ToString('N').Substring(0, 6)
        $bat = Join-Path $dir ('proc_' + $tag + '.bat')
        $outF = Join-Path $dir ('proc_' + $tag + '.txt')
        try {
            $line = '"' + $file + '"'
            foreach ($a in $argList) {
                $q = ([string]$a) -replace '%', '%%'      # % e' speciale dentro un .bat
                if ($q.StartsWith('-') -or $q.StartsWith([char]47)) { $line += ' ' + $q }
                elseif (($file -like '*msiexec*') -and ($q -match '^([A-Z][A-Z0-9_]*)=(.*)$')) {
                    # ATTENZIONE: per msiexec la forma "NOME=valore" (virgolette su TUTTO il token)
                    # NON e' valida, e non da' nemmeno un errore: apre la finestra d'uso di Windows
                    # Installer ANCHE con /quiet e NON ESCE MAI. Al timeout qui viene ucciso cmd.exe
                    # e msiexec resta orfano con la finestra modale -> era la causa di "TightVNC si
                    # blocca e non va avanti manco in timeout", e colpiva solo TightVNC perche' e'
                    # l'unico a passare parametri NOME=valore. Verificato: token quotato per intero
                    # -> appeso a tempo indefinito; NOME="valore" -> risposta in 0,07 s.
                    # La forma documentata e' NOME="valore": virgolette solo sul VALORE.
                    $line += ' ' + $Matches[1] + '="' + $Matches[2] + '"'
                }
                else { $line += ' "' + $q + '"' }
            }
            Set-Content -LiteralPath $bat -Value ("@echo off`r`n" + $line + ' > "' + $outF + '" 2>&1') -Encoding ASCII
            $pi = New-Object System.Diagnostics.ProcessStartInfo
            $pi.FileName = 'cmd.exe'
            $pi.Arguments = '/c "' + $bat + '"'
            $pi.UseShellExecute = $false
            $pi.CreateNoWindow = $true
            $proc = [System.Diagnostics.Process]::Start($pi)
            if (-not $proc.WaitForExit($timeoutSec * 1000)) {
                Log ("timeout " + $timeoutSec + "s: termino " + (Split-Path $file -Leaf) + " e i suoi figli")
                Stop-ProcTree $proc.Id
                return @{ Code = -1; Out = 'timeout' }
            }
            $code = -1; try { $code = [int]$proc.ExitCode } catch {}
            $o = ''
            try { if (Test-Path -LiteralPath $outF) { $o = (Get-Content -LiteralPath $outF -Raw -EA SilentlyContinue) } } catch {}
            return @{ Code = $code; Out = ("" + $o).Trim() }
        }
        catch { return @{ Code = -1; Out = $_.Exception.Message } }
        finally { Remove-Item -LiteralPath $bat, $outF -Force -EA SilentlyContinue }
    }
    # Esegue una riga di comando qualsiasi COME SYSTEM (task pianificato temporaneo) e ne cattura
    # l'output su file. Serve sia a RustDesk (--config scrive nel profilo del chiamante) sia a
    # TightVNC (la sua chiave di registro nega la lettura anche all'admin).
    function SysCmd([string]$cmdLine, [int]$timeoutSec = 120) {
        $tn = 'iotatec_rd_cfg'
        $bat = Join-Path $dir 'rd_sys.bat'
        $outF = Join-Path $dir 'rd_sys_out.txt'
        Remove-Item -LiteralPath $outF -Force -EA SilentlyContinue
        Set-Content -LiteralPath $bat -Value ("@echo off`r`n" + $cmdLine + ' > "' + $outF + '" 2>&1') -Encoding ASCII
        try {
            Unregister-ScheduledTask -TaskName $tn -Confirm:$false -EA SilentlyContinue
            $act = New-ScheduledTaskAction -Execute $bat
            $pri = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
            Register-ScheduledTask -TaskName $tn -Action $act -Principal $pri -Settings $set -Force | Out-Null
            Start-ScheduledTask -TaskName $tn
            $sw3 = [Diagnostics.Stopwatch]::StartNew(); Start-Sleep -Milliseconds 900
            while ($sw3.Elapsed.TotalSeconds -lt $timeoutSec) {
                $t = Get-ScheduledTask -TaskName $tn -EA SilentlyContinue
                if (-not $t -or ([string]$t.State) -ne 'Running') { break }
                Start-Sleep -Milliseconds 700
            }
        }
        catch { Log ("SYSTEM errore: " + $_.Exception.Message); Remove-Item -LiteralPath $bat, $outF -Force -EA SilentlyContinue; return @{ Code = -1; Out = 'SYSTEM_FAIL' } }
        finally { Unregister-ScheduledTask -TaskName $tn -Confirm:$false -EA SilentlyContinue }
        $o = ''
        $ran = (Test-Path -LiteralPath $outF)   # il .bat redirige sempre: senza il file il task non e' partito
        try { if ($ran) { $o = (Get-Content -LiteralPath $outF -Raw -EA SilentlyContinue) } } catch {}
        # il .bat e il suo output contengono la riga di comando (quindi anche le password): via dal disco
        Remove-Item -LiteralPath $bat, $outF -Force -EA SilentlyContinue
        # distinguere "comando eseguito senza output" da "task mai eseguito" evita di confondere un
        # guasto dello scheduler con un risultato negativo (es. "password assente")
        if (-not $ran) { Log 'SYSTEM: il task non ha prodotto alcun output (non eseguito?)'; return @{ Code = -1; Out = 'SYSTEM_FAIL' } }
        return @{ Code = 0; Out = ("" + $o).Trim() }
    }
    function Get-File([string]$url, [string]$dest) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $dest -Headers @{ 'User-Agent' = 'iotahelp' } -UseBasicParsing -TimeoutSec 300
    }
    # blob cifrato password TightVNC (DES a chiave fissa VNC, bit invertiti)
    function Get-VncBlob([string]$pw) {
        $fixed = [byte[]](0x17, 0x52, 0x6b, 0x06, 0x23, 0x4e, 0x58, 0x07)
        $key = New-Object byte[] 8
        for ($i = 0; $i -lt 8; $i++) { $b = $fixed[$i]; $r = 0; for ($j = 0; $j -lt 8; $j++) { $r = ($r -shl 1) -bor ($b -band 1); $b = $b -shr 1 }; $key[$i] = [byte]$r }
        $pt = New-Object byte[] 8
        $pb = [System.Text.Encoding]::ASCII.GetBytes($pw)
        for ($i = 0; $i -lt 8 -and $i -lt $pb.Length; $i++) { $pt[$i] = $pb[$i] }
        $des = New-Object System.Security.Cryptography.DESCryptoServiceProvider
        $des.Mode = 'ECB'; $des.Padding = 'None'; $des.Key = $key
        $enc = $des.CreateEncryptor(); $out = $enc.TransformFinalBlock($pt, 0, 8); $des.Dispose()
        return $out
    }

    # ---------- RustDesk ----------
    function Install-RustDesk {
        $exeUrlHeaders = @{ 'User-Agent' = 'iotahelp' }
        $installer = Join-Path $dir 'rustdesk_installer.exe'
        $InstallDir = Join-Path $env:ProgramFiles 'RustDesk'
        $RustDeskExe = Join-Path $InstallDir 'rustdesk.exe'
        $svcCfg = @(
            'C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config\RustDesk.toml',
            'C:\Windows\System32\config\systemprofile\AppData\Roaming\RustDesk\config\RustDesk.toml'
        )
        function RdRun([string[]]$a, [int]$t = 30) { Invoke-Proc $RustDeskExe $a $t }
        function RdGetId {
            $r = RdRun @('--get-id') 8
            if ($r.Out -match '(\d{6,})') { return $Matches[1] }
            return ''
        }
        function RdReady([int]$to = 150) {
            # prontezza basata sull'IPC (--get-id risponde), non sullo stato Get-Service che puo' ingannare
            $sw = [Diagnostics.Stopwatch]::StartNew(); $n = 0; $recovered = $false
            while ($sw.Elapsed.TotalSeconds -lt $to) {
                $s = Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
                # Start() SOLO se davvero fermo: su StartPending solleva eccezione e disturba l'SCM
                if ($s -and $s.Status -eq 'Stopped') { try { $s.Start() } catch {} }
                $id = RdGetId
                if ($id) { $sync.rustId = $id; Log ("RD pronto: id=$id dopo $([int]$sw.Elapsed.TotalSeconds)s"); return $true }
                $n++
                if ($n % 5 -eq 0) { Log ("RD attesa IPC $([int]$sw.Elapsed.TotalSeconds)s, servizio=$(if ($s) { $s.Status } else { 'assente' })") }

                # RECUPERO (una volta sola): servizio impantanato in StartPending/StopPending o assente.
                # Si entra qui solo quando RustDesk gia' non funziona, quindi terminare i processi e'
                # il modo standard per sbloccare un servizio appeso.
                if (-not $recovered -and $to -ge 100 -and $sw.Elapsed.TotalSeconds -ge 40) {
                    $recovered = $true
                    Log ("RD RECUPERO: servizio=" + $(if ($s) { $s.Status } else { 'assente' }) + " -> termino i processi e reinstallo il servizio")
                    $sync.status = 'RustDesk: sblocco il servizio...'
                    try { Get-Process -Name 'rustdesk' -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue } catch {}
                    Start-Sleep -Seconds 3
                    try { & sc.exe stop RustDesk 2>&1 | Out-Null } catch {}   # sc.exe: 'sc' da solo e' alias di Set-Content
                    Start-Sleep -Seconds 2
                    RdRun @('--install-service') 60 | Out-Null
                    Start-Sleep -Seconds 4
                    $s2 = Get-Service -Name 'RustDesk' -EA SilentlyContinue
                    if ($s2 -and $s2.Status -eq 'Stopped') { try { $s2.Start() } catch {} }
                    Log ("RD dopo recupero: servizio=" + $(if ($s2) { (Get-Service RustDesk -EA SilentlyContinue).Status } else { 'assente' }))
                    $sync.status = 'RustDesk: servizio (avvio automatico)...'
                }
                Start-Sleep -Milliseconds 2000
            }
            Log "RD IPC non pronta entro il timeout."
            return $false
        }
        function RdPwSet {
            foreach ($p in $svcCfg) {
                try {
                    if (Test-Path -LiteralPath $p) {
                        $l = Select-String -LiteralPath $p -Pattern '^\s*password\s*=' -EA SilentlyContinue | Select-Object -First 1
                        if ($l -and $l.Line -notmatch "=\s*''" -and $l.Line -notmatch '=\s*""') { return $true }
                    }
                } catch {}
            }
            return $false
        }
        # Esegue rustdesk COME SYSTEM (task pianificato temporaneo).
        # Serve perche' --config scrive nel profilo del processo chiamante: da admin finirebbe in
        # %APPDATA% dell'utente, mentre il SERVIZIO legge il proprio profilo (ServiceProfiles\LocalService).
        function RdSystem([string[]]$rdArgs, [int]$timeoutSec = 120) {
            $line = '"' + $RustDeskExe + '"'
            foreach ($a in $rdArgs) { if ($a -like '--*') { $line += ' ' + $a } else { $line += ' "' + $a + '"' } }
            return (SysCmd $line $timeoutSec)
        }
        # NB: SysCmd e' definita a livello di worker, perche' serve anche a TightVNC

        # verifica password leggendo la config del SERVIZIO come SYSTEM (l'admin non puo' leggerla)
        function RdPwSetSystem {
            try {
                $v = SysCmd ('type "' + $svcCfg[0] + '"') 60
                if ($v.Out -match "(?m)^\s*password\s*=\s*['`"]\s*\S") { return $true }
            } catch {}
            return $false
        }

        # Scrive server/chiave/relay dentro un RustDesk2.toml (merge delle sole chiavi che gestiamo).
        # Serve perche' --config scrive SOLO nel profilo di chi lo esegue: se l'UAC e' stato soddisfatto
        # con un altro account admin, l'utente che usa il PC resterebbe senza configurazione.
        function Set-RdToml([string]$tomlPath) {
            try {
                $d = Split-Path $tomlPath -Parent
                if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
                $lines = @()
                if (Test-Path -LiteralPath $tomlPath) { $lines = @(Get-Content -LiteralPath $tomlPath -EA SilentlyContinue) }
                $lines = @($lines | Where-Object { $_ -notmatch '^\s*(custom-rendezvous-server|key|relay-server)\s*=' })
                if (-not ($lines -match '^\s*\[options\]')) { $lines += ''; $lines += '[options]' }
                $out = New-Object System.Collections.Generic.List[string]
                $added = $false
                foreach ($l in $lines) {
                    $out.Add($l)
                    if (-not $added -and $l -match '^\s*\[options\]') {
                        $out.Add("custom-rendezvous-server = '" + $cfg.rdHost + "'")
                        $out.Add("key = '" + $cfg.rdKey + "'")
                        $out.Add("relay-server = '" + $cfg.rdRelay + "'")
                        $added = $true
                    }
                }
                Set-Content -LiteralPath $tomlPath -Value $out -Encoding UTF8
                return $true
            }
            catch { Log ("toml KO " + $tomlPath + ": " + $_.Exception.Message); return $false }
        }
        # applica la config a TUTTI i profili utente della macchina
        function Set-RdAllUsers {
            $n = 0
            $dirs = New-Object System.Collections.Generic.List[string]
            # elenco autorevole dei profili reali dal registro: gestisce percorsi non standard
            # (profili su altro disco, ProfilesDirectory spostata) ed esclude gli account di sistema
            try {
                Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -EA SilentlyContinue | ForEach-Object {
                    if ($_.PSChildName -match '^S-1-5-(18|19|20)$') { return }
                    $pp = (Get-ItemProperty $_.PSPath -Name ProfileImagePath -EA SilentlyContinue).ProfileImagePath
                    if ($pp -and (Test-Path -LiteralPath $pp)) { $dirs.Add($pp) }
                }
            }
            catch {}
            if ($dirs.Count -eq 0) {
                # ripiego se il registro non e' leggibile
                foreach ($u in (Get-ChildItem (Join-Path $env:SystemDrive 'Users') -Directory -EA SilentlyContinue)) { $dirs.Add($u.FullName) }
            }
            foreach ($p in $dirs) {
                $roaming = Join-Path $p 'AppData\Roaming'
                if (-not (Test-Path -LiteralPath $roaming)) { continue }
                $t = Join-Path $roaming 'RustDesk\config\RustDesk2.toml'
                if (Set-RdToml $t) { $n++; Log ("toml OK " + $t) }
            }
            return $n
        }

        if (Test-Path -LiteralPath $RustDeskExe) {
            # gia' installato: NON reinstallare (l'installer con -Wait resterebbe appeso). Riconfiguro soltanto.
            St 'RustDesk: gia'' presente, riconfiguro...'; $sync.target = [Math]::Max($sync.target, 18)
        }
        else {
            if ($sync.offline) {
                St 'RustDesk: installazione (offline)...'; $sync.target = [Math]::Max($sync.target, 15)
                $installer = Join-Path $cfg.offlineDir 'rustdesk_installer.exe'
                if (-not (Test-Path -LiteralPath $installer)) { throw "RustDesk: file offline mancante." }
            }
            else {
                St 'RustDesk: scarico ultima versione...'; $sync.target = [Math]::Max($sync.target, 8)
                $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/rustdesk/rustdesk/releases/latest' -Headers $exeUrlHeaders
                $asset = $rel.assets | Where-Object { $_.name -match 'rustdesk-.*-x86_64\.exe$' -and $_.name -notmatch 'portable' } | Select-Object -First 1
                if (-not $asset) { throw "RustDesk: pacchetto x86_64 non trovato." }
                Get-File $asset.browser_download_url $installer
                St 'RustDesk: installazione...'; $sync.target = [Math]::Max($sync.target, 15)
            }
            $ip = Start-Process -FilePath $installer -ArgumentList '--silent-install' -PassThru -WindowStyle Hidden
            if (-not $ip.WaitForExit(120000)) { try { $ip.Kill() } catch {} }
            $sw = [Diagnostics.Stopwatch]::StartNew()
            while (-not (Test-Path -LiteralPath $RustDeskExe) -and $sw.Elapsed.TotalSeconds -lt 90) { Start-Sleep -Seconds 2 }
            if (-not (Test-Path -LiteralPath $RustDeskExe)) { throw "RustDesk: eseguibile non trovato dopo l'installazione." }
            if (-not $sync.offline) { Remove-Item -LiteralPath $installer -Force -EA SilentlyContinue }
        }

        St 'RustDesk: servizio (avvio automatico)...'; $sync.target = [Math]::Max($sync.target, 20)
        $svc0 = Get-Service -Name 'RustDesk' -EA SilentlyContinue
        Log ("RD servizio dopo install: " + $(if ($svc0) { $svc0.Status } else { 'ASSENTE' }))
        if (-not $svc0) {
            $ris = RdRun @('--install-service') 60
            Log ("RD --install-service code=" + $ris.Code + " out=" + ($ris.Out -replace '\s+', ' '))
            $sw2 = [Diagnostics.Stopwatch]::StartNew()
            while (-not (Get-Service -Name 'RustDesk' -EA SilentlyContinue) -and $sw2.Elapsed.TotalSeconds -lt 30) { Start-Sleep -Seconds 2 }
            Log ("RD servizio dopo --install-service: " + $(if (Get-Service -Name 'RustDesk' -EA SilentlyContinue) { (Get-Service RustDesk).Status } else { 'ANCORA ASSENTE' }))
        }
        try { Set-Service -Name 'RustDesk' -StartupType Automatic -EA SilentlyContinue } catch {}
        $svc1 = Get-Service -Name 'RustDesk' -EA SilentlyContinue
        if ($svc1 -and $svc1.Status -eq 'Stopped') { try { $svc1.Start() } catch {} }
        if (-not (RdReady 150)) { throw "RustDesk: il servizio non risponde (IPC) nemmeno dopo lo sblocco. Vedi log in C:\iotatec\iotahelp_deploy.log." }

        St 'RustDesk: server e chiave...'; $sync.target = [Math]::Max($sync.target, 24)
        $amAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        Log ("RD gate: elevato=$amAdmin  exe_installato=" + (Test-Path -LiteralPath $RustDeskExe))
        $cfgStr = 'host=' + $cfg.rdHost + ',key=' + $cfg.rdKey + ',relay=' + $cfg.rdRelay
        # COME SYSTEM: --config scrive nel profilo del chiamante; da admin finirebbe in %APPDATA%
        # dell'utente e il SERVIZIO non la vedrebbe mai.
        $rc = RdSystem @('--config', $cfgStr) 90
        Log ("RD --config (SYSTEM) -> [" + ($rc.Out -replace '\s+', ' ') + "]")
        if ($rc.Out -match 'privileges|Installation and admin') { throw ("RustDesk ha rifiutato --config: " + $rc.Out) }
        if ($rc.Out -eq 'SYSTEM_FAIL') { Log 'RD fallback: --config come admin'; RdRun @('--config', $cfgStr) 30 | Out-Null }
        Log ("RD config scritta in " + (Set-RdAllUsers) + " profili utente")
        Start-Sleep -Seconds 2
        try { Restart-Service -Name 'RustDesk' -Force -EA SilentlyContinue } catch {}
        Start-Sleep -Seconds 3
        if (-not (RdReady 120)) { throw "RustDesk: servizio non operativo dopo la configurazione." }

        # il processo uscente puo' riscrivere il proprio toml: riapplico dopo il riavvio
        Log ("RD config riscritta in " + (Set-RdAllUsers) + " profili utente")
        $chk = RdSystem @('--option', 'custom-rendezvous-server') 60
        Log ("RD verifica servizio -> [" + ($chk.Out -replace '\s+', ' ') + "]")
        # verifica reale: almeno un profilo utente contiene il nostro server
        $okCfg = $false
        foreach ($u in (Get-ChildItem 'C:\Users' -Directory -EA SilentlyContinue)) {
            $t = Join-Path $u.FullName 'AppData\Roaming\RustDesk\config\RustDesk2.toml'
            if (Test-Path -LiteralPath $t) {
                if ((Get-Content -LiteralPath $t -Raw -EA SilentlyContinue) -match [regex]::Escape($cfg.rdHost)) { $okCfg = $true; break }
            }
        }
        Log ("RD config presente nei profili utente: " + $okCfg)
        if (-not $okCfg -and $chk.Out -notmatch [regex]::Escape($cfg.rdHost)) {
            throw ("RustDesk: server non applicato. Verifica servizio: '" + ($chk.Out -replace '\s+', ' ') + "'")
        }

        St 'RustDesk: imposto la password...'
        $ok = $false; $lastOut = ''
        for ($i = 1; $i -le 6 -and -not $ok; $i++) {
            $sync.status = "RustDesk: imposto la password (tentativo $i)..."
            if (-not (RdReady 60)) { continue }
            $r = RdSystem @('--password', $cfg.rdPassword) 60
            if ($r.Out -eq 'SYSTEM_FAIL') { $r = RdRun @('--password', $cfg.rdPassword) 30 }
            $lastOut = $r.Out
            Log ("RD --password (try $i) -> " + ($r.Out -replace '\s+', ' '))
            Start-Sleep -Seconds 3
            # prima la verifica autorevole (config del servizio letta come SYSTEM), poi i ripieghi:
            # cosi' funziona anche se RustDesk non stampa "Done!" o cambia messaggio
            if ((RdPwSetSystem) -or ($r.Out -match 'Done') -or (RdPwSet)) { $ok = $true; break }
            if ($r.Out -match 'privileges|Installation and admin') { break }
            Start-Sleep -Seconds 3
        }
        if (-not $ok) { throw ("RustDesk: password non applicata. Risposta di RustDesk: '" + ($lastOut -replace '\s+', ' ') + "'") }
        if (-not $sync.rustId) { $sync.rustId = RdGetId }
        Remove-Item -LiteralPath $installer -Force -EA SilentlyContinue
        Log ("RustDesk OK. ID=" + $sync.rustId)
    }

    # ---------- Supremo ----------
    function Install-Supremo {
        if ($sync.offline) {
            $exe = Join-Path $cfg.offlineDir 'Supremo.exe'
            St 'Supremo: configuro (offline)...'
            if (-not (Test-Path -LiteralPath $exe)) { throw "Supremo: file offline mancante." }
        }
        else {
            $exe = Join-Path $dir 'Supremo.exe'
            St 'Supremo: scarico ultima versione...'
            Get-File $cfg.supUrl $exe
            if (-not (Test-Path -LiteralPath $exe)) { throw "Supremo: download fallito." }
        }

        St 'Supremo: configuro accesso non presidiato...'
        Invoke-Proc $exe @('-run-as-sys', '1') 30 | Out-Null
        # password fissa via stdin
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $exe; $psi.Arguments = '-set-password'
            $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true; $psi.CreateNoWindow = $true
            $p = [System.Diagnostics.Process]::Start($psi)
            $p.StandardInput.WriteLine($cfg.supPassword); $p.StandardInput.Close()
            if (-not $p.WaitForExit(20000)) { try { $p.Kill() } catch {} }
        } catch { Log ("Supremo set-password: " + $_.Exception.Message) }

        if ($cfg.supService) {
            St 'Supremo: servizio all'' avvio...'
            Invoke-Proc $exe @('-servicesetup') 40 | Out-Null
            Start-Sleep -Seconds 3
        }
        $r = Invoke-Proc $exe @('/get-id') 12
        if ($r.Out -match '(\d[\d\s]{5,})') { $sync.supId = ($Matches[1] -replace '\s', '') }

        # verifica: se ho chiesto il servizio, deve esistere davvero (altrimenti l'accesso
        # non presidiato non funzionerebbe e me ne accorgerei solo al momento del bisogno)
        if ($cfg.supService) {
            $ss = Get-Service -Name 'SupremoService' -EA SilentlyContinue
            if (-not $ss) { throw "Supremo: il servizio SupremoService non risulta registrato (accesso non presidiato non attivo)." }
            Log ("Supremo servizio: " + $ss.Status)
            if ($ss.Status -eq 'Stopped') { try { $ss.Start() } catch {} }
        }
        # la password finisce qui: se il file manca, segnalo ma non blocco (il percorso puo' cambiare tra versioni)
        $datOk = (Test-Path -LiteralPath 'C:\ProgramData\Supremo\RemoteDesktop\settings.dat')
        if (-not $datOk) { Log 'ATTENZIONE Supremo: settings.dat non trovato nel percorso noto, password non verificabile' }
        Log ("Supremo OK. ID=" + $sync.supId + "  settings=" + $datOk)
    }

    # ---------- TightVNC ----------
    # Qui l'ordine delle operazioni e' rovesciato rispetto a quello che sembrerebbe naturale, e il
    # motivo sta tutto nell'MSI di TightVNC (verificato leggendone le tabelle):
    #  - le proprieta' SET_PASSWORD / VALUE_OF_PASSWORD valgono SOLO a installazione NUOVA: la custom
    #    action che scrive la password (SetPasswordsActionSilently) ha condizione "NOT (!Server=3)",
    #    quindi su una macchina dove TightVNC c'e' gia' l'MSI installa o ripara ma NON tocca la password;
    #  - reinstallare la STESSA versione sopra se stessa ABORTA: custom action AlreadyUpdated (tipo 19,
    #    errore fatale) con condizione SELFFOUND -> "TightVNC has already been updated";
    #  - "msiexec /x <percorso.msi>" disinstalla solo se il ProductCode di QUEL file e' quello
    #    installato: con una versione diversa restituisce 1605 e non rimuove niente.
    # Percio': prima si prova a scrivere la password nel registro COME SYSTEM (e' esattamente cio' che
    # fa l'MSI, con una custom action deferred/NoImpersonate: l'admin elevato da solo non basta), e
    # solo se non funziona si passa a disinstalla-per-ProductCode + reinstalla. In ogni caso la
    # password viene RILETTA e CONFRONTATA: non si dichiara mai "OK" senza averla verificata.
    function Install-TightVNC {
        $pw = [string]$cfg.vncPassword
        if ([string]::IsNullOrEmpty($pw.Trim())) { throw "TightVNC: password non configurata nella build." }
        if ($pw.Length -gt 8) { $pw = $pw.Substring(0, 8) }     # lo standard VNC cifra con DES a 8 byte
        $regKey = 'HKLM\SOFTWARE\TightVNC\Server'
        $regSub = 'SOFTWARE\TightVNC\Server'
        $msiLog = Join-Path $dir 'iotahelp_vnc_msi.log'
        $okCodes = @(0, 1641, 3010)                             # 3010/1641 = riuscito, richiede riavvio
        $wantHex = ''
        try { $wantHex = ((Get-VncBlob $pw | ForEach-Object { $_.ToString('x2') }) -join '') }
        catch { throw ("TightVNC: non riesco a cifrare la password (DES non disponibile, criteri FIPS?). " + $_.Exception.Message) }

        # Lettura/scrittura della chiave di TightVNC. L'MSI le applica un'ACL che da' pieno controllo a
        # SYSTEM e ad Administrators (tabella LockPermissions), quindi da processo ELEVATO di norma si
        # legge e si scrive direttamente, senza task pianificato. Ma un'ACL sbagliata scritta
        # dall'installer e' un caso noto, percio' se la via diretta viene negata si ripassa da SYSTEM.
        # Vista di registro forzata a 64 bit: cosi' funziona anche se l'exe girasse a 32 bit (WOW64).
        function VncRegBase {
            return [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        }
        function VncPwRead {
            try {
                $base = VncRegBase
                $s = $base.OpenSubKey($regSub, $false)
                if ($s) {
                    $v = $s.GetValue('Password', $null)
                    $s.Close(); $base.Close()
                    if ($v -is [byte[]]) { return (($v | ForEach-Object { $_.ToString('x2') }) -join '') }
                    return ''
                }
                $base.Close()
                return ''
            }
            catch { Log ("TightVNC: lettura diretta del registro negata (" + $_.Exception.Message + "), passo da SYSTEM") }
            $q = SysCmd ('reg query "' + $regKey + '" /v Password') 90
            if ($q.Out -match 'REG_BINARY\s+([0-9A-Fa-f]+)') { return $Matches[1].ToLower() }
            return ''
        }
        function VncPwWrite {
            try {
                $base = VncRegBase
                $s = $base.CreateSubKey($regSub)
                $s.SetValue('Password', (Get-VncBlob $pw), [Microsoft.Win32.RegistryValueKind]::Binary)
                $s.SetValue('UseVncAuthentication', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
                $s.SetValue('AcceptRfbConnections', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
                $s.Close(); $base.Close()
                Log 'TightVNC: password scritta nel registro dal processo elevato.'
                return
            }
            catch { Log ("TightVNC: scrittura diretta negata (" + $_.Exception.Message + "), passo da SYSTEM") }
            # ripiego come SYSTEM: i tre valori in un solo comando raggruppato, perche' SysCmd appende
            # la redirezione in coda e "a & b > file" catturerebbe solo l'output di b
            $c = '( reg add "' + $regKey + '" /v Password /t REG_BINARY /d ' + $wantHex + ' /f'
            $c += ' & reg add "' + $regKey + '" /v UseVncAuthentication /t REG_DWORD /d 1 /f'
            $c += ' & reg add "' + $regKey + '" /v AcceptRfbConnections /t REG_DWORD /d 1 /f )'
            $r = SysCmd $c 90
            Log ("TightVNC reg add come SYSTEM -> " + (("" + $r.Out) -replace '\s+', ' '))
        }
        function VncSvcRestart {
            try {
                $s = Get-Service -Name 'tvnserver' -EA SilentlyContinue
                if (-not $s) { return }
                if ($s.Status -eq 'Running') { Stop-Service -Name 'tvnserver' -Force -EA SilentlyContinue; Start-Sleep -Seconds 2 }
                Start-Service -Name 'tvnserver' -EA SilentlyContinue
                Start-Sleep -Seconds 2
                $s2 = Get-Service -Name 'tvnserver' -EA SilentlyContinue
                # 'sc' da solo in PowerShell e' alias di Set-Content: serve sc.exe
                if ($s2 -and $s2.Status -ne 'Running') { & sc.exe start tvnserver 2>&1 | Out-Null }
            }
            catch { Log ("TightVNC riavvio servizio: " + $_.Exception.Message) }
        }
        # via ufficiale per far rileggere la configurazione al servizio senza interrompere le sessioni
        # in corso: "Updates settings of running TightVNC Server from the Windows registry"
        function VncSvcReload {
            $exe = Join-Path $env:ProgramFiles 'TightVNC\tvnserver.exe'
            if (-not (Test-Path -LiteralPath $exe)) { return $false }
            $r = Invoke-Proc $exe @('-controlservice', '-reload') 30
            Log ("TightVNC -controlservice -reload -> code=" + $r.Code)
            return ($r.Code -eq 0)
        }
        # il servizio tiene la configurazione in memoria: senza reload (o riavvio) la password non vale
        function VncApplyPw {
            VncPwWrite
            if (-not (VncSvcReload)) { VncSvcRestart }
            return (VncPwRead)
        }
        # eccezione firewall: se TightVNC era stato installato senza, il server non e' raggiungibile
        function VncFirewall {
            try {
                $exe = Join-Path $env:ProgramFiles 'TightVNC\tvnserver.exe'
                if (-not (Test-Path -LiteralPath $exe)) { return }
                $ex = @(Get-NetFirewallRule -DisplayName '*TightVNC*' -EA SilentlyContinue | Where-Object { ([string]$_.Enabled) -eq 'True' })
                if ($ex.Count -gt 0) { return }
                New-NetFirewallRule -DisplayName 'iotatec TightVNC' -Direction Inbound -Action Allow -Program $exe -Profile Any -Enabled True -EA Stop | Out-Null
                Log 'TightVNC: aggiunta eccezione firewall (mancava).'
            }
            catch { Log ("TightVNC firewall: " + $_.Exception.Message) }
        }
        # prodotto installato (ProductCode + versione), cercato in ENTRAMBE le viste di registro
        # Le due viste si aprono con OpenBaseKey e la vista ESPLICITA, non con i provider HKLM:\...:
        # da un processo a 32 bit (WOW64) il provider non vedrebbe mai la voce a 64 bit, $inst
        # resterebbe $null e salterebbe la disinstallazione, mandando il /i a sbattere su SELFFOUND.
        function VncInstalled {
            $best = $null
            foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
                try {
                    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
                    $un = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', $false)
                    if ($un) {
                        foreach ($name in $un.GetSubKeyNames()) {
                            try {
                                $sk = $un.OpenSubKey($name, $false)
                                if (-not $sk) { continue }
                                $dn = [string]$sk.GetValue('DisplayName', '')
                                if ($dn -match '^TightVNC') {
                                    $o = @{
                                        Code    = $(if ($name -match '^\{[0-9A-Fa-f-]+\}$') { $name } else { '' })
                                        Version = [string]$sk.GetValue('DisplayVersion', '')
                                        Name    = $dn
                                    }
                                    if (-not $best) { $best = $o }
                                    else { try { if ([version]$o.Version -gt [version]$best.Version) { $best = $o } } catch {} }
                                }
                                $sk.Close()
                            }
                            catch {}
                        }
                        $un.Close()
                    }
                    $base.Close()
                }
                catch {}
            }
            return $best
        }
        # righe utili dal log verboso di msiexec, per capire DOVE si e' rotto. Il log viene poi
        # cancellato: contiene la riga di comando, quindi la password in chiaro.
        function VncMsiLogTail {
            $t = ''
            try {
                if (Test-Path -LiteralPath $msiLog) {
                    $l = Get-Content -LiteralPath $msiLog -EA SilentlyContinue |
                        Where-Object { $_ -match 'Return value 3|AlreadyUpdated|NoDowngrade|SetPasswordsActionSilently|FindRelatedProducts|Installation success or error status|Error [0-9]{4}|MainEngineThread is returning' } |
                        Select-Object -Last 15
                    $t = (($l -join ' / ') -replace '\s+', ' ')
                    if ($pw) { $t = $t.Replace($pw, '***') }
                }
            }
            catch {}
            Remove-Item -LiteralPath $msiLog -Force -EA SilentlyContinue
            if ($t.Length -gt 900) { $t = $t.Substring(0, 900) }
            return $t
        }

        $svc0 = Get-Service -Name 'tvnserver' -EA SilentlyContinue
        $inst = VncInstalled
        Log ("TightVNC stato iniziale: servizio=" + $(if ($svc0) { $svc0.Status } else { 'assente' }) +
            "  prodotto=" + $(if ($inst) { $inst.Name + ' v' + $inst.Version + ' ' + $inst.Code } else { 'assente' }))

        # ---- 1) c'e' gia' ed e' gia' a posto: non toccare nulla (non far cadere sessioni in corso) ----
        if ($svc0) {
            $have = VncPwRead
            Log ("TightVNC password memorizzata=[" + $have + "]  attesa=[" + $wantHex + "]")
            if ($have -and $have -eq $wantHex) {
                VncFirewall
                if ($svc0.Status -ne 'Running') { VncSvcRestart }
                St 'TightVNC: gia'' configurato correttamente'
                Log 'TightVNC OK (nessuna modifica necessaria).'
                return
            }

            # ---- 2) c'e' gia' ma la password e' diversa: la scrivo come SYSTEM, senza reinstallare ----
            St 'TightVNC: imposto la password...'
            $have = VncApplyPw
            if ($have -eq $wantHex) {
                VncFirewall
                Log ("TightVNC OK (password scritta nel registro come SYSTEM; conservata la versione presente " + $(if ($inst) { 'v' + $inst.Version } else { '?' }) + ").")
                return
            }
            Log ("TightVNC: scrittura diretta non riuscita (memorizzata=[" + $have + "]), passo a disinstalla+reinstalla.")
        }

        # ---- 3) procura l'MSI. In ogni caso finisce in $dir: l'MSI incorporato viene estratto in
        #         %TEMP% dell'utente che ha elevato, e msiexec lo apre con l'identita' del servizio
        #         Windows Installer (SYSTEM). Copiarlo in C:\iotatec elimina ogni dubbio di accesso.
        $msi = Join-Path $dir 'tightvnc-setup-64bit.msi'
        if ($sync.offline) {
            $emb = Join-Path $cfg.offlineDir 'tightvnc.msi'
            if (-not (Test-Path -LiteralPath $emb)) { throw ("TightVNC: file offline mancante (" + $emb + ").") }
            Copy-Item -LiteralPath $emb -Destination $msi -Force
        }
        else {
            $urls = New-Object System.Collections.Generic.List[string]
            try {
                $page = Invoke-WebRequest -Uri 'https://www.tightvnc.com/download.php' -UseBasicParsing -TimeoutSec 20 -Headers @{ 'User-Agent' = 'iotahelp' }
                $m = [regex]::Match($page.Content, 'https://www\.tightvnc\.com/download/[0-9.]+/tightvnc-[0-9.]+-gpl-setup-64bit\.msi')
                if ($m.Success) { $urls.Add($m.Value) }
            }
            catch { Log ("TightVNC: pagina download non leggibile (" + $_.Exception.Message + ")") }
            if (-not $urls.Contains([string]$cfg.vncMsiUrl)) { $urls.Add([string]$cfg.vncMsiUrl) }   # fallback della build
            St 'TightVNC: scarico ultima versione...'
            $got = $false; $lastErr = ''
            foreach ($u in $urls) {
                try {
                    Get-File $u $msi
                    # un MSI vero sta sopra il mezzo mega: sotto e' una pagina di errore salvata come .msi
                    if ((Test-Path -LiteralPath $msi) -and (Get-Item $msi).Length -gt 500000) { $got = $true; Log ("TightVNC: scaricato " + $u); break }
                }
                catch { $lastErr = $_.Exception.Message; Log ("TightVNC: download fallito da " + $u + " (" + $lastErr + ")") }
            }
            if (-not $got) { throw ("TightVNC: download fallito. " + $lastErr) }
        }

        # ---- 4) disinstalla per ProductCode. NON per percorso dell'MSI: con una versione diversa
        #         msiexec /x <file> risponde 1605 e non rimuove niente (era il bug precedente).
        if ($inst -and $inst.Code) {
            St 'TightVNC: rimuovo la versione presente...'
            $ru = Invoke-Proc 'msiexec.exe' @('/x', $inst.Code, '/quiet', '/norestart') 180
            Log ("TightVNC msiexec /x " + $inst.Code + " -> code=" + $ru.Code)
            Start-Sleep -Seconds 4
        }

        # ---- 5) installa: le proprieta' della password valgono solo adesso, a installazione nuova ----
        St 'TightVNC: installazione (servizio + password)...'
        $msiArgs = @(
            '/i', $msi, '/quiet', '/norestart', '/l*v', $msiLog,
            'ADDLOCAL=Server',
            'SERVER_REGISTER_AS_SERVICE=1', 'SERVER_ADD_FIREWALL_EXCEPTION=1', 'SERVER_ALLOW_SAS=1',
            'SET_USEVNCAUTHENTICATION=1', 'VALUE_OF_USEVNCAUTHENTICATION=1',
            'SET_PASSWORD=1', ('VALUE_OF_PASSWORD=' + $pw),
            'SET_ACCEPTRFBCONNECTIONS=1', 'VALUE_OF_ACCEPTRFBCONNECTIONS=1',
            # senza queste due LoopbackOnly non viene scritto affatto e si eredita il default
            # dell'eseguibile: meglio dire esplicitamente che deve accettare connessioni non locali
            'SET_LOOPBACKONLY=1', 'VALUE_OF_LOOPBACKONLY=0'
        )
        $r = Invoke-Proc 'msiexec.exe' $msiArgs 300
        Log ("TightVNC msiexec /i -> code=" + $r.Code)
        # 1618 = un'altra installazione MSI in corso (tipicamente Windows Update): aspetto e riprovo
        for ($i = 1; $i -le 6 -and $r.Code -eq 1618; $i++) {
            St 'TightVNC: attendo Windows Installer (occupato)...'
            Start-Sleep -Seconds 20
            $r = Invoke-Proc 'msiexec.exe' $msiArgs 300
            Log ("TightVNC msiexec /i (tentativo " + ($i + 1) + ") -> code=" + $r.Code)
        }
        Start-Sleep -Seconds 5

        # ---- 6) il servizio deve esserci ----
        $svc = Get-Service -Name 'tvnserver' -EA SilentlyContinue
        if ($null -eq $svc) { throw ("TightVNC: installazione fallita (msiexec " + $r.Code + "). " + (VncMsiLogTail)) }
        if ($svc.Status -ne 'Running') { VncSvcRestart }
        VncFirewall

        # ---- 7) verifica la password. Se l'MSI ha fatto un upgrade invece di un'installazione nuova,
        #         la custom action e' stata saltata: la scrivo io.
        $have = VncPwRead
        Log ("TightVNC dopo msiexec: password memorizzata=[" + $have + "]  attesa=[" + $wantHex + "]")
        if ($have -ne $wantHex) {
            St 'TightVNC: imposto la password...'
            $have = VncApplyPw
            Log ("TightVNC dopo scrittura diretta: memorizzata=[" + $have + "]")
        }
        if ($have -ne $wantHex) {
            $tail = VncMsiLogTail
            if (-not $have) {
                # registro illeggibile: se e' stata un'installazione NUOVA e msiexec ha dato esito
                # positivo, la password l'ha messa l'MSI. Lo segnalo ma non blocco.
                if (($okCodes -contains $r.Code) -and (-not $inst)) {
                    Log 'ATTENZIONE TightVNC: password non verificabile (chiave di registro illeggibile anche come SYSTEM), ma installazione nuova riuscita: impostata dall''MSI.'
                    Remove-Item -LiteralPath $msi -Force -EA SilentlyContinue
                    return
                }
                throw ("TightVNC: installato, ma non riesco a VERIFICARE la password (chiave di registro illeggibile anche come SYSTEM). msiexec " + $r.Code + ". " + $tail)
            }
            throw ("TightVNC: installato, ma la password memorizzata non e' quella attesa. msiexec " + $r.Code + ". " + $tail)
        }

        Remove-Item -LiteralPath $msiLog -Force -EA SilentlyContinue    # contiene la password in chiaro
        Remove-Item -LiteralPath $msi -Force -EA SilentlyContinue       # era una copia nella cartella di lavoro
        Log 'TightVNC OK (password verificata).'
    }

    try {
        if (-not $cfg.preview -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $tasks = @()
        if ($sync.doRust) { $tasks += 'rust' }
        if ($sync.doSup)  { $tasks += 'sup' }
        if ($sync.doVnc)  { $tasks += 'vnc' }

        # ---- ANTEPRIMA: simula senza installare nulla ----
        if ($cfg.preview) {
            $names = @{ rust = 'RustDesk'; sup = 'Supremo'; vnc = 'TightVNC' }
            $substeps = @{
                rust = @('scarico ultima versione...', 'installazione...', 'servizio (avvio automatico)...', 'server e chiave...', 'imposto la password...')
                sup  = @('scarico ultima versione...', 'accesso non presidiato...', 'imposto la password...', 'servizio all''avvio...')
                vnc  = @('scarico ultima versione...', 'installazione (servizio)...', 'imposto la password...')
            }
            $n = [Math]::Max(1, $tasks.Count); $k = 0
            foreach ($t in $tasks) {
                $sync.state[$t] = 'running'; $base = ($k / $n) * 100.0; $slice = 100.0 / $n
                $ss = $substeps[$t]
                for ($j = 0; $j -lt $ss.Count; $j++) {
                    $sync.status = $names[$t] + ': ' + $ss[$j]
                    $sync.target = [int]($base + $slice * (($j + 1) / [double]$ss.Count))
                    Start-Sleep -Milliseconds 850
                }
                if ($t -eq 'rust') { $sync.rustId = '123 456 789' }
                if ($t -eq 'sup')  { $sync.supId = '987654321' }
                $sync.state[$t] = 'done'; $k++; $sync.target = [int](($k / $n) * 100)
            }
            $sync.target = 100
            $sync.status = 'ANTEPRIMA: installazione simulata (nessuna modifica al PC).'
            $sync.done = $true
            return
        }
        $n = [Math]::Max(1, $tasks.Count); $k = 0
        $errs = New-Object System.Collections.Generic.List[string]
        foreach ($t in $tasks) {
            $base = [int](($k / $n) * 100)
            $sync.target = [Math]::Max($sync.target, $base)
            $sync.state[$t] = 'running'
            try {
                switch ($t) {
                    'rust' { Install-RustDesk }
                    'sup'  { Install-Supremo }
                    'vnc'  { Install-TightVNC }
                }
                $sync.state[$t] = 'done'
            } catch {
                # un componente che fallisce NON deve impedire gli altri: registro e proseguo
                $sync.state[$t] = 'fail'
                $nm = @{ rust = 'RustDesk'; sup = 'Supremo'; vnc = 'TightVNC' }[$t]
                $errs.Add($nm + ': ' + $_.Exception.Message)
                Log ("ERRORE " + $nm + ": " + $_.Exception.Message)
            }
            $k++
            $sync.target = [int](($k / $n) * 100)
        }
        $sync.target = 100
        if ($errs.Count -gt 0) {
            $sync.error = ($errs -join '   |   ')
        }
        else {
            $sync.status = 'Installazione completata.'
            $sync.done = $true
        }
    }
    catch {
        $sync.error = $_.Exception.Message
        Log ("ERRORE: " + $_.Exception.Message)
    }
}

# ==================== GUI (vinorosso #600030) ====================
$brand      = [System.Drawing.Color]::FromArgb(96, 0, 48)     # #600030
$brandHover = [System.Drawing.Color]::FromArgb(120, 22, 66)   # hover pulsante
$onBrand    = [System.Drawing.Color]::FromArgb(255, 245, 250) # testo su header
$onBrandDim = [System.Drawing.Color]::FromArgb(216, 180, 198) # testo header attenuato
$cGreen     = [System.Drawing.Color]::FromArgb(29, 158, 117)
$cRed       = [System.Drawing.Color]::FromArgb(196, 60, 60)
$cGray      = [System.Drawing.Color]::FromArgb(150, 150, 150)
$cDark      = [System.Drawing.Color]::FromArgb(34, 34, 34)
$cTrack     = [System.Drawing.Color]::FromArgb(233, 233, 233)
$white      = [System.Drawing.Color]::White
$fUi        = New-Object System.Drawing.Font('Segoe UI', 9.5)
$W = 460
$offH = if ($OfflineBuild) { 44 } else { 0 }
$H = 384 + $offH

$form = New-Object System.Windows.Forms.Form
$form.Text = 'iotatec - assistenza remota'
$form.FormBorderStyle = 'None'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size($W, $H)
$form.BackColor = $white
$form.TopMost = $true; $form.Font = $fUi
$fi = Get-FormIcon; if ($fi) { $form.Icon = $fi }
# angoli arrotondati
$gp = New-Object System.Drawing.Drawing2D.GraphicsPath
$rad = 14; $dia = $rad * 2
$gp.AddArc(0, 0, $dia, $dia, 180, 90)
$gp.AddArc($W - $dia, 0, $dia, $dia, 270, 90)
$gp.AddArc($W - $dia, $H - $dia, $dia, $dia, 0, 90)
$gp.AddArc(0, $H - $dia, $dia, $dia, 90, 90)
$gp.CloseAllFigures()
$form.Region = New-Object System.Drawing.Region($gp)

# ---- HEADER band ----
$hdr = New-Object System.Windows.Forms.Panel
$hdr.BackColor = $brand; $hdr.Location = New-Object System.Drawing.Point(0, 0); $hdr.Size = New-Object System.Drawing.Size($W, 78)
$form.Controls.Add($hdr)

$tile = New-Object System.Windows.Forms.Panel
$tile.BackColor = $white; $tile.Size = New-Object System.Drawing.Size(46, 46); $tile.Location = New-Object System.Drawing.Point(18, 16)
$hdr.Controls.Add($tile)
$pic = New-Object System.Windows.Forms.PictureBox
$pic.SizeMode = 'Zoom'; $pic.Size = New-Object System.Drawing.Size(38, 38); $pic.Location = New-Object System.Drawing.Point(4, 4); $pic.BackColor = $white
$img = Get-LogoImage; if ($img) { $pic.Image = $img }
$tile.Controls.Add($pic)

$lblBrand = New-Object System.Windows.Forms.Label
$lblBrand.Text = 'iotatec'; $lblBrand.ForeColor = $onBrand; $lblBrand.BackColor = $brand
$lblBrand.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$lblBrand.AutoSize = $true; $lblBrand.Location = New-Object System.Drawing.Point(76, 15)
$hdr.Controls.Add($lblBrand)

$lblHdrSub = New-Object System.Windows.Forms.Label
$lblHdrSub.Text = 'assistenza remota'; $lblHdrSub.ForeColor = $onBrandDim; $lblHdrSub.BackColor = $brand
$lblHdrSub.AutoSize = $true; $lblHdrSub.Location = New-Object System.Drawing.Point(78, 46)
$hdr.Controls.Add($lblHdrSub)

$lblVer = New-Object System.Windows.Forms.Label
$lblVer.Text = 'v' + $AppVersion; $lblVer.ForeColor = $onBrandDim; $lblVer.BackColor = $brand
$lblVer.AutoSize = $false; $lblVer.TextAlign = 'MiddleRight'
$lblVer.Size = New-Object System.Drawing.Size(70, 16); $lblVer.Location = New-Object System.Drawing.Point(($W - 84), 52)
$hdr.Controls.Add($lblVer)

# pulsanti finestra (chiudi / riduci)
$btnX = New-Object System.Windows.Forms.Label
$btnX.Text = [string][char]0x2715; $btnX.ForeColor = $onBrand; $btnX.BackColor = $brand
$btnX.Font = New-Object System.Drawing.Font('Segoe UI', 11); $btnX.TextAlign = 'MiddleCenter'
$btnX.Size = New-Object System.Drawing.Size(26, 24); $btnX.Location = New-Object System.Drawing.Point(($W - 32), 8); $btnX.Cursor = 'Hand'
$btnX.Add_Click({ $form.Close() })
$btnX.Add_MouseEnter({ $btnX.ForeColor = $white }); $btnX.Add_MouseLeave({ $btnX.ForeColor = $onBrand })
$hdr.Controls.Add($btnX)

$btnMin = New-Object System.Windows.Forms.Label
$btnMin.Text = [string][char]0x2013; $btnMin.ForeColor = $onBrand; $btnMin.BackColor = $brand
$btnMin.Font = New-Object System.Drawing.Font('Segoe UI', 11); $btnMin.TextAlign = 'MiddleCenter'
$btnMin.Size = New-Object System.Drawing.Size(26, 24); $btnMin.Location = New-Object System.Drawing.Point(($W - 60), 8); $btnMin.Cursor = 'Hand'
$btnMin.Add_Click({ $form.WindowState = 'Minimized' })
$btnMin.Add_MouseEnter({ $btnMin.ForeColor = $white }); $btnMin.Add_MouseLeave({ $btnMin.ForeColor = $onBrand })
$hdr.Controls.Add($btnMin)

# ---- trascinamento finestra dall'header ----
$script:drag = $false; $script:dx = 0; $script:dy = 0
$mDown = { $script:drag = $true; $cp = [System.Windows.Forms.Cursor]::Position; $script:dx = $cp.X - $form.Left; $script:dy = $cp.Y - $form.Top }
$mMove = { if ($script:drag) { $cp = [System.Windows.Forms.Cursor]::Position; $form.Left = $cp.X - $script:dx; $form.Top = $cp.Y - $script:dy } }
$mUp = { $script:drag = $false }
foreach ($drC in @($hdr, $lblBrand, $lblHdrSub, $tile, $pic)) { $drC.Add_MouseDown($mDown); $drC.Add_MouseMove($mMove); $drC.Add_MouseUp($mUp) }

# ---- PANNELLO SELEZIONE ----
$selPanel = New-Object System.Windows.Forms.Panel
$selPanel.Location = New-Object System.Drawing.Point(0, 78); $selPanel.Size = New-Object System.Drawing.Size($W, ($H - 78)); $selPanel.BackColor = $white
$form.Controls.Add($selPanel)

$lblChoose = New-Object System.Windows.Forms.Label
$lblChoose.Text = 'Scegli cosa installare'; $lblChoose.ForeColor = $cDark
$lblChoose.Font = New-Object System.Drawing.Font('Segoe UI', 10.5); $lblChoose.AutoSize = $true
$lblChoose.Location = New-Object System.Drawing.Point(26, 14); $selPanel.Controls.Add($lblChoose)

$script:sel = @{ rust = [bool]$Def_Rust; sup = [bool]$Def_Sup; vnc = [bool]$Def_Vnc }
$rowUI = @{}
$checkFont = New-Object System.Drawing.Font('Segoe UI', 11)
$nameFont  = New-Object System.Drawing.Font('Segoe UI', 11)

function Set-Ind($k) {
    $ind = $rowUI[$k].Ind
    if ($script:sel[$k]) { $ind.BackColor = $brand; $ind.ForeColor = $white; $ind.Text = [string][char]0x2714 }
    else { $ind.BackColor = $white; $ind.Text = '' }
}
$onToggle = { $k = $this.Tag; $script:sel[$k] = -not $script:sel[$k]; Set-Ind $k }

$rowDefs = @(@('rust', 'RustDesk'), @('sup', 'Supremo'), @('vnc', 'TightVNC'))
for ($i = 0; $i -lt 3; $i++) {
    $k = $rowDefs[$i][0]; $nm = $rowDefs[$i][1]; $yy = 44 + $i * 46
    $card = New-Object System.Windows.Forms.Panel
    $card.Size = New-Object System.Drawing.Size(408, 38); $card.Location = New-Object System.Drawing.Point(26, $yy)
    $card.BackColor = [System.Drawing.Color]::FromArgb(248, 248, 248); $card.BorderStyle = 'FixedSingle'; $card.Cursor = 'Hand'; $card.Tag = $k
    $ind = New-Object System.Windows.Forms.Label
    $ind.Size = New-Object System.Drawing.Size(22, 22); $ind.Location = New-Object System.Drawing.Point(12, 8); $ind.TextAlign = 'MiddleCenter'
    $ind.Font = $checkFont; $ind.Cursor = 'Hand'; $ind.Tag = $k; $ind.BorderStyle = 'FixedSingle'
    $card.Controls.Add($ind)
    $txt = New-Object System.Windows.Forms.Label
    $txt.Text = $nm; $txt.Font = $nameFont; $txt.ForeColor = $cDark; $txt.AutoSize = $true; $txt.Location = New-Object System.Drawing.Point(46, 8); $txt.Cursor = 'Hand'; $txt.Tag = $k
    $card.Controls.Add($txt)
    $card.Add_Click($onToggle); $ind.Add_Click($onToggle); $txt.Add_Click($onToggle)
    $selPanel.Controls.Add($card)
    $rowUI[$k] = @{ Ind = $ind; Txt = $txt; Card = $card }
    Set-Ind $k
}

$cbOffline = $null
if ($OfflineBuild) {
    $cbOffline = New-Object System.Windows.Forms.CheckBox
    $cbOffline.Text = 'Installa offline (usa i file inclusi, senza rete)'
    $cbOffline.Checked = $false
    # i file incorporati vengono estratti in %TEMP% all'avvio: se non ci sono (estrazione fallita,
    # cartella temporanea ripulita) non offrire un'opzione che fallirebbe a meta' installazione
    if (-not $OfflineAvailable) {
        $cbOffline.Enabled = $false
        $cbOffline.Text = 'Installa offline (file inclusi non disponibili)'
    }
    $cbOffline.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $cbOffline.ForeColor = $cDark; $cbOffline.AutoSize = $false
    $cbOffline.Size = New-Object System.Drawing.Size(408, 26)
    $cbOffline.Location = New-Object System.Drawing.Point(26, 182)
    $selPanel.Controls.Add($cbOffline)
}

$lblNote = New-Object System.Windows.Forms.Label
$lblNote.ForeColor = $cGray; $lblNote.AutoSize = $true; $lblNote.Location = New-Object System.Drawing.Point(28, (196 + $offH))
$lblNote.Text = 'Un solo consenso (UAC) all''avvio, poi procede da solo.'
$selPanel.Controls.Add($lblNote)

$btnInstall = New-Object System.Windows.Forms.Button
$btnInstall.Text = 'Installa'; $btnInstall.FlatStyle = 'Flat'; $btnInstall.BackColor = $brand; $btnInstall.ForeColor = $white
$btnInstall.Font = New-Object System.Drawing.Font('Segoe UI', 11); $btnInstall.Cursor = 'Hand'
$btnInstall.FlatAppearance.BorderSize = 0; $btnInstall.FlatAppearance.MouseOverBackColor = $brandHover
$btnInstall.Size = New-Object System.Drawing.Size(408, 40); $btnInstall.Location = New-Object System.Drawing.Point(26, (226 + $offH))
$selPanel.Controls.Add($btnInstall)

# ---- PANNELLO AVANZAMENTO ----
$progPanel = New-Object System.Windows.Forms.Panel
$progPanel.Location = New-Object System.Drawing.Point(0, 78); $progPanel.Size = New-Object System.Drawing.Size($W, ($H - 78)); $progPanel.BackColor = $white; $progPanel.Visible = $false
$form.Controls.Add($progPanel)

$rowKeys = @('rust', 'sup', 'vnc')
$rowNames = @{ rust = 'RustDesk'; sup = 'Supremo'; vnc = 'TightVNC' }
$glyphs = @{}; $texts = @{}
for ($i = 0; $i -lt 3; $i++) {
    $key = $rowKeys[$i]; $yy = 20 + $i * 32
    $g = New-Object System.Windows.Forms.Label
    $g.Font = New-Object System.Drawing.Font('Segoe UI', 11); $g.TextAlign = 'MiddleCenter'
    $g.Size = New-Object System.Drawing.Size(24, 24); $g.Location = New-Object System.Drawing.Point(28, $yy)
    $progPanel.Controls.Add($g); $glyphs[$key] = $g
    $t = New-Object System.Windows.Forms.Label
    $t.Font = $nameFont; $t.AutoSize = $true; $t.Location = New-Object System.Drawing.Point(58, ($yy + 3)); $t.Text = $rowNames[$key]
    $progPanel.Controls.Add($t); $texts[$key] = $t
}

# barra di avanzamento custom (traccia + riempimento vinorosso)
$track = New-Object System.Windows.Forms.Panel
$track.BackColor = $cTrack; $track.Size = New-Object System.Drawing.Size(408, 8); $track.Location = New-Object System.Drawing.Point(28, 128)
$progPanel.Controls.Add($track)
$fill = New-Object System.Windows.Forms.Panel
$fill.BackColor = $brand; $fill.Size = New-Object System.Drawing.Size(0, 8); $fill.Location = New-Object System.Drawing.Point(0, 0)
$track.Controls.Add($fill)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.ForeColor = $cDark; $lblStatus.AutoSize = $false
$lblStatus.Size = New-Object System.Drawing.Size(408, 20); $lblStatus.Location = New-Object System.Drawing.Point(28, 148)
$progPanel.Controls.Add($lblStatus)

$lblInfo = New-Object System.Windows.Forms.Label
$lblInfo.ForeColor = $cGray; $lblInfo.AutoSize = $false
$lblInfo.Size = New-Object System.Drawing.Size(408, 44); $lblInfo.Location = New-Object System.Drawing.Point(28, 172)
$progPanel.Controls.Add($lblInfo)

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text = 'Chiudi'; $btnClose.FlatStyle = 'Flat'; $btnClose.BackColor = $brand; $btnClose.ForeColor = $white
$btnClose.Font = New-Object System.Drawing.Font('Segoe UI', 10.5); $btnClose.Cursor = 'Hand'
$btnClose.FlatAppearance.BorderSize = 0; $btnClose.FlatAppearance.MouseOverBackColor = $brandHover
$btnClose.Visible = $false
$btnClose.Size = New-Object System.Drawing.Size(140, 34); $btnClose.Location = New-Object System.Drawing.Point(294, 244)
$btnClose.Add_Click({ $form.Close() })
$progPanel.Controls.Add($btnClose)

# ---- runspace ----
$rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
$rs.SessionStateProxy.SetVariable('sync', $sync)
$rs.SessionStateProxy.SetVariable('cfg', $cfg)
$psw = [powershell]::Create(); $psw.Runspace = $rs; $null = $psw.AddScript($worker).AddArgument($sync).AddArgument($cfg)
$script:async = $null

# ---- timer ----
$script:finalized = $false
$script:countdown = $AutoCloseSeconds
$D = [char]0x2714; $R = [char]0x25CF; $P = [char]0x25CB; $F = [char]0x2716

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 120
$timer.Add_Tick({
    $tgt = [int]$sync.target
    $want = [int]($track.Width * $tgt / 100)
    if ($fill.Width -lt $want) { $fill.Width = [Math]::Min($want, $fill.Width + 8) }
    elseif ($fill.Width -gt $want) { $fill.Width = $want }
    $lblStatus.Text = [string]$sync.status

    foreach ($key in $rowKeys) {
        $stt = [string]$sync.state[$key]
        $g = $glyphs[$key]; $t = $texts[$key]
        switch ($stt) {
            'skip'    { $g.Text = $P; $g.ForeColor = $cGray;  $t.ForeColor = $cGray;  $t.Text = $rowNames[$key] + ' - non selezionato' }
            'pending' { $g.Text = $P; $g.ForeColor = $cGray;  $t.ForeColor = $cGray;  $t.Text = $rowNames[$key] }
            'running' { $g.Text = $R; $g.ForeColor = $brand;  $t.ForeColor = $cDark;  $t.Text = $rowNames[$key] }
            'done'    { $g.Text = $D; $g.ForeColor = $cGreen; $t.ForeColor = $cDark;  $t.Text = $rowNames[$key] }
            'fail'    { $g.Text = $F; $g.ForeColor = $cRed;   $t.ForeColor = $cRed;   $t.Text = $rowNames[$key] }
        }
    }

    # il worker e' terminato senza segnalare done/errore -> crash: mostralo invece di restare bloccati
    if (-not $script:finalized -and $script:async -and $script:async.IsCompleted -and -not $sync.done -and -not $sync.error) {
        $script:finalized = $true; $timer.Stop()
        $emsg = 'Errore imprevisto durante l''installazione.'
        try { if ($psw.Streams.Error.Count -gt 0) { $emsg = [string]$psw.Streams.Error[0] } } catch {}
        $lblHdrSub.Text = 'installazione non riuscita'
        $lblStatus.ForeColor = $cRed; $lblStatus.Text = 'Installazione non riuscita.'
        $lblInfo.ForeColor = $cRed; $lblInfo.Size = New-Object System.Drawing.Size(408, 66); $lblInfo.Text = $emsg
        $btnClose.Visible = $true
        try { $lg = Join-Path $DownloadDir 'iotahelp_deploy.log'; if (Test-Path $lg) { Start-Process notepad.exe $lg } } catch {}
        return
    }
    if ($sync.error -and -not $script:finalized) {
        $script:finalized = $true; $timer.Stop()
        $lblHdrSub.Text = 'installazione non riuscita'
        $lblStatus.ForeColor = $cRed; $lblStatus.Text = 'Installazione non riuscita.'
        $lblInfo.ForeColor = $cRed; $lblInfo.Size = New-Object System.Drawing.Size(408, 66); $lblInfo.Text = [string]$sync.error
        $btnClose.Visible = $true
        try { $lg = Join-Path $DownloadDir 'iotahelp_deploy.log'; if (Test-Path $lg) { Start-Process notepad.exe $lg } } catch {}
        return
    }
    if ($sync.done -and -not $script:finalized) {
        $script:finalized = $true; $fill.Width = $track.Width
        $lblHdrSub.Text = 'installazione completata'
        $lblStatus.ForeColor = $cGreen; $lblStatus.Text = 'Tutto pronto.'
        $info = @()
        if ($sync.rustId) { $info += ("RustDesk ID: " + $sync.rustId) }
        if ($sync.supId)  { $info += ("Supremo ID: " + $sync.supId) }
        $lblInfo.Text = ($info -join "`r`n")
        $btnClose.Visible = $true
        $script:countdown = $AutoCloseSeconds; $btnClose.Text = "Chiudi ($script:countdown)"; $closeTimer.Start(); return
    }
})

$closeTimer = New-Object System.Windows.Forms.Timer
$closeTimer.Interval = 1000
$closeTimer.Add_Tick({
    $script:countdown--
    if ($script:countdown -le 0) { $closeTimer.Stop(); $form.Close() } else { $btnClose.Text = "Chiudi ($script:countdown)" }
})

$btnInstall.Add_Click({
    if (-not ($script:sel['rust'] -or $script:sel['sup'] -or $script:sel['vnc'])) {
        [System.Windows.Forms.MessageBox]::Show('Seleziona almeno un componente.', 'iotatec', 'OK', 'Information') | Out-Null
        return
    }
    $sync.doRust = $script:sel['rust']; $sync.doSup = $script:sel['sup']; $sync.doVnc = $script:sel['vnc']
    if ($cbOffline) { $sync.offline = ([bool]$cbOffline.Checked -and [bool]$OfflineAvailable) }
    $sync.state['rust'] = $(if ($script:sel['rust']) { 'pending' } else { 'skip' })
    $sync.state['sup']  = $(if ($script:sel['sup'])  { 'pending' } else { 'skip' })
    $sync.state['vnc']  = $(if ($script:sel['vnc'])  { 'pending' } else { 'skip' })
    $sync.status = 'Avvio installazione...'
    $selPanel.Visible = $false; $progPanel.Visible = $true
    $script:async = $psw.BeginInvoke()
    $timer.Start()
})

$form.Add_Shown({ $form.Activate() })
[System.Windows.Forms.Application]::Run($form)

# cleanup
try { $timer.Stop(); $closeTimer.Stop() } catch {}
try { if ($script:async -and -not $script:async.IsCompleted) { $psw.Stop() } } catch {}
try { $psw.Dispose() } catch {}
try { $rs.Close(); $rs.Dispose() } catch {}

