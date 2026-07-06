<#
===========================================================================
  CCL Setup Script
  Usage:  irm https://your-raw-github-url/Setup.ps1 | iex
  IMPORTANT: PowerShell ko "Run as Administrator" me kholo, warna account
             banana aur folder share karna kaam nahi karega.
===========================================================================
#>

# ==========================================================================
#  >>>>>>>>>>>>>>>>>>>>>  YAHAN APNI DETAILS BHARO  <<<<<<<<<<<<<<<<<<<<<<<<<
# ==========================================================================

# ----- Default local admin account (Option 1 -> 1) -----
$DefaultUser = "CNB"
$DefaultPass = "1234"

# ----- Remote connect ke liye credentials (har PC par CNB/1234 hona chahiye)
$ConnectUser = "CNB"
$ConnectPass = "1234"

# ----- Shared folder (har PC par D:\Shared banega aur "Shared" naam se share hoga)
$SharedPath  = "D:\Shared"
$ShareName   = "Shared"

# ----- Inbox drive letter (khud ke PC ka Shared) - hamesha I -----
$InboxLetter = "I"

# ----- DRIVE MAP: PC NAME wali list (Option 2 -> 1) -----
#   Name  = doosre PC ka naam   |   Label = drive ka naam jo "This PC" me dikhega
$PCMap = @(
    @{ Name = "CCL-PC2"; Label = "Mohit"  }
    @{ Name = "CCL-PC3"; Label = "Label3" }
    @{ Name = "CCL-PC4"; Label = "Label4" }
    @{ Name = "CCL-PC5"; Label = "Label5" }
    @{ Name = "CCL-PC6"; Label = "Label6" }
    @{ Name = "CCL-PC7"; Label = "Label7" }
    @{ Name = "CCL-PC8"; Label = "Label8" }
)

# ----- DRIVE MAP: IP wali list (Option 2 -> 2) -----
#   Last = IP ka aakhri number (series khud detect hogi)  |  Label = drive ka naam
$IPMap = @(
    @{ Last = 50; Label = "Mohit"   }
    @{ Last = 51; Label = "Label51" }
    @{ Last = 52; Label = "Label52" }
    @{ Last = 53; Label = "Label53" }
    @{ Last = 54; Label = "Label54" }
    @{ Last = 55; Label = "Label55" }
    @{ Last = 56; Label = "Label56" }
    @{ Last = 57; Label = "Label57" }
    @{ Last = 58; Label = "Label58" }
    @{ Last = 59; Label = "Label59" }
    @{ Last = 60; Label = "Label60" }
)

# ==========================================================================
#  >>>>>>>>>>>>>>>>>>>>  ISKE NEECHE KUCH MAT CHHEDO  <<<<<<<<<<<<<<<<<<<<<<<
# ==========================================================================

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Info { param($m) Write-Host $m -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host $m -ForegroundColor Green }
function Write-Warn { param($m) Write-Host $m -ForegroundColor Yellow }
function Write-Err  { param($m) Write-Host $m -ForegroundColor Red }

# --------------------------------------------------------------------------
#  D:\Shared banao + Everyone ko Full Access ke saath share karo
# --------------------------------------------------------------------------
function Ensure-Share {
    try {
        if (-not (Test-Path $SharedPath)) {
            New-Item -Path $SharedPath -ItemType Directory -Force | Out-Null
            Write-Ok "Folder banaya: $SharedPath"
        } else {
            Write-Info "Folder pehle se hai: $SharedPath"
        }

        # NTFS permission - Everyone Full Control
        icacls $SharedPath /grant "Everyone:(OI)(CI)F" /T /C | Out-Null

        $existing = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
        if ($existing) {
            if ($existing.Path -ne $SharedPath) {
                Remove-SmbShare -Name $ShareName -Force
                New-SmbShare -Name $ShareName -Path $SharedPath -FullAccess "Everyone" | Out-Null
            }
            Write-Info "Share pehle se hai: $ShareName"
        } else {
            New-SmbShare -Name $ShareName -Path $SharedPath -FullAccess "Everyone" | Out-Null
            Write-Ok "Share banaya: $ShareName -> $SharedPath (Everyone Full)"
        }
    } catch {
        Write-Err "Share setup fail: $($_.Exception.Message)"
    }
}

# --------------------------------------------------------------------------
#  Drive letter pool - I ke baad se (J..Z) jo free ho
# --------------------------------------------------------------------------
function Get-LetterPool {
    $used = @()
    Get-PSDrive -PSProvider FileSystem | ForEach-Object { $used += $_.Name.ToUpper() }
    (net use) 2>$null | ForEach-Object {
        if ($_ -match '([A-Za-z]):') { $used += $Matches[1].ToUpper() }
    }
    $pool = @()
    foreach ($c in [byte][char]'J'..[byte][char]'Z') {
        $L = [char]$c
        if ($used -notcontains "$L") { $pool += "$L" }
    }
    return $pool
}

