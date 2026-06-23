# ==============================================================
#   FEATURE 01 : LAN File & Printer Sharing Fix
#   Created by : Salman | Coaching Depot, Kanpur Central - NCR
# ==============================================================

$lf_log  = [System.Collections.Generic.List[string]]::new()
$lf_ok   = 0
$lf_skip = 0
$lf_fail = 0

function LF-Log {
    param([string]$msg, [string]$st = "OK")
    $col = switch ($st) {
        "OK"   { "Green"   }
        "SKIP" { "Cyan"    }
        "FAIL" { "Red"     }
        "INFO" { "Yellow"  }
        "HEAD" { "Magenta" }
        default { "White"  }
    }
    if ($st -eq "HEAD") {
        Write-Host ""
        Write-Host "  $msg" -ForegroundColor $col
        Write-Host "  $(([string]"-") * 44)" -ForegroundColor DarkGray
    } else {
        Write-Host "   $([char]0x2022) $msg" -ForegroundColor $col
    }
    $script:lf_log.Add("[$st] $msg")
    if ($st -eq "OK")   { $script:lf_ok++   }
    if ($st -eq "SKIP") { $script:lf_skip++ }
    if ($st -eq "FAIL") { $script:lf_fail++ }
}

function LF-Reg {
    param($p, $n, $v, $t, $d)
    try {
        if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null }
        $cur = (Get-ItemProperty -Path $p -Name $n -ErrorAction SilentlyContinue).$n
        if ($cur -ne $v) {
            Set-ItemProperty -Path $p -Name $n -Value $v -Type $t -Force -ErrorAction Stop
            LF-Log "$d = $v"
        } else { LF-Log "$d pehle se $v" "SKIP" }
    } catch { LF-Log "$d : $($_.Exception.Message)" "FAIL" }
}

