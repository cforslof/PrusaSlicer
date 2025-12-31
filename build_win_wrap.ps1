<# 
build_win_wrap.ps1 - Single-file wrapper for PrusaSlicer build_win.bat

Goals:
- Live console output + saved log file (tee)
- Optional parallelism cap via PS_MAX_JOBS
- Optional CMake selection via PS_CMAKE_EXE
- Pass everything else through to build_win.bat unchanged (including -s, -r, -a, -c, etc.)

Usage (from cmd.exe or VS2019 x64 tools prompt):
  powershell -NoProfile -ExecutionPolicy Bypass -File .\build_win_wrap.ps1 --log "logs\app.log" --jobs 8 --cmake cmake -s app-dirty -r none -a x64 -c Release

Wrapper args:
  --log <file>        Enable logging to <file> while keeping live output
  --no-log            Disable logging (live output only; default)
  --jobs <N>          Set PS_MAX_JOBS to cap parallelism for msbuild/cmake/cl
  --cmake <exe|path>  Set PS_CMAKE_EXE (cmake.exe | cmake3 | full path)
  --                 Stop wrapper parsing; pass remaining args through verbatim
  --help             Show this help
#>

[CmdletBinding(PositionalBinding=$false)]
param(
  # Capture *all* arguments (including tokens like -s, -r, etc.) without PowerShell trying to bind them.
  [Parameter(ValueFromRemainingArguments=$true)]
  [string[]]$AllArgs
)

function Show-Help {
  Write-Host ""
  Write-Host "build_win_wrap.ps1 - wrapper for build_win.bat"
  Write-Host ""
  Write-Host "Usage:"
  Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File .\build_win_wrap.ps1 --log ""logs\build.log"" --jobs 8 --cmake cmake -s app-dirty -r none -a x64 -c Release"
  Write-Host ""
  Write-Host "Wrapper args:"
  Write-Host "  --log <file>        Enable logging to <file> while keeping live output"
  Write-Host "  --no-log            Disable logging (default)"
  Write-Host "  --jobs <N>          Set PS_MAX_JOBS to cap parallelism for msbuild/cmake/cl"
  Write-Host "  --cmake <exe|path>  Set PS_CMAKE_EXE (cmake.exe | cmake3 | full path)"
  Write-Host "  --                 Stop wrapper parsing; pass remaining args through verbatim"
  Write-Host "  --help             Show this help"
  Write-Host ""
}

# Resolve build_win.bat next to this script
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BuildBat  = Join-Path $ScriptDir "build_win.bat"
if (-not (Test-Path -LiteralPath $BuildBat)) {
  Write-Error "Cannot find build_win.bat next to this wrapper: $BuildBat"
  exit 2
}


# PowerShell 7+ treats native stderr as error records by default; this keeps stderr as normal text output.
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -Scope Global -ErrorAction SilentlyContinue) {
  $global:PSNativeCommandUseErrorActionPreference = $false
}
# Defaults
$LogEnabled = $false
$LogFile    = $null
$Jobs       = $null
$CMakeExe   = $null
$BuildDir   = $null   # forwarded via env:PS_APP_BUILD_DIR
$TestsMode  = $null   # on|off|skip|warn|fail
$TestTarget = "libslic3r_tests"
$TestsPolicy = "fail" # fail|warn (only used with --tests warn/fail)
$MsbuildVerbosity = $null  # quiet|minimal|normal|detailed|diag
$BinlogPath = $null  # .binlog path (optional)
$RunTestsAfter = $false
$PassArgs   = New-Object System.Collections.Generic.List[string]

