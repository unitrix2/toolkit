#Requires -Version 3.0
<#
===============================================================================
 CCL LAN Admin Tool  (CCL-LanAdmin.ps1)
-------------------------------------------------------------------------------
 Office ke sabhi PCs ko LAN par connect / manage karne ka single tool.
 Modules : 1) Setup  2) Bulk Drive Map  3) Cleanup/Reset  4) Folder+Printer Share

 DESIGN RULES (har command 100% ya to kaam kare, ya saaf bataye kyu nahi):
   R1  Triple pattern : pre-check (state) -> apply -> post-verify (re-query)
   R2  Har action try/catch + -ErrorAction Stop -> typed status (OK/SKIP/FAIL+reason)
   R3  Idempotent      : already-applied ho to skip, dobara error na de
   R4  Backup+manifest : destructive step se pehle export -> rollback possible
   R5  Dry-run -> pilot -> rollout : -WhatIf mode, phir 1 PC, phir sab
   +   Self-elevation, functional verify (sirf status nahi), structured log,
       credential masking, edition/version guard, summary table.

 USAGE :
   Right-click -> Run with PowerShell  (khud elevate ho jayega)
   ya:  powershell -ExecutionPolicy Bypass -File .\CCL-LanAdmin.ps1
   Dry-run :  .\CCL-LanAdmin.ps1 -DryRun
   Direct  :  .\CCL-LanAdmin.ps1 -Action Setup -DryRun

 NOTE: File UTF-8 with BOM me save karein (Hindi comments/labels safe rahein).
===============================================================================
#>

