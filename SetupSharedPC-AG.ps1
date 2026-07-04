# =====================================================================
#   OFFICE NETWORK TOOL
#   Run (PowerShell as Administrator):  irm <your-github-raw-url> | iex
#
#    1 CLEANUP         Remove old mappings / credentials / cache
#    2 SETUP           Create share + user + map drives
#    9 MAP DRIVES      Only re-map drives (2nd pass)
#    3 HARDEN          LAN priority + router-proof settings
#    4 IP SERIES       Enter series + last number manually
#    5 AUTO IP         Auto series, keep current last number
#    8 SET IP BY NAME  Name-based IP + full per-PC setup
#    6 HOTSPOT NET     Internet via hotspot when router is dead
#    7 HEALTH CHECK    Diagnose + auto-fix everything
#   10 ACCOUNTS        Create / delete local accounts
#   11 PRINTER FIX     Windows 11 host fix for Win7 <-> Win11 printer sharing
#                       (Windows 7 side uses a SEPARATE offline file, see chat)
#   12 REMOTE CHECK    Live status from every PC via WinRM -- no visit needed
# =====================================================================

# ============================ CONFIG =================================
# 1) Common ADMIN account (same user + pass on EVERY PC)
$AdminUser = "CNB"
$AdminPass = "1234"

# 2) Shared folder (same on every PC)
$ShareName = "Shared-PC"
$LocalPath = "D:\Shared-PC"

# 2b) Workgroup name (must be same on all PCs)
$Workgroup = "WORKGROUP"

# 2c) Default series (manual mode + fallback when auto-detect fails)
$Series = "192.168.0"

# 3) MASTER LIST -- Windows PC name -> last IP number -> drive label
#    (IP = <series>.<Octet> , e.g. 192.168.0.241 for CCL-PC7)
$Pcs = @(
    @{ Host = "CCL-PC2"; Octet = 246; Label = "Mohit"              },
    @{ Host = "CCL-PC3"; Octet = 244; Label = "Sunil Kushwaha Sir" },
    @{ Host = "CCL-PC4"; Octet = 248; Label = "Vipin"              },
    @{ Host = "CCL-PC5"; Octet = 243; Label = "Aseem Meena Sir"    },
    @{ Host = "CCL-PC6"; Octet = 247; Label = "Raveesh"            },
    @{ Host = "CCL-PC7"; Octet = 241; Label = "Salman"             },
    @{ Host = "CCL-PC8"; Octet = 242; Label = "Mukesh"             }
)
# ====================================================================


$ToolVersion = "v2.9"

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

# Centered banner box (auto-padded, always aligned)
function Write-Banner {
    Clear-Host
    $w   = 62
    $bar = '  +' + ('=' * $w) + '+'
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
    & $row ''                                          Cyan
    & $row 'OFFICE  NETWORK  TOOL'                     White
    & $row 'LAN . Sharing . Drive Mapping . IP Manage' Gray
    & $row $ToolVersion                                DarkGray
    & $row ''                                          Cyan
    Write-Host $bar -ForegroundColor Cyan
}

function Read-Yes ($q) { return ((Read-Host "     $q (Y/N)").Trim().ToUpper() -eq 'Y') }

# Series input + validation (e.g. 192.168.0)
function Read-Series {
    do {
        $s = (Read-Host "     Enter series (e.g. 192.168.0)").Trim()
        $ok = $s -match '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})$'
        if ($ok) { $ok = ($s.Split('.') | ForEach-Object { ([int]$_ -ge 0) -and ([int]$_ -le 255) }) -notcontains $false }
        if (-not $ok) { Write-Fail "Wrong format. Correct example: 192.168.0" }
    } while (-not $ok)
    return $s
}


# ------------------------- ADMIN CHECK ------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
          ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Banner
    Write-Host ""
    Write-Fail "This tool needs Administrator rights."
    Write-Info "Open PowerShell as 'Run as Administrator', then run again."
    Write-Host ""
    return
}


# ------------------------- CORE HELPERS -----------------------------
# Active wired LAN adapter (fallback: any Up adapter)
function Get-LanAdapter {
    $a = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
         Where-Object { $_.Status -eq 'Up' -and $_.PhysicalMediaType -match '802\.3' } |
         Select-Object -First 1
    if (-not $a) {
        $a = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
    }
    return $a
}

# Current LAN IPv4 (skip APIPA/loopback)
function Get-MyLanIP {
    $lan = Get-LanAdapter
    if (-not $lan) { return $null }
    return (Get-NetIPAddress -InterfaceIndex $lan.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' } |
            Select-Object -First 1).IPAddress
}

# Current series (e.g. 192.168.0), fallback to config $Series
function Get-MySeries {
    $ip = Get-MyLanIP
    if ($ip) { return ($ip -replace '\.\d+$','') }
    return $Series
}

# Detect the router's real series by briefly using DHCP.
# Returns series string, or $null (and restores the old static IP).
function Find-RouterSeries ($adapter) {
    $if = $adapter.Name; $idx = $adapter.ifIndex
    $cfg0  = Get-NetIPConfiguration -InterfaceIndex $idx -ErrorAction SilentlyContinue
    $oldIp = ($cfg0.IPv4Address        | Select-Object -First 1).IPAddress
    $oldGw = ($cfg0.IPv4DefaultGateway | Select-Object -First 1).NextHop

    Write-Info "Detecting series from router (please wait)..."
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

# Set a static IP (series + octet); gateway/DNS = series.1
function Set-StaticIP ($adapter, $series, $octet) {
    $if = $adapter.Name
    $ip = "$series.$octet"; $gw = "$series.1"
    netsh interface ip set address "name=$if" static $ip 255.255.255.0 $gw 1 | Out-Null
    netsh interface ip set dns     "name=$if" static $gw                     | Out-Null
    ipconfig /flushdns | Out-Null
    return $ip
}

# Explorer refresh (so drive labels show)
function Restart-Shell {
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 900
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer }
}


# ------------------------- DRIVE MAP HELPERS ------------------------
# Quick TCP reachability check with a REAL timeout. Test-Connection / net.exe use
# have no timeout of their own and can hang for a long time (sometimes minutes)
# when the router is down and Windows is stuck "Identifying network...". Used to
# fail fast on unreachable peer PCs instead of freezing the whole mapping loop.
function Test-PortOpen ($ip, $port, $timeoutMs = 1500) {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($ip, $port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne($timeoutMs) -and $client.Connected
        if ($ok) { $client.EndConnect($iar) }
        $client.Close()
        return $ok
    } catch { return $false }
}

