# ==============================================================================
# Script Name: reset_ip_dhcp.ps1
# Description: Resets the active network adapter's IP and DNS settings from 
#              Static back to Automatic (DHCP).
# ==============================================================================

# 1. Admin privilege check
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "Admin permissions required. Relaunching as Administrator..." -ForegroundColor Yellow
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    Exit
}

Write-Host "--------------------------------------------------" -ForegroundColor Cyan
Write-Host "Resetting IP to Automatic (DHCP)..." -ForegroundColor Cyan
Write-Host "--------------------------------------------------" -ForegroundColor Cyan

try {
    # Find active physical network adapter
    $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.Virtual -eq $false -and $_.MacAddress } | Select-Object -First 1

    if ($adapter) {
        Write-Host "Found active adapter: '$($adapter.Name)'" -ForegroundColor White
        Write-Host "Configuring adapter to obtain IP and DNS automatically..." -ForegroundColor Yellow

        # Enable DHCP for IP
        Set-NetIPInterface -InterfaceAlias $adapter.Name -Dhcp Enabled -ErrorAction Stop
        
        # Reset DNS to obtain automatically
        Set-DnsClientServerAddress -InterfaceAlias $adapter.Name -ResetServerAddresses -ErrorAction Stop

        Write-Host "--------------------------------------------------" -ForegroundColor Green
        Write-Host "SUCCESS: IP and DNS are now set to Automatic (DHCP)!" -ForegroundColor Green
        Write-Host "--------------------------------------------------" -ForegroundColor Green
    } else {
        Write-Host "No active physical network adapter found to reset." -ForegroundColor Red
    }
} catch {
    Write-Host "--------------------------------------------------" -ForegroundColor Red
    Write-Host "[ERR] Failed to reset IP: $_" -ForegroundColor Red
    Write-Host "--------------------------------------------------" -ForegroundColor Red
}

Read-Host "`nPress Enter to exit"
