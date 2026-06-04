# scripts/detect-doc-type.ps1
# ─────────────────────────────────────────────────────────────────────────────
# Probes a documentation site or RTD slug and recommends the correct
# projects.yml `type` entry to use.
#
# Usage (run from repo root):
#   .\scripts\detect-doc-type.ps1 <slug-or-url> [-Verbose]
#
# Examples:
#   .\scripts\detect-doc-type.ps1 flask
#   .\scripts\detect-doc-type.ps1 https://docs.docker.com/build/
#   .\scripts\detect-doc-type.ps1 https://docs.pydantic.dev/latest/ -Verbose
#
# Requirements: PowerShell 5.1+ or PowerShell 7+ (pwsh)
#               Internet access to probe URLs
# ─────────────────────────────────────────────────────────────────────────────
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Input,

    [Parameter()]
    [switch]$ShowEntry   # Print the projects.yml entry at the end (default: true)
)

$ErrorActionPreference = "SilentlyContinue"

# ── Helpers ───────────────────────────────────────────────────────────────────

function Write-Section($text) {
    Write-Host "`n── $text ──" -ForegroundColor White
}

function Write-Ok($text) {
    Write-Host "[✓] $text" -ForegroundColor Green
}

function Write-Warn($text) {
    Write-Host "[!] $text" -ForegroundColor Yellow
}

function Write-Fail($text) {
    Write-Host "[✗] $text" -ForegroundColor Red
}

function Write-Info($text) {
    Write-Host "[~] $text" -ForegroundColor Cyan
}

function Get-HttpStatus {
    param([string]$Url)
    try {
        $response = Invoke-WebRequest -Uri $Url -Method Head `
            -UserAgent "Mozilla/5.0 (compatible; rtd-mirror-detector/1.0)" `
            -MaximumRedirection 5 -TimeoutSec 10 -UseBasicParsing
        return [int]$response.StatusCode
    } catch {
        if ($_.Exception.Response) {
            return [int]$_.Exception.Response.StatusCode
        }
        return 0
    }
}

function Get-HttpBody {
    param([string]$Url)
    try {
        $response = Invoke-WebRequest -Uri $Url `
            -UserAgent "Mozilla/5.0 (compatible; rtd-mirror-detector/1.0)" `
            -MaximumRedirection 5 -TimeoutSec 15 -UseBasicParsing
        return $response.Content
    } catch {
        return ""
    }
}

function Test-GitHubFileExists {
    param([string]$Owner, [string]$Repo, [string]$Path)
    foreach ($branch in @("main", "master")) {
        $url = "https://raw.githubusercontent.com/$Owner/$Repo/$branch/$Path"
        $status = Get-HttpStatus $url
        if ($status -eq 200) {
            return $true
        }
    }
    return $false
}

function Get-GitHubFileContent {
    param([string]$Owner, [string]$Repo, [string]$Path)
    foreach ($branch in @("main", "master")) {
        $url = "https://raw.githubusercontent.com/$Owner/$Repo/$branch/$Path"
        $content = Get-HttpBody $url
        if ($content -and $content -ne "404: Not Found") {
            return $content
        }
    }
    return $null
}

# ── Known repo mappings ───────────────────────────────────────────────────────

$KnownRepos = @{
    "flask"       = "pallets/flask"
    "requests"    = "psf/requests"
    "celery"      = "celery/celery"
    "sphinx"      = "sphinx-doc/sphinx"
    "fastapi"     = "tiangolo/fastapi"
    "pydantic"    = "pydantic/pydantic"
    "docker"      = "docker/docs"
    "kubernetes"  = "kubernetes/website"
    "ansible"     = "ansible/ansible-documentation"
    "numpy"       = "numpy/numpy"
    "pandas"      = "pandas-dev/pandas"
    "pytest"      = "pytest-dev/pytest"
    "sqlalchemy"  = "sqlalchemy/sqlalchemy"
    "django"      = "django/django"
    "mkdocs"      = "mkdocs/mkdocs"
    "scrapy"      = "scrapy/scrapy"
    "aiohttp"     = "aio-libs/aiohttp"
    "httpx"       = "encode/httpx"
}

