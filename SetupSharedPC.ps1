# =====================================================================
#   OFFICE NETWORK TOOL
#   Run (PowerShell as Administrator):  irm <your-github-raw-url> | iex
#
#   1 CLEANUP       purani mapping / credentials / cache saaf
#   2 SETUP         Shared-PC banao + drives map (I=Inbox, J,K,L...)
#   3 HARDEN        LAN priority + router-proof connection settings
#   4 IP SERIES     series + last number dono khud daalo
#   5 AUTO IP       series router se auto, last number JO ABHI HAI wahi rahe
#   6 HOTSPOT NET   router dead? sharing chaalu + internet hotspot se
#   7 HEALTH CHECK  network diagnose + har fixable problem auto-fix
#   8 SET IP BY NAME PC ke naam se last number (series auto/manual) + drives
# =====================================================================

# ============================ CONFIG =================================
# 1) Common ADMIN account (same user + pass HAR PC par banega)
$AdminUser = "CNB"
$AdminPass = "1234"

# 2) Shared folder (har PC par same)
$ShareName = "Shared-PC"
$LocalPath = "D:\Shared-PC"

# 2b) Workgroup naam (sab PC par same hona chahiye)
$Workgroup = "WORKGROUP"

# 2c) Default series (manual mode + jab auto-detect na ho paye)
$Series = "192.168.0"

# 3) MASTER LIST -- Windows PC naam -> last IP number -> drive label
#    (IP = <series>.<Octet> , jaise 192.168.0.241 for CCL-PC7)
$Pcs = @(
    @{ Host = "CCL-PC1"; Octet = 249; Label = "USER"               },
    @{ Host = "CCL-PC2"; Octet = 247; Label = "Mohit"              },
    @{ Host = "CCL-PC3"; Octet = 244; Label = "Sunil Kushwaha Sir" },
    @{ Host = "CCL-PC4"; Octet = 246; Label = "Vipin"              },
    @{ Host = "CCL-PC5"; Octet = 243; Label = "Aseem Meena Sir"    },
    @{ Host = "CCL-PC6"; Octet = 248; Label = "Raveesh"            },
    @{ Host = "CCL-PC7"; Octet = 241; Label = "Salman"             },
    @{ Host = "CCL-PC8"; Octet = 242; Label = "Mukesh"             }
)
# ====================================================================


$ToolVersion = "v2.0"

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
    $w   = 60
    $bar = '  +' + ('-' * $w) + '+'
    $row = {
        param($t, $col)
        $t = "$t"
        if ($t.Length -gt $w) { $t = $t.Substring(0, $w) }
        $pad  = $w - $t.Length
        $left = [math]::Floor($pad / 2)
        Write-Host ('  |' + (' ' * $left) + $t + (' ' * ($pad - $left)) + '|') -ForegroundColor $col
    }
    Write-Host ""
    Write-Host $bar -ForegroundColor Cyan
    & $row ''                                           Cyan
    & $row 'OFFICE  NETWORK  TOOL'                      White
    & $row 'LAN Sharing . Drive Mapping . Router-Proof' Gray
    & $row $ToolVersion                                 DarkGray
    & $row ''                                           Cyan
    Write-Host $bar -ForegroundColor Cyan
}

function Read-Yes ($q) { return ((Read-Host "     $q (Y/N)").Trim().ToUpper() -eq 'Y') }

