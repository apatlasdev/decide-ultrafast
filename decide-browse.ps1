# Decide-powered browsing for Claude Code (and anything else that can run a command).
#
#   powershell -ExecutionPolicy Bypass -File .\decide-browse.ps1 -Url "https://en.wikipedia.org" -Goal "Search for Ridgecrest California and open the article"
#
# NOTE: -ExecutionPolicy Bypass is required. CurrentUser and LocalMachine are
# both Undefined on this machine, so Windows defaults to Restricted and a bare
# 'powershell -File ...' fails with "running scripts is disabled on this system".
# NOTE 2: its Chrome profile lives at C:\decide\chrome-profile (moved off %TEMP% on
# 2026-09-18 so a disk cleanup cannot wipe the logins). Sign in to a site there
# once and it persists. Signed in as of 2026-09-18: Discord.
#
# Decide picks the element for each step through OpenRouter's Decisions API (~250ms
# per decision; default model inception/mercury-decide:free, set via TYPESAFE_MODEL
# in .env, same API shape as Decide); a small text model only types. Uses its own Chrome profile on
# port 9222 so your normal Chrome and its logins are untouched.

param(
  [Parameter(Mandatory = $true)][string]$Url,
  [Parameter(Mandatory = $true)][string[]]$Goal
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$python = if ($env:DECIDE_PYTHON) { $env:DECIDE_PYTHON } else { (Get-Command python -ErrorAction Stop).Source }
$chrome = "C:\Program Files\Google\Chrome\Application\chrome.exe"
$profileDir = if ($env:DECIDE_CHROME_PROFILE) { $env:DECIDE_CHROME_PROFILE } else { Join-Path $env:LOCALAPPDATA "decide-ultrafast\chrome-profile" }

# Bring up the dedicated debug Chrome only when it is not already listening.
$live = $false
try {
  Invoke-WebRequest -Uri "http://127.0.0.1:9222/json/version" -UseBasicParsing -TimeoutSec 3 | Out-Null
  $live = $true
} catch { $live = $false }

if (-not $live) {
  New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
  Start-Process $chrome -ArgumentList "--remote-debugging-port=9222", "--user-data-dir=$profileDir", "--no-first-run", "--no-default-browser-check", "about:blank"
  Start-Sleep -Seconds 6
}

$env:BU_CDP_URL = "http://127.0.0.1:9222"

# Relative paths on purpose: an absolute Windows path loses its backslashes on
# the way through uv argument parsing, so the script runs from the project root.
$cliArgs = @("-m", "uv", "run", "--env-file", ".env", "python", "examples/run.py", "--url", $Url)
foreach ($g in $Goal) { $cliArgs += @("--goal", $g) }

function Reset-Harness {
  # The browser-harness daemon wedges after Chrome goes away and then answers
  # nothing ("Emulation.setDeviceMetricsOverride timed out"). Killing the daemon
  # and its Chrome makes the next run start both cleanly.
  Get-CimInstance Win32_Process -Filter "Name like '%python%'" |
    Where-Object { $_.CommandLine -like "*browser_harness*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" |
    Where-Object { $_.CommandLine -like "*chrome-profile*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Seconds 4
  New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
  Start-Process $chrome -ArgumentList "--remote-debugging-port=9222", "--user-data-dir=$profileDir", "--no-first-run", "--no-default-browser-check", "about:blank"
  Start-Sleep -Seconds 6
}

Push-Location $root
try {
  $output = & $python @cliArgs 2>&1
  $output
  if ($output -match "timed out after .*s waiting for the daemon") {
    Write-Host "harness was wedged; resetting and retrying once"
    Reset-Harness
    & $python @cliArgs
  }
} finally { Pop-Location }
