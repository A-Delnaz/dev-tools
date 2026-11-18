# =================================================================
#  dev.ps1 v2.2.0 - one developer tool for every project
#
#  Started by dev.cmd in the project folder. This file is NOT copied
#  into projects: it lives in github.com/A-Delnaz/dev-tools and dev.cmd
#  keeps a copy in %LOCALAPPDATA%\dev-tools (updated on every start).
#
#  Project types (found automatically):
#    django   manage.py in the project folder
#    dotnet   a *.slnx / *.sln file in the project folder
#    other    anything else (git options only)
#
#  Per-project settings: dev.json in the project folder (all optional).
#  See dev.example.json and README.md in the dev-tools repository.
#
#  Command line (without a command the menu is shown):
#    dev.cmd start | run | pull | push | status | open | migrate | seed
#            build | history | publish | zip | <command of a tool in dev.json>
# =================================================================

param(
    [string]$Root = "",
    [string]$Command = ""
)

$ToolVersion = "2.2.0"
$ErrorActionPreference = "Continue"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$OutputEncoding = [System.Text.Encoding]::UTF8

if ([string]::IsNullOrWhiteSpace($Root)) { $Root = (Get-Location).Path }
$Root = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\', '/')
Set-Location -LiteralPath $Root

$ToolDir     = $PSScriptRoot
$Utf8NoBom   = New-Object System.Text.UTF8Encoding($false)
$ProjectName = Split-Path $Root -Leaf
$LocalDir    = Join-Path $Root ".local"              # files of this PC only (never committed)
$HistoryPath = Join-Path $LocalDir "update-history.jsonl"
$RequestPath = Join-Path $LocalDir "update-request.json"
$SeedStamp   = Join-Path $LocalDir "dev-seeded"
$DataDir     = Join-Path $env:LOCALAPPDATA "dev-tools-data"   # shared by all projects on this PC
$PortsFile   = Join-Path $DataDir "ports.json"

# Tells the project it runs on a developer PC (a project can then use a local test database)
$env:APP_DEV = "1"

# Python always reads and writes UTF-8 (Persian text). Without this, Python uses the old
# Windows code page (cp1256) when its output goes through this tool, and Persian text fails.
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"


# ---------------------------------------------------------------
#  Project settings (dev.json)
# ---------------------------------------------------------------

$Config = [pscustomobject]@{
    type              = "auto"     # auto | django | dotnet | other
    github_user       = "A-Delnaz"
    port              = 0          # 0 = choose a free port and save it in dev.json
    env               = $null      # extra environment variables: { "NAME": "value" }
    # Django
    python            = "3.13"
    setup_commands    = @()        # manage.py commands after every pull (must be safe to repeat)
    seed_commands     = @()        # manage.py commands for default data (once per database)
    # .NET
    dotnet_sdk        = ""         # required SDK major version, for example "10"
    launch_profile    = "http"
    restart_exit_code = 42         # the site exits with this code to ask for "pull, build, restart"
    # Publishing
    work_branch       = ""         # branch Claude writes to (for example "dev")
    publish_branch    = ""         # branch the servers install from (for example "main")
    release_mode      = ""         # "" = automatic | "branch" | "tag" | "none"
    # Update packages (.adup) of licensed products, see docs/UPDATES-AND-LICENSES.md
    product           = ""         # product id, for example "security-reports" (empty = not a licensed product)
    product_name      = ""         # for example "Security Reports"
    # Extra menu items: [{ "title": "...", "script": "path\\to\\script.ps1", "args": "...", "command": "name" }]
    tools             = @()
    secret_patterns   = @(".env", "*/.env", "*.sqlite3", "*.pfx", "*.key", "*.pem")
}
$ConfigFile = Join-Path $Root "dev.json"
if (Test-Path $ConfigFile) {
    try {
        $loaded = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $loaded.PSObject.Properties) {
            $Config | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
        }
    } catch {
        Write-Host "   dev.json is not valid JSON: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "   Using default settings." -ForegroundColor Yellow
    }
}

# Project type
$ProjectType = [string]$Config.type
if ($ProjectType -eq "auto" -or [string]::IsNullOrWhiteSpace($ProjectType)) {
    if (Test-Path (Join-Path $Root "manage.py")) { $ProjectType = "django" }
    elseif (Get-ChildItem $Root -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @(".slnx", ".sln") }) { $ProjectType = "dotnet" }
    else { $ProjectType = "other" }
}
$IsDjango = ($ProjectType -eq "django")
$IsDotnet = ($ProjectType -eq "dotnet")

# How a finished version reaches the servers
$ReleaseMode = [string]$Config.release_mode
if ([string]::IsNullOrWhiteSpace($ReleaseMode)) {
    if ($Config.work_branch -and $Config.publish_branch) { $ReleaseMode = "branch" } else { $ReleaseMode = "none" }
}

# Extra environment variables from dev.json
if ($Config.env) {
    foreach ($p in $Config.env.PSObject.Properties) { Set-Item -Path "Env:$($p.Name)" -Value ([string]$p.Value) }
}

# Python virtual environment: use "venv" or ".venv" if one exists, otherwise create "venv"
$VenvName = "venv"
foreach ($n in @("venv", ".venv")) {
    if (Test-Path (Join-Path $Root "$n\Scripts\python.exe")) { $VenvName = $n; break }
}
$VenvPython = Join-Path $Root "$VenvName\Scripts\python.exe"
$ReqFile    = Join-Path $Root "requirements.txt"
$ReqStamp   = Join-Path $Root "$VenvName\.requirements-hash"


# ---------------------------------------------------------------
#  Output helpers
# ---------------------------------------------------------------

function Write-Step([string]$Text) { Write-Host ""; Write-Host ">> $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "   $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "   $Text" -ForegroundColor Yellow }
function Write-Bad([string]$Text)  { Write-Host "   $Text" -ForegroundColor Red }
function Write-Info([string]$Text) { Write-Host "   $Text" }

# Run a command and stop if it fails
function Invoke-Step([string]$Title, [scriptblock]$Command) {
    & $Command | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Step '$Title' failed." }
}

# Ask a yes/no question. Enter = the default answer.
function Read-YesNo([string]$Question, [bool]$Default = $false) {
    $hint = "y/n"
    if ($Default) { $hint = "Y/n" } else { $hint = "y/N" }
    $a = Read-Host "   $Question ($hint)"
    if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
    return ($a.Trim() -match "^(y|yes)$")
}

function Write-Utf8File([string]$Path, [string]$Text) {
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}


# ---------------------------------------------------------------
#  Git helpers
# ---------------------------------------------------------------

$env:GIT_TERMINAL_PROMPT = "0"

# Run git and return its output lines (also the error lines). $script:GitExit has the exit code.
function Invoke-Git {
    $out = & git.exe -C $Root -c i18n.logOutputEncoding=UTF-8 -c core.quotepath=false @args 2>&1
    $script:GitExit = $LASTEXITCODE
    return @($out | ForEach-Object { "$_" })
}

# Run git quietly and return only success / failure
function Test-Git {
    Invoke-Git @args | Out-Null
    return ($script:GitExit -eq 0)
}

function Test-Repo     { return (Test-Path (Join-Path $Root ".git")) }
function Test-Remote   { return (Test-Git remote get-url origin) }
function Get-Head      { return (Invoke-Git rev-parse HEAD | Select-Object -First 1) }

function Get-Branch {
    $b = Invoke-Git rev-parse --abbrev-ref HEAD | Select-Object -First 1
    if ($script:GitExit -ne 0 -or -not $b -or $b -eq "HEAD") { return "main" }
    return $b.Trim()
}

function Get-Upstream {
    $u = Invoke-Git rev-parse --abbrev-ref --symbolic-full-name "@{u}" | Select-Object -First 1
    if ($script:GitExit -ne 0) { return $null }
    return $u.Trim()
}