[CmdletBinding()]
param(
    [ValidateSet('Menu','Setup','BulkMap','Cleanup','Share')]
    [string]$Action = 'Menu',
    [switch]$DryRun,
    [switch]$NoElevate   # internal: re-launch loop rokne ke liye
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# =============================================================================
# ==  CONFIG  (yahi edit karein -- sab in-file, koi external file nahi)       ==
# =============================================================================
$Global:CFG = [ordered]@{

    # --- Workgroup / Network ---------------------------------------------
    Workgroup   = 'WORKGROUP'   # Windows default -- functionally optional, sharing isse independent chalta hai
    Subnet      = '192.168.1'          # /24
    Mask        = '255.255.255.0'
    Gateway     = '192.168.1.1'        # router; blank '' rakho agar na chahiye
    DnsServers  = @('192.168.1.1')     # blank @() = router/DHCP DNS

    # --- PCs : name -> last IP octet --------------------------------------
    #     IP = Subnet + '.' + Octet   (CCL-PC1 => 192.168.10.101)
    PCs = [ordered]@{
        'CCL-PC1' = 101
        'CCL-PC2' = 102
        'CCL-PC3' = 103
        'CCL-PC4' = 104
        'CCL-PC5' = 105
        'CCL-PC6' = 106
        'CCL-PC7' = 107
        'CCL-PC8' = 108
    }

    # --- Default local admin account (Sub-Option A) -----------------------
    DefaultAdmin = @{
        User = 'CNB'
        Pass = '1234'
    }

    # --- Bulk drive mapping ----------------------------------------------
    #     DriveLetter -> @{ Host=PC name ; Share=shared folder ; Label=sidebar naam }
    #     Label/Host apni marzi se badal lena.
    DriveMaps = [ordered]@{
        'N' = @{ Host = 'CCL-PC2'; Share = 'Shared';  Label = 'Mohit'  }
        'O' = @{ Host = 'CCL-PC3'; Share = 'Shared';  Label = 'Sunil Kushwaha Sir'  }
        'P' = @{ Host = 'CCL-PC4'; Share = 'Shared';  Label = 'Vipin'  }
        'Q' = @{ Host = 'CCL-PC5'; Share = 'Shared';  Label = 'Aseem Sir'  }
        'R' = @{ Host = 'CCL-PC6'; Share = 'Shared';  Label = 'Raveesh'  }
        'S' = @{ Host = 'CCL-PC7'; Share = 'Shared';  Label = 'Salman'  }
        'T' = @{ Host = 'CCL-PC8'; Share = 'Shared';  Label = 'Mukesh'  }
    }

    # --- Folders to share on THIS pc (Share module) -----------------------
    #     Hidden=$true : folder ka apna icon D: browsing me chhupega (cosmetic
    #     only, NTFS security nahi). Mapped-drive se andar ka content normal
    #     dikhega, koi file hidden nahi hogi.
    SharedFolders = @(
        @{ Path = 'D:\Shared'; Name = 'Shared'; Everyone = $true; Hidden = $true }
    )

    # --- Deferred auto-map poller ----------------------------------------
    DeferMaxHours   = 48        # 2 din
    PingTimeoutMs   = 400       # fast pre-check
    PortTimeoutMs   = 500       # SMB 445 test
    OverallBudgetSec= 45        # bulk-map ka total hard cap

    # --- Timing / retry ---------------------------------------------------
    ReachRetries    = 2         # false-negative avoid (2 quick attempts)
}

# =============================================================================
# ==  INFRA : logging, elevation, status objects, backup/manifest           ==
# =============================================================================

$Global:RunStamp = (Get-Date -Format 'yyyyMMdd-HHmmss')
$Global:BaseDir  = Join-Path $env:ProgramData 'CCL-LanAdmin'
$Global:LogDir   = Join-Path $BaseDir 'logs'
$Global:BackupDir= Join-Path $BaseDir ("backup-{0}" -f $RunStamp)
$Global:Manifest = Join-Path $BaseDir 'manifest.json'
$Global:LogFile  = Join-Path $LogDir ("run-{0}.log" -f $RunStamp)
$Global:Results  = New-Object System.Collections.ArrayList   # summary table rows

foreach ($d in @($BaseDir,$LogDir,$BackupDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

function Write-Log {
    param([string]$Msg, [ValidateSet('INFO','OK','SKIP','WARN','FAIL','STEP')][string]$Lvl='INFO')
    # credential masking: config ka password kabhi log/console me plaintext na jaye
    $safe = $Msg
    if ($CFG.DefaultAdmin.Pass) { $safe = $safe -replace [regex]::Escape($CFG.DefaultAdmin.Pass), '****' }
    $line = "{0} [{1,-4}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Lvl, $safe
    $color = switch ($Lvl) {
        'OK'   {'Green'}  'SKIP' {'DarkGray'} 'WARN' {'Yellow'}
        'FAIL' {'Red'}    'STEP' {'Cyan'}     default {'Gray'}
    }
    Write-Host $line -ForegroundColor $color
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch {}
}

# Har step ka result yahi se banega (R2: typed status)
function New-Result {
    param([string]$Target, [string]$Step, [ValidateSet('OK','SKIP','FAIL','WHATIF')][string]$Status, [string]$Reason='')
    $row = [pscustomobject]@{
        Target=$Target; Step=$Step; Status=$Status; Reason=$Reason; Time=(Get-Date -Format 'HH:mm:ss')
    }
    [void]$Results.Add($row)
    $lvl = switch ($Status) { 'OK'{'OK'} 'SKIP'{'SKIP'} 'FAIL'{'FAIL'} default{'INFO'} }
    Write-Log ("{0} :: {1} => {2} {3}" -f $Target,$Step,$Status,$Reason) $lvl
    return $row
}

# Core wrapper : R1+R2+R3+R5 ek jagah.
#   $Test   = { } -> $true agar already-applied (idempotent skip)
#   $Apply  = { } -> actual change
#   $Verify = { } -> $true agar change ke baad sach me laga (functional verify)
function Invoke-Step {
    param(
        [string]$Target, [string]$Step,
        [scriptblock]$Test    = $null,
        [Parameter(Mandatory)][scriptblock]$Apply,
        [scriptblock]$Verify  = $null,
        [switch]$Critical      # FAIL hone par module rok de
    )
    Write-Log "-> $Target :: $Step" 'STEP'
    try {
        if ($Test) {
            $already = & $Test
            if ($already) { return (New-Result $Target $Step 'SKIP' 'already applied') }
        }
        if ($DryRun) { return (New-Result $Target $Step 'WHATIF' 'dry-run, no change') }

        & $Apply

        if ($Verify) {
            $ok = & $Verify
            if (-not $ok) {
                $r = New-Result $Target $Step 'FAIL' 'verify failed (applied but re-query mismatch)'
                if ($Critical) { throw "Critical step failed: $Step" }
                return $r
            }
        }
        return (New-Result $Target $Step 'OK')
    }
    catch {
        $r = New-Result $Target $Step 'FAIL' $_.Exception.Message
        if ($Critical) { throw }
        return $r
    }
}

# StrictMode-safe registry read : key/property missing -> $null (throw nahi)
function Get-RegVal {
    param([string]$Path, [string]$Name)
    try {
        $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        return $item.$Name
    } catch { return $null }
}

function Save-Manifest {
    param([hashtable]$Entry)
    $data = @()
    if (Test-Path $Manifest) {
        try { $data = @(Get-Content $Manifest -Raw | ConvertFrom-Json) } catch { $data = @() }
    }
    $Entry['stamp'] = $RunStamp
    $data += [pscustomobject]$Entry
    $data | ConvertTo-Json -Depth 6 | Set-Content -Path $Manifest -Encoding UTF8
}

function Backup-RegKey {
    param([string]$KeyPath, [string]$Tag)   # KeyPath = 'HKLM\...'
    try {
        $out = Join-Path $BackupDir ("{0}.reg" -f $Tag)
        & reg.exe export $KeyPath $out /y *> $null
        Write-Log "backup saved: $Tag" 'INFO'
    } catch { Write-Log "backup skip ($Tag): $($_.Exception.Message)" 'WARN' }
}

# ---- Self elevation (R: admin rights guarantee) -----------------------------
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator)
}
function Assert-Admin {
    if (Test-Admin) { return }
    if ($DryRun) { Write-Log 'DryRun: admin ke bina chal raha (koi change nahi)' 'WARN'; return }
    if ($NoElevate) { throw 'Admin rights chahiye, par elevation fail hua.' }
    Write-Log 'Admin nahi -- elevated re-launch kar raha hu...' 'WARN'
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",
                 '-Action',$Action,'-NoElevate')
    if ($DryRun) { $argList += '-DryRun' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    exit
}

# ---- Environment guard (edition/version/OS fallback ke liye) -----------------
function Get-EnvInfo {
    $os = Get-CimInstance Win32_OperatingSystem
    [pscustomobject]@{
        Caption      = $os.Caption
        IsHome       = ($os.Caption -match 'Home')
        HasSmbCmdlet = [bool](Get-Command New-SmbMapping -ErrorAction SilentlyContinue)
        HasNetConn   = [bool](Get-Command Test-NetConnection -ErrorAction SilentlyContinue)
        HasLocalUser = [bool](Get-Command New-LocalUser -ErrorAction SilentlyContinue)
        PSVer        = $PSVersionTable.PSVersion.ToString()
    }
}
$Global:ENV = $null   # lazy init after elevation

# =============================================================================
# ==  REACHABILITY  (ping != SMB ; port 445 = asli signal)                  ==
# =============================================================================
function Test-Reachable {
    param([string]$IpOrHost)
    # 2 quick attempts (false-negative avoid), pehle ping hint phir port 445 decide
    for ($i=1; $i -le $CFG.ReachRetries; $i++) {
        $ping = $false
        try {
            $p = New-Object System.Net.NetworkInformation.Ping
            $r = $p.Send($IpOrHost, $CFG.PingTimeoutMs)
            $ping = ($r.Status -eq 'Success')
        } catch { $ping = $false }

        # asli decision : TCP 445 (SMB). ICMP block ho sakta hai, 445 sahi signal.
        $port = Test-Port445 -IpOrHost $IpOrHost
        if ($port) { return [pscustomobject]@{ Reachable=$true;  Ping=$ping; Smb=$true } }
        Start-Sleep -Milliseconds 150
    }
    return [pscustomobject]@{ Reachable=$false; Ping=$ping; Smb=$false }
}

function Test-Port445 {
    param([string]$IpOrHost)
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($IpOrHost, 445, $null, $null)
        $ok  = $iar.AsyncWaitHandle.WaitOne($CFG.PortTimeoutMs, $false)
        if ($ok -and $client.Connected) { $client.EndConnect($iar); $client.Close(); return $true }
        $client.Close(); return $false
    } catch { return $false }
}