# --------------------------------------------------------------------------
#  Ek network path ko drive letter par map karo
# --------------------------------------------------------------------------
function Map-One {
    param([string]$Letter, [string]$UNC, [string]$Label, [switch]$UseCreds)
    try {
        # letter pehle se mapped ho to hata do
        cmd /c "net use ${Letter}: /delete /y" 2>$null | Out-Null

        if ($UseCreds) {
            $host2 = $UNC.TrimStart('\').Split('\')[0]
            cmdkey /add:$host2 /user:$ConnectUser /pass:$ConnectPass | Out-Null
            $r = cmd /c "net use ${Letter}: `"$UNC`" /user:$ConnectUser $ConnectPass /persistent:yes" 2>&1
        } else {
            $r = cmd /c "net use ${Letter}: `"$UNC`" /persistent:yes" 2>&1
        }

        if ($LASTEXITCODE -eq 0) {
            try {
                $sh = New-Object -ComObject Shell.Application
                $sh.NameSpace("${Letter}:").Self.Name = $Label
            } catch {}
            Write-Ok  ("  {0}:  ->  {1}   [{2}]" -f $Letter, $UNC, $Label)
        } else {
            Write-Err ("  {0}:  FAIL  {1}  ({2})" -f $Letter, $UNC, ($r -join ' '))
        }
    } catch {
        Write-Err "  $Letter map error: $($_.Exception.Message)"
    }
}

# --------------------------------------------------------------------------
#  Inbox map (khud ke PC ka Shared -> I:)
# --------------------------------------------------------------------------
function Map-Inbox {
    Ensure-Share
    $unc = "\\$env:COMPUTERNAME\$ShareName"
    Write-Info "Inbox map ho raha hai..."
    Map-One -Letter $InboxLetter -UNC $unc -Label "Inbox"
}

# --------------------------------------------------------------------------
#  OPTION 2 -> 1 : PC NAME se drive map
# --------------------------------------------------------------------------
function Map-ByName {
    Map-Inbox
    $pool = Get-LetterPool
    $i = 0
    foreach ($e in $PCMap) {
        if ($i -ge $pool.Count) { Write-Warn "Drive letters khatam."; break }
        $letter = $pool[$i]; $i++
        $unc = "\\$($e.Name)\$ShareName"
        Map-One -Letter $letter -UNC $unc -Label $e.Label -UseCreds
    }
    Write-Ok "PC-name drive mapping complete."
}

# --------------------------------------------------------------------------
#  OPTION 2 -> 2 : IP se drive map (series auto-detect)
# --------------------------------------------------------------------------
function Map-ByIP {
    $ip = (Get-NetIPConfiguration | Where-Object {
              $_.IPv4DefaultGateway -ne $null -and $_.NetAdapter.Status -eq "Up"
          }).IPv4Address.IPAddress | Select-Object -First 1

    if (-not $ip) {
        $ip = (Get-NetIPAddress -AddressFamily IPv4 |
               Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.*" } |
               Select-Object -First 1).IPAddress
    }
    if (-not $ip) { Write-Err "IP detect nahi hui."; return }

    $prefix = ($ip -split '\.')[0..2] -join '.'
    Write-Info "Detected IP series: $prefix.x   (aapka IP: $ip)"

    Map-Inbox
    $pool = Get-LetterPool
    $i = 0
    foreach ($e in $IPMap) {
        if ($i -ge $pool.Count) { Write-Warn "Drive letters khatam."; break }
        $letter = $pool[$i]; $i++
        $target = "$prefix.$($e.Last)"
        $unc = "\\$target\$ShareName"
        Map-One -Letter $letter -UNC $unc -Label $e.Label -UseCreds
    }
    Write-Ok "IP drive mapping complete."
}

# --------------------------------------------------------------------------
#  OPTION 1 : Account manager
# --------------------------------------------------------------------------
function New-DefaultAdmin {
    try {
        $sec = ConvertTo-SecureString $DefaultPass -AsPlainText -Force
        if (Get-LocalUser -Name $DefaultUser -ErrorAction SilentlyContinue) {
            Set-LocalUser -Name $DefaultUser -Password $sec
            Write-Info "User pehle se tha, password reset kiya: $DefaultUser"
        } else {
            New-LocalUser -Name $DefaultUser -Password $sec -PasswordNeverExpires -AccountNeverExpires | Out-Null
            Write-Ok "User banaya: $DefaultUser"
        }
        Add-LocalGroupMember -Group "Administrators" -Member $DefaultUser -ErrorAction SilentlyContinue
        Write-Ok "$DefaultUser ko Administrators me daala. (pass: $DefaultPass)"
    } catch {
        Write-Err "Account fail: $($_.Exception.Message)"
    }
}

function New-ManualAccount {
    $u = Read-Host "Username daalo"
    if ([string]::IsNullOrWhiteSpace($u)) { Write-Warn "Username khali."; return }
    $p = Read-Host "Password daalo"
    Write-Host ""
    Write-Host "  Account type: [1] Normal  [2] Admin  [3] Guest" -ForegroundColor White
    $t = Read-Host "Choose (1/2/3)"
    try {
        $sec = ConvertTo-SecureString $p -AsPlainText -Force
        if (Get-LocalUser -Name $u -ErrorAction SilentlyContinue) {
            Set-LocalUser -Name $u -Password $sec
            Write-Info "User tha, password update kiya: $u"
        } else {
            New-LocalUser -Name $u -Password $sec -PasswordNeverExpires -AccountNeverExpires | Out-Null
            Write-Ok "User banaya: $u"
        }
        switch ($t) {
            "2" { Add-LocalGroupMember -Group "Administrators" -Member $u -ErrorAction SilentlyContinue
                  Write-Ok "$u -> Administrators" }
            "3" { Add-LocalGroupMember -Group "Guests" -Member $u -ErrorAction SilentlyContinue
                  Write-Ok "$u -> Guests" }
            default { Add-LocalGroupMember -Group "Users" -Member $u -ErrorAction SilentlyContinue
                  Write-Ok "$u -> Users (Normal)" }
        }
    } catch {
        Write-Err "Account fail: $($_.Exception.Message)"
    }
}

function Menu-Account {
    Write-Host ""
    Write-Host "  --- Account Manager ---" -ForegroundColor Magenta
    Write-Host "   1) Default local admin ($DefaultUser / $DefaultPass)"
    Write-Host "   2) Manual account (username/password/type khud daalo)"
    $c = Read-Host "  Choose"
    switch ($c) {
        "1" { New-DefaultAdmin }
        "2" { New-ManualAccount }
        default { Write-Warn "Galat choice." }
    }
}

# --------------------------------------------------------------------------
#  OPTION 2 : Drive map menu
# --------------------------------------------------------------------------
function Menu-Drive {
    Write-Host ""
    Write-Host "  --- Drive Map ---" -ForegroundColor Magenta
    Write-Host "   1) PC NAME se map"
    Write-Host "   2) IP se map (series auto-detect)"
    $c = Read-Host "  Choose"
    switch ($c) {
        "1" { Map-ByName }
        "2" { Map-ByIP }
        default { Write-Warn "Galat choice." }
    }
}

# --------------------------------------------------------------------------
#  OPTION 3 : Clean sab kuch
# --------------------------------------------------------------------------
function Clean-All {
    Write-Host ""
    Write-Warn "Sab kuch clean ho raha hai..."

    # 1) Saari mapped drives hatao
    try {
        Get-SmbMapping -ErrorAction SilentlyContinue | Remove-SmbMapping -Force -ErrorAction SilentlyContinue
        cmd /c "net use * /delete /y" 2>$null | Out-Null
        Write-Ok "Mapped drives hata diye."
    } catch { Write-Err "Drive clean: $($_.Exception.Message)" }

    # 2) Stored credentials delete
    try {
        (cmdkey /list) 2>$null |
            Select-String "Target:" |
            ForEach-Object {
                $t = ($_ -replace ".*Target:\s*", "").Trim()
                if ($t) { cmdkey /delete:$t | Out-Null }
            }
        Write-Ok "Saved credentials delete kar diye."
    } catch { Write-Err "Cred clean: $($_.Exception.Message)" }

    # 3) SMB share remove (folder rahega)
    try {
        if (Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue) {
            Remove-SmbShare -Name $ShareName -Force
            Write-Ok "Share '$ShareName' hata diya (folder waisa hi hai)."
        } else { Write-Info "Koi '$ShareName' share nahi mila." }
    } catch { Write-Err "Share clean: $($_.Exception.Message)" }

    # 4) CNB account delete
    try {
        if (Get-LocalUser -Name $DefaultUser -ErrorAction SilentlyContinue) {
            Remove-LocalUser -Name $DefaultUser
            Write-Ok "Account '$DefaultUser' delete kar diya."
        } else { Write-Info "Account '$DefaultUser' mila hi nahi." }
    } catch { Write-Err "Account clean: $($_.Exception.Message)" }

    Write-Ok "Clean complete."
}

# --------------------------------------------------------------------------
#  MAIN MENU
# --------------------------------------------------------------------------
function Show-Menu {
    Write-Host ""
    Write-Host "===========================================" -ForegroundColor DarkCyan
    Write-Host "            CCL  SETUP  MENU" -ForegroundColor White
    Write-Host "===========================================" -ForegroundColor DarkCyan
    Write-Host "   1) Account Manager"
    Write-Host "   2) Drive Map"
    Write-Host "   3) Clean (sab hata do)"
    Write-Host "   0) Exit"
    Write-Host "-------------------------------------------" -ForegroundColor DarkCyan
}

if (-not (Test-Admin)) {
    Write-Warn "NOTE: Ye script Administrator me chalao warna account/share ban nahi payenge."
}

do {
    Show-Menu
    $choice = Read-Host "  Apna option choose karo"
    switch ($choice) {
        "1" { Menu-Account }
        "2" { Menu-Drive }
        "3" { Clean-All }
        "0" { Write-Info "Bye."; break }
        default { Write-Warn "Galat option, dobara try karo." }
    }
    if ($choice -ne "0") {
        Write-Host ""
        Read-Host "  Enter dabao menu par wapas jaane ke liye" | Out-Null
    }
} while ($choice -ne "0")