# Changes to files git already tracks (new untracked files are not counted)
function Get-LocalChanges {
    return @(Invoke-Git status --porcelain --untracked-files=no | Where-Object { $_.Trim() -ne "" })
}

# Keep .local (files of this PC) out of git without touching .gitignore
function Initialize-LocalExclude {
    if (-not (Test-Repo)) { return }
    $exclude = Join-Path $Root ".git\info\exclude"
    $text = ""
    if (Test-Path $exclude) { $text = [System.IO.File]::ReadAllText($exclude) }
    if ($text -notmatch "(?m)^/?\.local/?\s*$") {
        $dir = Split-Path $exclude -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [System.IO.File]::AppendAllText($exclude, "`n# dev.cmd: files of this PC only`n.local/`n", $Utf8NoBom)
    }
}

# Create the git repo and connect it to GitHub if needed
function Initialize-Git {
    if (-not (Test-Repo)) {
        Write-Step "Creating git repository"
        Invoke-Step "git init" { git init }
        git branch -M main
        Initialize-LocalExclude
    }
    if (-not (Test-Remote)) {
        Write-Host ""
        Write-Warn "This project is not connected to GitHub yet."
        Write-Warn "First create an EMPTY repository on GitHub (no README)."
        $name = Read-Host "   GitHub repository name [$ProjectName]"
        if ([string]::IsNullOrWhiteSpace($name)) { $name = $ProjectName }
        $url = "https://github.com/$($Config.github_user)/$name.git"
        Invoke-Step "git remote add" { git remote add origin $url }
        Write-Ok "Connected to $url"
    }
}

# Git writes your name on every commit. Ask for it once per PC.
function Confirm-GitIdentity {
    if (Invoke-Git config user.name | Select-Object -First 1) { return }
    Write-Warn "Git does not know your name yet (it is written on every commit)."
    $n = Read-Host "   Your name"
    $e = Read-Host "   Your e-mail (the one on GitHub)"
    git config --global user.name $n
    git config --global user.email $e
}

# Link the local branch to GitHub if the branch already exists there
function Repair-Upstream {
    if (Get-Upstream) { return $true }
    if (-not (Test-Remote)) { return $false }
    $branch = Get-Branch
    if (Test-Git ls-remote --exit-code --heads origin $branch) {
        Invoke-Git fetch origin $branch | Out-Null
        if (Test-Git branch "--set-upstream-to=origin/$branch" $branch) { return $true }
    }
    return $false
}

# Use the work branch from dev.json (if there is one) instead of the publish branch
function Select-WorkBranch {
    $work = [string]$Config.work_branch
    if ([string]::IsNullOrWhiteSpace($work)) { return }
    if ((Get-Branch) -eq $work) { return }
    if ((Get-LocalChanges).Count -gt 0) {
        Write-Warn "You have unsaved changes on branch '$(Get-Branch)'. Use 'Finish work' first, then try again."
        throw "Could not switch to branch '$work'."
    }
    Write-Step "Switching to branch '$work'"
    Invoke-Git fetch origin | Out-Null
    if (Test-Git show-ref --verify --quiet "refs/heads/$work") {
        Invoke-Step "git checkout" { git checkout $work }
    } elseif (Test-Git ls-remote --exit-code --heads origin $work) {
        Invoke-Step "git checkout" { git checkout -b $work --track "origin/$work" }
    } else {
        Invoke-Step "git checkout" { git checkout -b $work }
        Invoke-Step "first push" { git push -u origin $work }
    }
    Write-Ok "Now on branch '$work'."
}

# Commits in a range, as objects (for the screen and the history file)
function Get-Commits([string]$Range) {
    $lines = Invoke-Git log --reverse "--format=%H%x1f%cI%x1f%s" $Range
    $list = @()
    foreach ($l in $lines) {
        $p = $l -split [char]0x1f
        if ($p.Count -ge 3) { $list += [pscustomobject]@{ sha = $p[0]; date = $p[1]; subject = $p[2] } }
    }
    return ,$list
}


# ---------------------------------------------------------------
#  Version number of the project
#  VERSION file, or the newest entry of releases.json, or installer\version.txt
# ---------------------------------------------------------------

function Get-AppVersion {
    $file = Join-Path $Root "VERSION"
    if (Test-Path $file) { return (Get-Content $file -Raw).Trim() }
    $file = Join-Path $Root "releases.json"
    if (Test-Path $file) {
        try {
            $r = (Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json).releases
            return [string]($r | Sort-Object { [version]$_.version } -Descending | Select-Object -First 1).version
        } catch { }
    }
    $file = Join-Path $Root "installer\version.txt"
    if (Test-Path $file) { return (Get-Content $file -Raw).Trim() }
    return ""
}


# ---------------------------------------------------------------
#  Update history (.local\update-history.jsonl, one JSON object per line)
#  Domainator's Updates page reads the same file.
# ---------------------------------------------------------------

function Write-History($Trigger, $User, $Result, $From, $To, $Message, $Commits, $Stopwatch, $FromVersion) {
    if (-not (Test-Path $LocalDir)) { New-Item -ItemType Directory -Path $LocalDir | Out-Null }
    $entry = [ordered]@{
        time        = (Get-Date).ToString("o")
        trigger     = $Trigger
        user        = $User
        result      = $Result
        from        = "$From"
        to          = "$To"
        fromVersion = "$FromVersion"
        toVersion   = "$(Get-AppVersion)"
        message     = "$Message"
        seconds     = [math]::Round($Stopwatch.Elapsed.TotalSeconds, 1)
        commits     = "__COMMITS__"
    }
    # Commits are converted separately so a single commit is still written as a JSON array
    $list = @($Commits | Where-Object { $_ })
    $commitsJson = "[]"
    if ($list.Count -gt 0) { $commitsJson = ConvertTo-Json -InputObject $list -Compress -Depth 3 }
    if (-not $commitsJson.StartsWith("[")) { $commitsJson = "[$commitsJson]" }
    $json = (ConvertTo-Json -InputObject $entry -Compress -Depth 3).Replace('"__COMMITS__"', $commitsJson)
    [System.IO.File]::AppendAllText($HistoryPath, $json + "`n", $Utf8NoBom)
}

function Show-History {
    if (-not (Test-Path $HistoryPath)) { Write-Info "No updates yet."; return }
    $lines = @(Get-Content $HistoryPath -Encoding UTF8 | Where-Object { $_.Trim() -ne "" } | Select-Object -Last 15)
    [array]::Reverse($lines)
    foreach ($l in $lines) {
        try {
            $e = $l | ConvertFrom-Json
            $t = ([DateTimeOffset]::Parse($e.time)).ToString("yyyy-MM-dd HH:mm")
            $color = switch ($e.result) { "ok" { "Green" } "uptodate" { "Gray" } "refused" { "Yellow" } default { "Red" } }
            Write-Host ("   {0}  {1,-10} {2,-5} {3}  {4}" -f $t, $e.result, $e.trigger, $e.user, $e.message) -ForegroundColor $color
            foreach ($c in @($e.commits)) { if ($c) { Write-Host ("         " + $c.sha.Substring(0, 7) + "  " + $c.subject) } }
        } catch { }
    }
}


# ---------------------------------------------------------------
#  Ports: every project gets its own port, so several projects can run together.
#  The list of all projects on this PC is in %LOCALAPPDATA%\dev-tools-data\ports.json
# ---------------------------------------------------------------

function Test-PortListening([int]$Port) {
    try {
        $c = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        return [bool]$c
    } catch { return $false }
}

function Read-PortRegistry {
    $map = @{}
    if (Test-Path $PortsFile) {
        try {
            $data = Get-Content $PortsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $data.PSObject.Properties) {
                # forget projects whose folder was deleted or moved
                if (Test-Path $p.Name) { $map[$p.Name] = [int]$p.Value }
            }
        } catch { }
    }
    return $map
}