function Invoke-LanFix {
    Clear-Host
    $ts = Get-Date -Format "dd-MM-yyyy  HH:mm:ss"
    Write-Host ""
    Write-Host "  +----------------------------------------------+" -ForegroundColor Green
    Write-Host "  |   LAN FILE & PRINTER SHARING FIX            |" -ForegroundColor Green
    Write-Host "  |   PC: $($env:COMPUTERNAME.PadRight(15))  $ts  |" -ForegroundColor Green
    Write-Host "  +----------------------------------------------+" -ForegroundColor Green

    # S1: NETWORK PROFILE
    LF-Log "S1: Network Profile" "HEAD"
    try {
        foreach ($p in (Get-NetConnectionProfile -ErrorAction Stop)) {
            if ($p.NetworkCategory -ne "Private") {
                Set-NetConnectionProfile -InterfaceIndex $p.InterfaceIndex -NetworkCategory Private -ErrorAction Stop
                LF-Log "'$($p.InterfaceAlias)' Public se Private kar diya"
            } else { LF-Log "'$($p.InterfaceAlias)' pehle se Private" "SKIP" }
        }
    } catch { LF-Log "Network Profile: $($_.Exception.Message)" "FAIL" }

    # S2: FIREWALL RULES
    LF-Log "S2: Firewall Rules" "HEAD"
    foreach ($grp in @("File and Printer Sharing","Network Discovery","File and Printer Sharing (SMB-Direct)","Link-Layer Topology Discovery")) {
        try {
            $rules = Get-NetFirewallRule -DisplayGroup $grp -ErrorAction SilentlyContinue
            if ($null -eq $rules) { LF-Log "$grp nahi mila" "SKIP"; continue }
            Enable-NetFirewallRule -DisplayGroup $grp -ErrorAction Stop
            LF-Log "$grp enabled"
        } catch { LF-Log "$grp : $($_.Exception.Message)" "FAIL" }
    }
    $null = netsh advfirewall firewall set rule group="File and Printer Sharing" new enable=Yes profile=private 2>&1
    $null = netsh advfirewall firewall set rule group="File and Printer Sharing" new enable=Yes profile=domain 2>&1
    $null = netsh advfirewall firewall set rule group="Network Discovery" new enable=Yes profile=private 2>&1
    $null = netsh advfirewall firewall set rule group="Network Discovery" new enable=Yes profile=domain 2>&1
    $null = netsh advfirewall firewall add rule name="Allow ICMPv4-LAN" protocol=icmpv4:8,any dir=in action=allow 2>&1
    LF-Log "netsh: Private + Domain + ICMPv4 rules applied"

    # S3: WINDOWS SERVICES
    LF-Log "S3: Windows Services" "HEAD"
    $svcs = @(
        @{ N="fdPHost";           D="Function Discovery Provider Host"        }
        @{ N="FDResPub";          D="Function Discovery Resource Publication"  }
        @{ N="LanmanServer";      D="Server (File/Printer)"                   }
        @{ N="LanmanWorkstation"; D="Workstation"                             }
        @{ N="lmhosts";           D="TCP/IP NetBIOS Helper"                   }
        @{ N="Dnscache";          D="DNS Client"                              }
        @{ N="Spooler";           D="Print Spooler"                           }
        @{ N="NlaSvc";            D="Network Location Awareness"              }
        @{ N="Browser";           D="Computer Browser"                        }
        @{ N="upnphost";          D="UPnP Device Host"                       }
        @{ N="SSDPSRV";           D="SSDP Discovery"                         }
        @{ N="lltdsvc";           D="LLTD (Network Map)"                     }
        @{ N="RpcSs";             D="Remote Procedure Call"                   }
    )
    foreach ($svc in $svcs) {
        try {
            $s = Get-Service -Name $svc.N -ErrorAction SilentlyContinue
            if ($null -eq $s) { LF-Log "$($svc.D) exist nahi karta" "SKIP"; continue }
            $changed = $false
            if ($s.StartType -notin @("Automatic","AutomaticDelayedStart")) {
                Set-Service -Name $svc.N -StartupType Automatic -ErrorAction SilentlyContinue
                $changed = $true
            }
            if ($s.Status -ne "Running") {
                Start-Service -Name $svc.N -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 400
                $s.Refresh()
                if ($s.Status -eq "Running") { LF-Log "$($svc.D) start kar diya" }
                else { LF-Log "$($svc.D) start nahi hua" "FAIL" }
            } elseif ($changed) { LF-Log "$($svc.D) Startup Automatic kar diya" }
            else { LF-Log "$($svc.D) pehle se Running + Automatic" "SKIP" }
        } catch { LF-Log "$($svc.N) : $($_.Exception.Message)" "FAIL" }
    }

    # S4: SMB CONFIG
    LF-Log "S4: SMB Configuration" "HEAD"
    try {
        $smbS = Get-SmbServerConfiguration -ErrorAction Stop
        if (-not $smbS.EnableSMB2Protocol) {
            Set-SmbServerConfiguration -EnableSMB2Protocol $true -Force
            LF-Log "SMB2 Protocol enabled"
        } else { LF-Log "SMB2 pehle se enabled" "SKIP" }
        if ($smbS.RequireSecuritySignature) {
            Set-SmbServerConfiguration -RequireSecuritySignature $false -Force
            LF-Log "SMB Server: SecuritySignature=false (24H2 fix)"
        } else { LF-Log "SMB Server: SecuritySignature already off" "SKIP" }
    } catch { LF-Log "SMB Server: $($_.Exception.Message)" "FAIL" }
    try {
        $smbC = Get-SmbClientConfiguration -ErrorAction Stop
        if (-not $smbC.EnableInsecureGuestLogons) {
            Set-SmbClientConfiguration -EnableInsecureGuestLogons $true -Force
            LF-Log "SMB Client: InsecureGuestLogons enabled"
        } else { LF-Log "SMB Client: GuestLogons already enabled" "SKIP" }
        if ($smbC.RequireSecuritySignature) {
            Set-SmbClientConfiguration -RequireSecuritySignature $false -Force
            LF-Log "SMB Client: SecuritySignature=false (24H2 fix)"
        } else { LF-Log "SMB Client: SecuritySignature already off" "SKIP" }
    } catch { LF-Log "SMB Client: $($_.Exception.Message)" "FAIL" }

    # S5: NetBIOS
    LF-Log "S5: NetBIOS over TCP/IP" "HEAD"
    try {
        foreach ($adapter in (Get-WmiObject -Class Win32_NetworkAdapterConfiguration -Filter "IPEnabled = True" -ErrorAction Stop)) {
            if ($adapter.TcpipNetbiosOptions -ne 1) {
                $r = $adapter.SetTcpipNetbios(1)
                if ($r.ReturnValue -eq 0) { LF-Log "$($adapter.Description) NetBIOS enabled" }
                else { LF-Log "$($adapter.Description) code:$($r.ReturnValue)" "FAIL" }
            } else { LF-Log "$($adapter.Description) pehle se enabled" "SKIP" }
        }
    } catch { LF-Log "NetBIOS: $($_.Exception.Message)" "FAIL" }

    # S6: REGISTRY
    LF-Log "S6: Registry Fixes" "HEAD"
    LF-Reg "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters" "AllowInsecureGuestAuth"    1 "DWord" "AllowInsecureGuestAuth (LanmanWS)"
    LF-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LanmanWorkstation"          "AllowInsecureGuestAuth"    1 "DWord" "AllowInsecureGuestAuth (Policy)"
    LF-Reg "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters" "RequireSecuritySignature"  0 "DWord" "RequireSecuritySignature (Client)"
    LF-Reg "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters"      "RequireSecuritySignature"  0 "DWord" "RequireSecuritySignature (Server)"
    LF-Reg "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters"      "AutoShareWks"              1 "DWord" "AutoShareWks"
    LF-Reg "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters"      "AutoShareServer"           1 "DWord" "AutoShareServer"
    LF-Reg "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"                           "LmCompatibilityLevel"      1 "DWord" "LM Compatibility Level"
    LF-Reg "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"                           "RestrictAnonymous"         0 "DWord" "RestrictAnonymous"
    LF-Reg "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"                           "RestrictAnonymousSAM"      0 "DWord" "RestrictAnonymousSAM"
    LF-Reg "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"                           "everyoneincludesanonymous" 1 "DWord" "EveryoneIncludesAnonymous"

    # S7: IPv6
    LF-Log "S7: IPv6 Disable (24H2 Fix)" "HEAD"
    try {
        foreach ($v6 in (Get-NetAdapterBinding -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue)) {
            if ($v6.Enabled) {
                Disable-NetAdapterBinding -Name $v6.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
                LF-Log "IPv6 disabled: $($v6.Name)"
            } else { LF-Log "IPv6 pehle se disabled: $($v6.Name)" "SKIP" }
        }
    } catch { LF-Log "IPv6: $($_.Exception.Message)" "FAIL" }

    # S8: NIC POWER
    LF-Log "S8: NIC Power Management" "HEAD"
    try {
        $nicBase = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E972-E325-11CE-BFC1-08002BE10318}"
        Get-ChildItem $nicBase -ErrorAction SilentlyContinue | ForEach-Object {
            Set-ItemProperty -Path $_.PSPath -Name "*PnPCapabilities" -Value 24 -Type DWord -ErrorAction SilentlyContinue
        }
        LF-Log "NIC adapter sleep disabled"
    } catch { LF-Log "NIC Power: $($_.Exception.Message)" "FAIL" }

    # S9: GUEST ACCOUNT
    LF-Log "S9: Guest Account" "HEAD"
    try {
        $guest = Get-LocalUser -Name "Guest" -ErrorAction SilentlyContinue
        if ($null -ne $guest) {
            $null = net user Guest "" 2>&1
            LF-Log "Guest account password blank set kar diya"
        } else { LF-Log "Guest account exist nahi karta" "SKIP" }
    } catch { LF-Log "Guest: $($_.Exception.Message)" "FAIL" }

    # S10: DNS + RESTART
    LF-Log "S10: DNS Flush + Services Restart" "HEAD"
    $null = ipconfig /flushdns 2>&1
    LF-Log "DNS cache flush kar diya"
    foreach ($sn in @("LanmanServer","LanmanWorkstation","FDResPub","fdPHost","SSDPSRV","upnphost","NlaSvc")) {
        try {
            Restart-Service -Name $sn -Force -ErrorAction Stop
            LF-Log "$sn restarted"
        } catch { LF-Log "$sn restart skip" "SKIP" }
    }

    # S11: WORKGROUP
    LF-Log "S11: Workgroup Check" "HEAD"
    try {
        $cs = Get-WmiObject Win32_ComputerSystem
        LF-Log "PC: $($env:COMPUTERNAME)  |  Workgroup: $($cs.Workgroup)" "INFO"
        if ($cs.Workgroup -ne "WORKGROUP") {
            LF-Log "WARNING: Sab PCs pe same workgroup hona chahiye!" "INFO"
        } else { LF-Log "Workgroup WORKGROUP sahi hai" "SKIP" }
    } catch { LF-Log "Workgroup: $($_.Exception.Message)" "FAIL" }

    # S12: PORT TEST
    LF-Log "S12: Port 445 Test" "HEAD"
    try {
        $pt = Test-NetConnection -ComputerName "127.0.0.1" -Port 445 -InformationLevel Quiet -WarningAction SilentlyContinue
        if ($pt) { LF-Log "Port 445 (SMB) OPEN hai" }
        else { LF-Log "Port 445 closed - restart ke baad theek hoga" "FAIL" }
    } catch { LF-Log "Port test: $($_.Exception.Message)" "FAIL" }

    # SUMMARY
    Write-Host ""
    Write-Host "  +----------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |  RESULT SUMMARY                             |" -ForegroundColor Cyan
    Write-Host "  +----------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  | Fixed   : $($lf_ok.ToString().PadRight(35))|" -ForegroundColor Green
    Write-Host "  | Skipped : $($lf_skip.ToString().PadRight(35))|" -ForegroundColor Cyan
    Write-Host "  | Failed  : $($lf_fail.ToString().PadRight(35))|" -ForegroundColor Red
    Write-Host "  +----------------------------------------------+" -ForegroundColor Cyan
    if ($lf_fail -gt 0) {
        Write-Host ""
        Write-Host "  FAILED ITEMS:" -ForegroundColor Red
        $lf_log | Where-Object { $_.StartsWith("[FAIL]") } | ForEach-Object {
            Write-Host "   $([char]0x2022) $_" -ForegroundColor Red
        }
    }

    # LOG SAVE
    $logD  = Get-Date -Format "yyyyMMdd_HHmm"
    $logD2 = Get-Date -Format "dd-MM-yyyy HH:mm:ss"
    $logP  = "$env:USERPROFILE\Desktop\LAN_Fix_$($env:COMPUTERNAME)_$logD.txt"
    try {
        $h = "LAN Sharing Fix Log`r`nPC: $($env:COMPUTERNAME)`r`nDate: $logD2`r`n" + ("=" * 50)
        "$h`r`n$($lf_log -join "`r`n")" | Out-File -FilePath $logP -Encoding UTF8
        Write-Host ""
        Write-Host "  Log saved: $logP" -ForegroundColor Yellow
    } catch {}

    Write-Host ""
    Write-Host "  +----------------------------------------------+" -ForegroundColor Yellow
    Write-Host "  |  PC restart karo - changes apply karne ke  |" -ForegroundColor Yellow
    Write-Host "  |  liye restart zaroori hai.                  |" -ForegroundColor Yellow
    Write-Host "  +----------------------------------------------+" -ForegroundColor Yellow
    Write-Host ""
    $rst = Read-Host "  Restart karna hai? (Y/N)"
    if ($rst -eq "Y" -or $rst -eq "y") {
        Write-Host "  Restarting..." -ForegroundColor Yellow
        Start-Sleep -Seconds 2
        Restart-Computer -Force
    }
}

Invoke-LanFix
