[CmdletBinding()]
param(
    [string]$ProjectRoot = $PSScriptRoot,
    [ValidateRange(1, 3)]
    [int]$ParallelBuilds = 2
)

$ErrorActionPreference = 'Stop'
function Stop-BuildScript([string]$Message, [int]$Code = 1) {
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit $Code
}
function Format-Elapsed([double]$Seconds) {
    $duration = [TimeSpan]::FromSeconds([Math]::Max(0, $Seconds))
    return '{0:00}:{1:00}:{2:00}' -f [int]$duration.TotalHours, $duration.Minutes, $duration.Seconds
}

try { $ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path }
catch { Stop-BuildScript "Project folder not found: $ProjectRoot" }
if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot 'build.yaml') -PathType Leaf)) {
    Stop-BuildScript "build.yaml not found under $ProjectRoot."
}
if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot 'config/west.yml') -PathType Leaf)) {
    Stop-BuildScript "config/west.yml not found under $ProjectRoot."
}

# These entries match the supplied build.yaml.
$Builds = @(
    [pscustomobject]@{ Name='left'; Board='seeeduino_xiao_ble'; Shield='LiNEA40_left rgbled_adapter'; Snippet=''; CMakeArgs=@(); Output='LiNEA40_left.uf2' },
    [pscustomobject]@{ Name='right'; Board='seeeduino_xiao_ble'; Shield='LiNEA40_right rgbled_adapter'; Snippet='studio-rpc-usb-uart'; CMakeArgs=@('-DCONFIG_ZMK_STUDIO=y'); Output='LiNEA40_right.uf2' },
    [pscustomobject]@{ Name='settings_reset'; Board='seeeduino_xiao_ble'; Shield='settings_reset'; Snippet=''; CMakeArgs=@(); Output='LiNEA40_settings_reset.uf2' }
)

$Image = 'zmkfirmware/zmk-build-arm:stable'
$ContainerRoot = '/workspaces/zmk-config'
$FirmwareDir = Join-Path $ProjectRoot 'firmware'
$BuildRoot = Join-Path $ProjectRoot 'build'
$LogicalCores = [Environment]::ProcessorCount
$JobsPerBuild = [Math]::Max(1, [int][Math]::Floor($LogicalCores / $ParallelBuilds))

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { Stop-BuildScript 'Docker command not found.' }
& docker info *> $null
if ($LASTEXITCODE -ne 0) { Stop-BuildScript 'Docker is not running. Start Docker Desktop first.' }
& docker image inspect $Image *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Downloading Docker image $Image ..." -ForegroundColor Cyan
    & docker pull $Image
    if ($LASTEXITCODE -ne 0) { Stop-BuildScript 'Could not download the Docker image.' }
}

New-Item -ItemType Directory -Force -Path $FirmwareDir, $BuildRoot | Out-Null
$BashLines = @(
    'if [ ! -f .west/config ]; then'
    '  echo "Initializing West workspace..."'
    '  west init -l config'
    '  setup_status=$?'
    '  if [ "$setup_status" -ne 0 ]; then echo "__WEST_INIT_FAILED__:$setup_status"; exit "$setup_status"; fi'
    'fi'
    'needs_update=0'
    'for required in zmk/app zephyr/share/zephyr-package/cmake/zephyr_export.cmake modules zmk-naginata zmk-pmw3610-driver zmk-rgbled-widget; do'
    '  if [ ! -e "$required" ]; then needs_update=1; fi'
    'done'
    'if [ "$needs_update" -ne 0 ]; then'
    '  echo "Missing West projects detected; fetching dependencies (network required on first setup)..."'
    '  west update --fetch-opt=--filter=tree:0'
    '  setup_status=$?'
    '  if [ "$setup_status" -ne 0 ]; then echo "__WEST_UPDATE_FAILED__:$setup_status"; exit "$setup_status"; fi'
    'fi'
    'cmake -P zephyr/share/zephyr-package/cmake/zephyr_export.cmake'
    'export_status=$?'
    'if [ "$export_status" -ne 0 ]; then echo "__ZEPHYR_EXPORT_FAILED__:$export_status"; exit "$export_status"; fi'
)

