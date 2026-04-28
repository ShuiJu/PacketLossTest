param(
    [string]$ServerPath = (Join-Path $PSScriptRoot "..\OpenPacketLoss-Server"),
    [string]$OutputName = "openpacketloss-server.exe",
    [string]$CargoTargetDir = "",
    [switch]$SkipServerSync,
    [switch]$SkipServerBuild,
    [switch]$DebugBuild,
    [switch]$AllowNpxInstall
)

$ErrorActionPreference = "Stop"

function Invoke-Step {
    param(
        [string]$Name,
        [scriptblock]$Action
    )

    Write-Host "==> $Name"
    & $Action
}

function Invoke-External {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory = $PWD.Path
    )

    Push-Location $WorkingDirectory
    try {
        & $FilePath @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "$FilePath exited with code $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
    }
}

function Resolve-CommandPath {
    param([string]$CommandName)
    $command = Get-Command $CommandName -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }
    return $null
}

$frontendRoot = $PSScriptRoot
$mainJs = Join-Path $frontendRoot "main.js"
$bundleJs = Join-Path $frontendRoot "bundle.min.js"
$indexHtml = Join-Path $frontendRoot "index.html"

if (!(Test-Path -LiteralPath $mainJs)) {
    throw "main.js not found in $frontendRoot"
}
if (!(Test-Path -LiteralPath $indexHtml)) {
    throw "index.html not found in $frontendRoot"
}

Invoke-Step "Build frontend bundle" {
    $esbuild = Resolve-CommandPath "esbuild"
    if ($esbuild) {
        Invoke-External $esbuild @("main.js", "--bundle", "--format=esm", "--minify", "--outfile=bundle.min.js") $frontendRoot
        return
    }

    if ($AllowNpxInstall) {
        $npx = Resolve-CommandPath "npx"
        if ($npx) {
            Invoke-External $npx @("--yes", "esbuild@0.21.5", "main.js", "--bundle", "--format=esm", "--minify", "--outfile=bundle.min.js") $frontendRoot
            return
        }
    }

    Copy-Item -LiteralPath $mainJs -Destination $bundleJs -Force
    Write-Warning "esbuild was not found. Copied main.js to bundle.min.js without minifying. Install esbuild or rerun with -AllowNpxInstall for a minified bundle."
}

Invoke-Step "Refresh cache-busting query strings" {
    $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $html = [System.IO.File]::ReadAllText($indexHtml, [System.Text.Encoding]::UTF8)
    $html = [regex]::Replace($html, '((?:runtime-config\.js|bundle\.min\.js|styles\.min\.css|fonts\.min\.css)\?v=)\d+', "`${1}$stamp")
    [System.IO.File]::WriteAllText($indexHtml, $html, $utf8NoBom)
}

if (!$SkipServerSync -or !$SkipServerBuild) {
    $resolvedServerPath = Resolve-Path -LiteralPath $ServerPath -ErrorAction SilentlyContinue
    if (!$resolvedServerPath) {
        throw "Server path not found: $ServerPath"
    }
    $serverRoot = $resolvedServerPath.Path
    $cargoToml = Join-Path $serverRoot "Cargo.toml"
    if (!(Test-Path -LiteralPath $cargoToml)) {
        throw "Cargo.toml not found in server path: $serverRoot"
    }
}

if (!$SkipServerSync) {
    Invoke-Step "Sync frontend into server embed folder" {
        $targetFrontend = Join-Path $serverRoot "frontend"
        New-Item -ItemType Directory -Path $targetFrontend -Force | Out-Null

        foreach ($file in @("index.html", "bundle.min.js", "main.js", "styles.min.css", "fonts.min.css", "README.md", "LICENSE")) {
            $source = Join-Path $frontendRoot $file
            if (Test-Path -LiteralPath $source) {
                Copy-Item -LiteralPath $source -Destination (Join-Path $targetFrontend $file) -Force
            }
        }

        foreach ($dir in @("assets", "fonts", "icon")) {
            $source = Join-Path $frontendRoot $dir
            if (Test-Path -LiteralPath $source) {
                Copy-Item -LiteralPath $source -Destination $targetFrontend -Recurse -Force
            }
        }
    }
}

if (!$SkipServerBuild) {
    Invoke-Step "Compile Rust server with embedded frontend" {
        $cargo = Resolve-CommandPath "cargo"
        if (!$cargo) {
            throw "cargo was not found in PATH"
        }

        $profileDir = if ($DebugBuild) { "debug" } else { "release" }
        $profileArgs = if ($DebugBuild) { @("build") } else { @("build", "--release") }
        $targetRoot = Join-Path $serverRoot "target"
        if ($CargoTargetDir) {
            if ([System.IO.Path]::IsPathRooted($CargoTargetDir)) {
                $targetRoot = $CargoTargetDir
            } else {
                $targetRoot = Join-Path $serverRoot $CargoTargetDir
            }
            $profileArgs += @("--target-dir", $targetRoot)
        } else {
            $defaultExe = Join-Path $targetRoot "$profileDir\openpacketloss-server.exe"
            $runningFromDefaultTarget = Get-Process -ErrorAction SilentlyContinue | Where-Object {
                try {
                    $_.Path -and ([string]::Equals($_.Path, $defaultExe, [System.StringComparison]::OrdinalIgnoreCase))
                } catch {
                    $false
                }
            }
            if ($runningFromDefaultTarget) {
                $targetRoot = Join-Path $serverRoot "target\frontend-build"
                $profileArgs += @("--target-dir", $targetRoot)
                Write-Warning "The default cargo output exe is currently running. Building in $targetRoot instead."
            }
        }
        Invoke-External $cargo $profileArgs $serverRoot

        $builtExe = Join-Path $targetRoot "$profileDir\openpacketloss-server.exe"
        if (Test-Path -LiteralPath $builtExe) {
            Copy-Item -LiteralPath $builtExe -Destination (Join-Path $serverRoot $OutputName) -Force
            Write-Host "Built: $(Join-Path $serverRoot $OutputName)"
        } else {
            Write-Host "Build completed. Binary: $builtExe"
        }
    }
}

Write-Host "Done."
