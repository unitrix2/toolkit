# ==============================================================================
# Script Name: patch_hosts.ps1
# Version: 2.0 (Fixed Empty String Path Error)
# Description: Automatically detects its remote URL even when executed via 
#              'irm | iex' in memory, and patches the local Windows hosts file.
# Features: Auto-Admin Elevation, Safe Backup (.bak), Robust Path Detection.
# ==============================================================================

# 1. Admin privilege check (Required to modify Windows system files)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "Admin permissions required. Relaunching as Administrator..." -ForegroundColor Yellow
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    Exit
}

Write-Host "--------------------------------------------------" -ForegroundColor Cyan
Write-Host "Network Hosts Auto-Patching Started..." -ForegroundColor Cyan
Write-Host "--------------------------------------------------" -ForegroundColor Cyan

# 2. Advanced Path Detection (Error Fix Logic)
$scriptUrl = ""

# Method A: If the script is running normally
if ($MyInvocation.ScriptName) {
    $scriptUrl = $MyInvocation.ScriptName
} 
# Method B: If the script is running via irm | iex (RAM Memory)
elseif ($MyInvocation.Line) {
    # Extract the URL from the command line (e.g. irm "URL" | iex)
    if ($MyInvocation.Line -match '(http[^\s''"]+)') {
        $scriptUrl = $Matches[1]
    }
}

# 3. Validate the URL and set the path for the 'hosts' file
$githubHostsUrl = ""

if ($scriptUrl -like "http*") {
    # Remove the script name to get the folder URL and append 'hosts'
    $repoFolderUrl = $scriptUrl -replace "patch_hosts\.ps1.*$", ""
    $githubHostsUrl = "${repoFolderUrl}hosts"
} else {
    # If running locally for testing
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

# Local system paths
$localHostsPath = "$env:windir\System32\drivers\etc\hosts"
$backupHostsPath = "$env:windir\System32\drivers\etc\hosts.bak"

try {
    # 4. Read data (check that the path is not empty)
    if ([string]::IsNullOrWhiteSpace($githubHostsUrl)) {
        throw "Could not determine the remote hosts file path. Parameter 'Path' is empty."
    }

    Write-Host "Fetching adjacent hosts file from detected URL..." -ForegroundColor White
    $webClient = New-Object System.Net.WebClient
    $webClient.Encoding = [System.Text.Encoding]::UTF8
    
    if ($scriptUrl -like "http*") {
        $newHostsContent = $webClient.DownloadString($githubHostsUrl)
    } else {
        $newHostsContent = Get-Content -Path $githubHostsUrl -Raw
    }

    if ([string]::IsNullOrWhiteSpace($newHostsContent)) {
        throw "Downloaded content is empty or file not found on GitHub."
    }

    # 5. Create a safe .bak backup of the old file
    if (Test-Path $localHostsPath) {
        Write-Host "Creating safety backup of current hosts file..." -ForegroundColor White
        Copy-Item -Path $localHostsPath -Destination $backupHostsPath -Force -ErrorAction Stop
        Write-Host "Backup successfully saved at: $backupHostsPath" -ForegroundColor Green
    }

    # 6. Overwrite (patch) the new file into the system
    Write-Host "Applying new local IP mappings to Windows..." -ForegroundColor White
    Set-Content -Path $localHostsPath -Value $newHostsContent -Encoding UTF8 -Force -ErrorAction Stop
    
    Write-Host "--------------------------------------------------" -ForegroundColor Green
    Write-Host "SUCCESS: System successfully patched!" -ForegroundColor Green
    Write-Host "PCs and Printers will now communicate without Router." -ForegroundColor Green
    Write-Host "--------------------------------------------------" -ForegroundColor Green

} catch {
    Write-Host "--------------------------------------------------" -ForegroundColor Red
    Write-Host "[ERR] Feature failed to load: $_" -ForegroundColor Red
    Write-Host "--------------------------------------------------" -ForegroundColor Red
}

# Hold the screen so it doesn't close immediately
Read-Host "Press Enter to exit"