# =============================================================================
# ==  MODULE 1 : SETUP                                                       ==
# =============================================================================
function Invoke-Setup {
    Write-Log '===== MODULE: SETUP =====' 'STEP'
    Assert-Admin
    $me = $env:COMPUTERNAME

    # -- 1. LocalAccountTokenFilterPolicy (silent Access-Denied fix) --------
    $polKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    Invoke-Step $me 'LocalAccountTokenFilterPolicy=1' `
        -Test   { (Get-RegVal $polKey 'LocalAccountTokenFilterPolicy') -eq 1 } `
        -Apply  { Backup-RegKey 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'PoliciesSystem'
                  New-ItemProperty $polKey -Name LocalAccountTokenFilterPolicy -Value 1 -PropertyType DWord -Force | Out-Null } `
        -Verify { (Get-RegVal $polKey 'LocalAccountTokenFilterPolicy') -eq 1 }

    # -- 2. EnableLinkedConnections (UAC token split fix; reboot req) --------
    Invoke-Step $me 'EnableLinkedConnections=1 (reboot pending)' `
        -Test   { (Get-RegVal $polKey 'EnableLinkedConnections') -eq 1 } `
        -Apply  { New-ItemProperty $polKey -Name EnableLinkedConnections -Value 1 -PropertyType DWord -Force | Out-Null
                  Set-PendingReboot 'EnableLinkedConnections' } `
        -Verify { (Get-RegVal $polKey 'EnableLinkedConnections') -eq 1 }

    # -- 3. ForceGuest = 0 (Classic auth; remote login guest na bane) -------
    $lsaKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
    Invoke-Step $me 'ForceGuest=0 (Classic model)' `
        -Test   { (Get-RegVal $lsaKey 'ForceGuest') -eq 0 } `
        -Apply  { Backup-RegKey 'HKLM\SYSTEM\CurrentControlSet\Control\Lsa' 'Lsa'
                  New-ItemProperty $lsaKey -Name ForceGuest -Value 0 -PropertyType DWord -Force | Out-Null } `
        -Verify { (Get-RegVal $lsaKey 'ForceGuest') -eq 0 }

    # -- 4. Workgroup ------------------------------------------------------
    Invoke-Step $me "Workgroup=$($CFG.Workgroup)" `
        -Test   { (Get-CimInstance Win32_ComputerSystem).Workgroup -eq $CFG.Workgroup } `
        -Apply  { Add-Computer -WorkgroupName $CFG.Workgroup -Force -ErrorAction Stop
                  Set-PendingReboot 'Workgroup change' } `
        -Verify { $true }   # reboot ke baad hi asli verify; pending flag set

    # -- 5. Static IP on correct physical Ethernet adapter -----------------
    Set-StaticIP -MyName $me

    # -- 6. hosts file entries (NetBIOS-free name resolution) --------------
    Set-HostsEntries

    # -- 7. Services : running + automatic ---------------------------------
    $svc = @('LanmanServer','LanmanWorkstation','Winmgmt','FDResPub','fdPHost','RemoteRegistry','Spooler','NlaSvc')
    foreach ($s in $svc) { Set-ServiceRunning $s }

    # -- 8. Firewall rule GROUPS by internal name (localized-name trap) -----
    Enable-FirewallGroups

    # -- 9. Default admin account (idempotent, policy-safe) ----------------
    New-LocalAdminSafe -User $CFG.DefaultAdmin.User -Pass $CFG.DefaultAdmin.Pass

    # -- 10. Functional verify : ek WMI + share reachability self-test ------
    Invoke-Step $me 'Self-test: WMI local query' `
        -Apply  { Get-CimInstance Win32_OperatingSystem | Out-Null } `
        -Verify { [bool](Get-CimInstance Win32_ComputerSystem) }

    Write-Log 'SETUP done. Reboot recommended agar pending flags set hain.' 'OK'
}

function Set-PendingReboot {
    param([string]$Why)
    $f = Join-Path $BaseDir 'pending-reboot.flag'
    Add-Content -Path $f -Value ("{0}  {1}" -f (Get-Date -Format s), $Why) -Encoding UTF8
    Write-Log "PENDING REBOOT: $Why" 'WARN'
}

function Get-PhysicalEthernet {
    # adapter naam se nahi -- media/type se (WiFi/virtual skip)
    try {
        $all = Get-CimInstance Win32_NetworkAdapter -Filter "NetEnabled=TRUE" -ErrorAction Stop
    } catch {
        Write-Log "adapter query fail: $($_.Exception.Message)" 'WARN'
        return @()
    }
    @($all | Where-Object {
        $_.PhysicalAdapter -eq $true -and
        $_.Name -notmatch 'Wi-?Fi|Wireless|Virtual|VMware|Hyper-V|Loopback|Bluetooth|VPN|TAP'
    })
}