for ($i = 0; $i -lt $Builds.Count; $i++) {
    $Build = $Builds[$i]
    $BuildDir = "build/$($Build.Name)"
    $StateDir = Join-Path $BuildRoot $Build.Name
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    $SignatureObject = [ordered]@{
        Board = $Build.Board
        Shield = $Build.Shield
        Snippet = $Build.Snippet
        CMakeArgs = @($Build.CMakeArgs)
    }
    $Signature = $SignatureObject | ConvertTo-Json -Compress
    Set-Content -LiteralPath (Join-Path $StateDir '.build-config.expected') -Value $Signature -Encoding UTF8
    Remove-Item -LiteralPath (Join-Path $StateDir '.build-result'), (Join-Path $StateDir '.build-duration') -Force -ErrorAction SilentlyContinue

    $Progress = $i + 1
    $FunctionName = "build_$($Build.Name)"
    $BashLines += "$FunctionName() {"
    $BashLines += '  local start_time=$(date +%s)'
    $BashLines += "  echo '=== Build $Progress/$($Builds.Count): $($Build.Name) started ==='"
    $BashLines += "  if [ -f '$BuildDir/CMakeCache.txt' ] && cmp -s '$BuildDir/.build-config.expected' '$BuildDir/.build-config'; then"
    $BashLines += "    echo 'Using cached build configuration'"
    $BashLines += "    west build -o=-j$JobsPerBuild -d '$BuildDir'"
    $BashLines += '  else'
    $BashLines += "    echo 'Configuring CMake and building'"
    $BuildCommand = "    west build -o=-j$JobsPerBuild -s zmk/app -d '$BuildDir' -p auto -b '$($Build.Board)' -- -DZMK_CONFIG='$ContainerRoot/config' -DSHIELD='$($Build.Shield)'"
    if ($Build.Snippet) { $BuildCommand += " -DSNIPPET='$($Build.Snippet)'" }
    foreach ($Arg in $Build.CMakeArgs) { $BuildCommand += " '$Arg'" }
    $BashLines += $BuildCommand
    $BashLines += '  fi'
    $BashLines += '  local build_status=$?'
    $BashLines += '  local elapsed=$(($(date +%s)-start_time))'
    $BashLines += ('  echo "$build_status" > ' + "'" + $BuildDir + '/.build-result' + "'")
    $BashLines += ('  echo "$elapsed" > ' + "'" + $BuildDir + '/.build-duration' + "'")
    $BashLines += '  if [ "$build_status" -eq 0 ]; then'
    $BashLines += ('    cp ' + "'" + $BuildDir + '/.build-config.expected' + "' '" + $BuildDir + '/.build-config' + "'")
    $BashLines += ('    echo "=== ' + $Build.Name + ' SUCCESS after $elapsed seconds ==="')
    $BashLines += '  else'
    $BashLines += ('    echo "=== ' + $Build.Name + ' FAILED with exit $build_status after $elapsed seconds ==="')
    $BashLines += '  fi'
    $BashLines += '  return "$build_status"'
    $BashLines += '}'
}

for ($offset = 0; $offset -lt $Builds.Count; $offset += $ParallelBuilds) {
    $GroupEnd = [Math]::Min($offset + $ParallelBuilds, $Builds.Count)
    for ($i = $offset; $i -lt $GroupEnd; $i++) {
        $FunctionName = "build_$($Builds[$i].Name)"
        $BashLines += "$FunctionName &"
        $BashLines += ('pid_' + $Builds[$i].Name + '=$!')
    }
    for ($i = $offset; $i -lt $GroupEnd; $i++) {
        $BuildName = $Builds[$i].Name
        $BashLines += ('wait "$pid_' + $BuildName + '"; result_' + $BuildName + '=$?')
    }
}
$BashLines += 'exit 0'

