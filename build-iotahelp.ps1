<#
    build-iotahelp.ps1 - compila iotahelp da iotahelp.ps1
      .\build-iotahelp.ps1            -> iotatau-help.exe          (online, admin, FIRMATO)
      .\build-iotahelp.ps1 -Preview   -> iotatau-help_preview.exe  (no admin, simula, non firmato)
      .\build-iotahelp.ps1 -Offline   -> iotatau-help-offline.exe  (file INCORPORATI, admin, FIRMATO)

    La versione mostrata viene letta da $AppVersion in iotahelp.ps1.
    Per aggiornare: incrementa $AppVersion, poi rilancia.
    -Offline: scarica RustDesk/Supremo/TightVNC in C:\AI\offline e li incorpora nell'exe.
              I payload restano in cache; le versioni incorporate vengono sempre stampate.
      -Latest   controlla le versioni remote e riscarica SOLO cio' che e' cambiato (consigliato)
      -Refresh  svuota la cache e riscarica tutto, senza controlli
#>
param([switch]$Preview, [switch]$Offline, [switch]$Refresh, [switch]$Latest)
$ErrorActionPreference = 'Stop'
$root = 'C:\AI'
$srcFile = Join-Path $root 'iotahelp.ps1'
$icon    = Join-Path $root 'iotatec.ico'
$jpeg    = Join-Path $root 'iotatec.jpeg'

# --- logo 96px PNG base64 da iotatec.jpeg ---
Add-Type -AssemblyName System.Drawing
$im = [System.Drawing.Image]::FromFile($jpeg)
$bm = New-Object System.Drawing.Bitmap(96, 96)
$g = [System.Drawing.Graphics]::FromImage($bm)
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g.DrawImage($im, 0, 0, 96, 96); $g.Dispose(); $im.Dispose()
$ms = New-Object System.IO.MemoryStream
$bm.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $bm.Dispose()
$b64 = [Convert]::ToBase64String($ms.ToArray()); $ms.Dispose()

# --- sorgente + versione ---
$src = Get-Content -LiteralPath $srcFile -Raw
$ver = ([regex]::Match($src, "AppVersion\s*=\s*'([^']+)'")).Groups[1].Value
if (-not $ver) { $ver = '1.0.0' }
$fileVer = (($ver.Split('.') + @('0', '0', '0', '0'))[0..3]) -join '.'

# --- segreti: file locale NON versionato, iniettati qui al posto dei segnaposto ---
$secFile = Join-Path $root 'iotahelp.secrets.ps1'
if (-not (Test-Path $secFile)) {
    throw "Manca '$secFile': contiene password e chiave reali e non e' versionato. Crealo prima di compilare."
}
$sec = & $secFile
foreach ($k in @('RD_PASSWORD', 'RD_KEY', 'VNC_PASSWORD')) {
    if ([string]::IsNullOrEmpty([string]$sec[$k])) { throw "Nel file dei segreti manca la voce '$k'." }
    # una virgoletta doppia romperebbe la riga di comando costruita a runtime
    if (([string]$sec[$k]).Contains('"')) { throw "'$k' contiene una virgoletta doppia: non e' utilizzabile." }
}
# lo standard VNC cifra con DES a 8 byte: oltre l'ottavo carattere la password viene TRONCATA, quindi
# un segreto piu' lungo installerebbe in silenzio una password diversa da quella scritta nel file
if (([string]$sec['VNC_PASSWORD']).Length -gt 8) {
    throw ("VNC_PASSWORD e' di " + ([string]$sec['VNC_PASSWORD']).Length + " caratteri: lo standard VNC usa solo i primi 8, quindi la password installata NON sarebbe quella del file. Accorciala a 8.")
}

$out = $src.Replace('@@LOGO_B64@@', $b64)
$out = $out.Replace('@@RD_PASSWORD@@', [string]$sec['RD_PASSWORD'])
$out = $out.Replace('@@RD_KEY@@', [string]$sec['RD_KEY'])
$out = $out.Replace('@@VNC_PASSWORD@@', [string]$sec['VNC_PASSWORD'])
if ($out -match '@@[A-Z0-9_]+@@') { throw ("Segnaposto non sostituito nella build: " + $Matches[0]) }
if ($Preview) { $out = [regex]::Replace($out, '\$PreviewMode\s*=\s*\$false', '$$PreviewMode = $$true') }
if ($Offline) { $out = [regex]::Replace($out, '\$OfflineBuild\s*=\s*\$false', '$$OfflineBuild = $$true') }

