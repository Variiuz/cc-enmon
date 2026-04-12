param(
    [ValidateSet('major', 'minor', 'patch')]
    [string]$Part = 'patch',

    [string]$Version,

    [string]$Date = (Get-Date -Format 'yyyy-MM-dd'),

    [string[]]$Notes,

    [switch]$SkipChangelog
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $repoRoot 'manifest.json'
$installerPath = Join-Path $repoRoot 'installer.lua'
$versionPath = Join-Path $repoRoot 'lib/version.lua'
$changelogPath = Join-Path $repoRoot 'changelog.json'

function Get-NextVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CurrentVersion,

        [Parameter(Mandatory = $true)]
        [string]$Part
    )

    $parts = $CurrentVersion.Split('.')
    if ($parts.Count -ne 3) {
        throw "Expected semantic version x.y.z but got '$CurrentVersion'."
    }

    $major = [int]$parts[0]
    $minor = [int]$parts[1]
    $patch = [int]$parts[2]

    switch ($Part) {
        'major' { $major += 1; $minor = 0; $patch = 0 }
        'minor' { $minor += 1; $patch = 0 }
        'patch' { $patch += 1 }
    }

    return "$major.$minor.$patch"
}

function Update-FileVersionString {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Pattern,

        [Parameter(Mandatory = $true)]
        [string]$Replacement
    )

    $raw = Get-Content -Path $Path -Raw
    $updated = [regex]::Replace($raw, $Pattern, $Replacement, 1)
    if ($updated -eq $raw) {
        throw "No version string matched in $Path"
    }
    Set-Content -Path $Path -Value $updated
}

$manifest = Get-Content -Path $manifestPath -Raw | ConvertFrom-Json
$currentVersion = [string]$manifest.version

if (-not $Version) {
    $Version = Get-NextVersion -CurrentVersion $currentVersion -Part $Part
}

$manifest.version = $Version
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath

Update-FileVersionString -Path $installerPath -Pattern 'readManifestValue\("version", "[^"]+"\)' -Replacement ('readManifestValue("version", "{0}")' -f $Version)
Update-FileVersionString -Path $versionPath -Pattern 'version = "[^"]+"' -Replacement ('version = "{0}"' -f $Version)

if (-not $SkipChangelog) {
    if (Test-Path $changelogPath) {
        $changelog = Get-Content -Path $changelogPath -Raw | ConvertFrom-Json
        $entries = @($changelog.entries)
    } else {
        $entries = @()
    }

    if (-not $Notes -or $Notes.Count -eq 0) {
        $Notes = @(git -C $repoRoot log --pretty=format:%s -n 10)
        if (-not $Notes -or $Notes.Count -eq 0) {
            $Notes = @('Version bump.')
        }
    }

    $gitHead = $null
    try {
        $gitHead = (git -C $repoRoot rev-parse --short HEAD).Trim()
    } catch {
        $gitHead = $null
    }

    $newEntry = [ordered]@{
        version = $Version
        date = $Date
        git_head = $gitHead
        notes = @($Notes)
    }

    $filtered = @()
    foreach ($entry in $entries) {
        if ($entry.version -ne $Version) {
            $filtered += $entry
        }
    }

    $updatedChangelog = [ordered]@{
        entries = $filtered + @($newEntry)
    }

    $updatedChangelog | ConvertTo-Json -Depth 10 | Set-Content -Path $changelogPath
}

Write-Host ("Version bumped: {0} -> {1}" -f $currentVersion, $Version)
if (-not $SkipChangelog) {
    Write-Host "Updated changelog.json"
}