function Save-PortRegistry($Map) {
    $obj = [ordered]@{}
    foreach ($k in ($Map.Keys | Sort-Object)) { $obj[$k] = $Map[$k] }
    Write-Utf8File $PortsFile (ConvertTo-Json -InputObject $obj)
}

# Write the port into dev.json (keeps the rest of the file as it is)
function Save-ConfigPort([int]$Port) {
    if (Test-Path $ConfigFile) {
        $text = [System.IO.File]::ReadAllText($ConfigFile)
        if ($text -match '"port"\s*:\s*\d+') {
            $text = ([regex]'"port"\s*:\s*\d+').Replace($text, "`"port`": $Port", 1)
        } else {
            $text = ([regex]'\{').Replace($text, "{`n  `"port`": $Port,", 1)
        }
    } else {
        $text = "{`n  `"port`": $Port`n}`n"
    }
    Write-Utf8File $ConfigFile $text
    $Config.port = $Port
}

function Get-DefaultPort {
    if ($IsDotnet) {
        # the port in Properties\launchSettings.json of the web project
        $ls = Get-ChildItem (Join-Path $Root "src") -Recurse -Depth 3 -Filter "launchSettings.json" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($ls) {
            $m = [regex]::Match((Get-Content $ls.FullName -Raw), 'http://localhost:(\d+)')
            if ($m.Success) { return [int]$m.Groups[1].Value }
        }
        return 5000
    }
    return 8000
}

# The port of this project. Changes it (and saves it) if another project on this PC has the same one.
function Get-ProjectPort {
    $map = Read-PortRegistry
    $port = [int]$Config.port
    $owner = $null
    if ($port -gt 0) {
        foreach ($k in $map.Keys) { if ($k -ne $Root -and $map[$k] -eq $port) { $owner = $k } }
    }
    if ($port -le 0 -or $owner) {
        $used = @($map.Values)
        $candidate = Get-DefaultPort
        while (($used -contains $candidate) -or (Test-PortListening $candidate)) { $candidate++ }
        if ($owner) {
            Write-Warn "Port $port is already used by project '$(Split-Path $owner -Leaf)' on this PC."
        }
        Write-Warn "This project now uses port $candidate (saved in dev.json; commit it with 'Finish work')."
        $port = $candidate
        Save-ConfigPort $port
    }
    if ($map[$Root] -ne $port) {
        $map[$Root] = $port
        Save-PortRegistry $map
    }
    return $port
}

function Get-SiteUrl {
    if ($IsDotnet) { return "http://localhost:$(Get-ProjectPort)" }
    return "http://127.0.0.1:$(Get-ProjectPort)"
}

function Open-Site {
    if (-not ($IsDjango -or $IsDotnet)) { Write-Warn "This project has no site."; return }
    Start-Process (Get-SiteUrl)
}

function Show-PortList {
    $map = Read-PortRegistry
    if ($map.Count -eq 0) { return }
    Write-Info "Ports on this PC:"
    foreach ($k in ($map.Keys | Sort-Object { $map[$_] })) {
        $state = "stopped"
        if (Test-PortListening $map[$k]) { $state = "running" }
        Write-Info ("   {0,-6} {1,-28} {2}" -f $map[$k], (Split-Path $k -Leaf), $state)
    }
}


# ---------------------------------------------------------------
#  Pull: get the latest code from GitHub
#  .NET: builds the new code; if it does not build, goes back to the previous version.
# ---------------------------------------------------------------

function Invoke-Pull([string]$Trigger = "menu", [string]$User = "$env:USERDOMAIN\$env:USERNAME") {
    Write-Step "Getting latest changes from GitHub"
    if (-not (Test-Repo)) { Write-Warn "No git repository here. Skipped."; return $true }
    Initialize-LocalExclude
    $interactive = ($Trigger -eq "menu")
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $fromVersion = Get-AppVersion
    $from = Get-Head

    if ($interactive) { Select-WorkBranch }
    if (-not (Repair-Upstream)) {
        Write-Warn "Nothing has been pushed to GitHub yet. Skipped."
        return $true
    }
    $upstream = Get-Upstream
    $remote = ($upstream -split "/")[0]

    $fetch = Invoke-Git fetch $remote
    if ($script:GitExit -ne 0) {
        $fetch | ForEach-Object { Write-Bad $_ }
        Write-Bad "Could not reach GitHub."
        Write-History $Trigger $User "failed" $from $from ("git fetch failed: " + ($fetch -join " ")) @() $sw $fromVersion
        return $false
    }

    $commits = Get-Commits "HEAD..$upstream"
    if ($commits.Count -eq 0) {
        Write-Ok "Already up to date."
        Write-History $Trigger $User "uptodate" $from $from "No new changes on GitHub." @() $sw $fromVersion
        return $true
    }
    Write-Info "$($commits.Count) new change(s):"
    $commits | ForEach-Object { Write-Info ("   " + $_.sha.Substring(0, 7) + "  " + $_.subject) }

    $merge = Invoke-Git merge --ff-only $upstream
    if ($script:GitExit -ne 0) {
        $merge | ForEach-Object { Write-Bad $_ }
        $ahead = (Invoke-Git rev-list --count "$upstream..HEAD" | Select-Object -First 1)
        $done = $false
        if ($interactive -and $ahead -and $ahead.Trim() -ne "0") {
            Write-Warn "This PC has $($ahead.Trim()) commit(s) that GitHub does not have, and GitHub has new ones too."
            if (Read-YesNo "Merge them automatically?" $true) {
                $m2 = Invoke-Git merge --no-edit $upstream
                if ($script:GitExit -eq 0) { $done = $true }
                else {
                    $m2 | ForEach-Object { Write-Bad $_ }
                    Invoke-Git merge --abort | Out-Null
                    Write-Bad "The changes touch the same lines. Nothing was changed. Ask Claude for help."
                }
            }
        } else {
            Write-Warn "Usually this means: files changed on this PC clash with the new ones. Use 'Finish work' first."
        }
        if (-not $done) {
            Write-History $Trigger $User "failed" $from $from ("git merge failed: " + ($merge -join " ")) $commits $sw $fromVersion
            return $false
        }
    }
    $to = Get-Head

    if ($IsDotnet) {
        if (Test-SiteRunning) {
            Write-Warn "Files updated. The site is running in another window: stop it and start it again."
            Write-History $Trigger $User "ok" $from $to "Files updated; not built because the site was running." $commits $sw $fromVersion
            return $true
        }
        $build = Invoke-Build
        if (-not $build.Ok) {
            Write-Warn "Going back to the previous version..."
            Invoke-Git reset --hard $from | Out-Null
            Invoke-Build | Out-Null
            Write-History $Trigger $User "rolledback" $from $from ("New version did not build: " + $build.Tail) $commits $sw $fromVersion
            return $false
        }
    }

    $v = Get-AppVersion
    if ($v -and $v -ne $fromVersion) { Write-Ok "Updated: version $fromVersion -> $v" } else { Write-Ok "Code is up to date." }
    Write-History $Trigger $User "ok" $from $to "Updated." $commits $sw $fromVersion
    return $true
}


# ---------------------------------------------------------------
#  Push: commit everything and send it to GitHub
# ---------------------------------------------------------------

# Ask for the commit message in this window (Persian or English)
function Read-CommitMessage {
    Write-Host ""
    $msg = Read-Host "   Commit message (Enter = automatic)"
    if ([string]::IsNullOrWhiteSpace($msg)) {
        $msg = "Update from $env:COMPUTERNAME " + (Get-Date -Format "yyyy-MM-dd HH:mm")
        Write-Warn "Using: $msg"
    }
    # Saved to a UTF-8 file so Persian text reaches git correctly
    $file = Join-Path ([System.IO.Path]::GetTempPath()) "dev-commit-msg.txt"
    Write-Utf8File $file $msg
    return $file
}

# Stop if secrets or databases would go to GitHub
function Test-Secrets {
    $patterns = @($Config.secret_patterns | Where-Object { $_ })
    if ($patterns.Count -eq 0) { return }
    $bad = @(Invoke-Git ls-files -- @patterns | Where-Object { $_.Trim() -ne "" -and $_ -notmatch "\.example$" })
    if ($bad.Count -gt 0) {
        Invoke-Git reset -q | Out-Null
        Write-Bad "These files must not go to GitHub (passwords, keys or databases):"
        $bad | ForEach-Object { Write-Bad "   $_" }
        Write-Bad "Add them to .gitignore. If they were sent before, ask Claude how to remove them."
        throw "Push stopped. Nothing was sent."
    }
}

function Invoke-Push {
    Initialize-Git
    Initialize-LocalExclude
    Confirm-GitIdentity
    $branch = Get-Branch

    Write-Step "Changed files"
    git status --short
    $changes = @(Invoke-Git status --porcelain | Where-Object { $_.Trim() -ne "" })
    if ($changes.Count -gt 0) {
        Invoke-Step "git add" { git add -A }
        Test-Secrets
        $msgFile = Read-CommitMessage
        Invoke-Step "git commit" { git commit -q -F $msgFile }
        Remove-Item $msgFile -ErrorAction SilentlyContinue
        Write-Ok "Commit saved."
    } else {
        Write-Ok "No new changes to commit."
        Test-Secrets
    }

    Write-Step "Sending to GitHub"
    if (Repair-Upstream) {
        # GitHub may have new commits (from Claude or the other PC): put ours on top of them first
        $upstream = Get-Upstream
        Invoke-Git fetch ($upstream -split "/")[0] | Out-Null
        $behind = (Invoke-Git rev-list --count "HEAD..$upstream" | Select-Object -First 1)
        if ($behind -and $behind.Trim() -ne "0") {
            Write-Info "GitHub has $($behind.Trim()) new commit(s). Getting them first..."
            $p = Invoke-Git pull --rebase
            if ($script:GitExit -ne 0) {
                $p | ForEach-Object { Write-Bad $_ }
                Invoke-Git rebase --abort | Out-Null
                throw "Your changes and the changes on GitHub touch the same lines. Nothing was sent. Ask Claude for help."
            }
            if ($IsDjango) { Write-Warn "New code arrived. Use 'Start work' after this, so packages and database are updated." }
        }
        Invoke-Step "git push" { git push -q }
    } else {
        Invoke-Step "first push" { git push -q -u origin $branch }
    }
    Write-Ok "Everything is on GitHub. You can shut down this PC."
}


# ---------------------------------------------------------------
#  Python and Django
# ---------------------------------------------------------------

function Initialize-Venv {
    if (-not $IsDjango) { return }
    if (Test-Path $VenvPython) { return }
    Write-Step "Creating Python $($Config.python) virtual environment ($VenvName)"
    if (Get-Command py -ErrorAction SilentlyContinue) {
        Invoke-Step "create venv" { py "-$($Config.python)" -m venv $VenvName }
    } else {
        Invoke-Step "create venv" { python -m venv $VenvName }
    }
    Invoke-Step "upgrade pip" { & $VenvPython -m pip install --upgrade pip --quiet }
    Write-Ok "Virtual environment created."
}

# Install packages only when requirements.txt has changed
function Install-Packages {
    if (-not $IsDjango -or -not (Test-Path $ReqFile)) { return }
    $hash = (Get-FileHash $ReqFile -Algorithm SHA256).Hash
    if ((Test-Path $ReqStamp) -and ((Get-Content $ReqStamp -Raw).Trim() -eq $hash)) {
        Write-Step "Packages"
        Write-Ok "No changes."
        return
    }
    Write-Step "Installing packages"
    Invoke-Step "pip install" { & $VenvPython -m pip install -r $ReqFile --quiet }
    Write-Utf8File $ReqStamp $hash
    Write-Ok "Packages installed."
}

function Save-Requirements {
    if (-not $IsDjango) { return }
    Write-Step "Saving package list"
    $freeze = @(& $VenvPython -m pip freeze | Where-Object { $_ -and $_ -notmatch "^-e " })
    if ($freeze.Count -eq 0) {
        Write-Warn "Virtual environment is empty. requirements.txt was not touched."
        return
    }
    $old = @()
    if (Test-Path $ReqFile) { $old = @(Get-Content $ReqFile -Encoding UTF8) }
    if (($old -join "`n").Trim() -eq ($freeze -join "`n").Trim()) { Write-Ok "No changes."; return }
    [System.IO.File]::WriteAllLines($ReqFile, [string[]]$freeze, $Utf8NoBom)
    Write-Utf8File $ReqStamp (Get-FileHash $ReqFile -Algorithm SHA256).Hash
    Write-Ok "requirements.txt updated."
}

function Invoke-Manage([string[]]$ManageArgs) {
    & $VenvPython manage.py @ManageArgs
}

function Update-Database {
    if (-not $IsDjango) { return }
    Write-Step "Updating database"
    Invoke-Step "migrate" { Invoke-Manage @("migrate") }
}

# Project setup commands from dev.json (must be safe to run again)
function Invoke-Setup {
    if (-not $IsDjango) { return }
    foreach ($cmd in @($Config.setup_commands)) {
        if ([string]::IsNullOrWhiteSpace($cmd)) { continue }
        Write-Step "Setup: $cmd"
        $parts = @($cmd -split "\s+" | Where-Object { $_ })
        Invoke-Step $cmd { Invoke-Manage $parts }
    }
}

# Default data (seed_commands in dev.json). Safe to run again, but it re-creates defaults you deleted.
function Invoke-Seed {
    if (-not $IsDjango) { return }
    $list = @($Config.seed_commands | Where-Object { $_ })
    if ($list.Count -eq 0) { Write-Warn "dev.json has no seed_commands."; return }
    foreach ($cmd in $list) {
        Write-Step "Default data: $cmd"
        $parts = @($cmd -split "\s+" | Where-Object { $_ })
        Invoke-Step $cmd { Invoke-Manage $parts }
    }
    Write-Utf8File $SeedStamp (Get-Date -Format "s")
    Write-Ok "Default data loaded."
}

# On a new PC / new database: load the default data once
function Invoke-SeedOnce {
    if (@($Config.seed_commands | Where-Object { $_ }).Count -eq 0) { return }
    # .dev-seeded in the project folder is the old place of this mark (dev.ps1 v1.x)
    if ((Test-Path $SeedStamp) -or (Test-Path (Join-Path $Root ".dev-seeded"))) { return }
    Invoke-Seed
}

# Checks two things in one go:
#   - the cookies have their own names (otherwise two sites on this PC log each other out,
#     or the forms of one site fail with a CSRF error after the other site was opened)
#   - an admin user exists (sites without django.contrib.auth need none)
function Confirm-DjangoBasics {
    if (-not $IsDjango) { return }
    $code = "from django.apps import apps; from django.conf import settings as s; " +
            "print('SESSION=' + (s.SESSION_COOKIE_NAME if apps.is_installed('django.contrib.sessions') else '-')); " +
            "print('CSRF=' + s.CSRF_COOKIE_NAME); " +
            "print('SU=NA' if not apps.is_installed('django.contrib.auth') else 'SU=' + str(int(__import__('django.contrib.auth', fromlist=['g']).get_user_model().objects.filter(is_superuser=True).exists())))"
    $out = (Invoke-Manage @("shell", "-v", "0", "-c", $code)) -join "`n"
    $default = @()
    if ($out -match "SESSION=sessionid\b") { $default += "SESSION_COOKIE_NAME" }
    if ($out -match "CSRF=csrftoken\b")    { $default += "CSRF_COOKIE_NAME" }
    if ($default.Count -gt 0) {
        Write-Warn "This site uses Django's default cookie names ($($default -join ', '))."
        Write-Warn "If two sites run on this PC, they disturb each other. Ask Claude to give them own names."
    }
    if ($out -match "SU=(1|NA)") { return }
    Write-Step "No admin user on this PC yet. Create one:"
    Invoke-Step "createsuperuser" { Invoke-Manage @("createsuperuser") }
}

