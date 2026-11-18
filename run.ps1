# CN-PAL Adoption Tool for Cisco Catalyst Center - one-line launcher (Windows)
# Usage (PowerShell):
#   irm https://raw.githubusercontent.com/cc-cnpal/cnpal-tool/main/run.ps1 | iex
#
# Downloads the latest release, extracts it to %LOCALAPPDATA%\CNPAL-Tool\app,
# and starts the local dashboard in your browser. Nothing is installed.

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # much faster Invoke-WebRequest
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$url  = 'https://github.com/cc-cnpal/cnpal-tool/releases/latest/download/CNPAL-Tool-Windows.zip'
$base = Join-Path $env:LOCALAPPDATA 'CNPAL-Tool'
$dir  = Join-Path $base 'app'
$zip  = Join-Path $env:TEMP 'CNPAL-Tool-Windows.zip'

Write-Host 'Downloading the CN-PAL Adoption Tool...'
Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip

Get-Process -Name 'cnpal-tool-*' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
New-Item -ItemType Directory -Path $dir -Force | Out-Null

Write-Host 'Extracting...'
Expand-Archive -Path $zip -DestinationPath $dir -Force
Remove-Item $zip -Force
Get-ChildItem -Path $dir -Recurse | Unblock-File

$bat = Get-ChildItem -Path $dir -Recurse -Filter 'Start.bat' | Select-Object -First 1
if (-not $bat) { throw 'Start.bat not found in the downloaded package.' }

Write-Host 'Starting the dashboard. Your browser will open; keep the new command window open while you use the tool.'
Start-Process -FilePath $bat.FullName -WorkingDirectory $bat.DirectoryName