# Map one drive -> returns { Letter, IP, Label, OK } and prints a row
function Connect-Drive ($letter, $ip, $label) {
    if (-not (Test-PortOpen $ip 445)) {
        Write-Host ("     {0,-4} {1,-26} {2,-20} " -f "$letter`:", "\\$ip\$ShareName", $label) -NoNewline -ForegroundColor Gray
        Write-Host "FAIL" -ForegroundColor Red
        return [pscustomobject]@{ Letter = $letter; IP = $ip; Label = $label; OK = $false }
    }
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

# I: = own folder (Inbox) -- LOCAL only (subst), never touches the network.
# Earlier versions mapped this over SMB to the PC's own IP (a full network
# round-trip through the switch back to itself). When the router died,
# Windows' Network Location Awareness could get stuck "Identifying
# network..." and that self-addressed SMB call would hang, freezing the
# whole tool before it even reached the other PCs / printer. subst is a
# pure local drive-letter alias, so it can never hang regardless of
# router/network state.
function Connect-InboxLocal {
    & net.exe use "I:" /delete /y *>$null   # remove any old network-based Inbox mapping
    subst I: /d *>$null                     # remove any previous subst
    subst I: $LocalPath *>$null
    $ok = (Test-Path "I:\")
    $status = if ($ok) { "OK" } else { "FAIL" }
    $color  = if ($ok) { "Green" } else { "Red" }
    Write-Host ("     {0,-4} {1,-26} {2,-20} " -f "I:", $LocalPath, "Inbox") -NoNewline -ForegroundColor Gray
    Write-Host $status -ForegroundColor $color
    return [pscustomobject]@{ Letter = "I"; IP = $null; Label = "Inbox"; OK = $ok }
}

# I: = own folder (Inbox, local) + other PCs on J,K,L... (from list, on given series)
function Set-AllDrives ($series) {
    Write-Host ""
    Write-Info "Mapping drives..."
    Write-Host ""
    Write-Host ("     {0,-4} {1,-26} {2,-20} {3}" -f "DRV","PATH","LABEL","STATUS") -ForegroundColor DarkGray

    $results = @()
    if (Test-Path $LocalPath) { $results += Connect-InboxLocal }
    else { Write-Warn "Local folder '$LocalPath' not found -- Inbox skipped (run SETUP (2) first)." }

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
    Write-Ok "$good drives mapped.  (I: = Inbox)"
    if ($bad -gt 0) { Write-Warn "$bad drives failed (that PC not ready yet? run again later)." }
}


# =====================  OPTION 1 : CLEANUP  =========================
function Invoke-Cleanup {
    Write-Section "CLEANUP  -  remove everything for a fresh start"
    Write-Warn "This deletes ALL mapped drives + network credentials + cache."
    if (-not (Read-Yes "Continue?")) { Write-Info "Cancelled."; return }
    Write-Host ""

    # remove mapped drives (active + dead/stuck)
    Get-SmbMapping -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-SmbMapping -LocalPath $_.LocalPath -Force -UpdateProfile -ErrorAction SilentlyContinue
    }
    & net.exe use * /delete /y *>$null
    foreach ($code in 69..90) {   # E: .. Z: force delete (local disks ignored)
        & net.exe use ("{0}:" -f [char]$code) /delete /y *>$null
    }
    subst I: /d *>$null   # Inbox is a local subst now, not a net-use mapping
    Write-Ok "All mapped drives deleted (including dead/stuck ones)."

    # remove saved network credentials (including old PC-name ones)
    $removed = 0
    foreach ($line in (cmdkey /list 2>$null)) {
        if ($line -match 'Target:\s*Domain:target=(.+)$') {
            cmdkey /delete:$($matches[1].Trim()) 2>$null | Out-Null
            $removed++
        }
    }
    foreach ($pc in $Pcs) { cmdkey /delete:$($pc.Host) 2>$null | Out-Null }
    Write-Ok "Saved network credentials cleared ($removed removed)."

    # remove drive labels / history (MountPoints2)
    $mp = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2"
    Get-ChildItem $mp -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -like '##*' } |
        ForEach-Object { Remove-Item $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Ok "Drive labels / history cleared."

    # remove persistent connections (HKCU\Network)
    Remove-Item "HKCU:\Network\*" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "Persistent connections cleared."

    # flush caches
    ipconfig /flushdns              | Out-Null
    nbtstat -R 2>$null              | Out-Null
    netsh interface ip delete arpcache | Out-Null
    Write-Ok "DNS / NetBIOS / ARP cache flushed."

    Restart-Shell
    Write-Host ""
    Write-Ok "Cleanup complete -- now run SETUP (2) or SET IP BY NAME (8)."
    Write-Info "If a drive still shows, it is held by your login session (registry already cleared)."
    Write-Info "Just LOGOFF/RESTART once -- it will be gone and won't return."
}


# ------------------------- SHARE + USER helper ----------------------
function Set-ShareAndUser {
    # common admin user
    try {
        $sec = ConvertTo-SecureString $AdminPass -AsPlainText -Force
        if (Get-LocalUser -Name $AdminUser -ErrorAction SilentlyContinue) {
            Set-LocalUser -Name $AdminUser -Password $sec
            Write-Ok "User '$AdminUser' (password updated)."
        } else {
            New-LocalUser -Name $AdminUser -Password $sec -FullName $AdminUser `
                -Description "Office shared access" -PasswordNeverExpires -AccountNeverExpires | Out-Null
            Write-Ok "User '$AdminUser' created."
        }
        Add-LocalGroupMember -Group "Administrators" -Member $AdminUser -ErrorAction SilentlyContinue
        Write-Ok "'$AdminUser' -> Administrators group."
    } catch { Write-Fail "User: $($_.Exception.Message)" }

    # folder
    if (-not (Test-Path $LocalPath)) {
        New-Item -Path $LocalPath -ItemType Directory -Force | Out-Null
        Write-Ok "Folder created: $LocalPath"
    } else { Write-Ok "Folder exists: $LocalPath" }

    # share to Everyone (share + NTFS)
    try {
        if (Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue) {
            Remove-SmbShare -Name $ShareName -Force -ErrorAction SilentlyContinue
        }
        New-SmbShare -Name $ShareName -Path $LocalPath -FullAccess "Everyone" | Out-Null
        icacls $LocalPath /grant "Everyone:(OI)(CI)F" /T /C 2>$null | Out-Null
        Write-Ok "'$ShareName' shared to Everyone (Full)."
    } catch { Write-Fail "Share: $($_.Exception.Message)" }
}


# ---- FIREWALL fix helper (incoming + outgoing) ----
function Repair-Firewall {
    # keep Windows Firewall running (do not disable it)
    Set-Service -Name MpsSvc -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name MpsSvc -ErrorAction SilentlyContinue
    # outbound default allow
    Set-NetFirewallProfile -All -DefaultOutboundAction Allow -ErrorAction SilentlyContinue

    # Built-in sharing/discovery: re-scope to Domain+Private only (removes Public).
    # IMPORTANT: "-Profile X" on Set-NetFirewallRule SETS the rule's scope to X,
    # it does not filter by current scope. Using it here is the correct way to
    # pull these rules OUT of the Public profile.
    Set-NetFirewallRule -DisplayGroup "File and Printer Sharing" -Profile Domain,Private -Enabled True -ErrorAction SilentlyContinue
    Set-NetFirewallRule -DisplayGroup "Network Discovery"        -Profile Domain,Private -Enabled True -ErrorAction SilentlyContinue
    # NOTE: LAN sharing still survives "Public/Unidentified" (router dead) via the
    #       narrow LocalSubnet-only allow-rules created below (Profile Any, LAN only).

    # disable BLOCK rules that stop sharing/discovery
    Get-NetFirewallRule -Direction Inbound -Action Block -Enabled True -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayGroup -in @("File and Printer Sharing","Network Discovery") } |
        ForEach-Object { Disable-NetFirewallRule -Name $_.Name -ErrorAction SilentlyContinue }

    # disable BLOCK rules (either direction) on SMB/NetBIOS AND printer ports --
    # covers block-rules created by GPO/antivirus/other tools that would otherwise
    # override our allow-rules below (Windows Firewall: an explicit Block always
    # wins over an Allow for the same traffic).
    $criticalTcp = '445','139','9100','515','631'   # SMB, NetBIOS, RAW/JetDirect, LPR, IPP printing
    $criticalUdp = '137','138','161'                 # NetBIOS, SNMP (printer status)
    foreach ($r in (Get-NetFirewallRule -Action Block -Enabled True -ErrorAction SilentlyContinue)) {
        $pf = $r | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
        if (-not $pf) { continue }
        $hit = ($pf.LocalPort + $pf.RemotePort) | Where-Object {
            ($pf.Protocol -eq 'TCP' -and $criticalTcp -contains $_) -or
            ($pf.Protocol -eq 'UDP' -and $criticalUdp -contains $_)
        }
        if ($hit) { Disable-NetFirewallRule -Name $r.Name -ErrorAction SilentlyContinue }
    }

    # Explicit ALLOW rules for LAN subnet only (in + out) -- file sharing + printing.
    # Direction matters for which port field to use:
    #   Inbound  -> "LocalPort"  (the port on THIS pc being connected to)
    #   Outbound -> "RemotePort" (the destination port we are connecting to, e.g.
    #                the printer's 9100) -- the local/source port is always random,
    #                so using LocalPort on an outbound rule would never match real traffic.
    $allow = @(
        @{ N="OfficeTool-SMB-In";     D="Inbound";  P="TCP"; Port=@(445)          },
        @{ N="OfficeTool-NB-In";      D="Inbound";  P="TCP"; Port=@(139)          },
        @{ N="OfficeTool-NBu-In";     D="Inbound";  P="UDP"; Port=@(137,138)      },
        @{ N="OfficeTool-SMB-Out";    D="Outbound"; P="TCP"; Port=@(445)          },
        @{ N="OfficeTool-NB-Out";     D="Outbound"; P="TCP"; Port=@(139)          },
        @{ N="OfficeTool-NBu-Out";    D="Outbound"; P="UDP"; Port=@(137,138)      },
        @{ N="OfficeTool-Print-Out";  D="Outbound"; P="TCP"; Port=@(9100,515,631) },  # PC -> printer: RAW/JetDirect, LPR, IPP
        @{ N="OfficeTool-Print-In";   D="Inbound";  P="TCP"; Port=@(9100,515,631) },  # in case this PC hosts/shares the printer
        @{ N="OfficeTool-SNMP-Out";   D="Outbound"; P="UDP"; Port=@(161)          },  # PC -> printer: status queries
        @{ N="OfficeTool-SNMP-In";    D="Inbound";  P="UDP"; Port=@(161,162)      },  # status replies / traps
        @{ N="OfficeTool-WinRM-In";   D="Inbound";  P="TCP"; Port=@(5985)         }   # remote fleet health-check (Option 12)
    )
    foreach ($a in $allow) {
        Remove-NetFirewallRule -Name $a.N -ErrorAction SilentlyContinue
        if ($a.D -eq 'Outbound') {
            New-NetFirewallRule -Name $a.N -DisplayName $a.N -Direction $a.D -Action Allow `
                -Protocol $a.P -RemotePort $a.Port -Profile Any -RemoteAddress LocalSubnet -ErrorAction SilentlyContinue | Out-Null
        } else {
            New-NetFirewallRule -Name $a.N -DisplayName $a.N -Direction $a.D -Action Allow `
                -Protocol $a.P -LocalPort $a.Port -Profile Any -RemoteAddress LocalSubnet -ErrorAction SilentlyContinue | Out-Null
        }
    }
    # ping (ICMP echo) inbound allow -- local subnet
    Remove-NetFirewallRule -Name "OfficeTool-Ping-In" -ErrorAction SilentlyContinue
    New-NetFirewallRule -Name "OfficeTool-Ping-In" -DisplayName "OfficeTool-Ping-In" -Direction Inbound -Action Allow `
        -Protocol ICMPv4 -IcmpType 8 -Profile Any -RemoteAddress LocalSubnet -ErrorAction SilentlyContinue | Out-Null
    Write-Ok "Printer ports (9100/515/631 print, 161/162 SNMP) explicitly allowed, LAN-only."

    # Password-protected sharing ON (blocks anonymous/Guest access to shares).
    # "ForceGuest = 0" = Classic model: a real matching username+password is required.
    # Our drive mappings always supply valid $AdminUser credentials, so this does not
    # break anything -- it only blocks devices that connect without any credentials.
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'ForceGuest' -Value 0 -Type DWord -ErrorAction SilentlyContinue
    Disable-LocalUser -Name 'Guest' -ErrorAction SilentlyContinue
    Write-Ok "Password-protected sharing ON (anonymous/Guest access blocked; needs a restart to fully apply)."
}


# ---- REMOTING helper (enables Option 12 : Remote Fleet Check) ----
# PowerShell Remoting (WinRM) is built into Windows -- nothing to install.
# We enable it here (same places Repair-Firewall is called) so a plain
# re-run of Setup/Harden/Set-IP-by-Name on every PC is all that's needed;
# no extra manual step. TrustedHosts is scoped to this office's own
# subnet only (not "*"), matching the LocalSubnet-only philosophy used
# everywhere else in this tool.
function Enable-Remoting {
    try {
        Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction Stop | Out-Null
        Set-Item WSMan:\localhost\Client\TrustedHosts -Value "$(Get-MySeries).*" -Force -ErrorAction SilentlyContinue
        Restart-Service WinRM -ErrorAction SilentlyContinue
        Write-Ok "Remote fleet check (WinRM) enabled -- Option 12 can now query this PC."
    } catch { Write-Warn "Remoting setup: $($_.Exception.Message)" }
}


# =====================  OPTION 2 : SETUP  ===========================
function Invoke-Setup {
    Write-Section "SETUP  -  create share/user and map drives"
    Set-ShareAndUser

    # firewall + profile + linked connections
    Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object {
        Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private -ErrorAction SilentlyContinue
    }
    Repair-Firewall
    Enable-Remoting
    reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableLinkedConnections /t REG_DWORD /d 1 /f | Out-Null
    Write-Ok "Firewall + Private profile + linked-connections set."

    # map drives (on current series)
    $me = $Pcs | Where-Object { $_.Host -ieq $env:COMPUTERNAME } | Select-Object -First 1
    if (-not $me) { Write-Warn "This PC's name ($env:COMPUTERNAME) is not in the list -- Inbox will use detected IP." }
    Set-AllDrives (Get-MySeries)
    Write-Info "If drives don't show, restart the PC once."
}


# =====================  OPTION 9 : MAP DRIVES ONLY  =================
function Invoke-MapDrivesOnly {
    Write-Section "MAP DRIVES  -  only re-map drives (2nd pass)"
    Write-Info "How it works: does NOT touch IP/user/share -- just connects Inbox + other drives."
    Write-Info "Use this after every PC has been prepared once (so all have the '$AdminUser' account)."
    Set-AllDrives (Get-MySeries)
    Write-Info "Drives that failed before will connect once that PC is ready."
}


# ===============  OPTION 3 : NETWORK HARDENING  =====================
function Optimize-Network {
    Write-Section "HARDEN  -  router-proof connection (LAN always priority)"

    # LAN priority, Wi-Fi secondary (physical adapters only)
    foreach ($ad in Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }) {
        $isWifi = ($ad.PhysicalMediaType -match '802\.11') -or ($ad.InterfaceDescription -match 'Wi-?Fi|Wireless')
        $metric = if ($isWifi) { 50 } else { 10 }
        Set-NetIPInterface -InterfaceIndex $ad.ifIndex -InterfaceMetric $metric -ErrorAction SilentlyContinue
        Write-Ok ("{0,-26} metric {1}  ({2})" -f $ad.Name, $metric, ($(if($isWifi){'Wi-Fi'}else{'LAN'})))
    }

    # NIC power-saving OFF
    foreach ($ad in Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }) {
        try {
            $pm = Get-NetAdapterPowerManagement -Name $ad.Name -ErrorAction Stop
            $pm.AllowComputerToTurnOffDevice = 'Disabled'
            Set-NetAdapterPowerManagement -InputObject $pm -ErrorAction SilentlyContinue
        } catch {}
    }
    Write-Ok "Network card power-saving disabled."

    # profile Private + firewall (all profiles)
    Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object {
        Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private -ErrorAction SilentlyContinue
    }
    Repair-Firewall
    Enable-Remoting
    Write-Ok "Firewall: sharing+printer ON for Private (Public stays OFF), LAN-only allow-rules (in+out), ping ON."

    # NetBIOS over TCP/IP ON (via registry -- reliable on every Windows)
    $nbBase = "HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces"
    Get-ChildItem $nbBase -ErrorAction SilentlyContinue | ForEach-Object {
        Set-ItemProperty -Path $_.PSPath -Name NetbiosOptions -Value 1 -Type DWord -ErrorAction SilentlyContinue
    }
    Write-Ok "NetBIOS over TCP/IP enabled."

    # required services Automatic + Start
    foreach ($s in "LanmanServer","LanmanWorkstation","FDResPub","fdPHost","SSDPSRV","upnphost","Spooler") {
        Set-Service -Name $s -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service -Name $s -ErrorAction SilentlyContinue
    }
    Write-Ok "Sharing / Discovery / Print services Automatic + running."

    # linked connections
    reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableLinkedConnections /t REG_DWORD /d 1 /f | Out-Null
    Write-Ok "Mapped drives visible in both elevated + normal sessions."

    Write-Host ""
    Write-Ok "HARDENING complete -- switch on + LAN connected = stays connected even if router dies."
    Write-Info "Restart once for metric/linked-connections to fully apply."
}


# ===============  OPTION 4 : IP SERIES (fully manual)  ==============
function Set-IPSeries {
    Write-Section "IP SERIES  -  enter series + last number manually"
    Write-Info "How it works: you type both the series and last number; that IP is applied."

    $adapter = Get-LanAdapter
    if (-not $adapter) { Write-Fail "No active LAN adapter found."; return }

    $curIp   = Get-MyLanIP
    $defLast = if ($curIp) { $curIp.Split('.')[-1] } else { $null }
    Write-Info ("Adapter    : {0}" -f $adapter.Name)
    Write-Info ("Current IP : {0}" -f ($(if ($curIp) { $curIp } else { '(no static IP)' })))
    Write-Host ""

    $series = Read-Series
    $prompt = if ($defLast) { "     Last number (Enter = keep $defLast)" } else { "     Last number (e.g. 240)" }
    $inLast = (Read-Host $prompt).Trim()
    $lastOctet = if ($inLast) { $inLast } elseif ($defLast) { $defLast } else { $null }
    if (-not $lastOctet -or $lastOctet -notmatch '^\d+$' -or [int]$lastOctet -lt 1 -or [int]$lastOctet -gt 254) {
        Write-Fail "Invalid last number (1-254). Stopped."; return
    }

    Write-Host ""
    Write-Info "Will set:  IP $series.$lastOctet   Gateway $series.1   Mask 255.255.255.0"
    Write-Host ""
    if (-not (Read-Yes "Apply?")) { Write-Info "Cancelled."; return }

    $ip = Set-StaticIP $adapter $series $lastOctet
    Write-Host ""
    Write-Ok "New IP = $ip , Gateway = $series.1"
}


# ===============  OPTION 5 : AUTO IP (keep current octet)  =========
function Update-IPSeriesAuto {
    Write-Section "AUTO IP  -  auto series, keep current last number"
    Write-Info "How it works: detects series from router, keeps this PC's CURRENT last number,"
    Write-Info "              sets the new IP, then re-maps all drives. (Use when octet is already right.)"

    $adapter = Get-LanAdapter
    if (-not $adapter) { Write-Fail "No active LAN adapter found."; return }
    $oldIp = Get-MyLanIP
    if (-not $oldIp) { Write-Fail "This PC has no IP -- run IP SERIES (4) or SET IP BY NAME (8) first."; return }
    $octet = $oldIp.Split('.')[-1]
    Write-Info ("Current IP: {0}  (keeping last number {1})" -f $oldIp, $octet)

    $series = Find-RouterSeries $adapter
    if (-not $series) { Write-Fail "Could not detect series (DHCP off / router dead?). Old IP restored."; return }

    $ip = Set-StaticIP $adapter $series $octet
    Write-Ok "New IP set: $ip , Gateway $series.1"
    Set-AllDrives $series
    Write-Host ""
    Write-Ok "Everything moved to the new series ($series.x)."
}


# ===============  OPTION 6 : HOTSPOT INTERNET  ======================
function Enable-HotspotInternet {
    Write-Section "HOTSPOT NET  -  router dead? sharing stays on, internet via hotspot"
    Write-Info "How it works: removes the LAN dead gateway (keeps IP/mask). Sharing keeps working;"
    Write-Info "              internet comes from a mobile hotspot (Wi-Fi)."

    $lan = Get-LanAdapter
    if (-not $lan) { Write-Fail "No active LAN adapter found."; return }
    $ipAddr = Get-MyLanIP
    if (-not $ipAddr) { Write-Fail "No LAN IP found. Set a static IP first (Option 4/8)."; return }

    Write-Info "LAN adapter: $($lan.Name)   IP: $ipAddr"
    Write-Host ""
    if (-not (Read-Yes "Remove LAN gateway and use hotspot for internet?")) { Write-Info "Cancelled."; return }

    Remove-NetRoute -InterfaceIndex $lan.ifIndex -DestinationPrefix '0.0.0.0/0' -Confirm:$false -ErrorAction SilentlyContinue
    netsh interface ip set address "name=$($lan.Name)" static $ipAddr 255.255.255.0 | Out-Null
    ipconfig /flushdns | Out-Null

    Write-Host ""
    Write-Ok "LAN gateway removed -- internet will now use Wi-Fi/hotspot."
    Write-Ok "LAN sharing ($ipAddr) still works -- PCs keep talking to each other."
    Write-Info "Now connect a mobile HOTSPOT via Wi-Fi. When router returns, run AUTO IP (5) or SET IP BY NAME (8)."
}


# ===============  OPTION 7 : HEALTH CHECK (diagnose + fix)  ==========
function Invoke-Diagnose {
    Write-Section "HEALTH CHECK  -  diagnose + auto-fix"
    $fixed  = 0
    $manual = New-Object System.Collections.ArrayList
    $me     = $Pcs | Where-Object { $_.Host -ieq $env:COMPUTERNAME } | Select-Object -First 1

    # 1) Adapter & Cable
    Write-Host "`n   [ 1. Adapter & Cable ]" -ForegroundColor White
    $wired = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.PhysicalMediaType -match '802\.3' }
    if (-not $wired) {
        Write-Fail "No wired LAN adapter found."
        [void]$manual.Add("Check wired LAN adapter/driver (Device Manager).")
    } else {
        foreach ($w in $wired) {
            if     ($w.Status -eq 'Disabled')     { Enable-NetAdapter -Name $w.Name -Confirm:$false -ErrorAction SilentlyContinue; Write-Ok "LAN '$($w.Name)' was disabled -> enabled."; $fixed++ }
            elseif ($w.Status -eq 'Disconnected') { Write-Fail "LAN '$($w.Name)': cable NOT connected (Disconnected)."; [void]$manual.Add("Check LAN cable/switch -- '$($w.Name)' disconnected.") }
            else                                   { Write-Ok "LAN '$($w.Name)' connected and active." }
        }
    }
    $lan = Get-LanAdapter

    # 2) PC name in list?
    Write-Host "`n   [ 2. PC Name ]" -ForegroundColor White
    if ($me) { Write-Ok "Name '$env:COMPUTERNAME' is in the list (last number = $($me.Octet), '$($me.Label)')." }
    else     { Write-Warn "Name '$env:COMPUTERNAME' is NOT in the list."; [void]$manual.Add("This PC's name does not match the list -- fix the name or add it to config.") }

    # 3) IP config
    Write-Host "`n   [ 3. IP Address ]" -ForegroundColor White
    $ipObj = $null
    if ($lan) {
        $ipObj = Get-NetIPAddress -InterfaceIndex $lan.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                 Where-Object { $_.IPAddress -ne '127.0.0.1' } | Select-Object -First 1
    }
    if (-not $ipObj -or $ipObj.IPAddress -like '169.254.*') {
        Write-Fail "No static IP (APIPA / none)."
        [void]$manual.Add("Set an IP using SET IP BY NAME (8).")
    } else {
        $ip = $ipObj.IPAddress
        if ($ipObj.AddressState -eq 'Duplicate') {
            Write-Fail "IP CONFLICT: $ip is also used by another device."
            [void]$manual.Add("IP conflict ($ip) -- re-run SET IP BY NAME (8) or change the number.")
        } else { Write-Ok "IP: $ip (no conflict)." }
        if ($ipObj.PrefixLength -ne 24) {
            $gw = ((Get-NetIPConfiguration -InterfaceIndex $lan.ifIndex).IPv4DefaultGateway | Select-Object -First 1).NextHop
            if ($gw) { netsh interface ip set address "name=$($lan.Name)" static $ip 255.255.255.0 $gw 1 | Out-Null }
            else     { netsh interface ip set address "name=$($lan.Name)" static $ip 255.255.255.0        | Out-Null }
            Write-Ok "Subnet mask was wrong (/$($ipObj.PrefixLength)) -> set to 255.255.255.0."; $fixed++
        } else { Write-Ok "Subnet mask correct (255.255.255.0)." }
        if ($me -and ($ip.Split('.')[-1] -ne "$($me.Octet)")) {
            Write-Warn "Last number ($($ip.Split('.')[-1])) differs from name-based value ($($me.Octet))."
            [void]$manual.Add("IP does not match the name -- run SET IP BY NAME (8).")
        } elseif ($me) { Write-Ok "Last number matches the name ($($me.Octet))." }
    }

    # 4) Gateway
    Write-Host "`n   [ 4. Gateway ]" -ForegroundColor White
    if ($lan) {
        $gw = ((Get-NetIPConfiguration -InterfaceIndex $lan.ifIndex).IPv4DefaultGateway | Select-Object -First 1).NextHop
        if ($gw) {
            if (Test-Connection -ComputerName $gw -Count 1 -Quiet -ErrorAction SilentlyContinue) { Write-Ok "Gateway $gw reachable (internet path OK)." }
            else { Write-Warn "Gateway $gw not reachable (router dead?)." ; [void]$manual.Add("Need internet? run HOTSPOT NET (6). LAN sharing still works.") }
        } else { Write-Info "No gateway set (LAN-only mode -- fine for sharing)." }
    }

    # 5) WiFi/LAN clash (two-doors)
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
        Write-Warn "Wi-Fi is on the same series as LAN (two-doors problem) -- metric fix applied below."
        [void]$manual.Add("Disconnect this PC from OFFICE Wi-Fi -- keep only LAN cable (mobile hotspot is fine).")
    } else { Write-Ok "No WiFi/LAN series clash." }

    # 6) Workgroup
    Write-Host "`n   [ 6. Workgroup ]" -ForegroundColor White
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($cs.PartOfDomain) { Write-Ok "Domain-joined ($($cs.Domain)) -- workgroup skipped." }
    elseif ($cs.Workgroup -ne $Workgroup) {
        try { Add-Computer -WorkgroupName $Workgroup -Force -ErrorAction Stop
              Write-Ok "Workgroup '$($cs.Workgroup)' -> '$Workgroup' changed."; $fixed++
              [void]$manual.Add("Workgroup changed -- restart the PC once.") }
        catch { Write-Warn "Workgroup not set: $($_.Exception.Message)" }
    } else { Write-Ok "Workgroup correct ($Workgroup)." }

    # 7) SMB & Share
    Write-Host "`n   [ 7. SMB & Share ]" -ForegroundColor White
    $smb = Get-SmbServerConfiguration -ErrorAction SilentlyContinue
    if ($smb -and -not $smb.EnableSMB2Protocol) { Set-SmbServerConfiguration -EnableSMB2Protocol $true -Force -ErrorAction SilentlyContinue; Write-Ok "SMB2 was off -> enabled."; $fixed++ }
    else { Write-Ok "SMB protocol OK." }
    if (Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue) { Write-Ok "Share '$ShareName' exists." }
    else { Write-Warn "Share '$ShareName' missing."; [void]$manual.Add("Run SETUP (2) to create the shared folder.") }

    # 8) Firewall (file sharing + printer ports)
    Write-Host "`n   [ 8. Firewall ]" -ForegroundColor White
    $critTcp = '445','139','9100','515','631'
    $critUdp = '137','138','161','162'
    $blocks = 0
    foreach ($r in (Get-NetFirewallRule -Action Block -Enabled True -ErrorAction SilentlyContinue)) {
        $pf = $r | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
        if (-not $pf) { continue }
        $hit = ($pf.LocalPort + $pf.RemotePort) | Where-Object {
            ($pf.Protocol -eq 'TCP' -and $critTcp -contains $_) -or
            ($pf.Protocol -eq 'UDP' -and $critUdp -contains $_)
        }
        if ($hit -or $r.DisplayGroup -in @("File and Printer Sharing","Network Discovery")) { $blocks++ }
    }
    Repair-Firewall
    if ($blocks -gt 0) { Write-Ok "Firewall: removed $blocks block-rules (sharing + printer ports)."; $fixed++ }
    else               { Write-Ok "Firewall: sharing + printer allow-rules (in+out) set, ping ON." }
    $av = Get-CimInstance -Namespace root\SecurityCenter2 -ClassName FirewallProduct -ErrorAction SilentlyContinue |
          Where-Object { $_.displayName -notmatch 'Windows' }
    if ($av) {
        foreach ($p in $av) { Write-Warn "Third-party firewall found: $($p.displayName)" }
        [void]$manual.Add("Allow LAN/file-sharing in the third-party firewall/AV ($(( $av.displayName ) -join ', ')).")
    } else { Write-Ok "No third-party firewall (Windows Firewall only)." }

    # 9) Router-proof standard fixes
    Write-Host "`n   [ 9. Applying router-proof settings ]" -ForegroundColor White
    Optimize-Network | Out-Null
    $fixed += 7

    # cache flush
    ipconfig /flushdns              | Out-Null
    nbtstat -R 2>$null              | Out-Null
    netsh interface ip delete arpcache | Out-Null
    Write-Ok "DNS / NetBIOS / ARP cache flushed."

    # 10) Connectivity to other PCs
    Write-Host "`n   [ 10. Connection to other PCs ]" -ForegroundColor White
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
    Write-Ok "$fixed items auto-fixed / set."
    if ($manual.Count -gt 0) {
        Write-Host ""
        Write-Warn "NEEDS ATTENTION (do these by hand):"
        foreach ($m in $manual) { Write-Host "        - $m" -ForegroundColor Yellow }
    } else { Write-Ok "Nothing manual left -- all good!" }
    Restart-Shell
}