# On a new PC: create .env from .env.example with a fresh SECRET_KEY
function Initialize-Env {
    $envFile = Join-Path $Root ".env"
    $example = Join-Path $Root ".env.example"
    if ((Test-Path $envFile) -or -not (Test-Path $example)) { return }
    Write-Step "Creating .env from .env.example"
    $text = [System.IO.File]::ReadAllText($example)
    if ($IsDjango -and (Test-Path $VenvPython)) {
        $key = (& $VenvPython -c "import secrets; print(secrets.token_urlsafe(50))").Trim()
        $text = $text -replace "(?m)^SECRET_KEY=.*$", "SECRET_KEY=$key"
    }
    Write-Utf8File $envFile $text
    Write-Warn ".env created. Fill in empty values (like API tokens) if this PC needs them."
}

function New-Migrations {
    if (-not $IsDjango) { Write-Warn "This is not a Django project."; return }
    Initialize-Venv
    Write-Step "Creating migrations"
    Invoke-Step "makemigrations" { Invoke-Manage @("makemigrations") }
    Update-Database
}

# Before pushing: make migrations if models changed and none were made
function Confirm-Migrations {
    if (-not $IsDjango) { return }
    Write-Step "Checking migrations"
    Invoke-Manage @("makemigrations", "--check", "--dry-run") | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Ok "Nothing missing."; return }
    Write-Warn "Models changed without migrations. Making them now."
    New-Migrations
}


