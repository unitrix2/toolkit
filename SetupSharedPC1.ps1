# =====================================================================
#   OFFICE NETWORK TOOL
#   Run (PowerShell as Administrator):  irm <your-github-raw-url> | iex
#
#   1 CLEANUP    purani mapping / credentials / cache saaf
#   2 SETUP      Shared-PC banao + drives map (I=Inbox, J,K,L...)
#   3 HARDEN     LAN priority + router-proof connection settings
#   4 IP SERIES  series khud daalo (last number same, gateway auto)
#   5 AUTO IP    router se series khud pata karke sab set (automatic)
# =====================================================================

# ============================ CONFIG =================================
# 1) Common ADMIN account (same user + pass HAR PC par banega)
$AdminUser = "officeadmin"
$AdminPass = "Office@12345"

# 2) Shared folder (har PC par same)
$ShareName = "Shared-PC"
$LocalPath = "D:\Shared-PC"

# 3) Office ke SAARE PC -- Name + static IP (isi order me J,K,L milenge)
$Pcs = @(
    @{ Name = "Reception"; IP = "192.168.0.11" },
    @{ Name = "Accounts";  IP = "192.168.0.12" },
    @{ Name = "Sales";     IP = "192.168.0.13" }
)
# ====================================================================


$ToolName    = "OFFICE NETWORK TOOL"
$ToolVersion = "v1.0"

# ------------------------- UI HELPERS -------------------------------
function Write-Ok   ($m) { Write-Host "     [ OK ] " -NoNewline -ForegroundColor Green;   Write-Host $m -ForegroundColor Gray }
function Write-Info ($m) { Write-Host "     [ .. ] " -NoNewline -ForegroundColor Cyan;    Write-Host $m -ForegroundColor Gray }
function Write-Warn ($m) { Write-Host "     [ !  ] " -NoNewline -ForegroundColor Yellow;  Write-Host $m -ForegroundColor Gray }
function Write-Fail ($m) { Write-Host "     [FAIL] " -NoNewline -ForegroundColor Red;     Write-Host $m -ForegroundColor Gray }

function Write-Section ($t) {
    Write-Host ""
    Write-Host "  ==================================================================" -ForegroundColor DarkCyan
    Write-Host "   $t" -ForegroundColor White
    Write-Host "  ==================================================================" -ForegroundColor DarkCyan
}

function Write-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  ##################################################################" -ForegroundColor Cyan
    Write-Host "  #                                                                #" -ForegroundColor Cyan
    Write-Host "  #            O F F I C E   N E T W O R K   T O O L               #" -ForegroundColor White
    Write-Host "  #            LAN Sharing . Drive Mapping . Router-Proof          #" -ForegroundColor DarkGray
    Write-Host "  #                                                       $ToolVersion       #" -ForegroundColor DarkGray
    Write-Host "  #                                                                #" -ForegroundColor Cyan
    Write-Host "  ##################################################################" -ForegroundColor Cyan
}

function Read-Yes ($q) {
    return ((Read-Host "     $q (Y/N)").Trim().ToUpper() -eq 'Y')
}


# ------------------------- ADMIN CHECK ------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
          ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Banner
    Write-Host ""
    Write-Fail "Ye tool Administrator ke bina nahi chalega."
    Write-Info "PowerShell ko 'Run as Administrator' se kholo, phir dobara chalao."
    Write-Host ""
    return
}


# =====================  OPTION 1 : CLEANUP  =========================
function Invoke-Cleanup {
    Write-Section "CLEANUP  -  fresh karne ke liye sab saaf"
    Write-Warn "Ye SAARI mapped drives + network credentials + cache delete karega."
    if (-not (Read-Yes "Aage badhein?")) { Write-Info "Cancel kiya."; return }
    Write-Host ""

    # 1) Mapped network drives hatao
    & net.exe use * /delete /y *>$null
    Write-Ok "Saari mapped drives delete."

    # 2) Saved network credentials hatao (purane PC-name wale bhi)
    $removed = 0
    foreach ($line in (cmdkey /list 2>$null)) {
        if ($line -match 'Target:\s*Domain:target=(.+)$') {
            cmdkey /delete:$($matches[1].Trim()) 2>$null | Out-Null
            $removed++
        }
    }
    foreach ($pc in $Pcs) {
        cmdkey /delete:$($pc.IP)   2>$null | Out-Null
        cmdkey /delete:$($pc.Name) 2>$null | Out-Null
    }
    Write-Ok "Saved network credentials saaf ($removed hatye)."

    # 3) Drive labels / history (MountPoints2)
    $mp = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2"
    Get-ChildItem $mp -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -like '##*' } |
        ForEach-Object { Remove-Item $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Ok "Drive labels / history saaf."

    # 4) Persistent connections (HKCU\Network)
    Remove-Item "HKCU:\Network\*" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "Persistent connections saaf."

    # 5) Cache flush
    ipconfig /flushdns              | Out-Null
    nbtstat -R 2>$null              | Out-Null
    netsh interface ip delete arpcache | Out-Null
    Write-Ok "DNS / NetBIOS / ARP cache flush."

    Restart-Shell
    Write-Host ""
    Write-Ok "Cleanup complete -- ab fresh SETUP (2) kar sakte ho."
}