# Parse wrapper args
for ($i = 0; $i -lt $AllArgs.Count; $i++) {
  $a = $AllArgs[$i]

  switch ($a) {
    "--help" {
      Show-Help
      exit 0
    }
    "--log" {
      $LogEnabled = $true
      $i++
      if ($i -ge $AllArgs.Count) { Write-Error "--log requires a file path"; exit 2 }
      $LogFile = $AllArgs[$i]
      continue
    }
    "--no-log" {
      $LogEnabled = $false
      $LogFile = $null
      continue
    }
    "--jobs" {
      $i++
      if ($i -ge $AllArgs.Count) { Write-Error "--jobs requires a number"; exit 2 }
      $Jobs = [int]$AllArgs[$i]
      if ($Jobs -le 0) { Write-Error "--jobs must be > 0"; exit 2 }
      continue
    }
    "--cmake" {
      $i++
      if ($i -ge $AllArgs.Count) { Write-Error "--cmake requires an exe name or full path"; exit 2 }
      $CMakeExe = $AllArgs[$i]
      continue
    }
    "--build-dir" {
      $i++
      if ($i -ge $AllArgs.Count) { Write-Error "--build-dir requires a directory name"; exit 2 }
      $BuildDir = $AllArgs[$i]
      continue
    }
    "--tests" {
      $i++
      if ($i -ge $AllArgs.Count) { Write-Error "--tests requires one of: on|off|skip|warn|fail"; exit 2 }
      $TestsMode = ($AllArgs[$i]).ToLowerInvariant()
      if ($TestsMode -notin @("on","off","skip","warn","fail")) {
        Write-Error "--tests must be one of: on|off|skip|warn|fail"; exit 2
      }
      continue
    }
    "--test-target" {
      $i++
      if ($i -ge $AllArgs.Count) { Write-Error "--test-target requires a CMake target (e.g., libslic3r_tests)"; exit 2 }
      $TestTarget = $AllArgs[$i]
      continue
    }
    "--msbuild-verbosity" {
      $i++
      if ($i -ge $AllArgs.Count) { Write-Error "--msbuild-verbosity requires: quiet|minimal|normal|detailed|diag"; exit 2 }
      $MsbuildVerbosity = ($AllArgs[$i]).ToLowerInvariant()
      if ($MsbuildVerbosity -notin @("quiet","minimal","normal","detailed","diag")) {
        Write-Error "--msbuild-verbosity must be: quiet|minimal|normal|detailed|diag"; exit 2
      }
      continue
    }
    "--binlog" {
      $i++
      if ($i -ge $AllArgs.Count) { Write-Error "--binlog requires a .binlog path"; exit 2 }
      $BinlogPath = $AllArgs[$i]
      continue
    }
    "--" {
      # Pass everything after -- straight through
      for ($j = $i + 1; $j -lt $AllArgs.Count; $j++) {
        $PassArgs.Add($AllArgs[$j])
      }
      break
    }
    default {
      $PassArgs.Add($a)
      continue
    }
  }
}

# Apply env vars for build_win.bat to consume
if ($Jobs)    { $env:PS_MAX_JOBS  = "$Jobs" }
if ($CMakeExe){ $env:PS_CMAKE_EXE = "$CMakeExe" }


# Wrapper-driven env overrides (consumed by build_win.bat)
if ($BuildDir) { $env:PS_APP_BUILD_DIR = "$BuildDir" }
if ($MsbuildVerbosity) { $env:PS_MSBUILD_VERBOSITY = "$MsbuildVerbosity" }
if ($BinlogPath) {
  $fullBinlog = $BinlogPath
  if (-not [System.IO.Path]::IsPathRooted($fullBinlog)) { $fullBinlog = Join-Path (Get-Location) $fullBinlog }
  $env:PS_MSBUILD_BINLOG = "$fullBinlog"
}