# ---------------------------------------------------------------
#  .NET
# ---------------------------------------------------------------

function Get-Solution { return (Get-ChildItem $Root -File | Where-Object { $_.Extension -in @(".slnx", ".sln") } | Select-Object -First 1).FullName }

function Get-WebProject {
    $p = Get-ChildItem $Root -Recurse -Depth 3 -Filter "*.Web.csproj" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $p) { $p = Get-ChildItem $Root -Recurse -Depth 3 -Filter "*.csproj" -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if ($p) { return $p.DirectoryName }
    return $null
}

# True when a fitting .NET SDK is installed
function Test-Sdk {
    if (-not (Get-Command dotnet.exe -CommandType Application -ErrorAction SilentlyContinue)) { return $false }
    $sdks = @(& dotnet.exe --list-sdks 2>$null)
    if ($Config.dotnet_sdk) { return [bool]($sdks | Where-Object { $_ -match "^$([regex]::Escape([string]$Config.dotnet_sdk))\." }) }
    return ($sdks.Count -gt 0)
}

function Show-SdkMissing {
    $v = [string]$Config.dotnet_sdk
    if (-not $v) { $v = "(latest)" }
    Write-Bad "The .NET SDK $v is not installed on this PC, so the site cannot be built or run."
    Write-Warn "Install it once, then close this window and open dev.cmd again:"
    if ($Config.dotnet_sdk) { Write-Warn "   winget install Microsoft.DotNet.SDK.$($Config.dotnet_sdk)" }
    Write-Warn "   (or download it from https://dotnet.microsoft.com/download)"
}

function Invoke-Build {
    if (-not $IsDotnet) { Write-Warn "This is not a .NET project."; return [pscustomobject]@{ Ok = $true; Tail = "" } }
    if (-not (Test-Sdk)) { Show-SdkMissing; return [pscustomobject]@{ Ok = $false; Tail = "No .NET SDK." } }
    Write-Step "Building"
    $out = @(& dotnet build (Get-Solution) --nologo -v q 2>&1 | ForEach-Object { "$_" })
    $ok = ($LASTEXITCODE -eq 0)
    if ($ok) { Write-Ok "Build succeeded." }
    else {
        $out | Select-Object -Last 25 | ForEach-Object { Write-Bad $_ }
        Write-Bad "Build FAILED. Copy the red lines above into the chat."
    }
    return [pscustomobject]@{ Ok = $ok; Tail = (($out | Where-Object { $_ -match "error" } | Select-Object -First 3) -join " | ") }
}


# ---------------------------------------------------------------
#  Run the site
#  It runs as a child process: Enter or Ctrl+C stops only the site and you return to the menu.
# ---------------------------------------------------------------

function Test-SiteRunning { return (Test-PortListening ([int]$Config.port)) }

# Open the browser a few seconds later, when the site has started
function Open-SiteLater([string]$Url, [int]$Seconds) {
    Start-Process powershell -WindowStyle Hidden -ArgumentList "-NoProfile -Command Start-Sleep $Seconds; Start-Process '$Url'"
}

# Runs a process and waits until it ends, or until Enter / Ctrl+C is pressed (then stops it)
# Returns the exit code of the process, or -1 when it was stopped by the user.
function Wait-SiteProcess($Process) {
    $oldCtrlC = [Console]::TreatControlCAsInput
    [Console]::TreatControlCAsInput = $true
    $stopped = $false
    try {
        while (-not $Process.HasExited) {
            $hasKey = $false
            try { $hasKey = [Console]::KeyAvailable } catch { }
            if ($hasKey) {
                $key = [Console]::ReadKey($true)
                $ctrlC = ($key.Key -eq [ConsoleKey]::C) -and ($key.Modifiers -band [ConsoleModifiers]::Control)
                if ($key.Key -eq [ConsoleKey]::Enter -or $ctrlC) { $stopped = $true; break }
            }
            Start-Sleep -Milliseconds 200
        }
    } finally {
        [Console]::TreatControlCAsInput = $oldCtrlC
        if (-not $Process.HasExited) {
            # /T also stops child processes (the auto-reload process of runserver, the dotnet app)
            & taskkill /PID $Process.Id /T /F 2>$null | Out-Null
        }
    }
    if ($stopped) { return -1 }
    $Process.WaitForExit()
    return $Process.ExitCode
}

function Start-Site {
    if (-not ($IsDjango -or $IsDotnet)) { Write-Warn "This project has no site to run."; return }
    $port = Get-ProjectPort
    if (Test-PortListening $port) {
        Write-Warn "Port $port is already in use. Is this site open in another window?"
        return
    }
    if ($IsDjango) { Start-DjangoSite $port } else { Start-DotnetSite $port }
}

function Start-DjangoSite([int]$Port) {
    $url = "http://127.0.0.1:$Port"
    Write-Step "Site: $url"
    Write-Warn "To stop the site: press Enter (or Ctrl+C) in this window. You return to the menu."
    Open-SiteLater $url 3
    $server = Start-Process -FilePath $VenvPython -ArgumentList @("manage.py", "runserver", "127.0.0.1:$Port") `
        -WorkingDirectory $Root -NoNewWindow -PassThru
    Wait-SiteProcess $server | Out-Null
    Write-Ok "Site stopped."
}

# The .NET site can ask for an update: it writes .local\update-request.json and exits with
# restart_exit_code (42). Then this tool pulls, builds, records it and starts the site again.
function Start-DotnetSite([int]$Port) {
    if (-not (Test-Sdk)) { Show-SdkMissing; return }
    $web = Get-WebProject
    if (-not $web) { Write-Bad "No web project (*.csproj) found."; return }
    $url = "http://localhost:$Port"
    $first = $true
    while ($true) {
        if ($first) { Open-SiteLater $url 8; $first = $false }
        Write-Step "Site: $url"
        Write-Warn "To stop the site: press Enter (or Ctrl+C) in this window. You return to the menu."
        $argList = @("run", "--project", "`"$web`"", "--launch-profile", $Config.launch_profile, "--", "--urls", $url)
        $server = Start-Process -FilePath "dotnet" -ArgumentList $argList -WorkingDirectory $Root -NoNewWindow -PassThru
        $null = $server.Handle   # keeps the handle, so the exit code can be read later
        $code = Wait-SiteProcess $server
        if ($code -ne [int]$Config.restart_exit_code) {
            if ($code -eq -1) { Write-Ok "Site stopped." } else { Write-Warn "The site stopped (exit code $code)." }
            break
        }
        # The site asked for an update
        $user = "web"
        if (Test-Path $RequestPath) {
            try { $user = (Get-Content $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json).user } catch { }
            Remove-Item $RequestPath -Force -ErrorAction SilentlyContinue
        }
        Write-Step "Update requested from the site by $user."
        Invoke-Pull -Trigger "web" -User $user | Out-Null
    }
}


