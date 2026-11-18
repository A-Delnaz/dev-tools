# =================================================================
#  mirror.ps1 - copies new update files from GitHub to the shared folder
#
#  For networks whose servers have no internet: one always-on Windows PC
#  that has internet AND write access to the shared folder runs this every
#  hour (scheduled task made by install-mirror.cmd).
#
#  For every product it downloads ALL versions (*.adup) of the public
#  release repository into  <share>\<product folder>\  . Files already
#  there (same size) are skipped. The servers' update page only needs the
#  path of that folder.
#
#  The product list comes from mirror\products.json of the dev-tools
#  repository (read again on every run) plus the "products" of mirror.json.
#
#  Settings: mirror.json next to this file (made by install-mirror.ps1):
#    { "share": "\\\\fileserver\\Updates", "products": [ ... ], "patterns": ["*.adup"] }
#  Log: mirror.log next to this file.
# =================================================================

param(
    [string]$Config = "",
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$Here = $PSScriptRoot
if (-not $Config) { $Config = Join-Path $Here "mirror.json" }
$LogFile = Join-Path $Here "mirror.log"
$UserAgent = "A-Delnaz-Mirror"
$script:Errors = 0

function Write-Log([string]$Text, [string]$Color = "Gray") {
    $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Text
    if (-not $Quiet) { Write-Host $line -ForegroundColor $Color }
    try {
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) {
            Move-Item $LogFile "$LogFile.old" -Force
        }
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    } catch { }
}

function Get-Json([string]$Url) {
    $r = Invoke-RestMethod -Uri $Url -UserAgent $UserAgent -Headers @{ Accept = "application/vnd.github+json" } -TimeoutSec 60
    # raw.githubusercontent.com sends JSON as plain text: then it is still a string here
    if ($r -is [string]) { $r = $r | ConvertFrom-Json }
    elseif ($r -is [byte[]]) { $r = [Text.Encoding]::UTF8.GetString($r) | ConvertFrom-Json }
    return $r
}

# All releases of a repository (page by page)
function Get-Releases([string]$Api, [string]$Repo) {
    $all = @()
    $page = 1
    while ($true) {
        $batch = @(Get-Json "$Api/repos/$Repo/releases?per_page=100&page=$page")
        $all += $batch
        if ($batch.Count -lt 100) { break }
        $page++
    }
    return $all
}

function Sync-Product($Product, [string]$Share, [string]$Api, [string[]]$Patterns) {
    $target = Join-Path $Share $Product.folder
    if (-not (Test-Path $target)) { New-Item -ItemType Directory -Force -Path $target | Out-Null }
    $releases = Get-Releases $Api $Product.repo
    $new = 0
    foreach ($rel in $releases) {
        if ($rel.draft) { continue }
        foreach ($asset in @($rel.assets)) {
            $wanted = $false
            foreach ($p in $Patterns) { if ($asset.name -like $p) { $wanted = $true } }
            if (-not $wanted) { continue }
            if ($asset.name -match '[\\/]' -or $asset.name.StartsWith(".")) { continue }
            $dest = Join-Path $target $asset.name
            if ((Test-Path $dest) -and (Get-Item $dest).Length -eq [long]$asset.size) { continue }
            $part = "$dest.part"
            Write-Log "Downloading $($Product.repo) $($asset.name) ($([math]::Round($asset.size / 1MB, 1)) MB)"
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $part -UserAgent $UserAgent -UseBasicParsing -TimeoutSec 1800
            if ((Get-Item $part).Length -ne [long]$asset.size) {
                Remove-Item $part -Force
                throw "Download of $($asset.name) is incomplete."
            }
            Move-Item $part $dest -Force
            $new++
        }
    }
    if ($new -gt 0) { Write-Log "$($Product.folder): $new new file(s) in $target" "Green" }
    else { Write-Log "$($Product.folder): up to date" }
}

# ---------------------------------------------------------------
try {
    if (-not (Test-Path $Config)) { throw "Settings not found: $Config (run install-mirror.cmd)." }
    $cfg = Get-Content $Config -Raw -Encoding UTF8 | ConvertFrom-Json
    $share = [string]$cfg.share
    if (-not $share) { throw "mirror.json has no 'share'." }
    if (-not (Test-Path $share)) { throw "Shared folder not reachable: $share (rights of the account that runs this task?)" }
    $api = if ($cfg.api) { ([string]$cfg.api).TrimEnd("/") } else { "https://api.github.com" }
    $patterns = if ($cfg.patterns) { @($cfg.patterns) } else { @("*.adup") }
    $listUrl = if ($cfg.products_url) { [string]$cfg.products_url } else { "https://raw.githubusercontent.com/A-Delnaz/dev-tools/main/mirror/products.json" }

    # Products: the shared list (online) + the ones in mirror.json
    $products = @()
    try {
        $products += @((Get-Json $listUrl).products)
    } catch {
        Write-Log "Could not read the product list ($listUrl): $($_.Exception.Message). Using mirror.json only." "Yellow"
    }
    $products += @($cfg.products | Where-Object { $_ })
    $seen = @{}
    foreach ($p in $products) {
        if (-not $p.repo -or -not $p.folder -or $seen.ContainsKey($p.repo)) { continue }
        $seen[$p.repo] = $true
        try { Sync-Product $p $share $api $patterns }
        catch { $script:Errors++; Write-Log "$($p.repo): $($_.Exception.Message)" "Red" }
    }
    if ($seen.Count -eq 0) { Write-Log "No products to copy." "Yellow" }
} catch {
    $script:Errors++
    Write-Log "ERROR: $($_.Exception.Message)" "Red"
}
exit $(if ($script:Errors -gt 0) { 1 } else { 0 })
