# =================================================================
#  install-mirror.ps1 - installs the update mirror on this PC (run as administrator)
#
#  This PC needs internet AND write access to the shared update folder.
#  It copies mirror.ps1 to C:\ProgramData\A-Delnaz-Mirror, writes mirror.json
#  and makes the scheduled task "A-Delnaz update mirror" (every hour and at start-up).
#  Run it again to change the folder or the account. Remove: -Uninstall
# =================================================================

param([switch]$Uninstall)

$ErrorActionPreference = "Stop"
$TaskName = "A-Delnaz update mirror"
$Target = Join-Path $env:ProgramData "A-Delnaz-Mirror"

function Say([string]$Text, [string]$Color = "Gray") { Write-Host $Text -ForegroundColor $Color }

try {
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) { throw "Run install-mirror.cmd as administrator (right click > Run as administrator)." }

    if ($Uninstall) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Say "Scheduled task removed. The files in $Target and in the shared folder were kept." Green
        exit 0
    }

    $config = Join-Path $Target "mirror.json"
    $current = $null
    if (Test-Path $config) { $current = Get-Content $config -Raw -Encoding UTF8 | ConvertFrom-Json }

    Say ""
    Say "Shared update folder (every product gets a subfolder in it)" Cyan
    Say "Example: \\fileserver\Updates" Gray
    if ($current) { Say "Now: $($current.share)   (Enter = keep)" Gray }
    $share = (Read-Host "Folder").Trim().Trim('"')
    if (-not $share -and $current) { $share = [string]$current.share }
    if (-not $share) { throw "No folder given." }

    Say ""
    Say "Which account runs the mirror? It needs WRITE rights on $share." Cyan
    Say "  Enter            = SYSTEM (the computer account $env:COMPUTERNAME$ needs write rights on the share)" Gray
    Say "  DOMAIN\user       = that account (its password is asked; it is kept by Windows, not in a file)" Gray
    $account = (Read-Host "Account").Trim()

    New-Item -ItemType Directory -Force -Path $Target | Out-Null
    Copy-Item (Join-Path $PSScriptRoot "mirror.ps1") $Target -Force
    $data = [ordered]@{ share = $share; products = @(); patterns = @("*.adup") }
    if ($current -and $current.products) { $data.products = @($current.products) }
    [IO.File]::WriteAllText($config, ($data | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))

    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$Target\mirror.ps1`" -Quiet" -WorkingDirectory $Target
    $hourly = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Days 3650)
    $boot = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 2)
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    if ($account) {
        # The password is asked here in this window (a separate Windows dialog often opens hidden behind it)
        $secure = Read-Host "Password of $account (not shown while typing)" -AsSecureString
        $plain = (New-Object System.Net.NetworkCredential("", $secure)).Password
        if (-not $plain) { throw "No password given." }
        # Check the account and password before the task is made
        Add-Type -AssemblyName System.DirectoryServices.AccountManagement
        $parts = $account -split "\\", 2
        $ctxType = if ($parts.Count -eq 2 -and $parts[0] -ne $env:COMPUTERNAME -and $parts[0] -ne ".") { "Domain" } else { "Machine" }
        $ctx = if ($ctxType -eq "Domain") { New-Object System.DirectoryServices.AccountManagement.PrincipalContext($ctxType, $parts[0]) } `
               else { New-Object System.DirectoryServices.AccountManagement.PrincipalContext($ctxType) }
        $userOnly = $parts[-1]
        if (-not $ctx.ValidateCredentials($userOnly, $plain)) { throw "User name or password of $account is not correct." }
        Say "Account and password are correct." Green
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($hourly, $boot) -Settings $settings `
            -User $account -Password $plain -RunLevel Highest | Out-Null
        $plain = $null
    } else {
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($hourly, $boot) -Settings $settings `
            -User "SYSTEM" -RunLevel Highest | Out-Null
    }
    Say ""
    Say "Installed. First run now ..." Green
    Start-ScheduledTask -TaskName $TaskName
    Say "Waiting for the first run (up to 60 seconds) ..." Gray
    for ($i = 0; $i -lt 12; $i++) {
        Start-Sleep -Seconds 5
        if ((Get-ScheduledTask -TaskName $TaskName).State -ne "Running" -and $i -ge 1) { break }
    }
    $log = Join-Path $Target "mirror.log"
    if (Test-Path $log) { Get-Content $log -Tail 10 | ForEach-Object { Say "   $_" } }
    Say ""
    Say "Log file:  $log" Gray
    Say "In every site: System update > Source = shared folder:  $share\<product>" Green
    exit 0
} catch {
    Say "ERROR: $($_.Exception.Message)" Red
    exit 1
}