$BashScript = [string]::Join([string][char]10, $BashLines)
$RunnerScriptPath = Join-Path $BuildRoot '.run-zmk-builds.sh'
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($RunnerScriptPath, $BashScript, $Utf8NoBom)

Write-Host "Project: $ProjectRoot"
Write-Host "Parallel builds: $ParallelBuilds; Ninja jobs per build: $JobsPerBuild" -ForegroundColor Cyan
Write-Host 'Use -ParallelBuilds 1 if Docker runs out of memory; try 3 for more parallelism.' -ForegroundColor DarkGray
$TotalTimer = [Diagnostics.Stopwatch]::StartNew()
& docker run --rm -v "${ProjectRoot}:${ContainerRoot}" -w $ContainerRoot $Image bash $ContainerRoot/build/.run-zmk-builds.sh
$ContainerExitCode = $LASTEXITCODE
$TotalTimer.Stop()

$Results = @()
$AnyFailed = $false
foreach ($Build in $Builds) {
    $StateDir = Join-Path $BuildRoot $Build.Name
    $ResultPath = Join-Path $StateDir '.build-result'
    $DurationPath = Join-Path $StateDir '.build-duration'
    $Uf2Path = Join-Path $ProjectRoot "build/$($Build.Name)/zephyr/zmk.uf2"
    $OutputPath = Join-Path $FirmwareDir $Build.Output
    $Elapsed = 'unknown'
    if (Test-Path -LiteralPath $DurationPath -PathType Leaf) {
        $Elapsed = Format-Elapsed ([double](Get-Content -LiteralPath $DurationPath -Raw).Trim())
    }

    if ($ContainerExitCode -ne 0 -and -not (Test-Path -LiteralPath $ResultPath)) {
        $AnyFailed = $true
        $Results += [pscustomobject]@{ Build=$Build.Name; Result='FAILED'; Time=$Elapsed; Output="Docker/Zephyr setup failed (exit $ContainerExitCode)" }
        continue
    }
    if (-not (Test-Path -LiteralPath $ResultPath -PathType Leaf)) {
        $AnyFailed = $true
        $Results += [pscustomobject]@{ Build=$Build.Name; Result='FAILED'; Time=$Elapsed; Output='Build result marker missing; check Docker output.' }
        continue
    }

    $BuildExitCode = 1
    $ResultText = (Get-Content -LiteralPath $ResultPath -Raw).Trim()
    if ($ResultText -match '^\d+$') { $BuildExitCode = [int]$ResultText }
    if ($BuildExitCode -eq 0 -and (Test-Path -LiteralPath $Uf2Path -PathType Leaf)) {
        try {
            Copy-Item -LiteralPath $Uf2Path -Destination $OutputPath -Force
            $Results += [pscustomobject]@{ Build=$Build.Name; Result='SUCCESS'; Time=$Elapsed; Output=$OutputPath }
        } catch {
            $AnyFailed = $true
            $Results += [pscustomobject]@{ Build=$Build.Name; Result='COPY FAILED'; Time=$Elapsed; Output=$_.Exception.Message }
        }
    } else {
        $AnyFailed = $true
        if ($BuildExitCode -eq 0) { $Reason = "Build succeeded but UF2 was not found: $Uf2Path" }
        else { $Reason = "west build exited with code $BuildExitCode" }
        $Results += [pscustomobject]@{ Build=$Build.Name; Result='FAILED'; Time=$Elapsed; Output=$Reason }
    }
}
Write-Host ''
Write-Host '=== Build results ===' -ForegroundColor Cyan
$Results | Format-Table -AutoSize
Write-Host "Total time: $(Format-Elapsed $TotalTimer.Elapsed.TotalSeconds)"
Write-Host "Output folder: $FirmwareDir"
Read-Host "続行するには Enter キーを押してください..."
if ($AnyFailed) { exit 1 } else { exit 0 }