# ===============  OPTION 8 : SET IP BY NAME  ========================
function Set-IPByName {
    Write-Section "SET IP BY NAME  -  name-based IP + full per-PC setup"
    Write-Info "How it works: reads this PC's NAME ($env:COMPUTERNAME) from the list -> takes its last number."
    Write-Info "              Series is auto-detected or you enter it -> sets IP -> maps all drives."

    $me = $Pcs | Where-Object { $_.Host -ieq $env:COMPUTERNAME } | Select-Object -First 1
    if (-not $me) {
        Write-Fail "This PC's name '$env:COMPUTERNAME' is not in the list."
        Write-Info "Rename the PC (e.g. CCL-PC7) or add it to the config list."
        return
    }
    Write-Ok "Name '$($me.Host)' -> last number $($me.Octet) ('$($me.Label)')."

    $adapter = Get-LanAdapter
    if (-not $adapter) { Write-Fail "No active LAN adapter found."; return }

    # series mode
    Write-Host ""
    Write-Host "     1) AUTO-detect series (from router)" -ForegroundColor Gray
    Write-Host "     2) I will type the series" -ForegroundColor Gray
    do { $m = (Read-Host "     Choose (1 or 2)").Trim() } while ($m -notin @('1','2'))

    # 1) user + folder + share (full per-PC setup)
    Write-Host ""
    Set-ShareAndUser

    # 2) firewall + profile + linked connections
    Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object {
        Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private -ErrorAction SilentlyContinue
    }
    Repair-Firewall
    Enable-Remoting
    reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableLinkedConnections /t REG_DWORD /d 1 /f | Out-Null
    Write-Ok "Firewall + Private profile + linked-connections set."

    # 3) resolve series + set IP
    $series = $null
    if ($m -eq '1') {
        $series = Find-RouterSeries $adapter
        if (-not $series) {
            Write-Warn "Could not detect series (router dead / DHCP off)."
            if (Read-Yes "Type the series manually?") { $series = Read-Series } else { Write-Info "Cancelled."; return }
        } else { Write-Ok "Router series detected: $series.x" }
    } else {
        $series = Read-Series
    }
    $ip = Set-StaticIP $adapter $series $($me.Octet)
    Write-Ok "IP set: $ip , Gateway $series.1 , DNS $series.1"

    # 4) drives
    Set-AllDrives $series
    Write-Host ""
    Write-Ok "$($me.Host) fully ready -- user + share + IP ($ip) + drives set."
    Write-Info "Run this SET IP BY NAME (8) on every PC -- each one configures itself by its name."
}


