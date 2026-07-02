# ==============================================================================
# Script Name: patch_hosts.ps1
# Version: 2.0 (Fixed Empty String Path Error)
# Description: Automatically detects its remote URL even when executed via 
#              'irm | iex' in memory, and patches the local Windows hosts file.
# Features: Auto-Admin Elevation, Safe Backup (.bak), Robust Path Detection.
# ==============================================================================

# 1. एडमिन प्रिविलेज चेक (विंडोज सिस्टम फाइल बदलने के लिए ज़रूरी है)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "Admin permissions required. Relaunching as Administrator..." -ForegroundColor Yellow
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    Exit
}

Write-Host "--------------------------------------------------" -ForegroundColor Cyan
Write-Host "Network Hosts Auto-Patching Started..." -ForegroundColor Cyan
Write-Host "--------------------------------------------------" -ForegroundColor Cyan

# 2. एडवांस पाथ डिटेक्शन (Error Fix Logic)
$scriptUrl = ""

# तरीका A: अगर स्क्रिप्ट सामान्य रूप से चल रही है
if ($MyInvocation.ScriptName) {
    $scriptUrl = $MyInvocation.ScriptName
} 
# तरीका B: अगर स्क्रिप्ट irm | iex (RAM Memory) के ज़रिए चल रही है
elseif ($MyInvocation.Line) {
    # Line कमांड में से URL को एक्सट्रैक्ट करना (जैसे irm "URL" | iex)
    if ($MyInvocation.Line -match '"(http[^"]+)"' -or $MyInvocation.Line -match "'(http[^']+)'") {
        $scriptUrl = $Matches[1]
    }
}

# 3. यूआरएल को वैलिडेट करना और 'hosts' फ़ाइल का पाथ सेट करना
$githubHostsUrl = ""

if ($scriptUrl -like "http*") {
    # स्क्रिप्ट के नाम को हटाकर फोल्डर का पाथ निकालना और 'hosts' जोड़ना
    $repoFolderUrl = $scriptUrl -replace "patch_hosts\.ps1.*$", ""
    $githubHostsUrl = "${repoFolderUrl}hosts"
} else {
    # अगर लोकल टेस्टिंग कर रहे हैं
    $githubHostsUrl = Join-Path -Path (Split-Path -Path $PSCommandPath -Parent) -ChildPath "hosts"
}

# लोकल सिस्टम के पाथ्स
$localHostsPath = "$env:windir\System32\drivers\etc\hosts"
$backupHostsPath = "$env:windir\System32\drivers\etc\hosts.bak"

try {
    # 4. डेटा रीड करना (चेक करना कि पाथ खाली तो नहीं है)
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

    # 5. पुरानी फ़ाइल का सुरक्षित .bak बैकअप बनाना
    if (Test-Path $localHostsPath) {
        Write-Host "Creating safety backup of current hosts file..." -ForegroundColor White
        Copy-Item -Path $localHostsPath -Destination $backupHostsPath -Force -ErrorAction Stop
        Write-Host "Backup successfully saved at: $backupHostsPath" -ForegroundColor Green
    }

    # 6. नई फ़ाइल को सिस्टम में ओवरराइट (पैच) करना
    Write-Host "Applying new local IP mappings to Windows..." -ForegroundColor White
    Set-Content -Path $localHostsPath -Value $newHostsContent -Encoding UTF8 -Force -ErrorAction Stop
    
    Write-Host "--------------------------------------------------" -ForegroundColor Green
    Write-Host "SUCCESS: System successfully patched!" -ForegroundColor Green
    Write-Host "PCs and Printers will now communicate without Router." -ForegroundColor Green
    Write-Host "--------------------------------------------------" -ForegroundColor Green

} catch {
    Write-Host "--------------------------------------------------" -ForegroundColor Red
    Write-Host "[ERR] Feature load nahi hua: $_" -ForegroundColor Red
    Write-Host "--------------------------------------------------" -ForegroundColor Red
}

# स्क्रीन को होल्ड रखने के लिए
Read-Host "Enter dabao"