function Sign-Exe($exe) {
    $cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq 'CN=iotatec' } | Select-Object -First 1
    if ($cert) {
        $sig = Set-AuthenticodeSignature -FilePath $exe -Certificate $cert -TimeStampServer 'http://timestamp.digicert.com' -HashAlgorithm SHA256
        Write-Output ("Firma: " + $sig.Status)
    } else { Write-Output "ATTENZIONE: certificato iotatec non trovato, exe NON firmato." }
}

Import-Module ps2exe -ErrorAction Stop

if ($Preview) {
    $buildFile = Join-Path $root 'iotahelp.build.preview.ps1'
    Set-Content -LiteralPath $buildFile -Value $out -Encoding UTF8
    $exe = Join-Path $root 'iotatau-help_preview.exe'
    Invoke-ps2exe -inputFile $buildFile -outputFile $exe -iconFile $icon -noConsole `
        -title 'iotatec - Assistenza remota (ANTEPRIMA)' -company 'iotatec' -product 'iotatau-help preview' -version $fileVer | Out-Null
    Write-Output ("PREVIEW pronto: $exe  (v$ver, non firmato, senza admin)")
}
elseif ($Offline) {
    # --- raccogli i file da incorporare ---
    $offSrc = Join-Path $root 'offline'
    if (-not (Test-Path $offSrc)) { New-Item -ItemType Directory -Force -Path $offSrc | Out-Null }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $H = @{ 'User-Agent' = 'iotahelp-build' }
    $rd = Join-Path $offSrc 'rustdesk_installer.exe'
    $sp = Join-Path $offSrc 'Supremo.exe'
    $vn = Join-Path $offSrc 'tightvnc.msi'

    $verFile = Join-Path $offSrc 'versions.json'

    if ($Refresh) {
        Remove-Item $rd, $sp, $vn, $verFile -Force -EA SilentlyContinue
        Write-Output "Cache offline svuotata (-Refresh): riscarico tutto"
    }

    # identificativi di versione dei file gia' in cache
    $known = @{}
    if (Test-Path $verFile) {
        try { (Get-Content $verFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $known[$_.Name] = [string]$_.Value } } catch {}
    }
    if ($Latest) { Write-Output "Controllo le ultime versioni disponibili (-Latest)..." }

    # --- RustDesk: identificativo = nome dell'asset dell'ultima release ---
    $need = -not (Test-Path $rd); $id = $null; $url = $null
    if ($Latest -or $need) {
        try {
            $rel = Invoke-RestMethod 'https://api.github.com/repos/rustdesk/rustdesk/releases/latest' -Headers $H
            $asset = $rel.assets | Where-Object { $_.name -match 'rustdesk-.*-x86_64\.exe$' -and $_.name -notmatch 'portable' } | Select-Object -First 1
            $id = $asset.name; $url = $asset.browser_download_url
            if ($Latest -and $id -and $known['rustdesk'] -ne $id) { $need = $true }
        }
        catch { Write-Output ("   (controllo RustDesk fallito: " + $_.Exception.Message + ")") }
    }
    if ($need -and $url) {
        Write-Output ("   RustDesk: scarico " + $id)
        Invoke-WebRequest $url -OutFile $rd -Headers $H -UseBasicParsing
        $known['rustdesk'] = $id
    }
    elseif ($Latest) { Write-Output "   RustDesk: gia' aggiornato" }

    # --- Supremo: URL senza versione -> identificativo = Last-Modified + dimensione ---
    $need = -not (Test-Path $sp); $id = $null
    $supUrl = 'https://www.nanosystems.it/public/download/Supremo.exe'
    if ($Latest -or $need) {
        try {
            $req = [System.Net.WebRequest]::Create($supUrl); $req.Method = 'HEAD'; $req.UserAgent = 'iotahelp-build'
            $resp = $req.GetResponse()
            $id = ([string]$resp.Headers['Last-Modified']) + '|' + $resp.ContentLength
            $resp.Close()
            if ($Latest -and $id -and $known['supremo'] -ne $id) { $need = $true }
        }
        catch { Write-Output ("   (controllo Supremo fallito: " + $_.Exception.Message + ")") }
    }
    if ($need) {
        Write-Output "   Supremo: scarico l'ultima versione"
        Invoke-WebRequest $supUrl -OutFile $sp -Headers $H -UseBasicParsing
        if ($id) { $known['supremo'] = $id }
    }
    elseif ($Latest) { Write-Output "   Supremo: gia' aggiornato" }

    # --- TightVNC: identificativo = URL dell'MSI (contiene la versione) ---
    $need = -not (Test-Path $vn); $id = $null
    $vncUrl = 'https://www.tightvnc.com/download/2.8.90/tightvnc-2.8.90-gpl-setup-64bit.msi'
    if ($Latest -or $need) {
        try {
            $page = Invoke-WebRequest 'https://www.tightvnc.com/download.php' -UseBasicParsing -TimeoutSec 20 -Headers $H
            $m = [regex]::Match($page.Content, 'https://www\.tightvnc\.com/download/[0-9.]+/tightvnc-[0-9.]+-gpl-setup-64bit\.msi')
            if ($m.Success) { $vncUrl = $m.Value }
        }
        catch {}
        $id = $vncUrl
        if ($Latest -and $known['tightvnc'] -ne $id) { $need = $true }
    }
    if ($need) {
        Write-Output ("   TightVNC: scarico " + (Split-Path $vncUrl -Leaf))
        Invoke-WebRequest $vncUrl -OutFile $vn -Headers $H -UseBasicParsing
        $known['tightvnc'] = $id
    }
    elseif ($Latest) { Write-Output "   TightVNC: gia' aggiornato" }

    try { ($known | ConvertTo-Json) | Set-Content -LiteralPath $verFile -Encoding UTF8 } catch {}
    $tot = ((Get-Item $rd).Length + (Get-Item $sp).Length + (Get-Item $vn).Length)
    Write-Output ("File offline pronti (" + [int]($tot / 1MB) + " MB):")
    Write-Output ("   RustDesk  v" + (Get-Item $rd).VersionInfo.ProductVersion + "  (" + [int]((Get-Item $rd).Length / 1MB) + " MB)")
    Write-Output ("   Supremo   v" + (Get-Item $sp).VersionInfo.ProductVersion + "  (" + [int]((Get-Item $sp).Length / 1MB) + " MB)")
    Write-Output ("   TightVNC  " + [int]((Get-Item $vn).Length / 1MB) + " MB")

    $embed = @{
        '%TEMP%\iotatec_offline\rustdesk_installer.exe' = $rd
        '%TEMP%\iotatec_offline\Supremo.exe'            = $sp
        '%TEMP%\iotatec_offline\tightvnc.msi'           = $vn
    }
    $buildFile = Join-Path $root 'iotahelp.build.offline.ps1'
    Set-Content -LiteralPath $buildFile -Value $out -Encoding UTF8
    $exe = Join-Path $root 'iotatau-help-offline.exe'
    Invoke-ps2exe -inputFile $buildFile -outputFile $exe -iconFile $icon -requireAdmin -noConsole `
        -title 'iotatec - Assistenza remota' -company 'iotatec' -product 'iotatau-help offline' -version $fileVer -copyright '(c) 2026 iotatec' `
        -embedFiles $embed | Out-Null
    Sign-Exe $exe
    Write-Output ("OFFLINE pronto: $exe  (v$ver, ~" + [int](((Get-Item $exe).Length) / 1MB) + " MB)")
}
else {
    $buildFile = Join-Path $root 'iotahelp.build.ps1'
    Set-Content -LiteralPath $buildFile -Value $out -Encoding UTF8
    $exe = Join-Path $root 'iotatau-help.exe'
    Invoke-ps2exe -inputFile $buildFile -outputFile $exe -iconFile $icon -requireAdmin -noConsole `
        -title 'iotatec - Assistenza remota' -company 'iotatec' -product 'iotatau-help' -version $fileVer -copyright '(c) 2026 iotatec' | Out-Null
    Sign-Exe $exe
    Write-Output ("RELEASE pronto: $exe  (v$ver)")
}