# series input + validation (192.168.0 type) -- galat ho to dobara poochhe
function Read-Series {
    do {
        $s = (Read-Host "     Series daalo (jaise 192.168.0)").Trim()
        $ok = $s -match '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})$'
        if ($ok) { $ok = ($s.Split('.') | ForEach-Object { ([int]$_ -ge 0) -and ([int]$_ -le 255) }) -notcontains $false }
        if (-not $ok) { Write-Fail "Galat format. Sahi jaise: 192.168.0" }
    } while (-not $ok)
    return $s
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


# ------------------------- CORE HELPERS -----------------------------
# Active wired LAN adapter (na mile to koi bhi Up adapter)
function Get-LanAdapter {
    $a = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
         Where-Object { $_.Status -eq 'Up' -and $_.PhysicalMediaType -match '802\.3' } |
         Select-Object -First 1
    if (-not $a) {
        $a = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
    }
    return $a
}

# Is PC ki abhi wali LAN IP (169.254/loopback chhod kar)
function Get-MyLanIP {
    $lan = Get-LanAdapter
    if (-not $lan) { return $null }
    return (Get-NetIPAddress -InterfaceIndex $lan.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' } |
            Select-Object -First 1).IPAddress
}

# Abhi wali series (192.168.0) -- na mile to config $Series
function Get-MySeries {
    $ip = Get-MyLanIP
    if ($ip) { return ($ip -replace '\.\d+$','') }
    return $Series
}

# Router se ASLI series pata karo (thodi der DHCP par jaakar).
# Series milti hai -> string return. Nahi -> purana IP wapas + $null.
function Find-RouterSeries ($adapter) {
    $if = $adapter.Name; $idx = $adapter.ifIndex
    $cfg0  = Get-NetIPConfiguration -InterfaceIndex $idx -ErrorAction SilentlyContinue
    $oldIp = ($cfg0.IPv4Address        | Select-Object -First 1).IPAddress
    $oldGw = ($cfg0.IPv4DefaultGateway | Select-Object -First 1).NextHop

    Write-Info "Router se series pata kar raha hoon (thoda ruko)..."
    netsh interface ip set address "name=$if" dhcp | Out-Null
    netsh interface ip set dns     "name=$if" dhcp | Out-Null
    ipconfig /renew | Out-Null

    $gw = $null
    for ($t = 0; $t -lt 12; $t++) {
        Start-Sleep -Seconds 2
        $c  = Get-NetIPConfiguration -InterfaceIndex $idx -ErrorAction SilentlyContinue
        $gw = ($c.IPv4DefaultGateway | Select-Object -First 1).NextHop
        $d  = ($c.IPv4Address | Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1).IPAddress
        if ($gw -and $d) { break }
    }

    if (-not $gw) {
        if ($oldIp) {
            if ($oldGw) { netsh interface ip set address "name=$if" static $oldIp 255.255.255.0 $oldGw 1 | Out-Null
                          netsh interface ip set dns "name=$if" static $oldGw | Out-Null }
            else        { netsh interface ip set address "name=$if" static $oldIp 255.255.255.0        | Out-Null }
        }
        ipconfig /flushdns | Out-Null
        return $null
    }
    return ($gw -replace '\.\d+$','')
}

# IP static set karo (series + octet), gateway/DNS = series.1
function Set-StaticIP ($adapter, $series, $octet) {
    $if = $adapter.Name
    $ip = "$series.$octet"; $gw = "$series.1"
    netsh interface ip set address "name=$if" static $ip 255.255.255.0 $gw 1 | Out-Null
    netsh interface ip set dns     "name=$if" static $gw                     | Out-Null
    ipconfig /flushdns | Out-Null
    return $ip
}


# ------------------------- DRIVE MAP HELPERS ------------------------
# Ek drive map -- object { Letter, IP, Label, OK } return + clean row print
function Connect-Drive ($letter, $ip, $label) {
    cmdkey /add:$ip /user:$AdminUser "/pass:$AdminPass" 2>$null | Out-Null
    & net.exe use "${letter}:" /delete /y *>$null
    & net.exe use "${letter}:" "\\$ip\$ShareName" /persistent:yes *>$null
    $ok = ($LASTEXITCODE -eq 0)
    if ($ok) {
        $key = "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2\##$ip#$ShareName"
        reg add $key /v _LabelFromReg /t REG_SZ /d "$label" /f 2>$null | Out-Null
    }
    $status = if ($ok) { "OK" } else { "FAIL" }
    $color  = if ($ok) { "Green" } else { "Red" }
    Write-Host ("     {0,-4} {1,-26} {2,-20} " -f "$letter`:", "\\$ip\$ShareName", $label) -NoNewline -ForegroundColor Gray
    Write-Host $status -ForegroundColor $color
    return [pscustomobject]@{ Letter = $letter; IP = $ip; Label = $label; OK = $ok }
}

# I: = apna folder (Inbox) + baaki PC J,K,L... (naam list se, di gayi series par)
function Set-AllDrives ($series) {
    Write-Host ""
    Write-Info "Drives map kar raha hoon..."
    Write-Host ""
    Write-Host ("     {0,-4} {1,-26} {2,-20} {3}" -f "DRV","PATH","LABEL","STATUS") -ForegroundColor DarkGray

    $results = @()
    $selfIP  = Get-MyLanIP
    if ($selfIP) { $results += Connect-Drive "I" $selfIP "Inbox" }
    else { Write-Warn "Is PC par LAN IP nahi -- Inbox skip." }

    $others  = $Pcs | Where-Object { $_.Host -ine $env:COMPUTERNAME }
    $letters = @('J','K','L','M','N','O','P','Q','R','S','T','U','V','W','X','Y','Z')
    $i = 0
    foreach ($pc in $others) {
        if ($i -ge $letters.Count) { break }
        $results += Connect-Drive $letters[$i] "$series.$($pc.Octet)" $pc.Label
        $i++
    }

    Restart-Shell
    $good = ($results | Where-Object { $_.OK }).Count
    $bad  = ($results | Where-Object { -not $_.OK }).Count
    Write-Host ""
    Write-Ok "$good drive map hui.  (I: = Inbox)"
    if ($bad -gt 0) { Write-Warn "$bad drive fail (wo PC abhi on/ready nahi? baad me dobara chalao)." }
}


# =====================  OPTION 1 : CLEANUP  =========================
function Invoke-Cleanup {
    Write-Section "CLEANUP  -  fresh karne ke liye sab saaf"
    Write-Warn "Ye SAARI mapped drives + network credentials + cache delete karega."
    if (-not (Read-Yes "Aage badhein?")) { Write-Info "Cancel kiya."; return }
    Write-Host ""

    & net.exe use * /delete /y *>$null
    Write-Ok "Saari mapped drives delete."

    $removed = 0
    foreach ($line in (cmdkey /list 2>$null)) {
        if ($line -match 'Target:\s*Domain:target=(.+)$') {
            cmdkey /delete:$($matches[1].Trim()) 2>$null | Out-Null
            $removed++
        }
    }
    foreach ($pc in $Pcs) { cmdkey /delete:$($pc.Host) 2>$null | Out-Null }
    Write-Ok "Saved network credentials saaf ($removed hatye)."

    $mp = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2"
    Get-ChildItem $mp -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -like '##*' } |
        ForEach-Object { Remove-Item $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Ok "Drive labels / history saaf."

    Remove-Item "HKCU:\Network\*" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "Persistent connections saaf."

    ipconfig /flushdns              | Out-Null
    nbtstat -R 2>$null              | Out-Null
    netsh interface ip delete arpcache | Out-Null
    Write-Ok "DNS / NetBIOS / ARP cache flush."

    Restart-Shell
    Write-Host ""
    Write-Ok "Cleanup complete -- ab fresh SETUP (2) ya SET IP BY NAME (8) chala sakte ho."
}


# ------------------------- SHARE + USER helper ----------------------
function Set-ShareAndUser {
    # Common admin user
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

    # Folder
    if (-not (Test-Path $LocalPath)) {
        New-Item -Path $LocalPath -ItemType Directory -Force | Out-Null
        Write-Ok "Folder bana: $LocalPath"
    } else { Write-Ok "Folder maujood: $LocalPath" }

    # Share to Everyone (share + NTFS)
    try {
        if (Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue) {
            Remove-SmbShare -Name $ShareName -Force -ErrorAction SilentlyContinue
        }
        New-SmbShare -Name $ShareName -Path $LocalPath -FullAccess "Everyone" | Out-Null
        icacls $LocalPath /grant "Everyone:(OI)(CI)F" /T /C 2>$null | Out-Null
        Write-Ok "'$ShareName' Everyone ko share (Full)."
    } catch { Write-Fail "Share: $($_.Exception.Message)" }
}


# =====================  OPTION 2 : SETUP  ===========================
function Invoke-Setup {
    Write-Section "SETUP  -  Shared-PC banao aur drives map karo"
    Set-ShareAndUser

    # firewall + profile + linked connections
    Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object {
        Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private -ErrorAction SilentlyContinue
    }
    Repair-Firewall
    reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableLinkedConnections /t REG_DWORD /d 1 /f | Out-Null
    Write-Ok "Firewall + Private profile + linked-connections set."

    # drives (abhi wali series par)
    $me = $Pcs | Where-Object { $_.Host -ieq $env:COMPUTERNAME } | Select-Object -First 1
    if (-not $me) { Write-Warn "Is PC ka naam ($env:COMPUTERNAME) list me nahi -- Inbox self-detect IP se lagega, baaki drives phir bhi banenge." }
    Set-AllDrives (Get-MySeries)
    Write-Info "Drives na dikhein to ek baar PC restart karo."
}


# ---- FIREWALL fix helper (incoming + outgoing dono) ----
function Repair-Firewall {
    Set-Service -Name MpsSvc -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name MpsSvc -ErrorAction SilentlyContinue
    Set-NetFirewallProfile -All -DefaultOutboundAction Allow -ErrorAction SilentlyContinue

    Set-NetFirewallRule -DisplayGroup "File and Printer Sharing" -Enabled True -Profile Any -ErrorAction SilentlyContinue
    Set-NetFirewallRule -DisplayGroup "Network Discovery"        -Enabled True -Profile Any -ErrorAction SilentlyContinue
    Set-NetFirewallRule -Name "FPS-ICMP4-ERQ-In"                 -Enabled True -Profile Any -ErrorAction SilentlyContinue

    Get-NetFirewallRule -Direction Inbound -Action Block -Enabled True -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayGroup -in @("File and Printer Sharing","Network Discovery") } |
        ForEach-Object { Disable-NetFirewallRule -Name $_.Name -ErrorAction SilentlyContinue }

    foreach ($r in (Get-NetFirewallRule -Direction Inbound -Action Block -Enabled True -ErrorAction SilentlyContinue)) {
        $pf = $r | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
        if ($pf.LocalPort -match '^(445|139|137|138)$') { Disable-NetFirewallRule -Name $r.Name -ErrorAction SilentlyContinue }
    }

    $allow = @(
        @{ N="OfficeTool-SMB-In";  D="Inbound";  P="TCP"; Port=@(445)     },
        @{ N="OfficeTool-NB-In";   D="Inbound";  P="TCP"; Port=@(139)     },
        @{ N="OfficeTool-NBu-In";  D="Inbound";  P="UDP"; Port=@(137,138) },
        @{ N="OfficeTool-SMB-Out"; D="Outbound"; P="TCP"; Port=@(445)     },
        @{ N="OfficeTool-NB-Out";  D="Outbound"; P="TCP"; Port=@(139)     },
        @{ N="OfficeTool-NBu-Out"; D="Outbound"; P="UDP"; Port=@(137,138) }
    )
    foreach ($a in $allow) {
        Remove-NetFirewallRule -Name $a.N -ErrorAction SilentlyContinue
        New-NetFirewallRule -Name $a.N -DisplayName $a.N -Direction $a.D -Action Allow `
            -Protocol $a.P -LocalPort $a.Port -Profile Any -RemoteAddress LocalSubnet -ErrorAction SilentlyContinue | Out-Null
    }
    Remove-NetFirewallRule -Name "OfficeTool-Ping-In" -ErrorAction SilentlyContinue
    New-NetFirewallRule -Name "OfficeTool-Ping-In" -DisplayName "OfficeTool-Ping-In" -Direction Inbound -Action Allow `
        -Protocol ICMPv4 -IcmpType 8 -Profile Any -RemoteAddress LocalSubnet -ErrorAction SilentlyContinue | Out-Null
}


# ===============  OPTION 3 : NETWORK HARDENING  =====================
function Optimize-Network {
    Write-Section "HARDEN  -  router-proof connection (LAN hamesha priority)"

    foreach ($ad in Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }) {
        $isWifi = ($ad.PhysicalMediaType -match '802\.11') -or ($ad.InterfaceDescription -match 'Wi-?Fi|Wireless')
        $metric = if ($isWifi) { 50 } else { 10 }
        Set-NetIPInterface -InterfaceIndex $ad.ifIndex -InterfaceMetric $metric -ErrorAction SilentlyContinue
        Write-Ok ("{0,-26} metric {1}  ({2})" -f $ad.Name, $metric, ($(if($isWifi){'Wi-Fi'}else{'LAN'})))
    }

    foreach ($ad in Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }) {
        try {
            $pm = Get-NetAdapterPowerManagement -Name $ad.Name -ErrorAction Stop
            $pm.AllowComputerToTurnOffDevice = 'Disabled'
            Set-NetAdapterPowerManagement -InputObject $pm -ErrorAction SilentlyContinue
        } catch {}
    }
    Write-Ok "Network card power-saving band."

    Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object {
        Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private -ErrorAction SilentlyContinue
    }
    Repair-Firewall
    Write-Ok "Firewall: sharing/discovery/ping ON, block-rules hatye, LAN allow-rules bane (in+out)."

    foreach ($c in (Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" -ErrorAction SilentlyContinue)) {
        Invoke-CimMethod -InputObject $c -MethodName SetTcpipNetbios -Arguments @{ TcpipNetbios = [uint32]1 } -ErrorAction SilentlyContinue | Out-Null
    }
    Write-Ok "NetBIOS over TCP/IP enable."

    foreach ($s in "LanmanServer","LanmanWorkstation","FDResPub","fdPHost","SSDPSRV","upnphost","Spooler") {
        Set-Service -Name $s -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service -Name $s -ErrorAction SilentlyContinue
    }
    Write-Ok "Sharing / Discovery / Print services Automatic + chalu."

    reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableLinkedConnections /t REG_DWORD /d 1 /f | Out-Null
    Write-Ok "Mapped drives elevated+normal dono me dikhein."

    Write-Host ""
    Write-Ok "HARDENING complete -- switch on + LAN juda ho to router band hone par bhi jude rahenge."
    Write-Info "Poori tarah lagu hone ke liye ek baar PC restart behtar."
}


