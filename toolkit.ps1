# ==============================================================
#   IT FIX TOOLKIT - MAIN LAUNCHER
#   Created by : Salman | Coaching Depot, Kanpur Central - NCR
#   YE FILE KABHI MAT BADLNA.
# ==============================================================

$BASE_URL    = "https://raw.githubusercontent.com/unitrix2/toolkit/main"
$TOOLKIT_URL = "$BASE_URL/toolkit.ps1"
$MENU_URL    = "$BASE_URL/menu.txt"

# ---- ADMIN ELEVATION ----
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "  Admin rights required - UAC prompt incoming..." -ForegroundColor Yellow
    $cmd = "irm '$TOOLKIT_URL' | iex"
    Start-Process PowerShell -ArgumentList "-NoProfile -NoExit -ExecutionPolicy Bypass -Command `"$cmd`"" -Verb RunAs
    exit
}

Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

# ---- CONSOLE SETUP ----
try {
    $Host.UI.RawUI.WindowTitle = "IT Fix Toolkit - by Salman"
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

# ---- WRITE HELPERS ----
function Write-Color {
    param([string]$Text, [ConsoleColor]$Color = 'White', [switch]$NoNewline)
    if ($NoNewline) { Write-Host $Text -ForegroundColor $Color -NoNewline }
    else { Write-Host $Text -ForegroundColor $Color }
}

function Write-Line {
    param([ConsoleColor]$Color = 'DarkGray')
    Write-Color "   +----+---------------------------------------------------+" $Color
}

function Show-Header {
    Clear-Host
    Write-Host ""
    Write-Color "   =========================================================" Cyan
    Write-Color "   |                                                       |" Cyan
    Write-Color "   |          IT  FIX  TOOLKIT   v2.0                      |" Cyan
    Write-Color "   |          by Salman  |  Coaching Depot                  |" Cyan
    Write-Color "   |          Kanpur Central - NCR                         |" Cyan
    Write-Color "   |                                                       |" Cyan
    Write-Color "   =========================================================" Cyan
    Write-Host ""

    # System Info Bar
    $pcName  = $env:COMPUTERNAME
    $userName = $env:USERNAME
    $date = Get-Date -Format "dd-MMM-yyyy  hh:mm tt"
    Write-Color "   PC: " DarkCyan -NoNewline
    Write-Color "$pcName" Green -NoNewline
    Write-Color "   |   User: " DarkCyan -NoNewline
    Write-Color "$userName" Green -NoNewline
    Write-Color "   |   $date" DarkGray
    Write-Host ""
}

function Load-Menu {
    $raw   = irm $MENU_URL -ErrorAction Stop
    $items = [System.Collections.Generic.List[object]]::new()
    $i = 1
    foreach ($line in ($raw -split "`n")) {
        $line = $line.Trim().TrimEnd("`r")
        if ($line -eq "" -or $line.StartsWith("#")) { continue }
        $parts = $line -split "\|"
        if ($parts.Count -ge 2) {
            $items.Add([PSCustomObject]@{ Num=$i; Label=$parts[0].Trim(); File=$parts[1].Trim() })
            $i++
        }
    }
    return $items
}

$running = $true
while ($running) {
    Show-Header
    try { $menuItems = Load-Menu }
    catch {
        Write-Host ""
        Write-Color "   [ERROR] menu.txt failed to load: $($_.Exception.Message)" Red
        Write-Color "   Check GitHub repo and internet connection." Yellow
        Read-Host "`n   Press Enter to retry"
        continue
    }

    # ---- TABLE HEADER ----
    Write-Line DarkCyan
    Write-Color "   | " DarkCyan -NoNewline
    Write-Color " #  " White -NoNewline
    Write-Color "| " DarkCyan -NoNewline
    Write-Color "TOOL                                              " White -NoNewline
    Write-Color "|" DarkCyan
    Write-Line DarkCyan

    # ---- MENU ITEMS ----
    foreach ($item in $menuItems) {
        $num = (" {0} " -f $item.Num).PadLeft(4)
        $label = $item.Label.PadRight(50)
        if ($label.Length -gt 50) { $label = $label.Substring(0, 47) + "..." }

        Write-Color "   | " DarkCyan -NoNewline
        Write-Color $num Cyan -NoNewline
        Write-Color "| " DarkCyan -NoNewline
        Write-Color $label Green -NoNewline
        Write-Color "|" DarkCyan
    }

    # ---- EXIT ROW ----
    Write-Line DarkCyan
    Write-Color "   | " DarkCyan -NoNewline
    Write-Color " 0  " Red -NoNewline
    Write-Color "| " DarkCyan -NoNewline
    Write-Color "Exit                                              " DarkGray -NoNewline
    Write-Color "|" DarkCyan
    Write-Line DarkCyan

    Write-Host ""
    Write-Color "   Select option and press Enter:" White -NoNewline
    $choice = Read-Host " "

    if ($choice -eq "0") { $running = $false; continue }

    $intChoice = 0
    if (-not [int]::TryParse($choice, [ref]$intChoice)) {
        Write-Color "   Invalid input." Red; Start-Sleep -Seconds 1; continue
    }

    $sel = $menuItems | Where-Object { $_.Num -eq $intChoice } | Select-Object -First 1
    if ($null -eq $sel) {
        Write-Color "   Invalid option." Red; Start-Sleep -Seconds 1; continue
    }

    try {
        Clear-Host
        Write-Host ""
        Write-Color "   =========================================================" Yellow
        Write-Color "    Loading: $($sel.Label)..." Yellow
        Write-Color "   =========================================================" Yellow
        Write-Host ""

        if ($sel.File -match "^https?://") {
            $featureUrl = $sel.File
        } else {
            $featureUrl = "$BASE_URL/$($sel.File)"
        }
        $featureCode = irm $featureUrl -ErrorAction Stop
        Invoke-Expression $featureCode
    } catch {
        Write-Color "   [ERROR] Feature failed to load: $($_.Exception.Message)" Red
        Read-Host "   Press Enter to continue"
    }
    Clear-Host
}

Clear-Host
Write-Host ""
Write-Color "   =========================================================" Cyan
Write-Color "    Goodbye!  -  IT Fix Toolkit by Salman" Cyan
Write-Color "   =========================================================" Cyan
Write-Host ""