# SSG config files to probe, in priority order
$SsgChecks = @(
    @{ File = "hugo.toml";              SSG = "git-hugo"   },
    @{ File = "hugo.yaml";              SSG = "git-hugo"   },
    @{ File = "hugo.yml";               SSG = "git-hugo"   },
    @{ File = "config.toml";            SSG = "git-hugo"   },
    @{ File = "mkdocs.yml";             SSG = "git-mkdocs" },
    @{ File = "mkdocs.yaml";            SSG = "git-mkdocs" },
    @{ File = "docs/mkdocs.yml";        SSG = "git-mkdocs" },
    @{ File = "docs/en/mkdocs.yml";     SSG = "git-mkdocs" },
    @{ File = "next.config.js";         SSG = "git-nextjs" },
    @{ File = "next.config.ts";         SSG = "git-nextjs" },
    @{ File = "next.config.mjs";        SSG = "git-nextjs" },
    @{ File = "docusaurus.config.js";   SSG = "git-node"   },
    @{ File = "docusaurus.config.ts";   SSG = "git-node"   },
    @{ File = "docs/conf.py";           SSG = "sphinx"     },
    @{ File = "doc/conf.py";            SSG = "sphinx"     },
    @{ File = "docs/source/conf.py";    SSG = "sphinx"     }
)

# ── Main ──────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "RTD Mirror — Doc Type Detector" -ForegroundColor White
Write-Host "Input : $Input" -ForegroundColor Cyan

$IsUrl = $Input.StartsWith("http")
$ResultSlug   = ""
$ResultType   = ""
$ResultRepo   = ""
$ResultBranch = "main"
$ResultExtra  = ""
$GhOwner      = ""
$GhRepo       = ""
$TargetUrl    = ""

if ($IsUrl) {
    $TargetUrl = $Input
    $uri = [System.Uri]$Input
    $ResultSlug = $uri.Host -replace "^docs\." -replace "^www\." -replace "\..*$"
} else {
    $ResultSlug = $Input
    $TargetUrl  = "https://$Input.readthedocs.io/en/stable/"
}

Write-Host "Slug  : $ResultSlug`n" -ForegroundColor Cyan

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 — Check Read the Docs
# ─────────────────────────────────────────────────────────────────────────────
Write-Section "Step 1: Checking Read the Docs"

$RtdSlug = $ResultSlug
if ($IsUrl -and $Input -match "\.readthedocs\.io") {
    $RtdSlug = ($Input -replace "https://","" -replace "\.readthedocs\.io.*","")
    Write-Info "URL looks like RTD-hosted (slug: $RtdSlug)"
}

$htmlzipUrl = "https://$RtdSlug.readthedocs.io/_/downloads/en/stable/htmlzip/"
$htmlzipStatus = Get-HttpStatus $htmlzipUrl
Write-Verbose "htmlzip probe → $htmlzipUrl ($htmlzipStatus)"