# ===============  OPTION 4 : IP SERIES (fully manual)  ==============
function Set-IPSeries {
    Write-Section "IP SERIES  -  series + last number dono khud daalo"
    Write-Info "Kaam: aap series aur last number dono type karte ho; wahi IP lag jata hai."

    $adapter = Get-LanAdapter
    if (-not $adapter) { Write-Fail "Koi active LAN adapter nahi mila."; return }

    $curIp   = Get-MyLanIP
    $defLast = if ($curIp) { $curIp.Split('.')[-1] } else { $null }
    Write-Info ("Adapter : {0}" -f $adapter.Name)
    Write-Info ("Abhi IP : {0}" -f ($(if ($curIp) { $curIp } else { '(koi static IP nahi)' })))
    Write-Host ""

    $series = Read-Series
    $prompt = if ($defLast) { "     Last number (Enter = $defLast same rakho)" } else { "     Last number (jaise 240)" }
    $inLast = (Read-Host $prompt).Trim()
    $lastOctet = if ($inLast) { $inLast } elseif ($defLast) { $defLast } else { $null }
    if (-not $lastOctet -or $lastOctet -notmatch '^\d+$' -or [int]$lastOctet -lt 1 -or [int]$lastOctet -gt 254) {
        Write-Fail "Last number galat (1-254). Ruk gaya."; return
    }

    Write-Host ""
    Write-Info "Naya set hoga:  IP $series.$lastOctet  Gateway $series.1  Mask 255.255.255.0"
    Write-Host ""
    if (-not (Read-Yes "Apply karein?")) { Write-Info "Cancel kiya."; return }

    $ip = Set-StaticIP $adapter $series $lastOctet
    Write-Host ""
    Write-Ok "Naya IP = $ip , Gateway = $series.1"
}