# ---------------------------------------------------------------
#  Publish: make the finished version available to the servers
#    branch mode: send the work branch to the publish branch (fast-forward only)
#    tag mode:    publish the version in VERSION as tag v<version>
# ---------------------------------------------------------------

function Publish-Branch {
    $work = [string]$Config.work_branch
    $pub  = [string]$Config.publish_branch
    if (-not $work -or -not $pub) { Write-Warn "dev.json needs work_branch and publish_branch."; return }
    Write-Step "Getting latest changes from GitHub"
    Invoke-Step "git fetch" { git fetch -q origin }
    if ((Get-LocalChanges).Count -gt 0) {
        Write-Warn "This PC has unsaved changes. Use 'Finish work' first if they should be published too."
    }
    $ahead = @(Invoke-Git log --oneline "origin/$pub..origin/$work" | Where-Object { $_ })
    if ($ahead.Count -eq 0) { Write-Ok "Nothing new: '$pub' already has everything from '$work'."; return }
    $behind = @(Invoke-Git log --oneline "origin/$work..origin/$pub" | Where-Object { $_ })
    if ($behind.Count -gt 0) {
        Write-Bad "'$pub' has changes that '$work' does not have:"
        $behind | ForEach-Object { Write-Info "   $_" }
        throw "Publish stopped. Ask Claude to bring '$pub' into '$work' first."
    }
    $from = Invoke-Git show "origin/$($pub):VERSION" | Select-Object -First 1
    $fromOk = ($script:GitExit -eq 0)
    $to = Invoke-Git show "origin/$($work):VERSION" | Select-Object -First 1
    if ($fromOk -and $script:GitExit -eq 0) { Write-Step "Version $($from.Trim()) -> $($to.Trim())" }
    Write-Step "Changes that will be published:"
    $ahead | ForEach-Object { Write-Info "   $_" }
    if (-not (Read-YesNo "Publish these?" $false)) { Write-Warn "Cancelled."; return }
    Invoke-Step "git push" { git push -q origin "origin/$($work):refs/heads/$pub" }
    Write-Ok "Published to '$pub'. Now use the update button of the site on the server."
}

# The version to publish: VERSION file, or releases.json, or installer\version.txt (see Get-AppVersion)
function Get-TagVersion {
    $v = Get-AppVersion
    if (-not $v) { return $null }
    if ($v -notmatch '^\d+\.\d+\.\d+$') { throw "The version number is not valid: '$v'" }
    return $v
}

function Test-ReleaseWorkflow { return (Test-Path (Join-Path $Root ".github\workflows\release.yml")) }

# -Ask: used right after 'Finish work'; asks first and stays quiet if already published
function Publish-Tag([switch]$Ask) {
    $version = Get-TagVersion
    if (-not $version) { if (-not $Ask) { Write-Warn "No version number found. Nothing to publish." }; return }
    $tag = "v$version"
    Invoke-Git fetch origin --tags --quiet | Out-Null
    if (Invoke-Git tag -l $tag) {
        if ($Ask) { Write-Ok "Version $version is already published." }
        else { Write-Warn "Version $version is already published. Increase VERSION and CHANGELOG.md first." }
        return
    }
    if ((Get-LocalChanges).Count -gt 0) { throw "There are uncommitted changes. Use 'Finish work' first." }
    $behind = (Invoke-Git rev-list --count "HEAD..@{u}" | Select-Object -First 1)
    if ($script:GitExit -eq 0 -and $behind -and $behind.Trim() -ne "0") { throw "GitHub has newer commits. Use 'Pull' first." }
    $changelog = Join-Path $Root "CHANGELOG.md"
    if ((Test-Path $changelog) -and -not ((Get-Content $changelog -Raw -Encoding UTF8).Contains("## [$version]"))) {
        Write-Warn "CHANGELOG.md has no section for $version (the server will show no change list)."
    }
    Write-Step "Publish version $version for the servers"
    if (-not (Read-YesNo "Publish now? The servers' update page will offer it." $true)) {
        Write-Warn "Not published. You can publish later from the menu."
        return
    }
    Invoke-Step "git tag" { git tag -a $tag -m "Release $version" }
    Invoke-Step "git push tag" { git push -q origin $tag }
    if (Test-ReleaseWorkflow) {
        $repo = Get-GitHubRepo
        Write-Ok "Published $tag. GitHub now builds and publishes the files (about 10 minutes)."
        Write-Ok "Progress: https://github.com/$repo/actions"
    } else {
        Write-Ok "Published $tag. Open the update page on the server to install it."
    }
}

function Invoke-Publish {
    switch ($ReleaseMode) {
        "branch" { Publish-Branch }
        "tag"    { Publish-Tag }
        default  { Write-Warn "Publishing is not set up for this project (release_mode in dev.json)." }
    }
}


# ---------------------------------------------------------------
#  Update keys (licensed products only; see docs/UPDATES-AND-LICENSES.md)
#  The key store is ONE file on a USB stick, locked with a passphrase (release\keys.py).
#  Only its path is remembered on this PC.
# ---------------------------------------------------------------

$KeyStoreRemember = Join-Path $DataDir "keystore-path.txt"

# A Python that has the "cryptography" package: the project's venv, or the Python of this PC
function Get-ReleasePython {
    $candidates = @()
    if (Test-Path $VenvPython) { $candidates += ,@($VenvPython) }
    if (Get-Command py -ErrorAction SilentlyContinue) { $candidates += ,@("py", "-3") }
    if (Get-Command python -ErrorAction SilentlyContinue) { $candidates += ,@("python") }
    foreach ($c in $candidates) {
        $exe = $c[0]; $pre = @($c | Select-Object -Skip 1)
        & $exe @pre -c "import cryptography" 2>$null
        if ($LASTEXITCODE -eq 0) { return [pscustomobject]@{ Exe = $exe; Pre = $pre } }
    }
    if ($candidates.Count -eq 0) { throw "Python is not installed on this PC." }
    $exe = $candidates[-1][0]; $pre = @($candidates[-1] | Select-Object -Skip 1)
    Write-Step "Installing the Python package 'cryptography'"
    Invoke-Step "pip install cryptography" { & $exe @pre -m pip install --user --quiet cryptography }
    return [pscustomobject]@{ Exe = $exe; Pre = $pre }
}

# Runs release\<script>.py of this tool. Output lines are returned (prompts go to the screen).
function Invoke-ReleaseScript([string]$Script, [string[]]$ScriptArgs) {
    $py = Get-ReleasePython
    $pre = @($py.Pre)
    $out = & $py.Exe @pre (Join-Path $ToolDir "release\$Script.py") @ScriptArgs
    $script:ReleaseExit = $LASTEXITCODE
    return $out
}

