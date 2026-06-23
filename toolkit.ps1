# ==============================================================
#   IT FIX TOOLKIT - MAIN LAUNCHER
#   Created by : Salman
#   Dept       : Coaching Depot, Kanpur Central - NCR
# ==============================================================
#   YE FILE KABHI MAT BADLNA.
#   Naya feature add karna ho to:
#     1. Naya PS1 file GitHub pe upload karo
#     2. menu.txt mein ek line add karo  ->  Label|filename.ps1
# ==============================================================

$BASE_URL    = "https://raw.githubusercontent.com/unitrix2/toolkit/main"
$TOOLKIT_URL = "$BASE_URL/toolkit.ps1"
$MENU_URL    = "$BASE_URL/menu.txt"

# ---- ADMIN ELEVATION (irm | iex compatible + NoExit fix) ----
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "  Admin rights chahiye - UAC aa raha hai..." -ForegroundColor Yellow
    $cmd = "irm '$TOOLKIT_URL' | iex"
    Start-Process PowerShell -ArgumentList "-NoProfile -NoExit -ExecutionPolicy Bypass -Command `"$cmd`"" -Verb RunAs
    exit
}

Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

# ---- HEADER ----
function Show-Header {
    Clear-Host
    Write-Host ""
    Write-Host "  +------------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |        IT  FIX  TOOLKIT  -  by Salman                     |" -ForegroundColor Cyan
    Write-Host "  |        Coaching Depot, Kanpur Central - NCR               |" -ForegroundColor Cyan
    Write-Host "  +------------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host ""
}

# ---- LOAD MENU FROM menu.txt ----
function Load-Menu {
    $raw   = irm $MENU_URL -ErrorAction Stop
    $items = [System.Collections.Generic.List[object]]::new()
    $i = 1
    foreach ($line in ($raw -split "`n")) {
        $line = $line.Trim().TrimEnd("`r")
        if ($line -eq "" -or $line.StartsWith("#")) { continue }
        $parts = $line -split "\|"
        if ($parts.Count -ge 2) {
            $items.Add([PSCustomObject]@{
                Num   = $i
                Label = $parts[0].Trim()
                File  = $parts[1].Trim()
            })
            $i++
        }
    }
    return $items
}

# ---- MAIN LOOP ----
$running = $true
while ($running) {
    Show-Header
    try {
        $menuItems = Load-Menu
    } catch {
        Write-Host "  menu.txt load nahi hua: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  GitHub repo aur internet connection check karo." -ForegroundColor Yellow
        Write-Host ""
        Read-Host "  Enter dabao retry karne ke liye"
        continue
    }

    Write-Host "  SELECT OPTION:" -ForegroundColor White
    Write-Host ""
    foreach ($item in $menuItems) {
        Write-Host ("  [{0}]  {1}" -f $item.Num, $item.Label) -ForegroundColor Green
    }
    Write-Host ""
    Write-Host "  [0]  Exit" -ForegroundColor Red
    Write-Host ""
    Write-Host "  +------------------------------------------------------------+" -ForegroundColor DarkCyan
    $choice = Read-Host "  Option"

    if ($choice -eq "0") { $running = $false; continue }

    $intChoice = 0
    if (-not [int]::TryParse($choice, [ref]$intChoice)) {
        Write-Host "  Galat input." -ForegroundColor Red
        Start-Sleep -Seconds 1
        continue
    }

    $sel = $menuItems | Where-Object { $_.Num -eq $intChoice } | Select-Object -First 1
    if ($null -eq $sel) {
        Write-Host "  Galat option - dobara try karo." -ForegroundColor Red
        Start-Sleep -Seconds 1
        continue
    }

    try {
        Write-Host ""
        Write-Host "  Loading: $($sel.Label)..." -ForegroundColor Yellow
        $featureUrl  = "$BASE_URL/$($sel.File)"
        $featureCode = irm $featureUrl -ErrorAction Stop
        Invoke-Expression $featureCode
    } catch {
        Write-Host "  Feature load nahi hua: $($_.Exception.Message)" -ForegroundColor Red
        Read-Host "  Enter dabao"
    }
}

Write-Host ""
Write-Host "  Goodbye!  -  IT Fix Toolkit by Salman" -ForegroundColor Cyan
Write-Host ""