# ===============  OPTION 5 : AUTO IP (current octet rakhe)  =========
function Update-IPSeriesAuto {
    Write-Section "AUTO IP  -  series auto, last number JO ABHI HAI wahi rahe"
    Write-Info "Kaam: router se series khud pata karta hai; is PC ka ABHI wala last-number"
    Write-Info "      rakhkar naya IP set karta hai; phir saari drives remap. (Octet already sahi ho tab.)"

    $adapter = Get-LanAdapter
    if (-not $adapter) { Write-Fail "Koi active LAN adapter nahi mila."; return }
    $oldIp = Get-MyLanIP
    if (-not $oldIp) { Write-Fail "Is PC par abhi koi IP nahi -- pehle IP SERIES (4) ya BY NAME (8) chalao."; return }
    $octet = $oldIp.Split('.')[-1]
    Write-Info ("Abhi IP: {0}  (last number {1} yaad rakha)" -f $oldIp, $octet)

    $series = Find-RouterSeries $adapter
    if (-not $series) { Write-Fail "Router se series nahi mili (DHCP off / router band?). Purana IP wapas laga diya."; return }

    $ip = Set-StaticIP $adapter $series $octet
    Write-Ok "Naya IP set: $ip , Gateway $series.1"
    Set-AllDrives $series
    Write-Host ""
    Write-Ok "Sab kuch nayi series ($series.x) par set ho gaya."
}


