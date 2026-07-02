# ==============================================================================
# Script Name: manual_ip_patch.ps1
# Description: Downloads hosts file, lists all IP mappings, allows the user to
#              select one (or enter a custom IP), sets it as Static IP, and
#              patches the Windows hosts file.
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
Write-Host "Manual IP & Hosts Patching Started..." -ForegroundColor Cyan
Write-Host "--------------------------------------------------" -ForegroundColor Cyan

# 2. Advanced Path Detection
$scriptUrl = ""

if ($MyInvocation.ScriptName) {
    $scriptUrl = $MyInvocation.ScriptName
} elseif ($MyInvocation.Line -and $MyInvocation.Line -match '(http[^\s''"]+)') {
    $scriptUrl = $Matches[1]
} elseif ($featureUrl -like "http*") {
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

    # 5. Extract all IPs and display Menu
    $ipList = @()
    $counter = 1

    foreach ($line in ($newHostsContent -split "`n")) {
        $cleanLine = $line.Trim()
        if ($cleanLine.StartsWith("#") -or $cleanLine -eq "") { continue }
        
        $parts = $cleanLine -split "\s+"
        if ($parts.Count -ge 2) {
            $ipList += [PSCustomObject]@{ Id = $counter; IP = $parts[0]; Name = $parts[1] }
            $counter++
        }
    }

    Write-Host "`nAVAILABLE IPs FROM HOSTS FILE:" -ForegroundColor Cyan
    Write-Host "--------------------------------------------------" -ForegroundColor DarkCyan
    
    foreach ($item in $ipList) {
        Write-Host ("  [{0}] {1}`t- {2}" -f $item.Id, $item.IP, $item.Name) -ForegroundColor Green
    }
    
    Write-Host "--------------------------------------------------" -ForegroundColor DarkCyan
    Write-Host "  [C] Custom IP Address (Manual Entry)" -ForegroundColor Yellow
    Write-Host "  [0] Exit / Cancel" -ForegroundColor Red
    Write-Host "--------------------------------------------------" -ForegroundColor DarkCyan

    $choice = Read-Host "`nEnter your choice (Number, C, or 0)"
    $targetIp = $null

    if ($choice -eq '0') {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        Start-Sleep -Seconds 2
        Exit
    } elseif ($choice -match '^[cC]$') {
        $targetIp = Read-Host "Enter Custom IP Address (e.g., 192.168.0.251)"
        if (-not ($targetIp -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$')) {
            throw "Invalid IP Address format entered."
        }
    } else {
        $intChoice = 0
        if ([int]::TryParse($choice, [ref]$intChoice)) {
            $selectedItem = $ipList | Where-Object { $_.Id -eq $intChoice }
            if ($selectedItem) {
                $targetIp = $selectedItem.IP
            } else {
                throw "Invalid option selected."
            }
        } else {
            throw "Invalid input."
        }
    }

    # 6. Apply Static IP
    if ($targetIp) {
        Write-Host "`nPreparing to set Static IP: $targetIp" -ForegroundColor Cyan
        
        $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.Virtual -eq $false -and $_.MacAddress } | Select-Object -First 1
        
        if ($adapter) {
            Write-Host "Configuring adapter '$($adapter.Name)'..." -ForegroundColor Yellow
            
            # Disable DHCP
            Set-NetIPInterface -InterfaceAlias $adapter.Name -Dhcp Disabled -ErrorAction SilentlyContinue
            
            # Remove old IP and route
            Remove-NetIPAddress -InterfaceAlias $adapter.Name -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
            Remove-NetRoute -InterfaceAlias $adapter.Name -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
            
            # Set New IP
            New-NetIPAddress -InterfaceAlias $adapter.Name -IPAddress $targetIp -PrefixLength $PrefixLength -DefaultGateway $Gateway -ErrorAction SilentlyContinue | Out-Null
            
            # Set DNS
            Set-DnsClientServerAddress -InterfaceAlias $adapter.Name -ServerAddresses $DnsServers -ErrorAction SilentlyContinue
            
            Write-Host "Static IP $targetIp Configured Successfully!" -ForegroundColor Green
        } else {
            Write-Host "No active physical network adapter found!" -ForegroundColor Red
        }
    }

    # 7. Backup and Patch the Hosts file
    if (Test-Path $localHostsPath) {
        Copy-Item -Path $localHostsPath -Destination $backupHostsPath -Force -ErrorAction SilentlyContinue
    }

    Write-Host "`nApplying local IP mappings (hosts file) to Windows..." -ForegroundColor White
    Set-Content -Path $localHostsPath -Value $newHostsContent -Encoding UTF8 -Force -ErrorAction Stop
    
    Write-Host "--------------------------------------------------" -ForegroundColor Green
    Write-Host "SUCCESS: PC IP and Hosts File successfully patched!" -ForegroundColor Green
    Write-Host "--------------------------------------------------" -ForegroundColor Green

} catch {
    Write-Host "--------------------------------------------------" -ForegroundColor Red
    Write-Host "[ERR] Failed: $_" -ForegroundColor Red
    Write-Host "--------------------------------------------------" -ForegroundColor Red
}

Read-Host "`nPress Enter to exit"