if ($htmlzipStatus -eq 200) {
    Write-Ok "RTD htmlzip available → $htmlzipUrl"
    $ResultType = "rtd"
    $ResultSlug = $RtdSlug
} else {
    # Try RTD API
    $apiBody = Get-HttpBody "https://readthedocs.org/api/v2/project/?slug=$RtdSlug"
    if ($apiBody) {
        try {
            $apiData = $apiBody | ConvertFrom-Json
            if ($apiData.count -gt 0) {
                Write-Ok "Found on RTD API — htmlzip probe returned $htmlzipStatus (may be IP-restricted)"
                $ResultType = "rtd"
                $ResultSlug = $RtdSlug
            } else {
                Write-Warn "Not found on RTD"
            }
        } catch {
            Write-Warn "RTD API returned unparseable response"
        }
    } else {
        Write-Warn "Not found on RTD (htmlzip=$htmlzipStatus)"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2 — Find GitHub source repo
# ─────────────────────────────────────────────────────────────────────────────
Write-Section "Step 2: Looking for a GitHub source repo"

if ($KnownRepos.ContainsKey($ResultSlug)) {
    $full = $KnownRepos[$ResultSlug]
    $GhOwner = $full.Split("/")[0]
    $GhRepo  = $full.Split("/")[1]
    Write-Ok "Known project → GitHub: $GhOwner/$GhRepo"
} else {
    # Try to scrape GitHub link from the page
    $body = Get-HttpBody $TargetUrl
    if ($body) {
        $ghMatches = [regex]::Matches($body, 'github\.com/([a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+)')
        if ($ghMatches.Count -gt 0) {
            $firstMatch = $ghMatches[0].Groups[1].Value
            # Filter out obvious non-source matches
            if ($firstMatch -notmatch "^(github|features|topics|trending)") {
                $GhOwner = $firstMatch.Split("/")[0]
                $GhRepo  = $firstMatch.Split("/")[1]
                Write-Ok "Found GitHub repo in page source: $GhOwner/$GhRepo"
            }
        }
    }

    if (-not $GhOwner) {
        Write-Warn "Could not find GitHub repo automatically"
        Write-Warn "Search manually: https://github.com/search?q=$ResultSlug+docs&type=repositories"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 — Detect SSG
# ─────────────────────────────────────────────────────────────────────────────
$DetectedSSG     = ""
$DetectedFile    = ""

if ($GhOwner -and $GhRepo) {
    Write-Section "Step 3: Detecting SSG in $GhOwner/$GhRepo"
    $ResultRepo = "https://github.com/$GhOwner/$GhRepo"

    foreach ($check in $SsgChecks) {
        $file = $check.File
        $ssg  = $check.SSG
        Write-Verbose "  Probing: $file"
        if (Test-GitHubFileExists -Owner $GhOwner -Repo $GhRepo -Path $file) {
            Write-Ok "Found: $file → $ssg"
            $DetectedSSG  = $ssg
            $DetectedFile = $file
            break
        }
    }

    if (-not $DetectedSSG) {
        Write-Warn "Could not detect SSG from known config files"
    }

    # Determine default branch
    foreach ($branch in @("main", "master")) {
        $branchStatus = Get-HttpStatus "https://github.com/$GhOwner/$GhRepo/tree/$branch"
        if ($branchStatus -eq 200) {
            $ResultBranch = $branch
            Write-Verbose "Default branch: $branch"
            break
        }
    }

    # Build extra YAML fields
    switch ($DetectedSSG) {
        "git-mkdocs" { $ResultExtra = "  config: $DetectedFile" }
        "git-hugo"   { $ResultExtra = "  hugo_version: `"latest`"   # pin for reproducibility" }
        "git-nextjs" { $ResultExtra = "  build_cmd: `"npm ci && npm run build`"`n  out_dir: out" }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4 — Resolve final type
# ─────────────────────────────────────────────────────────────────────────────
Write-Section "Step 4: Resolution"

if ($DetectedSSG -and $DetectedSSG -ne "sphinx") {
    $ResultType = $DetectedSSG
} elseif ($DetectedSSG -eq "sphinx" -and -not $ResultType) {
    $ResultType = "rtd"
    Write-Warn "Sphinx detected — project is likely on RTD. Verify: https://$ResultSlug.readthedocs.io/"
}

if (-not $ResultType) {
    $ResultType = "wget"
    Write-Warn "Could not determine type — falling back to wget (last resort)"
}

Write-Ok "Final type: $ResultType"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5 — Print recommended projects.yml entry
# ─────────────────────────────────────────────────────────────────────────────
Write-Section "Recommended projects.yml entry"
Write-Host ""
Write-Host "# Detected: $ResultType" -ForegroundColor Green
Write-Host ""

switch ($ResultType) {
    "rtd" {
        Write-Host "- type: rtd"
        Write-Host "  slug: $ResultSlug"
        Write-Host "  version: stable"
        Write-Host "  formats: [htmlzip]"
    }
    "git-mkdocs" {
        Write-Host "- type: git-mkdocs"
        Write-Host "  slug: $ResultSlug"
        Write-Host "  repo: $ResultRepo"
        Write-Host "  branch: $ResultBranch"
        if ($ResultExtra) { Write-Host $ResultExtra }
    }
    "git-hugo" {
        Write-Host "- type: git-hugo"
        Write-Host "  slug: $ResultSlug"
        Write-Host "  repo: $ResultRepo"
        Write-Host "  branch: $ResultBranch"
        if ($ResultExtra) { Write-Host $ResultExtra }
    }
    "git-nextjs" {
        Write-Host "- type: git-nextjs"
        Write-Host "  slug: $ResultSlug"
        Write-Host "  repo: $ResultRepo"
        Write-Host "  branch: $ResultBranch"
        if ($ResultExtra) { Write-Host $ResultExtra }
    }
    "wget" {
        Write-Host "- type: wget"
        Write-Host "  slug: $ResultSlug"
        Write-Host "  url: $TargetUrl"
        Write-Host "  depth: 4"
    }
    default {
        Write-Host "- type: wget"
        Write-Host "  slug: $ResultSlug"
        Write-Host "  url: $TargetUrl"
        Write-Host "  depth: 4"
    }
}

Write-Host ""
Write-Host "Tip: Run with -Verbose to see all probe details" -ForegroundColor Yellow
Write-Host "Tip: Always test the output renders correctly before adding to projects.yml" -ForegroundColor Yellow
Write-Host ""