# ---- Explorer refresh (drive labels dikhane ke liye) ----
function Restart-Shell {
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 900
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer }
}


# ===============  OPTION 6 : HOTSPOT INTERNET  ======================
function Enable-HotspotInternet {
    Write-Section "HOTSPOT NET  -  router dead? sharing chaalu, internet hotspot se"
    Write-Info "Kaam: LAN ka dead gateway hata deta hai (IP/mask rehne dega). Sharing chalti"
    Write-Info "      rahegi; internet mobile hotspot (WiFi) se aayega."

    $lan = Get-LanAdapter
    if (-not $lan) { Write-Fail "Koi active LAN adapter nahi mila."; return }
    $ipAddr = Get-MyLanIP
    if (-not $ipAddr) { Write-Fail "LAN par IP nahi mila. Pehle static IP set karo (Option 4/8)."; return }

    Write-Info "LAN adapter: $($lan.Name)   IP: $ipAddr"
    Write-Host ""
    if (-not (Read-Yes "LAN ka gateway hata kar internet hotspot par le jaayein?")) { Write-Info "Cancel kiya."; return }

    Remove-NetRoute -InterfaceIndex $lan.ifIndex -DestinationPrefix '0.0.0.0/0' -Confirm:$false -ErrorAction SilentlyContinue
    netsh interface ip set address "name=$($lan.Name)" static $ipAddr 255.255.255.0 | Out-Null
    ipconfig /flushdns | Out-Null

    Write-Host ""
    Write-Ok "LAN ka gateway hataya -- ab internet WiFi/hotspot se jayega."
    Write-Ok "LAN sharing ($ipAddr) waise hi chaalu -- PCs aapas me judte rahenge."
    Write-Info "Ab mobile HOTSPOT se WiFi connect karo. Router wapas aane par AUTO IP (5) ya BY NAME (8) chalao."
}