# Tests navigation:
#   on   = build ALL_BUILD (includes tests if generated) and fail on any compile error
#   off  = configure without tests + build GUI app only (most reliable dev loop)
#   skip = configure with tests ON but build GUI app only (tests available in solution but not built)
#   warn = build GUI app, then try building test target; if tests fail, print warning and still exit 0
#   fail = build GUI app, then try building test target; if tests fail, exit non-zero
if ($TestsMode) {
  switch ($TestsMode) {
    "on" {
      $env:PS_SLIC3R_BUILD_TESTS = "ON"
      $env:PS_APP_BUILD_TARGET   = "ALL_BUILD"
      $RunTestsAfter = $false
    }
    "off" {
      $env:PS_SLIC3R_BUILD_TESTS = "OFF"
      $env:PS_APP_BUILD_TARGET   = "PrusaSlicer_app_gui"
      $RunTestsAfter = $false
    }
    "skip" {
      $env:PS_SLIC3R_BUILD_TESTS = "ON"
      $env:PS_APP_BUILD_TARGET   = "PrusaSlicer_app_gui"
      $RunTestsAfter = $false
    }
    "warn" {
      $env:PS_SLIC3R_BUILD_TESTS = "ON"
      $env:PS_APP_BUILD_TARGET   = "PrusaSlicer_app_gui"
      $RunTestsAfter = $true
      $TestsPolicy = "warn"
    }
    "fail" {
      $env:PS_SLIC3R_BUILD_TESTS = "ON"
      $env:PS_APP_BUILD_TARGET   = "PrusaSlicer_app_gui"
      $RunTestsAfter = $true
      $TestsPolicy = "fail"
    }
  }
}
# Prepare log file (optional)
$LogPath = $null
if ($LogEnabled) {
  if ([string]::IsNullOrWhiteSpace($LogFile)) {
    # Default log if --log was passed without a path (shouldn't happen due to parsing)
    $LogFile = "logs\build_win.log"
  }

  $LogPath = $LogFile
  if (-not [System.IO.Path]::IsPathRooted($LogPath)) {
    $LogPath = Join-Path (Get-Location) $LogPath
  }

  $LogDir = Split-Path -Parent $LogPath
  if (-not [string]::IsNullOrWhiteSpace($LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
  }

  Write-Host ("[wrap] Logging to: ""{0}""" -f $LogPath)
}

# Always print key env knobs so logs are self-contained
if ($Jobs)     { Write-Host ("[wrap] PS_MAX_JOBS={0}" -f $Jobs) }
if ($CMakeExe) { Write-Host ("[wrap] PS_CMAKE_EXE={0}" -f $CMakeExe) }
if ($env:PS_APP_BUILD_DIR) { Write-Host ("[wrap] PS_APP_BUILD_DIR={0}" -f $env:PS_APP_BUILD_DIR) }
if ($env:PS_SLIC3R_BUILD_TESTS) { Write-Host ("[wrap] PS_SLIC3R_BUILD_TESTS={0}" -f $env:PS_SLIC3R_BUILD_TESTS) }
if ($env:PS_APP_BUILD_TARGET) { Write-Host ("[wrap] PS_APP_BUILD_TARGET={0}" -f $env:PS_APP_BUILD_TARGET) }
if ($env:PS_MSBUILD_VERBOSITY) { Write-Host ("[wrap] PS_MSBUILD_VERBOSITY={0}" -f $env:PS_MSBUILD_VERBOSITY) }
if ($env:PS_MSBUILD_BINLOG) { Write-Host ("[wrap] PS_MSBUILD_BINLOG={0}" -f $env:PS_MSBUILD_BINLOG) }

# Run build_win.bat
if ($LogEnabled -and $LogPath) {
  & "$BuildBat" @PassArgs 2>&1 | Tee-Object -FilePath "$LogPath"
  $code = $LASTEXITCODE
} else {
  & "$BuildBat" @PassArgs
  $code = $LASTEXITCODE
}

# Optional: build tests after a successful GUI build (does not block app build unless policy=fail)
if ($RunTestsAfter -and ($code -eq 0)) {
  # Extract -c <Config> from forwarded args (default Release)
  $cfg = "Release"
  for ($k = 0; $k -lt $PassArgs.Count; $k++) {
    if ($PassArgs[$k] -eq "-c" -and ($k + 1) -lt $PassArgs.Count) { $cfg = $PassArgs[$k + 1]; break }
  }

  $bd = $env:PS_APP_BUILD_DIR
  if ([string]::IsNullOrWhiteSpace($bd)) { $bd = "build" }
  if (-not [System.IO.Path]::IsPathRooted($bd)) { $bd = Join-Path (Get-Location) $bd }

  $cm = $env:PS_CMAKE_EXE
  if ([string]::IsNullOrWhiteSpace($cm)) { $cm = "cmake.exe" }

  $msv = $env:PS_MSBUILD_VERBOSITY
  if ([string]::IsNullOrWhiteSpace($msv)) { $msv = "quiet" }

  $mOpt = "/m"
  if ($Jobs) { $mOpt = "/m:$Jobs" }

  Write-Host ("[wrap] Building test target: {0} (policy={1})" -f $TestTarget, $TestsPolicy)
  $testArgs = @("--build", $bd, "--config", $cfg, "--target", $TestTarget, "--", $mOpt, "/v:$msv")
  if ($env:PS_MSBUILD_BINLOG) { $testArgs += @("/bl:`"$($env:PS_MSBUILD_BINLOG)`"") }

  if ($LogEnabled -and $LogPath) {
    & $cm @testArgs 2>&1 | Tee-Object -FilePath $LogPath -Append
    $testCode = $LASTEXITCODE
  } else {
    & $cm @testArgs
    $testCode = $LASTEXITCODE
  }

  if ($testCode -ne 0) {
    if ($TestsPolicy -eq "warn") {
      Write-Warning ("[wrap] Tests failed to build (exit {0}). Continuing because policy=warn." -f $testCode)
      $code = 0
    } else {
      Write-Error ("[wrap] Tests failed to build (exit {0})." -f $testCode)
      $code = $testCode
    }
  }
}

exit $code