# ===============  OPTION 10 : ACCOUNT MANAGER  ======================
# Accounts that must never be deleted
# (includes $AdminUser -- deleting it would break ALL cross-PC drive sharing)
function Get-ProtectedNames {
    return @($env:USERNAME, $AdminUser, 'Administrator', 'Guest', 'DefaultAccount', 'WDAGUtilityAccount', 'defaultuser0')
}

# Is a given local user an Administrator?
function Test-IsAdminUser ($name) {
    return [bool](Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -like "*\$name" -or $_.Name -eq $name })
}

# Create a local account (admin / standard / guest)
function New-Account {
    Write-Host ""
    $name = (Read-Host "     New username").Trim()
    if (-not $name) { Write-Fail "Name cannot be empty."; return }
    if (Get-LocalUser -Name $name -ErrorAction SilentlyContinue) { Write-Warn "'$name' already exists."; return }

    Write-Host "     1) Administrator    2) Standard user    3) Guest (limited)" -ForegroundColor Gray
    do { $t = (Read-Host "     Account type (1/2/3)").Trim() } while ($t -notin @('1','2','3'))

    $pw = Read-Host "     Password (leave empty = no password)"
    try {
        if ([string]::IsNullOrEmpty($pw)) {
            New-LocalUser -Name $name -NoPassword -ErrorAction Stop | Out-Null
        } else {
            $sec = ConvertTo-SecureString $pw -AsPlainText -Force
            New-LocalUser -Name $name -Password $sec -PasswordNeverExpires -ErrorAction Stop | Out-Null
        }
        $group = switch ($t) { '1' { 'Administrators' } '2' { 'Users' } '3' { 'Guests' } }
        Add-LocalGroupMember -Group $group -Member $name -ErrorAction SilentlyContinue
        Write-Ok "'$name' created ($group)."
    } catch { Write-Fail "Could not create: $($_.Exception.Message)" }
}