# ===============  OPTION 7 : HEALTH CHECK (diagnose + fix)  ==========
function Invoke-Diagnose {
    Write-Section "HEALTH CHECK  -  network jaanch + auto-fix"
    $fixed  = 0
    $manual = New-Object System.Collections.ArrayList
    $me     = $Pcs | Where-Object { $_.Host -ieq $env:COMPUTERNAME } | Select-Object -First 1

    # 1) Adapter & Cable
    Write-Host "`n   [ 1. Adapter & Cable ]" -ForegroundColor White
    $wired = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.PhysicalMediaType -match '802\.3' }
    if (-not $wired) {
        Write-Fail "Koi wired LAN adapter nahi mila."
        [void]$manual.Add("Wired LAN adapter/driver check karo (Device Manager).")
    } else {
        foreach ($w in $wired) {
            if     ($w.Status -eq 'Disabled')     { Enable-NetAdapter -Name $w.Name -Confirm:$false -ErrorAction SilentlyContinue; Write-Ok "LAN '$($w.Name)' disabled tha -> enable kiya."; $fixed++ }
            elseif ($w.Status -eq 'Disconnected') { Write-Fail "LAN '$($w.Name)': cable NAHI juda (Disconnected)."; [void]$manual.Add("LAN cable/switch check karo -- '$($w.Name)' disconnected.") }
            else                                   { Write-Ok "LAN '$($w.Name)' juda aur active." }
        }
    }
    $lan = Get-LanAdapter

    # 2) PC naam list me hai?
    Write-Host "`n   [ 2. PC Naam ]" -ForegroundColor White
    if ($me) { Write-Ok "Naam '$env:COMPUTERNAME' list me hai (last number = $($me.Octet), '$($me.Label)')." }
    else     { Write-Warn "Naam '$env:COMPUTERNAME' list me NAHI."; [void]$manual.Add("Is PC ka naam list se match nahi -- naam theek karo ya config me add karo.") }

    # 3) IP config
    Write-Host "`n   [ 3. IP Address ]" -ForegroundColor White
    $ipObj = $null
    if ($lan) {
        $ipObj = Get-NetIPAddress -InterfaceIndex $lan.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                 Where-Object { $_.IPAddress -ne '127.0.0.1' } | Select-Object -First 1
    }
    if (-not $ipObj -or $ipObj.IPAddress -like '169.254.*') {
        Write-Fail "Static IP set nahi (APIPA/koi IP nahi)."
        [void]$manual.Add("IP set karne ke liye SET IP BY NAME (8) chalao.")
    } else {
        $ip = $ipObj.IPAddress
        if ($ipObj.AddressState -eq 'Duplicate') {
            Write-Fail "IP CONFLICT: $ip koi aur device bhi use kar raha hai."
            [void]$manual.Add("IP conflict ($ip) -- BY NAME (8) se dobara set karo ya number badlo.")
        } else { Write-Ok "IP: $ip (conflict nahi)." }
        if ($ipObj.PrefixLength -ne 24) {
            $gw = ((Get-NetIPConfiguration -InterfaceIndex $lan.ifIndex).IPv4DefaultGateway | Select-Object -First 1).NextHop
            if ($gw) { netsh interface ip set address "name=$($lan.Name)" static $ip 255.255.255.0 $gw 1 | Out-Null }
            else     { netsh interface ip set address "name=$($lan.Name)" static $ip 255.255.255.0        | Out-Null }
            Write-Ok "Subnet mask galat (/$($ipObj.PrefixLength)) tha -> 255.255.255.0 kiya."; $fixed++
        } else { Write-Ok "Subnet mask sahi (255.255.255.0)." }
        # naam ke hisaab se last number sahi hai?
        if ($me -and ($ip.Split('.')[-1] -ne "$($me.Octet)")) {
            Write-Warn "Last number ($($ip.Split('.')[-1])) naam ke hisaab se ($($me.Octet)) alag hai."
            [void]$manual.Add("Naam ke hisaab se IP galat -- SET IP BY NAME (8) chalao.")
        } elseif ($me) { Write-Ok "Last number naam ke hisaab se sahi ($($me.Octet))." }
    }

    # 4) Gateway
    Write-Host "`n   [ 4. Gateway ]" -ForegroundColor White
    if ($lan) {
        $gw = ((Get-NetIPConfiguration -InterfaceIndex $lan.ifIndex).IPv4DefaultGateway | Select-Object -First 1).NextHop
        if ($gw) {
            if (Test-Connection -ComputerName $gw -Count 1 -Quiet -ErrorAction SilentlyContinue) { Write-Ok "Gateway $gw reachable (internet path OK)." }
            else { Write-Warn "Gateway $gw reachable nahi (router band/dead?)." ; [void]$manual.Add("Internet chahiye to HOTSPOT NET (6) chalao. LAN sharing phir bhi chalegi.") }
        } else { Write-Info "Gateway set nahi (LAN-only mode -- sharing ke liye theek hai)." }
    }

    # 5) WiFi/LAN clash (do-darwaze)
    Write-Host "`n   [ 5. WiFi/LAN conflict ]" -ForegroundColor White
    $wifi = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { ($_.PhysicalMediaType -match '802\.11') -and $_.Status -eq 'Up' }
    $clash = $false
    if ($wifi -and $ipObj) {
        foreach ($wf in $wifi) {
            $wIP = (Get-NetIPAddress -InterfaceIndex $wf.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '169.254.*' }).IPAddress | Select-Object -First 1
            if ($wIP -and ($wIP -replace '\.\d+$','') -eq ($ipObj.IPAddress -replace '\.\d+$','')) { $clash = $true }
        }
    }
    if ($clash) {
        Write-Warn "WiFi bhi LAN wali series par hai (do-darwaze problem) -- metric fix niche lagega."
        [void]$manual.Add("PC ko OFFICE WiFi se disconnect karo -- sirf LAN cable rakho (mobile hotspot theek hai).")
    } else { Write-Ok "WiFi/LAN series clash nahi." }

    # 6) Workgroup
    Write-Host "`n   [ 6. Workgroup ]" -ForegroundColor White
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($cs.PartOfDomain) { Write-Ok "Domain-joined ($($cs.Domain)) -- workgroup skip." }
    elseif ($cs.Workgroup -ne $Workgroup) {
        try { Add-Computer -WorkgroupName $Workgroup -Force -ErrorAction Stop
              Write-Ok "Workgroup '$($cs.Workgroup)' -> '$Workgroup' badla."; $fixed++
              [void]$manual.Add("Workgroup badla -- ek baar PC RESTART karo.") }
        catch { Write-Warn "Workgroup set nahi hua: $($_.Exception.Message)" }
    } else { Write-Ok "Workgroup sahi ($Workgroup)." }

    # 7) SMB & Share
    Write-Host "`n   [ 7. SMB & Share ]" -ForegroundColor White
    $smb = Get-SmbServerConfiguration -ErrorAction SilentlyContinue
    if ($smb -and -not $smb.EnableSMB2Protocol) { Set-SmbServerConfiguration -EnableSMB2Protocol $true -Force -ErrorAction SilentlyContinue; Write-Ok "SMB2 band tha -> enable."; $fixed++ }
    else { Write-Ok "SMB protocol theek." }
    if (Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue) { Write-Ok "Share '$ShareName' maujood." }
    else { Write-Warn "Share '$ShareName' nahi bana."; [void]$manual.Add("Shared folder banane ke liye SETUP (2) chalao.") }

    # 8) Firewall
    Write-Host "`n   [ 8. Firewall ]" -ForegroundColor White
    $blocks = 0
    foreach ($r in (Get-NetFirewallRule -Direction Inbound -Action Block -Enabled True -ErrorAction SilentlyContinue)) {
        $pf = $r | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
        if ($pf.LocalPort -match '^(445|139|137|138)$' -or $r.DisplayGroup -in @("File and Printer Sharing","Network Discovery")) { $blocks++ }
    }
    Repair-Firewall
    if ($blocks -gt 0) { Write-Ok "Firewall: $blocks block-rule hataye + sharing allow (in+out) bane."; $fixed++ }
    else               { Write-Ok "Firewall: sharing allow-rules (in+out) set, ping ON." }
    $av = Get-CimInstance -Namespace root\SecurityCenter2 -ClassName FirewallProduct -ErrorAction SilentlyContinue |
          Where-Object { $_.displayName -notmatch 'Windows' }
    if ($av) {
        foreach ($p in $av) { Write-Warn "Third-party firewall mila: $($p.displayName)" }
        [void]$manual.Add("Third-party firewall/AV ($(( $av.displayName ) -join ', ')) me LAN/file-sharing ko allow karo.")
    } else { Write-Ok "Koi third-party firewall nahi (sirf Windows Firewall)." }

    # 9) Router-proof standard fixes
    Write-Host "`n   [ 9. Router-proof settings laga raha hoon ]" -ForegroundColor White
    Optimize-Network | Out-Null
    $fixed += 7

    ipconfig /flushdns              | Out-Null
    nbtstat -R 2>$null              | Out-Null
    netsh interface ip delete arpcache | Out-Null
    Write-Ok "DNS / NetBIOS / ARP cache flush."

    # 10) Baaki PCs se connection
    Write-Host "`n   [ 10. Baaki PCs se connection ]" -ForegroundColor White
    $series0 = Get-MySeries
    Write-Host ("     {0,-20} {1,-16} {2,-8} {3}" -f "LABEL","IP","PING","SHARING") -ForegroundColor DarkGray
    foreach ($pc in $Pcs) {
        if ($pc.Host -ieq $env:COMPUTERNAME) { continue }
        $tip  = "$series0.$($pc.Octet)"
        $ping = Test-Connection -ComputerName $tip -Count 1 -Quiet -ErrorAction SilentlyContinue
        $smbOk = $false
        if ($ping) { $smbOk = (Test-NetConnection -ComputerName $tip -Port 445 -InformationLevel Quiet -WarningAction SilentlyContinue) }
        $pTxt = if ($ping) {"UP"} else {"DOWN"};  $pCol = if ($ping) {"Green"} else {"Red"}
        $sTxt = if ($smbOk){"OK"} else {"--"};    $sCol = if ($smbOk){"Green"} else {"Yellow"}
        Write-Host ("     {0,-20} {1,-16} " -f $pc.Label, $tip) -NoNewline -ForegroundColor Gray
        Write-Host ("{0,-8}" -f $pTxt) -NoNewline -ForegroundColor $pCol
        Write-Host $sTxt -ForegroundColor $sCol
    }

    Write-Host ""
    Write-Host "  ------------------------------------------------------------------" -ForegroundColor DarkCyan
    Write-Ok "$fixed cheezein auto-fix / set ho gayin."
    if ($manual.Count -gt 0) {
        Write-Host ""
        Write-Warn "In par DHYAN do (haath se karna hoga):"
        foreach ($m in $manual) { Write-Host "        - $m" -ForegroundColor Yellow }
    } else { Write-Ok "Koi manual kaam baaki nahi -- sab theek!" }
    Restart-Shell
}


