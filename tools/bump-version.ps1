param(
    [ValidateSet('major', 'minor', 'patch')]
    [string]$Part = 'patch',

    [string]$Version,

    [switch]$Hotfix,

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
$basaltUrl = 'https://raw.githubusercontent.com/Pyroxenium/Basalt2/main/release/basalt-core.lua'

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
    $regex = [regex]::new($Pattern)
    if (-not $regex.IsMatch($raw)) {
        throw "No version string matched in $Path"
    }
    $updated = $regex.Replace($raw, $Replacement, 1)
    Set-Content -Path $Path -Value $updated
}

function Get-NormalizedUtf8Bytes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $normalized = $Text -replace "`r`n", "`n"
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    return $utf8.GetBytes($normalized)
}

function Get-Sha256Hex {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($Bytes)
    }
    finally {
        $sha.Dispose()
    }

    return ([System.BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
}

function Get-NormalizedFileHash {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $raw = Get-Content -Path $Path -Raw
    return Get-Sha256Hex -Bytes (Get-NormalizedUtf8Bytes -Text $raw)
}

function Get-NormalizedUrlHash {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing
    return Get-Sha256Hex -Bytes (Get-NormalizedUtf8Bytes -Text $response.Content)
}

function Get-ManifestManagedPaths {
    param(
        [Parameter(Mandatory = $true)]
        $Manifest
    )

    $paths = New-Object System.Collections.Generic.List[string]
    $seen = @{}

    foreach ($path in @('installer.lua', 'lib/basalt.lua')) {
        if (-not $seen.ContainsKey($path)) {
            $seen[$path] = $true
            $paths.Add($path)
        }
    }

    foreach ($entry in $Manifest.files.common) {
        if (-not $seen.ContainsKey($entry)) {
            $seen[$entry] = $true
            $paths.Add($entry)
        }
    }

    foreach ($roleProp in $Manifest.files.PSObject.Properties) {
        foreach ($entry in $roleProp.Value) {
            if (-not $seen.ContainsKey($entry)) {
                $seen[$entry] = $true
                $paths.Add($entry)
            }
        }
    }

    return $paths
}

function Update-ManifestHashes {
    param(
        [Parameter(Mandatory = $true)]
        $Manifest,

        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [string]$BasaltUrl
    )

    $hashes = [ordered]@{}
    foreach ($path in Get-ManifestManagedPaths -Manifest $Manifest) {
        if ($path -eq 'lib/basalt.lua') {
            $hashes[$path] = Get-NormalizedUrlHash -Url $BasaltUrl
            continue
        }

        $fullPath = Join-Path $RepoRoot $path
        if (-not (Test-Path $fullPath)) {
            throw "Managed file missing for hashing: $path"
        }
        $hashes[$path] = Get-NormalizedFileHash -Path $fullPath
    }

    $Manifest | Add-Member -NotePropertyName hashes -NotePropertyValue $hashes -Force
}

function Set-ManifestRevision {
    param(
        [Parameter(Mandatory = $true)]
        $Manifest,

        [Parameter(Mandatory = $true)]
        [int]$ManifestRevision
    )

    $Manifest | Add-Member -NotePropertyName manifest_revision -NotePropertyValue $ManifestRevision -Force
}

$manifest = Get-Content -Path $manifestPath -Raw | ConvertFrom-Json
$currentVersion = [string]$manifest.version
$currentManifestRevision = 0
if ($manifest.PSObject.Properties.Name -contains 'manifest_revision') {
    $currentManifestRevision = [int]$manifest.manifest_revision
}

if ($Hotfix -and $PSBoundParameters.ContainsKey('Version') -and $Version -ne $currentVersion) {
    throw 'Hotfix mode cannot change the semantic version. Omit -Version or pass the current version.'
}

if ($Hotfix) {
    $Version = $currentVersion
}
elseif (-not $Version) {
    $Version = Get-NextVersion -CurrentVersion $currentVersion -Part $Part
}

$manifestRevision = if ($Hotfix) { $currentManifestRevision + 1 } else { 0 }

$manifest.version = $Version
Set-ManifestRevision -Manifest $manifest -ManifestRevision $manifestRevision

Update-FileVersionString -Path $installerPath -Pattern 'local VERSION\s*=\s*composeReleaseLabel\(readManifestValue\("version", "[^"]+"\), readManifestNumber\("manifest_revision", \d+\)\)' -Replacement ('local VERSION    = composeReleaseLabel(readManifestValue("version", "{0}"), readManifestNumber("manifest_revision", {1}))' -f $Version, $manifestRevision)
Update-FileVersionString -Path $versionPath -Pattern '(?m)^\s*version = "[^"]+",' -Replacement ('    version = "{0}",' -f $Version)
Update-FileVersionString -Path $versionPath -Pattern '(?m)^\s*manifest_revision = \d+,' -Replacement ('    manifest_revision = {0},' -f $manifestRevision)

$manifest = Get-Content -Path $manifestPath -Raw | ConvertFrom-Json
$manifest.version = $Version
Set-ManifestRevision -Manifest $manifest -ManifestRevision $manifestRevision
Update-ManifestHashes -Manifest $manifest -RepoRoot $repoRoot -BasaltUrl $basaltUrl
$manifest | ConvertTo-Json -Depth 20 | Set-Content -Path $manifestPath

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

    $newEntry = [ordered]@{
        version = $Version
        manifest_revision = $manifestRevision
        date = $Date
        git_head = $gitHead
        notes = @($Notes)
    }

    $filtered = @()
    foreach ($entry in $entries) {
        $entryRevision = 0
        if ($entry.PSObject.Properties.Name -contains 'manifest_revision') {
            $entryRevision = [int]$entry.manifest_revision
        }
        if ($entry.version -ne $Version -or $entryRevision -ne $manifestRevision) {
            $filtered += $entry
        }
    }

    $updatedChangelog = [ordered]@{
        entries = $filtered + @($newEntry)
    }

    $updatedChangelog | ConvertTo-Json -Depth 10 | Set-Content -Path $changelogPath
}

if ($Hotfix) {
    Write-Host ("Hotfix revision bumped: {0}+r{1} -> {2}+r{3}" -f $currentVersion, $currentManifestRevision, $Version, $manifestRevision)
}
else {
    Write-Host ("Version bumped: {0} -> {1}" -f $currentVersion, $Version)
}
if (-not $SkipChangelog) {
    Write-Host "Updated changelog.json"
}