# List all local accounts (type + status)
function Show-Accounts {
    Write-Host ""
    Write-Host ("     {0,-26}{1,-12}{2}" -f "USERNAME","TYPE","STATUS") -ForegroundColor DarkGray
    foreach ($u in (Get-LocalUser | Sort-Object Name)) {
        $type = if (Test-IsAdminUser $u.Name) { 'Admin' } else { 'Standard' }
        $en   = if ($u.Enabled) { 'Enabled' } else { 'Disabled' }
        Write-Host ("     {0,-26}{1,-12}{2}" -f $u.Name, $type, $en) -ForegroundColor Gray
    }
}

# Delete one or more accounts (multi-select, protected ones locked)
function Remove-Accounts {
    $users     = Get-LocalUser | Sort-Object Name
    $protected = Get-ProtectedNames
    Write-Host ""
    Write-Host ("     {0,-6}{1,-26}{2,-12}{3}" -f "#","USERNAME","TYPE","STATUS") -ForegroundColor DarkGray
    $i = 1; $map = @{}
    foreach ($u in $users) {
        $prot = $protected -contains $u.Name
        $type = if (Test-IsAdminUser $u.Name) { 'Admin' } else { 'Standard' }
        $en   = if ($u.Enabled) { 'Enabled' } else { 'Disabled' }
        $tag  = if ($prot) { '[--]' } else { "[$i]" }
        $col  = if ($prot) { 'DarkGray' } else { 'Gray' }
        if (-not $prot) { $map[$i] = $u.Name; $i++ }
        Write-Host ("     {0,-6}{1,-26}{2,-12}{3}" -f $tag, $u.Name, $type, $en) -ForegroundColor $col
    }
    Write-Host "     ([--] = protected, cannot delete)" -ForegroundColor DarkGray

    if ($map.Count -eq 0) { Write-Warn "No deletable accounts."; return }
    Write-Host ""
    $sel = (Read-Host "     Numbers to delete (e.g. 1,3,5)").Trim()
    if (-not $sel) { Write-Info "Cancelled."; return }
    $picks = $sel -split '[, ]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
    $toDel = @(); foreach ($n in $picks) { if ($map.ContainsKey($n)) { $toDel += $map[$n] } }
    if (-not $toDel) { Write-Warn "No valid number selected."; return }

    Write-Host ""
    Write-Warn ("Will delete: " + ($toDel -join ', '))
    if (-not (Read-Yes "Delete for sure?")) { Write-Info "Cancelled."; return }
    foreach ($n in $toDel) {
        try { Remove-LocalUser -Name $n -ErrorAction Stop; Write-Ok "'$n' deleted." }
        catch { Write-Fail "'$n' not deleted: $($_.Exception.Message)" }
    }
}