# ===============  OPTION 8 : SET IP BY NAME  ========================
function Set-IPByName {
    Write-Section "SET IP BY NAME  -  PC ke naam se IP + drives"
    Write-Info "Kaam: is PC ka NAAM ($env:COMPUTERNAME) list me dekhta hai -> last number uthata hai."
    Write-Info "      Series router se auto ya aap daalo -> IP set -> saari drives map."

    $me = $Pcs | Where-Object { $_.Host -ieq $env:COMPUTERNAME } | Select-Object -First 1
    if (-not $me) {
        Write-Fail "Is PC ka naam '$env:COMPUTERNAME' list me nahi mila."
        Write-Info "PC ka naam theek karo (jaise CCL-PC7) ya config ki list me add karo."
        return
    }
    Write-Ok "Naam '$($me.Host)' -> last number $($me.Octet) ('$($me.Label)')."

    $adapter = Get-LanAdapter
    if (-not $adapter) { Write-Fail "Koi active LAN adapter nahi mila."; return }

    # series mode
    Write-Host ""
    Write-Host "     1) Series AUTO detect karo (router se)" -ForegroundColor Gray
    Write-Host "     2) Series main khud daalunga" -ForegroundColor Gray
    do { $m = (Read-Host "     Chuno (1 ya 2)").Trim() } while ($m -notin @('1','2'))

    # 1) user + folder + share (poora ek-click-per-PC)
    Write-Host ""
    Set-ShareAndUser

    # 2) firewall + profile + linked connections
    Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object {
        Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private -ErrorAction SilentlyContinue
    }
    Repair-Firewall
    reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableLinkedConnections /t REG_DWORD /d 1 /f | Out-Null
    Write-Ok "Firewall + Private profile + linked-connections set."

    # 3) series pata karo + IP set
    $series = $null
    if ($m -eq '1') {
        $series = Find-RouterSeries $adapter
        if (-not $series) {
            Write-Warn "Router se series nahi mili (router band/DHCP off)."
            if (Read-Yes "Series khud daalna chahte ho?") { $series = Read-Series } else { Write-Info "Cancel kiya."; return }
        } else { Write-Ok "Router series mili: $series.x" }
    } else {
        $series = Read-Series
    }
    $ip = Set-StaticIP $adapter $series $($me.Octet)
    Write-Ok "IP set: $ip , Gateway $series.1 , DNS $series.1"

    # 4) drives
    Set-AllDrives $series
    Write-Host ""
    Write-Ok "$($me.Host) poori tarah taiyaar -- user + share + IP ($ip) + drives set."
    Write-Info "Har PC par bas ye BY NAME (8) chala do -- har ek apne naam se sab kar lega."
}