# =====================  DRIVE MAP HELPER  ===========================
# Returns object { Letter, IP, Label, OK } and prints a clean row.
function Connect-Drive ($letter, $ip, $label) {
    cmdkey /add:$ip /user:$AdminUser /pass:$AdminPass 2>$null | Out-Null
    & net.exe use "${letter}:" /delete /y *>$null
    & net.exe use "${letter}:" "\\$ip\$ShareName" /persistent:yes *>$null
    $ok = ($LASTEXITCODE -eq 0)
    if ($ok) {
        $key = "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2\##$ip#$ShareName"
        reg add $key /v _LabelFromReg /t REG_SZ /d "$label" /f 2>$null | Out-Null
    }
    $status = if ($ok) { "OK" } else { "FAIL" }
    $color  = if ($ok) { "Green" } else { "Red" }
    Write-Host ("     {0,-4} {1,-30} {2,-10} " -f "$letter`:", "\\$ip\$ShareName", $label) -NoNewline -ForegroundColor Gray
    Write-Host $status -ForegroundColor $color
    return [pscustomobject]@{ Letter = $letter; IP = $ip; Label = $label; OK = $ok }
}


# =====================  OPTION 2 : SETUP  ===========================
function Invoke-Setup {
    Write-Section "SETUP  -  Shared-PC banao aur drives map karo"

    # 1) Common admin user
    try {
        $sec = ConvertTo-SecureString $AdminPass -AsPlainText -Force
        if (Get-LocalUser -Name $AdminUser -ErrorAction SilentlyContinue) {
            Set-LocalUser -Name $AdminUser -Password $sec
            Write-Ok "User '$AdminUser' (password update)."
        } else {
            New-LocalUser -Name $AdminUser -Password $sec -FullName $AdminUser `
                -Description "Office shared access" -PasswordNeverExpires -AccountNeverExpires | Out-Null
            Write-Ok "User '$AdminUser' ban gaya."
        }
        Add-LocalGroupMember -Group "Administrators" -Member $AdminUser -ErrorAction SilentlyContinue
        Write-Ok "'$AdminUser' -> Administrators group."
    } catch { Write-Fail "User: $($_.Exception.Message)" }

    # 2) Folder
    if (-not (Test-Path $LocalPath)) {
        New-Item -Path $LocalPath -ItemType Directory -Force | Out-Null
        Write-Ok "Folder bana: $LocalPath"
    } else { Write-Ok "Folder maujood: $LocalPath" }

    # 3) Share to Everyone (share + NTFS)
    try {
        if (Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue) {
            Remove-SmbShare -Name $ShareName -Force -ErrorAction SilentlyContinue
        }
        New-SmbShare -Name $ShareName -Path $LocalPath -FullAccess "Everyone" | Out-Null
        icacls $LocalPath /grant "Everyone:(OI)(CI)F" /T /C 2>$null | Out-Null
        Write-Ok "'$ShareName' Everyone ko share (Full)."
    } catch { Write-Fail "Share: $($_.Exception.Message)" }

    # 4) Sharing/discovery/firewall basics
    Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object {
        Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private -ErrorAction SilentlyContinue
    }
    Set-NetFirewallRule -DisplayGroup "File and Printer Sharing" -Enabled True -Profile Any -ErrorAction SilentlyContinue
    Set-NetFirewallRule -DisplayGroup "Network Discovery"        -Enabled True -Profile Any -ErrorAction SilentlyContinue
    reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableLinkedConnections /t REG_DWORD /d 1 /f | Out-Null
    Write-Ok "Firewall + Private profile + linked-connections set."

    # 5) Self detect (self ko J,K,L se pakka hatao)
    $localIPs  = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
    $selfEntry = $Pcs | Where-Object { $localIPs -contains $_.IP } | Select-Object -First 1
    $selfIP    = if ($selfEntry) { $selfEntry.IP }
                 else { ($localIPs | Where-Object { $_ -notlike '169.254.*' -and $_ -ne '127.0.0.1' } | Select-Object -First 1) }
    $others    = $Pcs | Where-Object { $_.IP -ne $selfIP }

    Write-Host ""
    Write-Info "Drives map kar raha hoon..."
    Write-Host ""
    Write-Host ("     {0,-4} {1,-30} {2,-10} {3}" -f "DRV", "PATH", "LABEL", "STATUS") -ForegroundColor DarkGray

    $results = @()
    if ($selfIP) { $results += Connect-Drive "I" $selfIP "Inbox" }
    $letters = @('J','K','L','M','N','O','P','Q','R','S','T','U','V','W','X','Y','Z')
    $i = 0
    foreach ($pc in $others) {
        if ($i -ge $letters.Count) { break }
        $results += Connect-Drive $letters[$i] $pc.IP $pc.Name
        $i++
    }

    Restart-Shell
    $good = ($results | Where-Object { $_.OK }).Count
    $bad  = ($results | Where-Object { -not $_.OK }).Count
    Write-Host ""
    Write-Ok "$good drive map hui.  (I: = Inbox)"
    if ($bad -gt 0) { Write-Warn "$bad drive fail (shayad wo PC abhi on/ready nahi -- baad me dobara chalao)." }
    Write-Info "Drives na dikhein to ek baar PC restart karo."
}


# ===============  OPTION 3 : NETWORK HARDENING  =====================
function Optimize-Network {
    Write-Section "HARDEN  -  router-proof connection (LAN hamesha priority)"

    # 1) LAN priority, Wi-Fi secondary (sirf physical adapters)
    foreach ($ad in Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }) {
        $isWifi = ($ad.PhysicalMediaType -match '802\.11') -or ($ad.InterfaceDescription -match 'Wi-?Fi|Wireless')
        $metric = if ($isWifi) { 50 } else { 10 }
        Set-NetIPInterface -InterfaceIndex $ad.ifIndex -InterfaceMetric $metric -ErrorAction SilentlyContinue
        Write-Ok ("{0,-26} metric {1}  ({2})" -f $ad.Name, $metric, ($(if($isWifi){'Wi-Fi'}else{'LAN'})))
    }

    # 2) NIC power-saving OFF
    foreach ($ad in Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }) {
        try {
            $pm = Get-NetAdapterPowerManagement -Name $ad.Name -ErrorAction Stop
            $pm.AllowComputerToTurnOffDevice = 'Disabled'
            Set-NetAdapterPowerManagement -InputObject $pm -ErrorAction SilentlyContinue
        } catch {}
    }
    Write-Ok "Network card power-saving band."

    # 3) Profile Private + sharing sabhi profile par
    Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object {
        Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private -ErrorAction SilentlyContinue
    }
    Set-NetFirewallRule -DisplayGroup "File and Printer Sharing" -Enabled True -Profile Any -ErrorAction SilentlyContinue
    Set-NetFirewallRule -DisplayGroup "Network Discovery"        -Enabled True -Profile Any -ErrorAction SilentlyContinue
    Set-NetFirewallRule -Name "FPS-ICMP4-ERQ-In"                 -Enabled True -Profile Any -ErrorAction SilentlyContinue
    Write-Ok "Sharing + Discovery + Ping sabhi profile par ON."

    # 4) NetBIOS over TCP/IP ON (CIM)
    foreach ($c in (Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" -ErrorAction SilentlyContinue)) {
        Invoke-CimMethod -InputObject $c -MethodName SetTcpipNetbios -Arguments @{ TcpipNetbios = [uint32]1 } -ErrorAction SilentlyContinue | Out-Null
    }
    Write-Ok "NetBIOS over TCP/IP enable."

    # 5) Zaroori services Automatic + Start
    foreach ($s in "LanmanServer","LanmanWorkstation","FDResPub","fdPHost","SSDPSRV","upnphost","Spooler") {
        Set-Service -Name $s -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service -Name $s -ErrorAction SilentlyContinue
    }
    Write-Ok "Sharing / Discovery / Print services Automatic + chalu."

    # 6) Linked connections
    reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableLinkedConnections /t REG_DWORD /d 1 /f | Out-Null
    Write-Ok "Mapped drives elevated+normal dono me dikhein."

    Write-Host ""
    Write-Ok "HARDENING complete -- switch on + LAN juda ho to router band hone par bhi jude rahenge."
    Write-Info "Poori tarah lagu hone ke liye ek baar PC restart behtar."
}


# ---- LAN adapter dhoondne ka helper (Option 4 & 5) ----
function Get-LanAdapter {
    $a = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
         Where-Object { $_.Status -eq 'Up' -and $_.PhysicalMediaType -match '802\.3' } |
         Select-Object -First 1
    if (-not $a) {
        $a = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
    }
    return $a
}


# ===============  OPTION 4 : CHANGE IP SERIES  ======================
function Set-IPSeries {
    Write-Section "IP SERIES  -  series khud daalo (last number same rahega)"

    $adapter = Get-LanAdapter
    if (-not $adapter) { Write-Fail "Koi active LAN adapter nahi mila."; return }

    $curIp = (Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' } |
              Select-Object -First 1).IPAddress
    $defLast = if ($curIp) { $curIp.Split('.')[-1] } else { $null }

    Write-Info ("Adapter : {0}" -f $adapter.Name)
    Write-Info ("Abhi IP : {0}" -f ($(if ($curIp) { $curIp } else { '(koi static IP nahi)' })))
    Write-Host ""

    do {
        $series = (Read-Host "     Nayi IP series (jaise 192.168.1)").Trim()
        $okSeries = $series -match '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})$'
        if ($okSeries) {
            $okSeries = ($series.Split('.') | ForEach-Object { ([int]$_ -ge 0) -and ([int]$_ -le 255) }) -notcontains $false
        }
        if (-not $okSeries) { Write-Fail "Galat format. Sahi jaise: 192.168.1" }
    } while (-not $okSeries)

    $prompt = if ($defLast) { "     Last number (Enter = $defLast same rakho)" } else { "     Last number (jaise 240)" }
    $inLast = (Read-Host $prompt).Trim()
    $lastOctet = if ($inLast) { $inLast } elseif ($defLast) { $defLast } else { $null }
    if (-not $lastOctet -or $lastOctet -notmatch '^\d+$' -or [int]$lastOctet -lt 1 -or [int]$lastOctet -gt 254) {
        Write-Fail "Last number galat (1-254). Ruk gaya."; return
    }

    $newIp = "$series.$lastOctet"; $gw = "$series.1"; $mask = "255.255.255.0"
    Write-Host ""
    Write-Info "Naya set hoga:"
    Write-Host ("        IP      : {0}" -f $newIp) -ForegroundColor White
    Write-Host ("        Mask    : {0}" -f $mask)  -ForegroundColor Gray
    Write-Host ("        Gateway : {0}" -f $gw)    -ForegroundColor Gray
    Write-Host ("        DNS     : {0}" -f $gw)    -ForegroundColor Gray
    Write-Host ""
    if (-not (Read-Yes "Apply karein?")) { Write-Info "Cancel kiya."; return }

    $if = $adapter.Name
    netsh interface ip set address "name=$if" static $newIp $mask $gw 1 | Out-Null
    netsh interface ip set dns     "name=$if" static $gw              | Out-Null
    ipconfig /flushdns | Out-Null

    Write-Host ""
    Write-Ok "Naya IP = $newIp , Gateway = $gw"
    Write-Info "Baaki PC bhi isi series me set karo (last number same). Fir `$Pcs update karke SETUP (2) chalao."
}


# ===============  OPTION 5 : AUTO IP SERIES  ========================
function Update-IPSeriesAuto {
    Write-Section "AUTO IP  -  router se series khud pata karke sab set"

    $adapter = Get-LanAdapter
    if (-not $adapter) { Write-Fail "Koi active LAN adapter nahi mila."; return }
    $if = $adapter.Name; $idx = $adapter.ifIndex

    $cfg0  = Get-NetIPConfiguration -InterfaceIndex $idx -ErrorAction SilentlyContinue
    $oldIp = ($cfg0.IPv4Address        | Select-Object -First 1).IPAddress
    $oldGw = ($cfg0.IPv4DefaultGateway | Select-Object -First 1).NextHop
    if (-not $oldIp) { Write-Fail "Is PC par abhi koi IP nahi -- pehle Option 4 se set karo."; return }
    $lastOctet = $oldIp.Split('.')[-1]
    Write-Info ("Abhi IP: {0}  (last number {1} yaad rakha)" -f $oldIp, $lastOctet)

    # 1) DHCP par jaakar router se series pata karo
    Write-Info "Router se nayi series pata kar raha hoon (thoda ruko)..."
    netsh interface ip set address "name=$if" dhcp | Out-Null
    netsh interface ip set dns     "name=$if" dhcp | Out-Null
    ipconfig /renew | Out-Null

    $gw = $null; $dhcpIp = $null
    for ($t = 0; $t -lt 12; $t++) {
        Start-Sleep -Seconds 2
        $c = Get-NetIPConfiguration -InterfaceIndex $idx -ErrorAction SilentlyContinue
        $gw     = ($c.IPv4DefaultGateway | Select-Object -First 1).NextHop
        $dhcpIp = ($c.IPv4Address | Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1).IPAddress
        if ($gw -and $dhcpIp) { break }
    }

    if (-not $gw) {
        Write-Fail "Router se series nahi mili (DHCP off / router band?). Purana IP wapas laga raha hoon."
        if ($oldGw) { netsh interface ip set address "name=$if" static $oldIp 255.255.255.0 $oldGw 1 | Out-Null }
        else        { netsh interface ip set address "name=$if" static $oldIp 255.255.255.0        | Out-Null }
        return
    }

    # 2) Series nikaalo + static laga do
    $series = ($gw.Split('.')[0..2] -join '.')
    $newIp  = "$series.$lastOctet"; $mask = "255.255.255.0"
    Write-Ok ("Router series mili: {0}.x  (gateway {1})" -f $series, $gw)
    netsh interface ip set address "name=$if" static $newIp $mask $gw 1 | Out-Null
    netsh interface ip set dns     "name=$if" static $gw              | Out-Null
    ipconfig /flushdns | Out-Null
    Write-Ok "Naya IP set: $newIp , Gateway $gw , DNS $gw"

    # 3) Saari drives nayi series par remap
    Write-Host ""
    Write-Info "Drives nayi series par remap kar raha hoon..."
    Write-Host ""
    Write-Host ("     {0,-4} {1,-30} {2,-10} {3}" -f "DRV", "PATH", "LABEL", "STATUS") -ForegroundColor DarkGray

    Connect-Drive "I" $newIp "Inbox" | Out-Null
    $others  = $Pcs | Where-Object { $_.IP.Split('.')[-1] -ne $lastOctet }
    $letters = @('J','K','L','M','N','O','P','Q','R','S','T','U','V','W','X','Y','Z')
    $i = 0
    foreach ($pc in $others) {
        if ($i -ge $letters.Count) { break }
        Connect-Drive $letters[$i] ("$series." + $pc.IP.Split('.')[-1]) $pc.Name | Out-Null
        $i++
    }

    Restart-Shell
    Write-Host ""
    Write-Ok "Sab kuch apne aap nayi series par set ho gaya."
    Write-Info "Har PC par bas ye AUTO IP (5) chala do."
}


# ---- Explorer refresh (drive labels dikhane ke liye) ----
function Restart-Shell {
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 900
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer }
}


# =========================  MAIN MENU  ==============================
do {
    Write-Banner
    Write-Host ""
    Write-Host "     CONFIG:  Admin='$AdminUser'   Share='$ShareName'   PCs=$($Pcs.Count)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "      [1]  CLEANUP     " -NoNewline -ForegroundColor Yellow; Write-Host "Purani mapping / credentials / cache saaf" -ForegroundColor Gray
    Write-Host "      [2]  SETUP       " -NoNewline -ForegroundColor Green;  Write-Host "Shared-PC banao + drives map (I=Inbox, J,K,L)" -ForegroundColor Gray
    Write-Host "      [3]  HARDEN      " -NoNewline -ForegroundColor Cyan;   Write-Host "LAN priority + router-proof settings" -ForegroundColor Gray
    Write-Host "      [4]  IP SERIES   " -NoNewline -ForegroundColor Magenta;Write-Host "Series khud daalo (last no. same, gateway auto)" -ForegroundColor Gray
    Write-Host "      [5]  AUTO IP     " -NoNewline -ForegroundColor White;  Write-Host "Router se series khud pata karke sab set" -ForegroundColor Gray
    Write-Host "      [0]  EXIT" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  ------------------------------------------------------------------" -ForegroundColor DarkCyan
    $choice = (Read-Host "     Option chuno (0-5)").Trim()

    switch ($choice) {
        '1' { Invoke-Cleanup }
        '2' { Invoke-Setup }
        '3' { Optimize-Network }
        '4' { Set-IPSeries }
        '5' { Update-IPSeriesAuto }
        '0' { Write-Host "`n     Bye!`n" -ForegroundColor Cyan }
        default { Write-Warn "Galat option. 0 se 5 tak chuno." }
    }

    if ($choice -ne '0') { Write-Host ""; Read-Host "     Enter dabao -> menu par wapas" | Out-Null }

} while ($choice -ne '0')