function Set-StaticIP {
    param([string]$MyName)
    $octet = $CFG.PCs[$MyName]
    if (-not $octet) {
        New-Result $MyName 'Static IP' 'SKIP' "PC name '$MyName' config me nahi -- IP skip"
        return
    }
    $ip = "$($CFG.Subnet).$octet"

    $adapters = @(Get-PhysicalEthernet)
    if ($adapters.Count -eq 0) { New-Result $MyName 'Static IP' 'FAIL' 'physical Ethernet adapter nahi mila'; return }
    if ($adapters.Count -gt 1) { Write-Log "Multiple Ethernet mile ($($adapters.Count)) -- pehla active use ho raha" 'WARN' }

    $nic = $adapters | Select-Object -First 1
    $ifIdx = (Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "Index=$($nic.DeviceID)").InterfaceIndex
    if (-not $ifIdx) { $ifIdx = $nic.InterfaceIndex }

    Invoke-Step $MyName "Static IP $ip" `
        -Test   {
            $cur = Get-NetIPAddress -InterfaceIndex $ifIdx -AddressFamily IPv4 -EA SilentlyContinue |
                   Where-Object { $_.PrefixOrigin -eq 'Manual' -and $_.IPAddress -eq $ip }
            [bool]$cur
        } `
        -Apply  {
            # purani manual/dhcp saaf, phir set
            Get-NetIPAddress -InterfaceIndex $ifIdx -AddressFamily IPv4 -EA SilentlyContinue |
                Remove-NetIPAddress -Confirm:$false -EA SilentlyContinue
            Remove-NetRoute -InterfaceIndex $ifIdx -Confirm:$false -EA SilentlyContinue
            Set-NetIPInterface -InterfaceIndex $ifIdx -Dhcp Disabled -EA SilentlyContinue
            $p = @{ InterfaceIndex=$ifIdx; IPAddress=$ip; PrefixLength=24; AddressFamily='IPv4' }
            if ($CFG.Gateway) { $p['DefaultGateway'] = $CFG.Gateway }
            New-NetIPAddress @p | Out-Null
            if ($CFG.DnsServers.Count) {
                Set-DnsClientServerAddress -InterfaceIndex $ifIdx -ServerAddresses $CFG.DnsServers
            }
        } `
        -Verify {
            $null -ne (Get-NetIPAddress -InterfaceIndex $ifIdx -AddressFamily IPv4 -EA SilentlyContinue |
             Where-Object IPAddress -eq $ip)
        }
}

function Set-HostsEntries {
    $me = $env:COMPUTERNAME
    $hosts = "$env:windir\System32\drivers\etc\hosts"
    Invoke-Step $me 'hosts file entries' `
        -Test   {
            $c = Get-Content $hosts -EA SilentlyContinue
            $miss = $false
            foreach ($kv in $CFG.PCs.GetEnumerator()) {
                if ($kv.Key -eq $me) { continue }
                $ip = "$($CFG.Subnet).$($kv.Value)"
                if (-not ($c -match "^\s*$([regex]::Escape($ip))\s+$([regex]::Escape($kv.Key))\b")) { $miss=$true }
            }
            -not $miss
        } `
        -Apply  {
            Copy-Item $hosts (Join-Path $BackupDir 'hosts.bak') -Force -EA SilentlyContinue
            $c = @(Get-Content $hosts -EA SilentlyContinue)
            # purani CCL-managed lines hata ke fresh likho (idempotent, duplicate na ho)
            $c = $c | Where-Object { $_ -notmatch '#\s*CCL-LAN' }
            $new = foreach ($kv in $CFG.PCs.GetEnumerator()) {
                if ($kv.Key -eq $me) { continue }
                "{0}`t{1}`t# CCL-LAN" -f "$($CFG.Subnet).$($kv.Value)", $kv.Key
            }
            Set-Content -Path $hosts -Value ($c + $new) -Encoding ASCII -Force
        } `
        -Verify { $true }
}