# =========================  MAIN MENU  ==============================
do {
    Write-Banner
    Write-Host ""
    Write-Host "     CONFIG:  Admin='$AdminUser'   Share='$ShareName'   PCs=$($Pcs.Count)   Series=$Series" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "      [1]  CLEANUP      " -NoNewline -ForegroundColor Yellow;  Write-Host "Purani mapping / credentials / cache saaf" -ForegroundColor Gray
    Write-Host "      [2]  SETUP        " -NoNewline -ForegroundColor Green;   Write-Host "Shared-PC banao + drives map (I=Inbox, J,K,L)" -ForegroundColor Gray
    Write-Host "      [3]  HARDEN       " -NoNewline -ForegroundColor Cyan;    Write-Host "LAN priority + router-proof settings" -ForegroundColor Gray
    Write-Host "      [4]  IP SERIES    " -NoNewline -ForegroundColor Magenta; Write-Host "Series + last number DONO khud daalo" -ForegroundColor Gray
    Write-Host "      [5]  AUTO IP      " -NoNewline -ForegroundColor White;   Write-Host "Series auto, last number JO ABHI HAI wahi rahe" -ForegroundColor Gray
    Write-Host "      [6]  HOTSPOT NET  " -NoNewline -ForegroundColor Blue;    Write-Host "Router dead? sharing chaalu + internet hotspot se" -ForegroundColor Gray
    Write-Host "      [7]  HEALTH CHECK " -NoNewline -ForegroundColor Red;     Write-Host "Network diagnose + har fixable problem auto-fix" -ForegroundColor Gray
    Write-Host "      [8]  SET IP BY NAME" -NoNewline -ForegroundColor Green;  Write-Host " PC ke NAAM se last number (series auto/manual) + drives" -ForegroundColor Gray
    Write-Host "      [0]  EXIT" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  ------------------------------------------------------------------" -ForegroundColor DarkCyan
    $choice = (Read-Host "     Option chuno (0-8)").Trim()

    switch ($choice) {
        '1' { Invoke-Cleanup }
        '2' { Invoke-Setup }
        '3' { Optimize-Network }
        '4' { Set-IPSeries }
        '5' { Update-IPSeriesAuto }
        '6' { Enable-HotspotInternet }
        '7' { Invoke-Diagnose }
        '8' { Set-IPByName }
        '0' { Write-Host "`n     Bye!`n" -ForegroundColor Cyan }
        default { Write-Warn "Galat option. 0 se 8 tak chuno." }
    }

    if ($choice -ne '0') { Write-Host ""; Read-Host "     Enter dabao -> menu par wapas" | Out-Null }

} while ($choice -ne '0')
