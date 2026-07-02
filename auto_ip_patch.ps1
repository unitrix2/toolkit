# ==============================================================================
# Script Name: auto_ip_patch.ps1
# Description: Automatically detects PC Name, finds matching IP from hosts file,
#              configures Static IP on the active network adapter, and patches
#              the Windows hosts file.
# Features: Auto-Admin Elevation, Smart PC Name Matching, Static IP Config.
# ==============================================================================

# ---------------- CONFIGURATION ----------------
$PrefixLength = 24             # 24 means Subnet Mask 255.255.255.0
$Gateway      = "192.168.0.1"  # Default Gateway (Router IP)
$DnsServers   = @("8.8.8.8", "8.8.4.4") # Google DNS
# -----------------------------------------------

# 1. Admin privilege check
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "Admin permissions required. Relaunching as Administrator..." -ForegroundColor Yellow
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    Exit
}

Write-Host "--------------------------------------------------" -ForegroundColor Cyan
Write-Host "Auto IP & Hosts Patching Started..." -ForegroundColor Cyan
Write-Host "--------------------------------------------------" -ForegroundColor Cyan

# 2. Advanced Path Detection
$scriptUrl = ""

# Method A: Normal Execution
if ($MyInvocation.ScriptName) {
    $scriptUrl = $MyInvocation.ScriptName
} 
# Method B: via irm | iex
elseif ($MyInvocation.Line -and $MyInvocation.Line -match '(http[^\s''"]+)') {
    $scriptUrl = $Matches[1]
}
# Method C: via toolkit.ps1 ($featureUrl from parent scope)
elseif ($featureUrl -like "http*") {
    $scriptUrl = $featureUrl
}

# 3. Validate URL and set hosts file path
$githubHostsUrl = ""

if ($scriptUrl -like "http*") {
    $repoFolderUrl = $scriptUrl -replace "[^/]+\.ps1.*$", ""
    $githubHostsUrl = "${repoFolderUrl}hosts"
} else {
    $scriptDir = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($scriptDir)) {
        if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
            $scriptDir = (Get-Location).Path
        } else {
            $scriptDir = Split-Path -Path $PSCommandPath -Parent
        }
    }
    $githubHostsUrl = Join-Path -Path $scriptDir -ChildPath "hosts"
}

$localHostsPath = "$env:windir\System32\drivers\etc\hosts"
$backupHostsPath = "$env:windir\System32\drivers\etc\hosts.bak"

try {
    # 4. Read Data
    if ([string]::IsNullOrWhiteSpace($githubHostsUrl)) {
        throw "Could not determine the remote hosts file path."
    }

    Write-Host "Fetching hosts file from detected URL..." -ForegroundColor White
    $webClient = New-Object System.Net.WebClient
    $webClient.Encoding = [System.Text.Encoding]::UTF8
    
    if ($scriptUrl -like "http*") {
        $newHostsContent = $webClient.DownloadString($githubHostsUrl)
    } else {
        $newHostsContent = Get-Content -Path $githubHostsUrl -Raw
    }

    if ([string]::IsNullOrWhiteSpace($newHostsContent)) {
        throw "Downloaded content is empty or file not found."
    }

    # 5. Extract IP based on PC Name
    $pcName = $env:COMPUTERNAME
    $targetIp = $null

    Write-Host "Current PC Name: $pcName" -ForegroundColor Cyan
    Write-Host "Searching for $pcName in hosts file..." -ForegroundColor White

    foreach ($line in ($newHostsContent -split "`n")) {
        $cleanLine = $line.Trim()
        if ($cleanLine.StartsWith("#") -or $cleanLine -eq "") { continue }
        
        $parts = $cleanLine -split "\s+"
        # Match PC Name (Case Insensitive)
        if ($parts.Count -ge 2 -and $parts[1] -ieq $pcName) {
            $targetIp = $parts[0]
            break
        }
    }

    if ($targetIp) {
        Write-Host "Found IP for $pcName: $targetIp" -ForegroundColor Green
        
        # 6. Apply Static IP to active adapter
        $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.Virtual -eq $false -and $_.MacAddress } | Select-Object -First 1
        
        if ($adapter) {
            Write-Host "Configuring Static IP on adapter '$($adapter.Name)'..." -ForegroundColor Yellow
            
            # Enable static IP configuration
            Set-NetIPInterface -InterfaceAlias $adapter.Name -Dhcp Disabled -ErrorAction SilentlyContinue
            
            # Remove old IP and route
            Remove-NetIPAddress -InterfaceAlias $adapter.Name -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
            Remove-NetRoute -InterfaceAlias $adapter.Name -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
            
            # Add New IP and Gateway
            New-NetIPAddress -InterfaceAlias $adapter.Name -IPAddress $targetIp -PrefixLength $PrefixLength -DefaultGateway $Gateway -ErrorAction SilentlyContinue | Out-Null
            
            # Set DNS
            Set-DnsClientServerAddress -InterfaceAlias $adapter.Name -ServerAddresses $DnsServers -ErrorAction SilentlyContinue
            
            Write-Host "Static IP Configuration Applied!" -ForegroundColor Green
        } else {
            Write-Host "No active physical network adapter found to apply IP." -ForegroundColor Red
        }
    } else {
        Write-Host "No IP mapping found for PC Name '$pcName' in the hosts file." -ForegroundColor Red
        Write-Host "Skipping Static IP configuration." -ForegroundColor Yellow
    }

    # 7. Backup and Patch the Hosts file
    if (Test-Path $localHostsPath) {
        Copy-Item -Path $localHostsPath -Destination $backupHostsPath -Force -ErrorAction SilentlyContinue
    }

    Write-Host "Applying new local IP mappings to Windows..." -ForegroundColor White
    Set-Content -Path $localHostsPath -Value $newHostsContent -Encoding UTF8 -Force -ErrorAction Stop
    
    Write-Host "--------------------------------------------------" -ForegroundColor Green
    Write-Host "SUCCESS: PC IP and Hosts File successfully patched!" -ForegroundColor Green
    Write-Host "--------------------------------------------------" -ForegroundColor Green

} catch {
    Write-Host "--------------------------------------------------" -ForegroundColor Red
    Write-Host "[ERR] Failed: $_" -ForegroundColor Red
    Write-Host "--------------------------------------------------" -ForegroundColor Red
}

Read-Host "Press Enter to exit"