# Account manager sub-menu
function Invoke-AccountManager {
    do {
        Write-Section "ACCOUNT MANAGER  -  create / delete local accounts"
        Write-Host "     [1]  Create account" -ForegroundColor Gray
        Write-Host "     [2]  Delete account(s)" -ForegroundColor Gray
        Write-Host "     [3]  List all accounts" -ForegroundColor Gray
        Write-Host "     [0]  Back" -ForegroundColor DarkGray
        $c = (Read-Host "     Choose (0-3)").Trim()
        switch ($c) {
            '1' { New-Account }
            '2' { Remove-Accounts }
            '3' { Show-Accounts }
            '0' { }
            default { Write-Warn "Wrong option." }
        }
        if ($c -ne '0') { Write-Host ""; Read-Host "     Enter -> account menu" | Out-Null }
    } while ($c -ne '0')
}


# ===============  OPTION 11 : WIN7 <-> WIN11 PRINTER FIX  ============
# Standalone (not tied to $Pcs / $AdminUser) -- this fixes the HOST side
# only. The Windows 7 CLIENT side must use a separate offline .ps1 file
# (Windows 7 lacks the newer NetAdapter/NetFirewall/SmbShare cmdlets this
# tool relies on elsewhere, and often can't reach GitHub over TLS 1.2).