# Where the key store is. Asks once and remembers the path on this PC.
function Get-KeyStorePath {
    $path = ""
    if (Test-Path $KeyStoreRemember) { $path = (Get-Content $KeyStoreRemember -Raw).Trim() }
    if ($path -and (Test-Path $path)) {
        if (Read-YesNo "Use the key store $path ?" $true) { return $path }
    } elseif ($path) {
        Write-Warn "The key store is not at $path (is the USB stick plugged in?)."
    }
    Write-Host ""
    Write-Info "The key store is one file on your USB stick, for example  E:\A-Delnaz-Keys\a-delnaz.adkeys"
    $path = (Read-Host "   Path of the key store file").Trim().Trim('"')
    if (-not $path) { throw "No key store chosen." }
    if (-not (Test-Path $path)) {
        Write-Warn "There is no key store at $path."
        if (-not (Read-YesNo "Create a NEW key store there? (only once, ever)" $false)) { throw "Cancelled." }
        Invoke-ReleaseScript "keys" @("init", "--store", $path) | Out-Host
        if ($script:ReleaseExit -ne 0) { throw "The key store was not created." }
    }
    Write-Utf8File $KeyStoreRemember $path
    return $path
}

# owner/name of the GitHub repository of this project
function Get-GitHubRepo {
    $url = Invoke-Git remote get-url origin | Select-Object -First 1
    $m = [regex]::Match([string]$url, 'github\.com[:/]([^/]+)/([^/\s]+?)(\.git)?$')
    if ($m.Success) { return "$($m.Groups[1].Value)/$($m.Groups[2].Value)" }
    return $null
}

function Test-GhReady {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { return $false }
    & gh auth status 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# Makes update-keys.json for this product and (if wanted) puts the keys into the GitHub secrets
function Initialize-UpdateKeys {
    if (-not $Config.product) { Write-Warn "dev.json has no 'product': this is not a licensed product."; return }
    $store = Get-KeyStorePath
    $keyFile = Join-Path $Root "update-keys.json"

    Write-Step "Key file of '$($Config.product)'"
    Invoke-ReleaseScript "keys" @("product", "--store", $store, "--product", [string]$Config.product, "--out", $keyFile) | Out-Host
    if ($script:ReleaseExit -ne 0) { throw "update-keys.json was not made." }
    if ((Invoke-Git status --porcelain -- update-keys.json | Where-Object { $_ })) {
        Write-Warn "update-keys.json is new: send it to GitHub with 'Finish work'."
    }

    $repo = Get-GitHubRepo
    Write-Step "GitHub secrets of $repo (needed to build packages on GitHub)"
    if (-not (Test-GhReady)) {
        Write-Warn "The GitHub command line tool (gh) is not installed or not signed in."
        Write-Warn "Install it once:   winget install GitHub.cli"
        Write-Warn "Then sign in:      gh auth login"
        Write-Warn "Then run this option (K) again. Nothing else is needed now."
        return
    }
    if (-not (Read-YesNo "Put the update keys into the secrets of $repo now?" $true)) { return }
    $content = (Get-Content $keyFile -Raw -Encoding UTF8 | ConvertFrom-Json).content_key
    $signing = Invoke-ReleaseScript "keys" @("secret", "--store", $store, "--name", "update") | Select-Object -Last 1
    if ($script:ReleaseExit -ne 0 -or -not $signing) { throw "The key store could not be opened." }
    # --body (not a pipe): a pipe could add a line break to the key
    gh secret set ADUP_SIGNING_KEY --repo $repo --body ([string]$signing).Trim()
    $ok1 = ($LASTEXITCODE -eq 0)
    $signing = $null
    gh secret set ADUP_CONTENT_KEY --repo $repo --body $content
    $ok2 = ($LASTEXITCODE -eq 0)
    if ($ok1 -and $ok2) { Write-Ok "Secrets ADUP_SIGNING_KEY and ADUP_CONTENT_KEY are set in $repo." }
    else { throw "Setting the GitHub secrets failed (see above)." }
    Initialize-ReleasesAccess $repo
}

# The public releases repository (<repo>-Releases) and the token that lets GitHub publish into it
function Initialize-ReleasesAccess([string]$Repo) {
    $releases = "$Repo-Releases"
    Write-Step "Releases repository $releases"
    & gh repo view $releases *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "It does not exist yet. It is PUBLIC: it only gets the encrypted .adup files."
        if (Read-YesNo "Create $releases now?" $true) {
            Invoke-Step "gh repo create" { gh repo create $releases --public --add-readme --description "Update packages (encrypted, signed)" }
        }
    } else { Write-Ok "Exists." }

    $names = @(& gh secret list --repo $Repo 2>$null | ForEach-Object { ($_ -split "\s+")[0] })
    if ($names -contains "RELEASES_TOKEN") {
        Write-Ok "Secret RELEASES_TOKEN is set in $Repo."
        if (-not (Read-YesNo "Replace it with a new token?" $false)) { return }
    }
    Write-Host ""
    Write-Info "GitHub needs a token to publish into $releases. Make it once (it can serve all products):"
    Write-Info "  1. Open  https://github.com/settings/personal-access-tokens/new"
    Write-Info "  2. Token name: releases    Expiration: No expiration"
    Write-Info "  3. Repository access: Only select repositories -> every *-Releases repository"
    Write-Info "  4. Permissions -> Repository permissions -> Contents: Read and write"
    Write-Info "  5. Generate token, copy it, and paste it here (it is not shown)."
    $secure = Read-Host "   Token (Enter = later)" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if ([string]::IsNullOrWhiteSpace($token)) { Write-Warn "Skipped. Run option K again when you have the token."; return }
    gh secret set RELEASES_TOKEN --repo $Repo --body $token.Trim()
    $ok = ($LASTEXITCODE -eq 0)
    $token = $null
    if ($ok) { Write-Ok "Secret RELEASES_TOKEN is set in $Repo." } else { throw "Setting RELEASES_TOKEN failed (see above)." }
}


# ---------------------------------------------------------------
#  Status, source zip, extra tools
# ---------------------------------------------------------------

function Show-Status {
    Write-Step "Status of $ProjectName"
    Write-Info "Folder:   $Root"
    Write-Info "Type:     $ProjectType      (dev tool $ToolVersion)"
    $v = Get-AppVersion
    if ($v) { Write-Info "Version:  $v" }
    if (Test-Repo) {
        $upstream = Get-Upstream
        Write-Info ("Branch:   " + (Get-Branch) + "  ->  " + $(if ($upstream) { $upstream } else { "(not on GitHub yet)" }))
        Write-Info ("Last:     " + (Invoke-Git log -1 "--format=%h  %ci  %s" | Select-Object -First 1))
        if ($upstream) {
            Invoke-Git fetch --quiet ($upstream -split "/")[0] | Out-Null
            $behind = (Invoke-Git rev-list --count "HEAD..$upstream" | Select-Object -First 1)
            $ahead  = (Invoke-Git rev-list --count "$upstream..HEAD" | Select-Object -First 1)
            Write-Info "GitHub:   $behind new change(s) to get, $ahead commit(s) of this PC to send"
        }
        $changes = @(Invoke-Git status --porcelain | Where-Object { $_.Trim() -ne "" })
        if ($changes.Count -eq 0) { Write-Ok "Local:    no unsaved changes" }
        else {
            Write-Warn "Local:    $($changes.Count) unsaved change(s):"
            $changes | Select-Object -First 20 | ForEach-Object { Write-Warn "   $_" }
        }
    } else {
        Write-Warn "Git:      not a git repository yet ('Finish work' creates it)"
    }
    if ($IsDjango -or $IsDotnet) {
        $url = Get-SiteUrl
        Write-Info ("Site:     $url  " + $(if (Test-SiteRunning) { "(running)" } else { "(not running)" }))
        Show-PortList
    }
    if ($ReleaseMode -ne "none") { Write-Info "Publish:  $ReleaseMode" }
}

