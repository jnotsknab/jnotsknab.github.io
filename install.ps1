# Mux-Swarm Windows Installer
# Recommended usage:
#   irm https://muxswarm.dev/install.ps1 | iex
#
# Optional direct usage:
#   .\install.ps1
#   .\install.ps1 -Version v1.0.1
#   .\install.ps1 -Force
#
# Expected release asset:
#   mux-swarm-win-x64.zip
#
# Expected zip layout:
#   Mux-Swarm.exe
#   Configs\
#   Prompts\
#   runtime\
#   skills\
#   Sessions\   (optional; usually preserved locally)

[CmdletBinding()]
param(
    [string]$Version = "latest",
    [string]$RepoOwner = "jnotsknab",
    [string]$RepoName = "mux-swarm",
    [string]$AssetName = "mux-swarm-win-x64.zip",
    [string]$InstallDir = "$env:LOCALAPPDATA\Mux-Swarm",
    [switch]$Force
)

$ErrorActionPreference = "Stop"

function Write-Info($Message) { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Ok($Message)   { Write-Host "[ OK ] $Message" -ForegroundColor Green }
function Write-Warn($Message) { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Fail($Message) { Write-Host "[FAIL] $Message" -ForegroundColor Red }

function Get-DownloadUrl {
    param(
        [string]$Owner,
        [string]$Name,
        [string]$Ver,
        [string]$ZipName
    )

    if ($Ver -eq "latest") {
        return "https://github.com/$Owner/$Name/releases/latest/download/$ZipName"
    }

    return "https://github.com/$Owner/$Name/releases/download/$Ver/$ZipName"
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Ensure-PathContains {
    param([string]$PathToAdd)

    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $segments = @()

    if (-not [string]::IsNullOrWhiteSpace($userPath)) {
        $segments = $userPath.Split(';', [System.StringSplitOptions]::RemoveEmptyEntries)
    }

    $normalizedExisting = $segments | ForEach-Object { $_.Trim().TrimEnd('\') }
    $normalizedNew = $PathToAdd.Trim().TrimEnd('\')

    if ($normalizedExisting -contains $normalizedNew) {
        Write-Info "User PATH already contains $PathToAdd"
        return
    }

    $newPath = if ([string]::IsNullOrWhiteSpace($userPath)) {
        $PathToAdd
    } else {
        "$userPath;$PathToAdd"
    }

    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    $env:Path = "$env:Path;$PathToAdd"
    Write-Ok "Added $PathToAdd to user PATH"
}

function Get-PayloadRoot {
    param([string]$ExtractPath)

    $items = Get-ChildItem -Path $ExtractPath -Force
    if ($items.Count -eq 1 -and $items[0].PSIsContainer) {
        return $items[0].FullName
    }

    return $ExtractPath
}

function Find-Executable {
    param([string]$Root)

    $preferred = @(
        (Join-Path $Root "Mux-Swarm.exe"),
        (Join-Path $Root "mux-swarm.exe"),
        (Join-Path $Root "Qwe.exe"),
        (Join-Path $Root "qwe.exe")
    )

    foreach ($candidate in $preferred) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    $fallback = Get-ChildItem -Path $Root -Filter *.exe -File -Recurse |
        Sort-Object FullName |
        Select-Object -First 1

    if ($fallback) {
        return $fallback.FullName
    }

    return $null
}

function Remove-InstallPayloadButPreserveData {
    param([string]$TargetDir)

    if (-not (Test-Path $TargetDir)) {
        return
    }

    $preserve = @(
        "Sessions",
        "Configs\local.json",
        "Configs\user.json"
    )

    Get-ChildItem -Path $TargetDir -Force | ForEach-Object {
        $full = $_.FullName
        $name = $_.Name

        if ($name -eq "Sessions") {
            Write-Info "Preserving $name"
            return
        }

        Remove-Item -Path $full -Recurse -Force
    }
}

function Copy-Payload {
    param(
        [string]$SourceDir,
        [string]$TargetDir
    )

    Ensure-Directory $TargetDir

    Get-ChildItem -Path $SourceDir -Force | ForEach-Object {
        $src = $_.FullName
        $dst = Join-Path $TargetDir $_.Name

        if ($_.PSIsContainer -and $_.Name -eq "Sessions" -and (Test-Path $dst)) {
            Write-Info "Preserving existing Sessions directory"
            return
        }

        Copy-Item -Path $src -Destination $dst -Recurse -Force
    }
}

function Install-PowerShellShim {
    param(
        [string]$InstallRoot,
        [string]$ExeName
    )

    $profilePath = $PROFILE.CurrentUserAllHosts
    $profileDir = Split-Path -Parent $profilePath
    Ensure-Directory $profileDir

    if (-not (Test-Path $profilePath)) {
        New-Item -ItemType File -Path $profilePath -Force | Out-Null
    }

    $startMarker = "# >>> Mux-Swarm shim >>>"
    $endMarker   = "# <<< Mux-Swarm shim <<<"

    $shimBlock = @"
$startMarker
function mux-swarm {
    param(
        [Parameter(ValueFromRemainingArguments = `$true)]
        [string[]]`$MuxSwarmArgs
    )

    `$installDir = '$InstallRoot'
    `$exePath = Join-Path `$installDir '$ExeName'

    if (-not (Test-Path `$installDir)) {
        Write-Error "Mux-Swarm install directory not found: `$installDir"
        return
    }

    if (-not (Test-Path `$exePath)) {
        Write-Error "Mux-Swarm executable not found: `$exePath"
        return
    }

    `$originalDir = Get-Location

    try {
        Set-Location `$installDir
        & `$exePath @MuxSwarmArgs
    }
    finally {
        Set-Location `$originalDir
    }
}

Set-Alias ms mux-swarm
$endMarker
"@

    $existing = Get-Content -Path $profilePath -Raw -ErrorAction SilentlyContinue
    if (-not $existing) { $existing = "" }

    $pattern = [regex]::Escape($startMarker) + ".*?" + [regex]::Escape($endMarker)
    if ([regex]::IsMatch($existing, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)) {
        $updated = [regex]::Replace(
            $existing,
            $pattern,
            [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $shimBlock },
            [System.Text.RegularExpressions.RegexOptions]::Singleline
        )
        Set-Content -Path $profilePath -Value $updated -Encoding UTF8
        Write-Ok "Updated PowerShell profile shim"
    }
    else {
        $prefix = if ($existing.Length -gt 0 -and -not $existing.EndsWith([Environment]::NewLine)) {
            [Environment]::NewLine + [Environment]::NewLine
        } else {
            ""
        }

        Add-Content -Path $profilePath -Value ($prefix + $shimBlock) -Encoding UTF8
        Write-Ok "Installed PowerShell profile shim"
    }
}

function Write-UninstallScript {
    param(
        [string]$InstallRoot,
        [string]$ExeName
    )

    $scriptPath = Join-Path $InstallRoot "uninstall.ps1"

    $content = @"
[CmdletBinding()]
param([switch]`$KeepSessions)

`$ErrorActionPreference = 'Stop'
`$installDir = '$InstallRoot'
`$profilePath = `$PROFILE.CurrentUserAllHosts
`$startMarker = '# >>> Mux-Swarm shim >>>'
`$endMarker   = '# <<< Mux-Swarm shim <<<'

Write-Host '[INFO] Removing PowerShell shim if present...'
if (Test-Path `$profilePath) {
    `$existing = Get-Content -Path `$profilePath -Raw -ErrorAction SilentlyContinue
    if (`$existing) {
        `$pattern = [regex]::Escape(`$startMarker) + '.*?' + [regex]::Escape(`$endMarker)
        `$updated = [regex]::Replace(
            `$existing,
            `$pattern,
            '',
            [System.Text.RegularExpressions.RegexOptions]::Singleline
        ).Trim()

        Set-Content -Path `$profilePath -Value `$updated -Encoding UTF8
    }
}

if (Test-Path `$installDir) {
    if (`$KeepSessions -and (Test-Path (Join-Path `$installDir 'Sessions'))) {
        Write-Host '[INFO] Preserving Sessions directory...'
        Get-ChildItem -Path `$installDir -Force | ForEach-Object {
            if (`$_.Name -ne 'Sessions') {
                Remove-Item -Path `$_.FullName -Recurse -Force
            }
        }
    }
    else {
        Write-Host '[INFO] Removing install directory...'
        Remove-Item -Path `$installDir -Recurse -Force
    }
}

Write-Host '[ OK ] Mux-Swarm uninstalled.'
"@

    Set-Content -Path $scriptPath -Value $content -Encoding UTF8
    Write-Ok "Wrote uninstall script to $scriptPath"
}

try {
    if ($env:OS -ne "Windows_NT") {
        throw "This installer is intended for Windows."
    }

    $downloadUrl = Get-DownloadUrl -Owner $RepoOwner -Name $RepoName -Ver $Version -ZipName $AssetName

    $tempRoot = Join-Path $env:TEMP ("mux-swarm-install-" + [Guid]::NewGuid().ToString("N"))
    $zipPath = Join-Path $tempRoot $AssetName
    $extractPath = Join-Path $tempRoot "extract"

    Ensure-Directory $tempRoot
    Ensure-Directory $extractPath
    Ensure-Directory $InstallDir

    Write-Info "Downloading $downloadUrl"
    Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing
    Write-Ok "Download complete"

    Write-Info "Extracting archive"
    Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

    $payloadRoot = Get-PayloadRoot -ExtractPath $extractPath
    $exePathInPayload = Find-Executable -Root $payloadRoot

    if (-not $exePathInPayload) {
        throw "No executable found in release archive."
    }

    $exeName = Split-Path -Leaf $exePathInPayload

    if ($Force) {
        Write-Warn "Force enabled; replacing existing install payload"
        Remove-InstallPayloadButPreserveData -TargetDir $InstallDir
    }
    else {
        Write-Info "Updating install payload in place"
        Remove-InstallPayloadButPreserveData -TargetDir $InstallDir
    }

    Write-Info "Copying files to $InstallDir"
    Copy-Payload -SourceDir $payloadRoot -TargetDir $InstallDir

    $finalExe = Join-Path $InstallDir $exeName
    if (-not (Test-Path $finalExe)) {
        throw "Install completed, but executable not found at $finalExe"
    }

    Ensure-PathContains -PathToAdd $InstallDir
    Install-PowerShellShim -InstallRoot $InstallDir -ExeName $exeName
    Write-UninstallScript -InstallRoot $InstallDir -ExeName $exeName

    Write-Host ""
    Write-Ok "Mux-Swarm installed successfully"
    Write-Host "Install directory: $InstallDir"
    Write-Host "Executable:       $exeName"
    Write-Host "PowerShell cmd:   mux-swarm"
    Write-Host "Alias:            ms"
    Write-Host ""
    Write-Host "Next steps:"
    Write-Host "  1. Open a new PowerShell window, or run: . `$PROFILE"
    Write-Host "  2. Run: mux-swarm"
    Write-Host ""

    if ($exeName -match '^(Qwe|qwe)\.exe$') {
        Write-Warn "The shipped binary is still named $exeName. Once you rename it to Mux-Swarm.exe, the installer will pick it up automatically."
    }
}
catch {
    Write-Fail $_.Exception.Message
    exit 1
}
finally {
    if ($tempRoot -and (Test-Path $tempRoot)) {
        try {
            Remove-Item -Path $tempRoot -Recurse -Force
        }
        catch {
            Write-Warn "Could not fully clean temporary files at $tempRoot"
        }
    }
}