function Repair-PrintSpooler {
    Write-Info "Restarting Print Spooler..."
    Stop-Service -Name Spooler -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Get-ChildItem "$env:WINDIR\System32\spool\PRINTERS" -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Start-Service -Name Spooler -ErrorAction SilentlyContinue
    Write-Ok "Print Spooler restarted, stuck jobs cleared."
}

function Invoke-Win11PrinterHostFix {
    Write-Section "PRINTER FIX  -  Windows 11 HOST (this PC shares the printer)"

    # 1) SMB signing off -- fixes "specified network name is no longer available"
    foreach ($p in "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters",
                   "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters") {
        New-ItemProperty -Path $p -Name RequireSecuritySignature -PropertyType DWord -Value 0 -Force -ErrorAction SilentlyContinue | Out-Null
        New-ItemProperty -Path $p -Name EnableSecuritySignature  -PropertyType DWord -Value 0 -Force -ErrorAction SilentlyContinue | Out-Null
    }
    Write-Ok "SMB signing requirement disabled (server + client)."

    # 2) NTLM compatibility -- let older Windows 7 auth negotiate successfully
    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name LmCompatibilityLevel -PropertyType DWord -Value 1 -Force -ErrorAction SilentlyContinue | Out-Null
    Write-Ok "NTLM compatibility relaxed (accepts NTLMv1/v2 from old clients)."

    # 3) Point-and-Print driver install restriction removed (PrintNightmare-era
    #    patch causes error 0x0000011b when a non-admin client fetches a driver)
    $pp = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint"
    if (-not (Test-Path $pp)) { New-Item -Path $pp -Force | Out-Null }
    New-ItemProperty -Path $pp -Name RestrictDriverInstallationToAdministrators -PropertyType DWord -Value 0 -Force -ErrorAction SilentlyContinue | Out-Null
    New-ItemProperty -Path $pp -Name NoWarningNoElevationOnInstall              -PropertyType DWord -Value 1 -Force -ErrorAction SilentlyContinue | Out-Null
    New-ItemProperty -Path $pp -Name NoWarningNoElevationOnUpdate               -PropertyType DWord -Value 1 -Force -ErrorAction SilentlyContinue | Out-Null
    Write-Ok "Point-and-Print driver install/update restriction removed."

    # 4) SMB 1.0/CIFS -- some Windows 7 setups still need this to browse/negotiate
    try {
        Enable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -All -NoRestart -ErrorAction Stop | Out-Null
        Write-Ok "SMB 1.0/CIFS support enabled (for legacy Windows 7 client)."
    } catch {
        Write-Warn "Could not auto-enable SMB1 -- turn it on manually via 'Turn Windows features on or off'."
    }

    # 5) Sharing / discovery / firewall (reuses the tool's existing hardening)
    Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object {
        Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private -ErrorAction SilentlyContinue
    }
    Repair-Firewall
    Write-Ok "Sharing + firewall (SMB, printer ports) opened for the LAN."

    # 6) Services
    foreach ($s in "LanmanServer","LanmanWorkstation","Spooler") {
        Set-Service -Name $s -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service -Name $s -ErrorAction SilentlyContinue
    }
    Repair-PrintSpooler

    # 7) Optional Guest access -- ONLY affects this standalone printer-host PC,
    #    unrelated to this tool's own $AdminUser-based office setup elsewhere.
    Write-Host ""
    if (Read-Yes "Also allow Guest/anonymous access (simplest for old Win7, less secure)?") {
        New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name ForceGuest -PropertyType DWord -Value 1 -Force -ErrorAction SilentlyContinue | Out-Null
        Enable-LocalUser -Name 'Guest' -ErrorAction SilentlyContinue
        Write-Ok "Guest network access enabled -- Windows 7 can connect without a matching password."
        Write-Info "Also check the PRINTER's own Sharing tab -> make sure it's shared to 'Everyone', not a specific user."
    } else {
        New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name ForceGuest -PropertyType DWord -Value 0 -Force -ErrorAction SilentlyContinue | Out-Null
        Write-Ok "Guest access left OFF -- Windows 7 must log in with a real matching account+password."
    }

    Write-Host ""
    Write-Ok "Windows 11 host ready. RESTART this PC now for everything to fully apply."
    Write-Info "Then on the Windows 7 PC, run the separate 'Win7-PrinterFix.ps1' file (fully offline)."
}

function Invoke-PrinterFix {
    Write-Section "PRINTER FIX  -  Windows 7 <-> Windows 11 printer sharing"
    Write-Host "     [1]  Fix THIS PC as the Windows 11 host (sharing the printer)" -ForegroundColor Gray
    Write-Host "     [2]  Windows 7 client instructions (separate offline file)"    -ForegroundColor Gray
    Write-Host "     [0]  Back" -ForegroundColor DarkGray
    $c = (Read-Host "     Choose (0-2)").Trim()
    switch ($c) {
        '1' { Invoke-Win11PrinterHostFix }
        '2' {
            Write-Host ""
            Write-Info "On the WINDOWS 7 PC: copy 'Win7-PrinterFix.ps1' to it (USB/network share)."
            Write-Info "It runs fully OFFLINE -- no internet or GitHub download needed on Windows 7."
            Write-Info "Run as Administrator: powershell -ExecutionPolicy Bypass -File 'C:\Win7-PrinterFix.ps1'"
        }
        '0' { }
        default { Write-Warn "Wrong option." }
    }
}


# ===============  OPTION 12 : REMOTE FLEET CHECK  ====================
# Pulls a live, READ-ONLY status snapshot from every other PC over
# PowerShell Remoting (WinRM) -- no physical visit needed. Requires that
# PC to have run Setup(2)/Harden(3)/Set-IP-by-Name(8) at least once since
# this update (that's what enables WinRM + opens the firewall port).
# IMPORTANT: only Get-* calls run remotely -- this must never touch a
# stranger's live desktop session (no Restart-Shell, no config changes).
function Get-RemoteHealthSnapshot ($ip, $octet, $cred) {
    try {
        $so = New-PSSessionOption -OperationTimeout 5000
        $r = Invoke-Command -ComputerName $ip -Credential $cred -SessionOption $so -ErrorAction Stop -ScriptBlock {
            param($expectOctet, $shareName)
            $prof = Get-NetConnectionProfile -ErrorAction SilentlyContinue | Select-Object -First 1
            $ipObj = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                     Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' } |
                     Select-Object -First 1
            $gw = ((Get-NetIPConfiguration -ErrorAction SilentlyContinue).IPv4DefaultGateway | Select-Object -First 1).NextHop
            $gwUp = $false
            if ($gw) { $gwUp = Test-Connection -ComputerName $gw -Count 1 -Quiet -ErrorAction SilentlyContinue }
            $pingRule = Get-NetFirewallRule -Name "OfficeTool-Ping-In" -ErrorAction SilentlyContinue
            [pscustomobject]@{
                IP          = $ipObj.IPAddress
                OctetOk     = ($ipObj.IPAddress -and $ipObj.IPAddress.EndsWith(".$expectOctet"))
                Category    = if ($prof) { $prof.NetworkCategory } else { "Unknown" }
                GatewayUp   = $gwUp
                PingRuleOn  = [bool]($pingRule -and $pingRule.Enabled -eq 'True')
                ShareExists = [bool](Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue)
            }
        } -ArgumentList $octet, $ShareName
        return $r
    } catch { return $null }
}