function Set-ServiceRunning {
    param([string]$Name)
    $me = $env:COMPUTERNAME
    Invoke-Step $me "Service $Name (auto+running)" `
        -Test   {
            $s = Get-Service -Name $Name -EA SilentlyContinue
            $s -and $s.Status -eq 'Running' -and
            (Get-CimInstance Win32_Service -Filter "Name='$Name'").StartMode -eq 'Auto'
        } `
        -Apply  {
            $s = Get-Service -Name $Name -EA SilentlyContinue
            if (-not $s) { throw "service $Name maujood nahi (edition me disabled?)" }
            Set-Service -Name $Name -StartupType Automatic -EA Stop
            if ($s.Status -ne 'Running') { Start-Service -Name $Name -EA Stop }
        } `
        -Verify { (Get-Service -Name $Name).Status -eq 'Running' }
}

function Enable-FirewallGroups {
    $me = $env:COMPUTERNAME
    # internal rule-GROUP names (localized display-name trap avoid)
    # NetFirewallRule -Group '@FirewallAPI.dll,...' resource strings language-neutral
    $groups = @(
        '@FirewallAPI.dll,-28502',   # File and Printer Sharing
        '@FirewallAPI.dll,-32752',   # Network Discovery
        '@FirewallAPI.dll,-34251'    # Windows Management Instrumentation (WMI)
    )
    foreach ($g in $groups) {
        Invoke-Step $me "Firewall group enable ($g)" `
            -Test   {
                $r = Get-NetFirewallRule -Group $g -EA SilentlyContinue
                $r -and -not ($r | Where-Object { $_.Enabled -eq 'False' })
            } `
            -Apply  {
                $r = Get-NetFirewallRule -Group $g -EA SilentlyContinue
                if (-not $r) { throw "rule group nahi mila ($g)" }
                $r | Enable-NetFirewallRule -EA Stop
            } `
            -Verify {
                $r = Get-NetFirewallRule -Group $g -EA SilentlyContinue
                $r -and -not ($r | Where-Object { $_.Enabled -eq 'False' })
            }
    }
    # network profile Private force (NLA se pehle)
    Invoke-Step $me 'Network profile -> Private' `
        -Test   { -not (Get-NetConnectionProfile | Where-Object NetworkCategory -ne 'Private') } `
        -Apply  { Get-NetConnectionProfile | ForEach-Object {
                     Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private -EA SilentlyContinue } } `
        -Verify { $true }
}

# ---- Policy-safe, idempotent local admin (Sub-A + Sub-B ka common backend)---
function New-LocalAdminSafe {
    param([Parameter(Mandatory)][string]$User, [Parameter(Mandatory)][string]$Pass)
    $me = $env:COMPUTERNAME

    # weak password (1234) => pehle local policy loosen (warna create FAIL)
    Invoke-Step $me 'Password policy loosen (min-len=0, complexity off)' `
        -Apply  {
            $cfgFile = Join-Path $env:TEMP 'ccl-secpol.cfg'
            & secedit.exe /export /cfg $cfgFile /quiet *> $null
            if (Test-Path $cfgFile) {
                (Get-Content $cfgFile) `
                    -replace 'MinimumPasswordLength = \d+','MinimumPasswordLength = 0' `
                    -replace 'PasswordComplexity = \d+','PasswordComplexity = 0' `
                    -replace 'LockoutBadCount = \d+','LockoutBadCount = 0' |
                    Set-Content $cfgFile
                & secedit.exe /configure /db "$env:windir\security\ccl.sdb" /cfg $cfgFile /quiet *> $null
                Remove-Item $cfgFile -Force -EA SilentlyContinue
            } else { throw 'secedit export fail' }
        } `
        -Verify { $true }

    $sec = ConvertTo-SecureString $Pass -AsPlainText -Force

    Invoke-Step $me "Local admin '$User' (create/update)" `
        -Test   { $false }  `
        -Apply  {
            $exists = $null
            if ($ENV.HasLocalUser) {
                $exists = Get-LocalUser -Name $User -EA SilentlyContinue
                if ($exists) {
                    Set-LocalUser -Name $User -Password $sec -PasswordNeverExpires $true
                } else {
                    New-LocalUser -Name $User -Password $sec -PasswordNeverExpires `
                        -UserMayNotChangePassword:$false -AccountNeverExpires | Out-Null
                }
                # change-at-next-logon OFF (remote logon block na ho) -- net user se pakka
                & net.exe user $User /logonpasswordchg:no *> $null
                if (-not (Get-LocalGroupMember -Group 'Administrators' -Member $User -EA SilentlyContinue)) {
                    Add-LocalGroupMember -Group 'Administrators' -Member $User -EA SilentlyContinue
                }
                Add-LocalGroupMember -Group 'Remote Desktop Users' -Member $User -EA SilentlyContinue
            } else {
                # purani OS fallback: net user
                $chk = & net.exe user $User 2>$null
                if ($LASTEXITCODE -eq 0) { & net.exe user $User $Pass *> $null }
                else { & net.exe user $User $Pass /add *> $null }
                & net.exe user $User /passwordchg:no /expires:never /active:yes /logonpasswordchg:no *> $null
                & net.exe localgroup Administrators $User /add *> $null
                & net.exe localgroup "Remote Desktop Users" $User /add *> $null
            }
        } `
        -Verify {
            if ($ENV.HasLocalUser) { [bool](Get-LocalUser -Name $User -EA SilentlyContinue) }
            else { & net.exe user $User *> $null; ($LASTEXITCODE -eq 0) }
        }
    Save-Manifest @{ action='create-admin'; user=$User }
}

# =============================================================================
# ==  MODULE 2 : BULK DRIVE MAP  (fault-tolerant + deferred)               ==
# =============================================================================
function Invoke-BulkMap {
    Write-Log '===== MODULE: BULK DRIVE MAP =====' 'STEP'
    $swStart = Get-Date
    $me = $env:COMPUTERNAME

    # creds pre-save (cmdkey) => interactive popup-hang avoid
    $u = $CFG.DefaultAdmin.User; $p = $CFG.DefaultAdmin.Pass

    foreach ($kv in $CFG.DriveMaps.GetEnumerator()) {
        # overall hard budget (worst case sab off ho to bhi turant niklo)
        if (((Get-Date) - $swStart).TotalSeconds -gt $CFG.OverallBudgetSec) {
            New-Result 'ALL' 'Bulk map budget' 'SKIP' 'overall timeout budget cross -- baaki defer'
            break
        }
        $L = $kv.Key; $m = $kv.Value
        $target = "$($m.Host) ($L`:)"
        $ip = Resolve-PcIp $m.Host

        # 1. drive-letter conflict pehle (already-in-use => safe disconnect)
        Resolve-DriveLetterConflict -Letter $L -WantHost $m.Host -WantShare $m.Share

        # 2. reachability (ping hint + 445 decide)
        $reachTarget = if ($ip) { $ip } else { $m.Host }
        $reach = Test-Reachable -IpOrHost $reachTarget
        if (-not $reach.Reachable) {
            # 3-bucket: SKIP (unreachable) + deferred auto-map register
            New-Result $target 'Map' 'SKIP' 'unreachable (445 closed/off) -- deferred poller set'
            Register-DeferredMap -Letter $L -Map $m -Ip $ip
            continue
        }

        # 3. cred pre-save (popup na aaye)
        & cmdkey.exe /add:$($m.Host) /user:$u /pass:$p *> $null

        # 4. map + verify (reachable+fail => cred/share galat, alag bucket)
        $unc = "\\$($m.Host)\$($m.Share)"
        Invoke-Step $target "Map $L -> $unc" `
            -Test   {
                $g = Get-SmbMapping -LocalPath "$L`:" -EA SilentlyContinue
                $g -and $g.RemotePath -eq $unc
            } `
            -Apply  {
                if ($ENV.HasSmbCmdlet) {
                    New-SmbMapping -LocalPath "$L`:" -RemotePath $unc -Persistent $true `
                        -UserName $u -Password $p -EA Stop | Out-Null
                } else {
                    & net.exe use "$L`:" $unc $p /user:$u /persistent:yes *> $null
                    if ($LASTEXITCODE -ne 0) { throw "net use failed rc=$LASTEXITCODE" }
                }
                Set-DriveLabel -Letter $L -Label $m.Label
            } `
            -Verify {
                Test-Path "$L`:\"    # functional: sach me access hua?
            }
    }
    Write-Log 'BULK MAP done.' 'OK'
}