# The code of the last commit as a zip on the desktop (for a new chat)
function New-SourceZip {
    if (-not (Test-Repo)) { Write-Warn "No git repository here."; return }
    $zip = Join-Path ([Environment]::GetFolderPath("Desktop")) "$ProjectName-src.zip"
    if ((Get-LocalChanges).Count -gt 0) { Write-Warn "Note: unsaved changes are NOT in the zip. Use 'Finish work' first if they matter." }
    Invoke-Git archive --format=zip -o $zip HEAD | Out-Null
    if ($script:GitExit -eq 0) { Write-Ok "Created $zip" } else { Write-Bad "Could not create the zip." }
}

function Get-Tools { return @(@($Config.tools) | Where-Object { $_ -and $_.title -and $_.script }) }

# Extra project tools from dev.json (for example: build a release, copy it to the update folder)
function Invoke-Tool($Tool) {
    $script = Join-Path $Root $Tool.script
    if (-not (Test-Path $script)) { throw "Tool script not found: $($Tool.script)" }
    Write-Step $Tool.title
    $toolArgs = @()
    if ($Tool.args) { $toolArgs = @(([string]$Tool.args) -split "\s+" | Where-Object { $_ }) }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script @toolArgs | Out-Host
    $code = $LASTEXITCODE
    if ($code -ne 0) { Write-Bad "Finished with errors (see above)." } else { Write-Ok "Done." }
    return $code
}


# ---------------------------------------------------------------
#  Menu actions
# ---------------------------------------------------------------

function Start-Work {
    if (-not (Invoke-Pull)) {
        if (-not (Read-YesNo "Getting the latest code failed. Continue with the code on this PC?" $false)) { return }
    }
    if ($IsDjango) {
        Initialize-Venv
        Install-Packages
        Initialize-Env
        Update-Database
        Invoke-Setup
        Invoke-SeedOnce
        Confirm-DjangoBasics
    } elseif ($IsDotnet) {
        Initialize-Env
    }
    Start-Site
}

function Start-SiteOnly {
    if ($IsDjango) { Initialize-Venv; Update-Database }
    Start-Site
}

function Stop-Work {
    if ($IsDjango) {
        Initialize-Venv
        Install-Packages
        Confirm-Migrations
        Save-Requirements
    } elseif ($IsDotnet -and (Get-LocalChanges).Count -gt 0) {
        $b = Invoke-Build
        if (-not $b.Ok -and -not (Read-YesNo "The code does not build. Send it to GitHub anyway?" $false)) { return }
    }
    Invoke-Push
    if ($ReleaseMode -eq "tag") { Publish-Tag -Ask }
}


# ---------------------------------------------------------------
#  Menu
# ---------------------------------------------------------------

# Every item: number, text, action. Built for the type of this project.
function Get-MenuItems {
    $items = New-Object System.Collections.ArrayList
    function Add-Item($Key, $Text, $Action, $Tool = $null) { [void]$items.Add([pscustomobject]@{ Key = "$Key"; Text = $Text; Action = $Action; Tool = $Tool }) }

    if ($IsDjango -or $IsDotnet) {
        Add-Item 1 "Start work      get latest, prepare, run site" { Start-Work }
        Add-Item 2 "Run site only" { Start-SiteOnly }
    } else {
        Add-Item 1 "Start work      get latest from GitHub" { Invoke-Pull | Out-Null }
    }
    if ($IsDjango) { Add-Item 3 "Make migrations" { New-Migrations } }
    if ($IsDotnet) { Add-Item 3 "Build" { Invoke-Build | Out-Null } }
    Add-Item 4 "Finish work     save and send to GitHub" { Stop-Work }
    Add-Item 5 "Get latest      only get the code from GitHub" { Invoke-Pull | Out-Null }
    Add-Item 6 "Status" { Show-Status }
    if ($IsDjango -or $IsDotnet) { Add-Item 7 "Open site in browser" { Open-Site } }
    if ($IsDjango -and @($Config.seed_commands | Where-Object { $_ }).Count -gt 0) {
        Add-Item 8 "Load default data   (new database)" { Initialize-Venv; Invoke-Seed }
    }
    if ($IsDotnet) { Add-Item 8 "Update history" { Show-History } }
    if ($ReleaseMode -eq "branch") { Add-Item 9 "Publish         send '$($Config.work_branch)' to '$($Config.publish_branch)' (servers)" { Publish-Branch } }
    if ($ReleaseMode -eq "tag")    { Add-Item 9 "Publish version (only if you skipped it in 'Finish work')" { Publish-Tag } }
    Add-Item 10 "Source zip      code as a zip on the desktop (for a new chat)" { New-SourceZip }
    if ($Config.product) { Add-Item "K" "Update keys     key file of this product, GitHub secrets (key store on USB)" { Initialize-UpdateKeys } }
    $n = 11
    foreach ($t in Get-Tools) {
        Add-Item $n $t.title $null $t
        $n++
    }
    return $items
}

function Show-Menu {
    while ($true) {
        $items = Get-MenuItems
        $ver = Get-AppVersion
        $title = $ProjectName
        if ($ver) { $title = "$ProjectName  (version $ver)" }
        Write-Host ""
        Write-Host "==============================================" -ForegroundColor DarkCyan
        Write-Host "   Project: $title" -ForegroundColor White
        if ($IsDjango -or $IsDotnet) { Write-Host "   $ProjectType, port $(Get-ProjectPort)" -ForegroundColor DarkGray }
        Write-Host "==============================================" -ForegroundColor DarkCyan
        foreach ($i in $items) { Write-Host ("  {0,2}) {1}" -f $i.Key, $i.Text) }
        Write-Host "   0) Exit"
        $choice = (Read-Host "  Choose").Trim()
        if ($choice -eq "0") { return }
        $item = $items | Where-Object { $_.Key -eq $choice } | Select-Object -First 1
        if (-not $item) { Write-Bad "Invalid option."; continue }
        try {
            if ($item.Tool) { Invoke-Tool $item.Tool | Out-Null } else { & $item.Action }
        } catch { Write-Bad $_.Exception.Message }
    }
}

# Command line: dev.cmd <command>. Returns the exit code.
function Invoke-DevCommand([string]$Name) {
    $tool = Get-Tools | Where-Object { $_.command -and $_.command -eq $Name } | Select-Object -First 1
    if ($tool) { return (Invoke-Tool $tool) }
    switch ($Name) {
        "start"   { Start-Work | Out-Host; return 0 }
        "run"     { Start-SiteOnly | Out-Host; return 0 }
        "pull"    { if (Invoke-Pull -Trigger "cli") { return 0 } else { return 1 } }
        "push"    { Stop-Work | Out-Host; return 0 }
        "status"  { Show-Status | Out-Host; return 0 }
        "open"    { Open-Site | Out-Host; return 0 }
        "migrate" { New-Migrations | Out-Host; return 0 }
        "seed"    { Initialize-Venv | Out-Host; Invoke-Seed | Out-Host; return 0 }
        "build"   { if ((Invoke-Build).Ok) { return 0 } else { return 1 } }
        "history" { Show-History | Out-Host; return 0 }
        "publish" { Invoke-Publish | Out-Host; return 0 }
        "zip"     { New-SourceZip | Out-Host; return 0 }
        "keys"    { Initialize-UpdateKeys | Out-Host; return 0 }
        default {
            $names = @("start", "run", "pull", "push", "status", "open", "migrate", "seed", "build", "history", "publish", "zip", "keys")
            $names += @(Get-Tools | Where-Object { $_.command } | ForEach-Object { $_.command })
            Write-Warn "Unknown command '$Name'. Use: $($names -join ', ')"
            return 1
        }
    }
}


# ---------------------------------------------------------------
#  Start
# ---------------------------------------------------------------

if (-not (Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue)) {
    Write-Bad "Git is not installed or not in PATH."
    exit 1
}
Initialize-LocalExclude

if ([string]::IsNullOrWhiteSpace($Command)) {
    Show-Menu
    exit 0
}
try {
    exit (Invoke-DevCommand $Command.ToLowerInvariant())
} catch {
    Write-Bad $_.Exception.Message
    exit 1
}