function Invoke-RemoteFleetCheck {
    Write-Section "REMOTE FLEET CHECK  -  live status from every PC, no physical visit needed"
    Write-Info "How it works: uses PowerShell Remoting (WinRM) -- READ-ONLY, does not touch anyone's desktop."
    Write-Info "Needs Setup(2)/Harden(3)/Set-IP-by-Name(8) to have been re-run once on each PC for this to work."
    Write-Host ""

    $cred   = New-Object System.Management.Automation.PSCredential($AdminUser, (ConvertTo-SecureString $AdminPass -AsPlainText -Force))
    $series = Get-MySeries
    $others = $Pcs | Where-Object { $_.Host -ine $env:COMPUTERNAME }

    Write-Host ("     {0,-20} {1,-16} {2,-8} {3,-10} {4,-12} {5,-8} {6,-8} {7}" -f "LABEL","IP","PING","WINRM","CATEGORY","GW-UP","PINGRULE","SHARE") -ForegroundColor DarkGray
    foreach ($pc in $others) {
        $ip = "$series.$($pc.Octet)"
        # Direct ICMP test from THIS PC (the caller) -- this is the actual real-world
        # "can I ping that PC" answer, independent of WinRM/remoting entirely.
        $pingOk  = Test-Connection -ComputerName $ip -Count 1 -Quiet -ErrorAction SilentlyContinue
        $pingCol = if ($pingOk) { 'Green' } else { 'Red' }
        Write-Host ("     {0,-20} {1,-16} " -f $pc.Label, $ip) -NoNewline -ForegroundColor Gray
        Write-Host ("{0,-8}" -f $(if ($pingOk) {"UP"} else {"DOWN"})) -NoNewline -ForegroundColor $pingCol

        if (-not (Test-PortOpen $ip 5985)) {
            Write-Host "unreachable" -ForegroundColor Red
            continue
        }
        $snap = Get-RemoteHealthSnapshot $ip $pc.Octet $cred
        if (-not $snap) {
            Write-Host "auth/RPC FAIL" -ForegroundColor Red
            continue
        }
        $catCol = if ($snap.Category -eq 'Private') { 'Green' } else { 'Yellow' }
        $gwCol  = if ($snap.GatewayUp) { 'Green' } else { 'Yellow' }
        $prCol  = if ($snap.PingRuleOn) { 'Green' } else { 'Red' }
        $shCol  = if ($snap.ShareExists) { 'Green' } else { 'Red' }
        Write-Host ("{0,-10}" -f "OK") -NoNewline -ForegroundColor Green
        Write-Host ("{0,-12}" -f $snap.Category) -NoNewline -ForegroundColor $catCol
        Write-Host ("{0,-8}" -f $(if ($snap.GatewayUp) {"UP"} else {"DOWN"})) -NoNewline -ForegroundColor $gwCol
        Write-Host ("{0,-8}" -f $(if ($snap.PingRuleOn) {"ON"} else {"OFF"})) -NoNewline -ForegroundColor $prCol
        Write-Host ("{0}" -f $(if ($snap.ShareExists) {"OK"} else {"MISSING"})) -ForegroundColor $shCol
    }

    Write-Host ""
    Write-Info "'unreachable' = WinRM port closed (router/switch down, or that PC hasn't re-run Setup/Harden/Set-IP-by-Name since this update)."
    Write-Info "CATEGORY should stay 'Private' even with the router off -- if it shows Public/Identifying, that's why ping/sharing drops."
}


# =========================  MAIN MENU  ==============================
$sep = "  +" + ("-" * 5) + "+" + ("-" * 18) + "+" + ("-" * 40) + "+"
$fmt = "  | {0,3} | {1,-16} | {2,-38} |"
do {
    Write-Banner
    Write-Host ""
    Write-Host "     Admin: $AdminUser    Share: $ShareName    PCs: $($Pcs.Count)    Series: $Series" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host $sep -ForegroundColor DarkCyan
    Write-Host ($fmt -f "No", "Action", "What it does") -ForegroundColor White
    Write-Host $sep -ForegroundColor DarkCyan
    Write-Host ($fmt -f "1",  "Cleanup",        "Remove old mappings, creds, cache")   -ForegroundColor Gray
    Write-Host ($fmt -f "2",  "Setup",          "Create share + user + map drives")    -ForegroundColor Gray
    Write-Host ($fmt -f "3",  "Harden",         "LAN priority + router-proof")         -ForegroundColor Gray
    Write-Host ($fmt -f "4",  "IP Series",      "Enter series + last number manually") -ForegroundColor Gray
    Write-Host ($fmt -f "5",  "Auto IP",        "Auto series, keep current number")    -ForegroundColor Gray
    Write-Host ($fmt -f "6",  "Hotspot Net",    "Internet via hotspot (router dead)")  -ForegroundColor Gray
    Write-Host ($fmt -f "7",  "Health Check",   "Diagnose + auto-fix everything")      -ForegroundColor Gray
    Write-Host ($fmt -f "8",  "Set IP by Name", "Name-based IP + full per-PC setup")   -ForegroundColor Gray
    Write-Host ($fmt -f "9",  "Map Drives",     "Only re-map drives (2nd pass)")       -ForegroundColor Gray
    Write-Host ($fmt -f "10", "Accounts",       "Create / delete local accounts")      -ForegroundColor Gray
    Write-Host ($fmt -f "11", "Printer Fix",    "Win7 <-> Win11 printer sharing fix")  -ForegroundColor Gray
    Write-Host ($fmt -f "12", "Remote Check",   "Live status from all PCs, no visit")  -ForegroundColor Gray
    Write-Host $sep -ForegroundColor DarkCyan
    Write-Host ($fmt -f "0",  "Exit",           "")                                    -ForegroundColor DarkGray
    Write-Host $sep -ForegroundColor DarkCyan
    Write-Host ""
    $choice = (Read-Host "     Choose option (0-12)").Trim()

    switch ($choice) {
        '1'  { Invoke-Cleanup }
        '2'  { Invoke-Setup }
        '3'  { Optimize-Network }
        '4'  { Set-IPSeries }
        '5'  { Update-IPSeriesAuto }
        '6'  { Enable-HotspotInternet }
        '7'  { Invoke-Diagnose }
        '8'  { Set-IPByName }
        '9'  { Invoke-MapDrivesOnly }
        '10' { Invoke-AccountManager }
        '11' { Invoke-PrinterFix }
        '12' { Invoke-RemoteFleetCheck }
        '0'  { Write-Host "`n     Bye!`n" -ForegroundColor Cyan }
        default { Write-Warn "Wrong option. Choose 0 to 12." }
    }

    if ($choice -ne '0') { Write-Host ""; Read-Host "     Press Enter -> back to menu" | Out-Null }

} while ($choice -ne '0')