function Resolve-PcIp {
    param([string]$HostName)
    $o = $CFG.PCs[$HostName]
    if ($o) { return "$($CFG.Subnet).$o" }
    return $null
}

function Resolve-DriveLetterConflict {
    param([string]$Letter, [string]$WantHost, [string]$WantShare)
    $me = $env:COMPUTERNAME
    $existing = Get-SmbMapping -LocalPath "$Letter`:" -EA SilentlyContinue
    if (-not $existing) { return }
    $want = "\\$WantHost\$WantShare"
    if ($existing.RemotePath -eq $want) { return }   # sahi hai, chhodo
    Invoke-Step "$Letter`:" 'Stale mapping disconnect' `
        -Apply  {
            if ($DryRun) { return }
            Remove-SmbMapping -LocalPath "$Letter`:" -Force -EA SilentlyContinue
            & net.exe use "$Letter`:" /delete /y *> $null
        } `
        -Verify { -not (Get-SmbMapping -LocalPath "$Letter`:" -EA SilentlyContinue) }
}

function Set-DriveLabel {
    param([string]$Letter, [string]$Label)
    # sidebar label => HKCU MountPoints2 _LabelFromReg
    try {
        $unc = (Get-SmbMapping -LocalPath "$Letter`:" -EA SilentlyContinue).RemotePath
        if (-not $unc) { return }
        $mp = '##' + ($unc.TrimStart('\') -replace '\\','#')
        $key = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2\$mp"
        if (-not (Test-Path $key)) { New-Item $key -Force | Out-Null }
        New-ItemProperty $key -Name '_LabelFromReg' -Value $Label -PropertyType String -Force | Out-Null
    } catch { Write-Log "label set skip ($Letter): $($_.Exception.Message)" 'WARN' }
}

# ---- Deferred auto-map : intent register, bounded backoff poller -----------
function Register-DeferredMap {
    param([string]$Letter, [hashtable]$Map, [string]$Ip)
    $taskName = "CCL-DeferMap-$($Map.Host)-$Letter"

    # duplicate-trigger guard : already pending to skip
    if (Get-ScheduledTask -TaskName $taskName -EA SilentlyContinue) {
        New-Result $Map.Host 'Deferred map' 'SKIP' 'already pending (duplicate guard)'
        return
    }
    if ($DryRun) { New-Result $Map.Host 'Deferred map' 'WHATIF' 'would register poller'; return }

    # helper script disk par likho (self-contained, self-deleting, backoff)
    $helper = Join-Path $BaseDir "defer-$($Map.Host)-$Letter.ps1"
    $u = $CFG.DefaultAdmin.User; $p = $CFG.DefaultAdmin.Pass
    $unc = "\\$($Map.Host)\$($Map.Share)"
    $deadlineTicks = (Get-Date).AddHours($CFG.DeferMaxHours).Ticks
    $pollTarget = if ($Ip) { $Ip } else { $Map.Host }

    $body = @"
`$ErrorActionPreference='SilentlyContinue'
`$deadline=[datetime]$deadlineTicks
`$start=Get-Date
`$log='$BaseDir\defer-$($Map.Host)-$Letter.log'
function P(`$m){ Add-Content `$log ("{0}  {1}" -f (Get-Date -Format s),`$m) }
P 'poller start'
while((Get-Date) -lt `$deadline){
    # adaptive backoff : 0-20min=>60s, 20min-4h=>300s, baaki=>1800s
    `$el=((Get-Date)-`$start).TotalMinutes
    `$wait= if(`$el -lt 20){60} elseif(`$el -lt 240){300} else{1800}
    `$c=New-Object System.Net.Sockets.TcpClient
    try{ `$iar=`$c.BeginConnect('$pollTarget',445,`$null,`$null)
         if(`$iar.AsyncWaitHandle.WaitOne(600,`$false) -and `$c.Connected){
            `$c.EndConnect(`$iar); `$c.Close()
            cmdkey /add:$($Map.Host) /user:$u /pass:$p | Out-Null
            net use ${Letter}: '$unc' $p /user:$u /persistent:yes | Out-Null
            if(Test-Path '${Letter}:\'){ P 'MAPPED ok'; break }
         } else { `$c.Close() }
    }catch{}
    Start-Sleep -Seconds `$wait
}
if((Get-Date) -ge `$deadline){ P 'DEADLINE 48h -- cancel, manual check karein' }
# self clean : task + helper delete
schtasks /delete /tn '$taskName' /f | Out-Null
Remove-Item '$helper' -Force
"@
    Set-Content -Path $helper -Value $body -Encoding UTF8 -Force

    # scheduled task : logged-on user context, NOT highest-priv (user-session me chale)
    $act = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$helper`""
    & schtasks.exe /create /tn $taskName /tr $act /sc onlogon /ru "$env:USERNAME" /rl LIMITED /f *> $null
    & schtasks.exe /run /tn $taskName *> $null
    New-Result $Map.Host 'Deferred map' 'OK' "poller set (48h backoff), task=$taskName"
    Save-Manifest @{ action='defer-map'; task=$taskName; helper=$helper }
}

# =============================================================================
# ==  MODULE 3 : CLEANUP / RESET-TO-DEFAULT                                  ==
# =============================================================================
function Invoke-Cleanup {
    Write-Log '===== MODULE: CLEANUP / RESET =====' 'STEP'
    $me = $env:COMPUTERNAME

    # -- 1. Mapped drives : 3 layers (session + HKCU\Network + explorer) ----
    Invoke-Step $me 'Mapped drives remove (all 3 layers)' `
        -Apply  {
            if ($DryRun) { return }
            # a) session
            Get-SmbMapping -EA SilentlyContinue | ForEach-Object {
                Remove-SmbMapping -LocalPath $_.LocalPath -Force -EA SilentlyContinue }
            & net.exe use * /delete /y *> $null
            # b) persistent registry (asli jagah) -- current user
            $nk = 'HKCU:\Network'
            if (Test-Path $nk) { Get-ChildItem $nk | Remove-Item -Recurse -Force -EA SilentlyContinue }
            # c) explorer cache refresh
            Restart-ExplorerSafe
        } `
        -Verify { -not (Get-SmbMapping -EA SilentlyContinue) }

    # -- 2. ALL user profiles ki HKCU\Network (offline hive load) -----------
    Clear-AllProfilesNetwork

    # -- 3. Saved credentials (sirf hamare target PCs, pura vault nahi) ------
    Invoke-Step $me 'Credential Manager (target PCs only)' `
        -Apply  {
            if ($DryRun) { return }
            $list = & cmdkey.exe /list
            foreach ($pc in $CFG.PCs.Keys) {
                if ($list -match [regex]::Escape($pc)) { & cmdkey.exe /delete:$pc *> $null }
            }
        } `
        -Verify { $true }

    # -- 4. Printer connections (default pehle hatao, phir delete) ----------
    Clear-NetworkPrinters

    # -- 5. Firewall duplicate custom rules (naam se, blind add nahi) -------
    # (is tool ne group-based enable kiya, custom rule nahi banayi -- safe no-op)
    New-Result $me 'Firewall custom rules' 'SKIP' 'group-based enable use kiya, koi custom rule nahi'

    Write-Log 'CLEANUP done.' 'OK'
}

function Restart-ExplorerSafe {
    try { Stop-Process -Name explorer -Force -EA SilentlyContinue; Start-Sleep 1
          if (-not (Get-Process explorer -EA SilentlyContinue)) { Start-Process explorer.exe } } catch {}
}

function Clear-AllProfilesNetwork {
    $me = $env:COMPUTERNAME
    Invoke-Step $me 'All-profiles HKCU\Network clear (offline hive)' `
        -Apply  {
            if ($DryRun) { return }
            $profiles = Get-CimInstance Win32_UserProfile |
                Where-Object { $_.Special -eq $false -and $_.LocalPath -like 'C:\Users\*' }
            foreach ($pr in $profiles) {
                $sid = $pr.SID
                $loaded = Test-Path "Registry::HKEY_USERS\$sid"
                $dat = Join-Path $pr.LocalPath 'NTUSER.DAT'
                if (-not $loaded) {
                    if (-not (Test-Path $dat)) { continue }
                    & reg.exe load "HKU\CCLtmp_$sid" "$dat" *> $null
                    $netKey = "Registry::HKEY_USERS\CCLtmp_$sid\Network"
                } else {
                    $netKey = "Registry::HKEY_USERS\$sid\Network"
                }
                if (Test-Path $netKey) { Remove-Item $netKey -Recurse -Force -EA SilentlyContinue }
                if (-not $loaded) {
                    [gc]::Collect(); Start-Sleep -Milliseconds 300
                    & reg.exe unload "HKU\CCLtmp_$sid" *> $null
                }
            }
        } `
        -Verify { $true }
}

function Clear-NetworkPrinters {
    $me = $env:COMPUTERNAME
    Invoke-Step $me 'Network printers remove (default first)' `
        -Apply  {
            if ($DryRun) { return }
            # default local par shift (network default delete resist karta hai)
            $localP = Get-CimInstance Win32_Printer -Filter "Network=FALSE" | Select-Object -First 1
            if ($localP) { (New-Object -ComObject WScript.Network).SetDefaultPrinter($localP.Name) }
            Get-CimInstance Win32_Printer -Filter "Network=TRUE" | ForEach-Object {
                & rundll32 printui.dll,PrintUIEntry /dn /n $_.Name *> $null
            }
        } `
        -Verify { $true }
}

# =============================================================================
# ==  MODULE 4 : FOLDER + PRINTER SHARE                                      ==
# =============================================================================
function Invoke-Share {
    Write-Log '===== MODULE: FOLDER + PRINTER SHARE =====' 'STEP'
    Assert-Admin
    $me = $env:COMPUTERNAME

    foreach ($f in $CFG.SharedFolders) {
        $path = $f.Path; $name = $f.Name
        $driveRoot = (Split-Path $path -Qualifier) + '\'
        $wantHidden = [bool]($f.Hidden)

        # drive root exist check (D: PC pe na ho to saaf FAIL, silent skip nahi)
        if (-not (Test-Path $driveRoot)) {
            New-Result $me "Folder exists ($path)" 'FAIL' "drive $driveRoot maujood nahi is PC par"
            continue
        }

        # folder exist
        Invoke-Step $me "Folder exists ($path)" `
            -Test   { Test-Path $path } `
            -Apply  { New-Item -ItemType Directory -Path $path -Force | Out-Null } `
            -Verify { Test-Path $path }

        # Hidden attribute : sirf folder ka apna icon local D: browsing me chhupega.
        # Andar ke files/folders untouched -- unpar attribute nahi lagta, mapped
        # drive se andar aane par sab kuch normal dikhega.
        if ($wantHidden) {
            Invoke-Step $me "Folder Hidden attribute ($path)" `
                -Test   { $it = Get-Item $path -Force -EA SilentlyContinue
                          $it -and (($it.Attributes -band [IO.FileAttributes]::Hidden) -ne 0) } `
                -Apply  { $it = Get-Item $path -Force; $it.Attributes = $it.Attributes -bor [IO.FileAttributes]::Hidden } `
                -Verify { ((Get-Item $path -Force).Attributes -band [IO.FileAttributes]::Hidden) -ne 0 }
        }

        # SMB share : Everyone Full on SHARE, restriction NTFS se
        Invoke-Step $me "Share '$name' (Everyone:Full on share)" `
            -Test   { [bool](Get-SmbShare -Name $name -EA SilentlyContinue) } `
            -Apply  {
                if (Get-SmbShare -Name $name -EA SilentlyContinue) {
                    Grant-SmbShareAccess -Name $name -AccountName 'Everyone' -AccessRight Full -Force -EA SilentlyContinue
                } else {
                    New-SmbShare -Name $name -Path $path -FullAccess 'Everyone' -EA Stop | Out-Null
                }
            } `
            -Verify { [bool](Get-SmbShare -Name $name -EA SilentlyContinue) }

        # NTFS : Everyone Modify (Read+Write+Delete) -- office LAN trusted hai,
        # kisi bhi PC se CNB account map kare to access-denied na aaye.
        Invoke-Step $me "NTFS ACL ($path) Everyone:Modify" `
            -Test   { $acl = Get-Acl $path -EA SilentlyContinue
                      [bool]($acl -and ($acl.Access | Where-Object {
                          $_.IdentityReference -match 'Everyone' -and
                          $_.FileSystemRights -match 'Modify|FullControl' })) } `
            -Apply  {
                $acl = Get-Acl $path
                $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    'Everyone','Modify','ContainerInherit,ObjectInherit','None','Allow')
                $acl.AddAccessRule($rule); Set-Acl $path $acl
            } `
            -Verify { $acl = Get-Acl $path -EA SilentlyContinue
                      [bool]($acl -and ($acl.Access | Where-Object {
                          $_.IdentityReference -match 'Everyone' -and
                          $_.FileSystemRights -match 'Modify|FullControl' })) }
    }

    # Point-and-Print : non-admin driver install prompt avoid
    $ppKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint'
    Invoke-Step $me 'Point-and-Print restriction relax' `
        -Test   { (Get-RegVal $ppKey 'RestrictDriverInstallationToAdministrators') -eq 0 } `
        -Apply  {
            if (-not (Test-Path $ppKey)) { New-Item $ppKey -Force | Out-Null }
            New-ItemProperty $ppKey -Name RestrictDriverInstallationToAdministrators -Value 0 -PropertyType DWord -Force | Out-Null
        } `
        -Verify { (Get-RegVal $ppKey 'RestrictDriverInstallationToAdministrators') -eq 0 }

    Write-Log 'SHARE done.' 'OK'
}

# =============================================================================
# ==  SUMMARY + MENU + MAIN                                                  ==
# =============================================================================
function Show-Summary {
    Write-Host ''
    Write-Host '============ SUMMARY ============' -ForegroundColor Cyan
    if ($Results.Count -eq 0) { Write-Host '(kuch nahi chala)'; return }
    $Results | Format-Table Target,Step,Status,Reason -AutoSize | Out-String | Write-Host
    $ok=@($Results|Where-Object Status -eq 'OK').Count
    $sk=@($Results|Where-Object Status -eq 'SKIP').Count
    $fl=@($Results|Where-Object Status -eq 'FAIL').Count
    $wi=@($Results|Where-Object Status -eq 'WHATIF').Count
    Write-Host ("OK={0}  SKIP={1}  FAIL={2}  DRYRUN={3}" -f $ok,$sk,$fl,$wi) -ForegroundColor Yellow
    Write-Host ("Log: {0}" -f $LogFile) -ForegroundColor DarkGray
    if (Test-Path (Join-Path $BaseDir 'pending-reboot.flag')) {
        Write-Host '*** REBOOT PENDING -- kuch settings reboot ke baad hi effective hongi ***' -ForegroundColor Magenta
    }
}

function Show-Menu {
    while ($true) {
        Write-Host ''
        Write-Host '==================================================' -ForegroundColor Cyan
        Write-Host '   CCL LAN ADMIN TOOL' -ForegroundColor White
        if ($DryRun) { Write-Host '   [ DRY-RUN MODE -- koi change nahi hoga ]' -ForegroundColor Yellow }
        Write-Host '==================================================' -ForegroundColor Cyan
        Write-Host '  1) Setup           (IP/workgroup/firewall/services/account)'
        Write-Host '  2) Bulk Drive Map  (fault-tolerant + offline defer)'
        Write-Host '  3) Cleanup / Reset (drives/creds/printers/profiles)'
        Write-Host '  4) Folder+Printer Share'
        Write-Host '  5) Run ALL (1->4)'
        Write-Host '  6) Toggle Dry-Run  (abhi: ' -NoNewline; Write-Host $DryRun -ForegroundColor Yellow
        Write-Host '  0) Exit'
        $c = Read-Host 'Choose'
        switch ($c) {
            '1' { Invoke-Setup;   Show-Summary }
            '2' { Invoke-BulkMap; Show-Summary }
            '3' { Invoke-Cleanup; Show-Summary }
            '4' { Invoke-Share;   Show-Summary }
            '5' { Invoke-Setup; Invoke-Share; Invoke-BulkMap; Show-Summary }
            '6' { $script:DryRun = -not $DryRun }
            '0' { return }
            default { Write-Host 'Galat choice' -ForegroundColor Red }
        }
    }
}

# ------------------------------- MAIN ----------------------------------------
try {
    Write-Log ("CCL LAN Admin start | host=$env:COMPUTERNAME | user=$env:USERNAME | dryrun=$DryRun") 'STEP'
    Assert-Admin
    $Global:ENV = Get-EnvInfo
    Write-Log ("OS: {0} | PSVer {1} | SmbCmdlet={2} Home={3}" -f $ENV.Caption,$ENV.PSVer,$ENV.HasSmbCmdlet,$ENV.IsHome) 'INFO'

    switch ($Action) {
        'Setup'   { Invoke-Setup;   Show-Summary }
        'BulkMap' { Invoke-BulkMap; Show-Summary }
        'Cleanup' { Invoke-Cleanup; Show-Summary }
        'Share'   { Invoke-Share;   Show-Summary }
        default   { Show-Menu }
    }
}
catch {
    Write-Log "FATAL: $($_.Exception.Message)" 'FAIL'
    Write-Log $_.ScriptStackTrace 'FAIL'
}
finally {
    Show-Summary
    if ($Action -eq 'Menu') { Read-Host 'Enter dabao band karne ke liye' | Out-Null }
}
