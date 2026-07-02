# ==============================================================================
# Script Name: patch_hosts.ps1
# Description: Automatically detects its own GitHub repository path, fetches the 
#              adjacent 'hosts' file, and patches the local Windows system.
# Features: Auto-Admin Elevation, Safe Backup (.bak), Smart Path Detection.
# ==============================================================================

# 1. एडमिन प्रिविलेज चेक (विंडोज सिस्टम फाइल बदलने के लिए ज़रूरी है)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "Admin permissions required. Relaunching as Administrator..." -ForegroundColor Yellow
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    Exit
}

# 2. स्मार्ट ऑटो-डिटेक्ट लॉजिक (यह स्क्रिप्ट के अपने रनिंग URL को खोजता है)
# जब आप irm | iex चलाते हैं, तो स्क्रिप्ट का सोर्स URL $MyInvocation.ScriptName में होता है
$scriptUrl = $MyInvocation.ScriptName

# डिफ़ॉल्ट रूप से अगर स्क्रिप्ट लोकल चल रही हो तो ये खाली हो सकता है, इसलिए चेक करना ज़रूरी है
if ($scriptUrl -like "http*") {
    # स्क्रिप्ट के URL से 'patch_hosts.ps1' का नाम हटाकर सिर्फ फोल्डर का पाथ निकालना
    $repoFolderUrl = $scriptUrl -replace "patch_hosts\.ps1.*$", ""
    # उसी फोल्डर पाथ के आगे 'hosts' फ़ाइल का नाम जोड़ना
    $githubHostsUrl = "${repoFolderUrl}hosts"
} else {
    # अगर आप टेस्टिंग के लिए इसे लोकल कंप्यूटर के सेम फोल्डर से चला रहे हैं
    $githubHostsUrl = Join-Path -Path $PSScriptRoot -ChildPath "hosts"
}

# लोकल सिस्टम के पाथ्स
$localHostsPath = "$env:windir\System32\drivers\etc\hosts"
$backupHostsPath = "$env:windir\System32\drivers\etc\hosts.bak"

Write-Host "--------------------------------------------------" -ForegroundColor Cyan
Write-Host "Network Hosts Auto-Patching Started..." -ForegroundColor Cyan
Write-Host "--------------------------------------------------" -ForegroundColor Cyan

try {
    # 3. गिटहब से बगल वाली hosts फ़ाइल का डेटा रीड करना
    Write-Host "Detecting and fetching adjacent hosts file..." -ForegroundColor White
    $webClient = New-Object System.Net.WebClient
    $webClient.Encoding = [System.Text.Encoding]::UTF8
    
    if ($scriptUrl -like "http*") {
        $newHostsContent = $webClient.DownloadString($githubHostsUrl)
    } else {
        $newHostsContent = Get-Content -Path $githubHostsUrl -Raw
    }

    if ([string]::IsNullOrWhiteSpace($newHostsContent)) {
        throw "Could not read data from the detected hosts file path."
    }

    # 4. पुरानी फ़ाइल का सुरक्षित .bak बैकअप बनाना
    if (Test-Path $localHostsPath) {
        Write-Host "Creating safety backup of current hosts file..." -ForegroundColor White
        Copy-Item -Path $localHostsPath -Destination $backupHostsPath -Force -ErrorAction Stop
        Write-Host "Backup successfully saved at: $backupHostsPath" -ForegroundColor Green
    }

    # 5. नई फ़ाइल को सिस्टम में ओवरराइट (पैच) करना
    Write-Host "Applying new local IP mappings to Windows..." -ForegroundColor White
    Set-Content -Path $localHostsPath -Value $newHostsContent -Encoding UTF8 -Force -ErrorAction Stop
    
    Write-Host "--------------------------------------------------" -ForegroundColor Green
    Write-Host "SUCCESS: System successfully patched!" -ForegroundColor Green
    Write-Host "PCs and Printers will now communicate without Router." -ForegroundColor Green
    Write-Host "--------------------------------------------------" -ForegroundColor Green

} catch {
    Write-Host "--------------------------------------------------" -ForegroundColor Red
    Write-Host "ERROR: Script failed to apply changes." -ForegroundColor Red
    Write-Host "Details: $_" -ForegroundColor Red
    Write-Host "--------------------------------------------------" -ForegroundColor Red
}

# स्क्रीन को होल्ड रखने के लिए
Read-Host "Press Enter to finish"