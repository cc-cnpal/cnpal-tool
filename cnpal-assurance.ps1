# CNOI Assurance Tool - PowerShell edition (no .exe)
# For PCs where antivirus or application control blocks the Windows .exe build.
#
# Usage (PowerShell):
#   irm https://raw.githubusercontent.com/cc-cnpal/cnpal-tool/main/cnpal-assurance.ps1 | iex
#
# Makes the Catalyst Center "Campus Network Observability and Insights"
# (Assurance) API calls, the same groups as the CNOI Workload button:
#   Network health  ~660 calls   (Assurance health, events, energy, licences)
#   Client health   ~660 calls   (client health, AI Endpoint Analytics)
#   360 views      ~2200 calls   (Device 360 and Client 360 across real devices/clients)
#   Audit logs      ~550 calls
#
# READ-ONLY: every request is checked before it is sent. Only GET and the
# login are allowed. Nothing on Catalyst Center is changed, even with an
# admin account. Nothing is installed. Every call is written to a CSV log.
# A full run takes about 60-75 minutes.

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$Version = '1.0.1'
$GapMs   = 700          # pause between calls
$SlowMs  = 5000         # endpoints slower than this are set aside if faster ones work

$Groups = @(
  @{ key = 'health'; name = 'Network health (Assurance health, events, energy, licences)'; target = 660; eps = @(
      '/dna/intent/api/v1/network-health',
      '/dna/intent/api/v1/site-health?limit=50',
      '/dna/intent/api/v1/device-health?limit=50',
      '/dna/data/api/v1/siteHealthSummaries?limit=50',
      '/dna/data/api/v1/networkDevices?limit=50',
      '/dna/data/api/v1/networkDevices/count',
      '/dna/data/api/v1/assuranceEvents?deviceFamily=Unified%20AP&limit=25',
      '/dna/data/api/v1/assuranceEvents/count?deviceFamily=Unified%20AP',
      '/dna/data/api/v1/energy/devices?limit=25',
      '/dna/intent/api/v1/licenses/device/count',
      '/dna/intent/api/v1/licenses/device/summary?page_number=1&order=asc&limit=25') },
  @{ key = 'client'; name = 'Client health (client health, AI Endpoint Analytics)'; target = 660; eps = @(
      '/dna/intent/api/v1/client-health',
      '/dna/data/api/v1/clients?limit=50',
      '/dna/data/api/v1/clients/count',
      '/dna/intent/api/v1/endpoint-analytics/endpoints?limit=50',
      '/dna/intent/api/v1/endpoint-analytics/endpoints/count') },
  @{ key = '360'; name = 'Device 360 and Client 360'; target = 2200; eps = @() },
  @{ key = 'audit'; name = 'Audit logs'; target = 550; eps = @(
      '/dna/data/api/v1/event/event-series/audit-logs?limit=25',
      '/dna/data/api/v1/event/event-series/audit-log/summary',
      '/dna/data/api/v1/event/event-series/audit-log/parent-records?limit=25') }
)

$AllowedPOST = @('/dna/system/api/v1/auth/token', '/api/system/v1/auth/token')

# ------------------------------------------------------------------ helpers
function Write-Step($t)  { Write-Host ''; Write-Host "> $t" -ForegroundColor Cyan }
function Write-Ok($t)    { Write-Host "  OK  $t" -ForegroundColor Green }
function Write-Skip($t)  { Write-Host "  --  $t" -ForegroundColor DarkGray }
function Write-Bad($t)   { Write-Host "  !!  $t" -ForegroundColor Yellow }

function Get-EpochMs([datetime]$d) {
  $epoch = ([datetime]'1970-01-01T00:00:00Z').ToUniversalTime()
  return [int64](($d.ToUniversalTime() - $epoch).TotalMilliseconds)
}

function Assert-ReadOnly([string]$method, [string]$path) {
  $p = ($path -split '\?')[0]
  $lp = $p.ToLower()
  if (-not $p.StartsWith('/') -or $p.Contains('..') -or $p.Contains('//') -or $lp.Contains('%2e') -or $lp.Contains('%2f') -or $p.Contains('\')) {
    throw "Blocked by the read-only guard: $method $path"
  }
  if ($method -eq 'GET') { return }
  if ($method -eq 'POST' -and $AllowedPOST -contains $p) { return }
  throw "Blocked by the read-only guard: $method $path"
}

# Endpoint as logged: query removed, device ids and MAC addresses shown as {id}
function Get-LogEndpoint([string]$path) {
  $p = ($path -split '\?')[0]
  $parts = $p -split '/'
  for ($k = 0; $k -lt $parts.Count; $k++) {
    $s = [uri]::UnescapeDataString($parts[$k])
    if ($s -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' -or
        $s -match '^([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}$' -or $s -match '^[0-9a-fA-F]{4}\.[0-9a-fA-F]{4}\.[0-9a-fA-F]{4}$') {
      $parts[$k] = '{id}'
    }
  }
  return ($parts -join '/')
}

$script:IsPS7 = $PSVersionTable.PSVersion.Major -ge 7
$script:Ok = 0; $script:Err = 0; $script:Token = $null; $script:Base = $null
$script:LastCall = Get-Date '2000-01-01'
$script:Group = 'login'
$script:LogFile = $null

function Write-CallLog($method, $path, $status, $ms) {
  if (-not $script:LogFile) { return }
  $now = Get-Date
  $res = if ($status -ge 200 -and $status -lt 300) { 'success' } else { 'error' }
  $line = '{0},{1},{2},{3},{4},{5},{6},{7}' -f $now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ'),
          $now.ToString('yyyy-MM-dd HH:mm:ss'), $method, (Get-LogEndpoint $path), $status, $res, $ms, $script:Group
  try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 } catch {}
}

function Invoke-CC([string]$method, [string]$path) {
  Assert-ReadOnly $method $path
  $wait = $GapMs - ((Get-Date) - $script:LastCall).TotalMilliseconds
  if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]$wait) }
  $script:LastCall = Get-Date
  $req = @{ Method = $method; Uri = ($script:Base + $path); TimeoutSec = 90
            Headers = @{ 'X-Auth-Token' = $script:Token; 'Accept' = 'application/json' } }
  if ($script:IsPS7) { $req.SkipCertificateCheck = $true } else { $req.UseBasicParsing = $true }
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
      $r = Invoke-RestMethod @req
      $sw.Stop()
      $script:Ok++
      Write-CallLog $method $path 200 $sw.ElapsedMilliseconds
      return @{ ok = $true; data = $r; ms = $sw.ElapsedMilliseconds }
    } catch {
      $sw.Stop()
      $code = 0
      try { $code = [int]$_.Exception.Response.StatusCode } catch {}
      if ($code -eq 429 -and $attempt -lt 3) { Write-Bad 'Rate-limited by Catalyst Center, waiting 30 s...'; Start-Sleep -Seconds 30; continue }
      if ($code -eq 401 -and $attempt -lt 3) { Connect-CC | Out-Null; $req.Headers['X-Auth-Token'] = $script:Token; continue }
      $script:Err++
      Write-CallLog $method $path $code $sw.ElapsedMilliseconds
      $msg = if ($code) { "HTTP $code" } else { $_.Exception.Message }
      return @{ ok = $false; code = $code; msg = $msg; net = ($code -eq 0); ms = $sw.ElapsedMilliseconds }
    }
  }
}

function Connect-CC {
  $user = $script:Cred.UserName
  $pass = $script:Cred.GetNetworkCredential().Password
  $b64 = $null
  try { $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${user}:${pass}")) } catch {}
  foreach ($p in @('/dna/system/api/v1/auth/token', '/api/system/v1/auth/token')) {
    Assert-ReadOnly 'POST' $p
    $req = @{ Method = 'POST'; Uri = ($script:Base + $p); TimeoutSec = 60; ContentType = 'application/json' }
    if ($b64) { $req.Headers = @{ Authorization = "Basic $b64" } } else { $req.Credential = $script:Cred }
    if ($script:IsPS7) { $req.SkipCertificateCheck = $true; if (-not $b64) { $req.Authentication = 'Basic' } } else { $req.UseBasicParsing = $true }
    try {
      $r = Invoke-RestMethod @req
      if ($r.Token) { $script:Token = $r.Token; return $true }
    } catch {
      $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch {}
      if ($code -eq 401) { throw 'Login failed: wrong username or password (HTTP 401).' }
      if ($code -eq 404) { continue }
      $m = $_.Exception.Message
      $in = $_.Exception.InnerException
      while ($in) { $m += ' | ' + $in.Message; $in = $in.InnerException }
      throw "Cannot reach Catalyst Center at $($script:Base): $m"
    }
  }
  throw 'Login failed: no token returned.'
}

# ------------------------------------------------------------------ progress
$script:PlanTotal = 0; $script:Done = 0; $script:T0 = Get-Date; $script:LastPrint = Get-Date

function Show-Progress {
  $el = ((Get-Date) - $script:T0).TotalSeconds
  $pending = [math]::Max(0, $script:PlanTotal - $script:Done)
  $left = if ($script:Done -gt 10) { [int]($pending * $el / $script:Done) } else { -1 }
  $pct = if ($script:PlanTotal) { [int]($script:Done * 100 / $script:PlanTotal) } else { 0 }
  $eta = if ($left -ge 0) { 'about {0}m {1}s left (finish ~{2})' -f [int][math]::Floor($left / 60), ($left % 60), (Get-Date).AddSeconds($left).ToString('HH:mm') } else { 'estimating...' }
  $status = "$($script:Done) / $($script:PlanTotal) calls  pending $pending  errors $($script:Err)  $eta"
  $ProgressPreference = 'Continue'
  Write-Progress -Activity "CNOI Assurance workload (read-only) - $($script:GroupName)" -Status $status -PercentComplete ([math]::Min(100, $pct))
  $ProgressPreference = 'SilentlyContinue'
  if (((Get-Date) - $script:LastPrint).TotalSeconds -ge 30) { Write-Host "  $status"; $script:LastPrint = Get-Date }
}

function Test-ErrorBudget {
  $t = $script:Ok + $script:Err
  return ($script:Err -gt 20 -and $script:Err -gt ($t * 0.025))
}

# ------------------------------------------------------------------ groups
function Invoke-StaticGroup($g, [int]$n) {
  $good = @(); $ok = 0
  foreach ($e in $g.eps) {
    $r = Invoke-CC 'GET' $e
    if ($r.ok) { $good += @{ p = $e; lat = $r.ms; fails = 0 }; $ok++; $script:Done++; Write-Ok ("GET {0} ({1:N1}s)" -f ($e -split '\?')[0], ($r.ms / 1000)) }
    else { Write-Skip "GET $(($e -split '\?')[0]) not available ($($r.msg)), skipped" }
  }
  if (-not $good.Count) { Write-Bad 'No endpoint in this group responds - check the account has Assurance read access.'; return $ok }
  $net = 0; $i = 0
  while ($ok -lt $n) {
    $usable = @($good | Where-Object { $_.fails -lt 3 })
    if (-not $usable.Count) { Write-Bad 'All endpoints in this group failed; stopping this group to protect the API error rate.'; break }
    $fast = @($usable | Where-Object { $_.lat -le $SlowMs })
    $pool = if ($fast.Count) { $fast } else { $usable }
    $e = $pool[$i % $pool.Count]; $i++
    $r = Invoke-CC 'GET' $e.p
    $e.lat = [int](($e.lat * 3 + $r.ms) / 4)
    if ($r.ok) { $ok++; $script:Done++; $e.fails = 0; $net = 0 }
    else { $e.fails++; if ($r.net) { $net++; if ($net -ge 3) { Write-Bad "Connection lost: $($r.msg)"; $script:Lost = $true; break } } }
    if (Test-ErrorBudget) { Write-Bad 'Too many errors; stopping to protect the API error rate.'; $script:Lost = $true; break }
    Show-Progress
  }
  return $ok
}

function Get-DeviceIds {
  $ids = @()
  for ($off = 1; $ids.Count -lt 2000; $off += 500) {
    $r = Invoke-CC 'GET' "/dna/intent/api/v1/network-device?offset=$off&limit=500"
    if (-not $r.ok) { break }
    $arr = @($r.data.response)
    foreach ($d in $arr) { if ($d.id -and $d.reachabilityStatus -ne 'Unreachable') { $ids += [string]$d.id } }
    if ($arr.Count -lt 500) { break }
  }
  return ,$ids
}

function Get-ClientMacs {
  $macs = New-Object System.Collections.ArrayList
  for ($off = 1; $macs.Count -lt 500; $off += 100) {
    $r = Invoke-CC 'GET' "/dna/data/api/v1/clients?limit=100&offset=$off"
    if (-not $r.ok) { break }
    $arr = @($r.data.response)
    foreach ($c in $arr) {
      $m = if ($c.macAddress) { [string]$c.macAddress } else { [string]$c.id }
      if ($m -and -not $macs.Contains($m)) { [void]$macs.Add($m) }
    }
    if ($arr.Count -lt 100) { break }
  }
  return ,@($macs)
}

function Get-360Path($kind, $style, $id) {
  $ts = Get-EpochMs ((Get-Date).AddMinutes(-5))
  $q = [uri]::EscapeDataString($id)
  switch ("$kind-$style") {
    'device-intent' { return "/dna/intent/api/v1/device-detail?identifier=uuid&searchBy=$q&timestamp=$ts" }
    'device-data'   { return "/dna/data/api/v1/networkDevices/$q" }
    'client-intent' { return "/dna/intent/api/v1/client-detail?macAddress=$q&timestamp=$ts" }
    'client-data'   { return "/dna/data/api/v1/clients/$q" }
  }
}

function Invoke-360Group([int]$n) {
  $devs = Get-DeviceIds
  $cls  = Get-ClientMacs
  Write-Host "  Found $($devs.Count) reachable devices and $($cls.Count) clients to look at."
  if (-not $devs.Count -and -not $cls.Count) { Write-Bad 'Could not list devices or clients.'; return 0 }
  $tmpls = @(
    @{ name = 'Device 360 (device-detail)';       kind = 'device'; style = 'intent' },
    @{ name = 'Device 360 (networkDevices/{id})'; kind = 'device'; style = 'data' },
    @{ name = 'Client 360 (client-detail)';       kind = 'client'; style = 'intent' },
    @{ name = 'Client 360 (clients/{id})';        kind = 'client'; style = 'data' }
  )
  $live = @(); $ok = 0
  foreach ($t in $tmpls) {
    $list = if ($t.kind -eq 'device') { $devs } else { $cls }
    if (-not $list.Count) { continue }
    $works = $false
    for ($try = 0; $try -lt [math]::Min(3, $list.Count); $try++) {
      $r = Invoke-CC 'GET' (Get-360Path $t.kind $t.style $list[$try])
      if ($r.ok) { $works = $true; $t.lat = $r.ms; $ok++; $script:Done++; break }
      if ($r.code -in 403, 405, 501) { break }
    }
    if ($works) { $t.fails = 0; $live += $t; Write-Ok ("{0} ({1:N1}s)" -f $t.name, ($t.lat / 1000)) }
    else { Write-Skip "$($t.name) not available on this release, skipped" }
  }
  if (-not $live.Count) { Write-Bad 'No 360 API responds - check the account has Assurance read access.'; return $ok }
  $cursor = @{ device = 3; client = 3 }
  $net = 0; $i = 0
  while ($ok -lt $n) {
    $usable = @($live | Where-Object { $_.fails -lt 5 })
    if (-not $usable.Count) { Write-Bad 'All 360 APIs failed; stopping this group to protect the API error rate.'; break }
    $fast = @($usable | Where-Object { $_.lat -le $SlowMs })
    $pool = if ($fast.Count) { $fast } else { $usable }
    $t = $pool[$i % $pool.Count]; $i++
    $list = if ($t.kind -eq 'device') { $devs } else { $cls }
    $id = $list[$cursor[$t.kind] % $list.Count]; $cursor[$t.kind]++
    $r = Invoke-CC 'GET' (Get-360Path $t.kind $t.style $id)
    $t.lat = [int](($t.lat * 3 + $r.ms) / 4)
    if ($r.ok) { $ok++; $script:Done++; $t.fails = 0; $net = 0 }
    else {
      $t.fails++
      if ($t.fails -eq 5) { Write-Skip "$($t.name) stopped after repeated errors" }
      if ($r.net) { $net++; if ($net -ge 3) { Write-Bad "Connection lost: $($r.msg)"; $script:Lost = $true; break } }
    }
    if (Test-ErrorBudget) { Write-Bad 'Too many errors; stopping to protect the API error rate.'; $script:Lost = $true; break }
    Show-Progress
  }
  return $ok
}

# ------------------------------------------------------------------ start
Clear-Host
Write-Host "CNOI Assurance Tool - PowerShell edition v$Version" -ForegroundColor White
Write-Host 'Read-only: only GET calls are sent. Nothing on Catalyst Center is changed.'
Write-Host "PowerShell $($PSVersionTable.PSVersion) - $($ExecutionContext.SessionState.LanguageMode) language mode"
Write-Host ''

$hostIn = Read-Host 'Catalyst Center address (IP or hostname)'
$hostIn = $hostIn.Trim().TrimEnd('/')
if ($hostIn -notmatch '^https?://') { $hostIn = 'https://' + $hostIn }
$script:Base = $hostIn
Write-Host 'Catalyst Center username and password (a read-only OBSERVER account is enough)'
$u = Read-Host 'Username'
$pw = Read-Host 'Password' -AsSecureString
if (-not $u -or -not $pw -or $pw.Length -eq 0) { Write-Bad 'No username or password entered. Stopping.'; return }
$script:Cred = New-Object System.Management.Automation.PSCredential($u.Trim(), $pw)

$mode = Read-Host 'Run type: press Enter for the FULL run (about 1 hour), or type T for a quick test (10 calls per group)'
$test = $mode.Trim().ToUpper() -eq 'T'

# Call log (CSV) in Documents\CNOI-Assurance
try {
  $docs = [Environment]::GetFolderPath('MyDocuments')
  if (-not $docs) { $docs = $env:USERPROFILE }
  if (-not $docs) { $docs = $HOME }
  if (-not $docs) { $docs = [IO.Path]::GetTempPath() }
  $dir = Join-Path $docs 'CNOI-Assurance'
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $hn = ($script:Base -replace '^https?://', '') -replace '[^A-Za-z0-9.-]', '_'
  $script:LogFile = Join-Path $dir ("api-call-log-{0}-{1}.csv" -f $hn, (Get-Date).ToString('yyyyMMdd-HHmm'))
  Set-Content -Path $script:LogFile -Value 'timestamp_utc,timestamp_local,method,endpoint,http_status,result,response_ms,group' -Encoding UTF8
} catch { $script:LogFile = $null; Write-Bad 'Could not create the call log file; continuing without it.' }

# TLS (Windows PowerShell 5.1): accept the Catalyst Center certificate (often
# self-signed) and allow TLS 1.2 and 1.3, with fallbacks.
$script:TlsOptions = @()
if (-not $script:IsPS7) {
  $certOk = $false
  try {
    if (-not ('CnpalTrustAll' -as [type])) {
      Add-Type -TypeDefinition @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class CnpalTrustAll : ICertificatePolicy {
  public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
"@
    }
    [Net.ServicePointManager]::CertificatePolicy = New-Object CnpalTrustAll
    [Net.ServicePointManager]::ServerCertificateValidationCallback = $null
    $certOk = $true
  } catch {}
  if (-not $certOk) {
    try { [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }; $certOk = $true } catch {}
  }
  if (-not $certOk) {
    Write-Bad 'This PC does not allow skipping certificate checks in Windows PowerShell 5.1.'
    Write-Bad 'If login fails, use the Catalyst Center hostname that matches its certificate, or run this in PowerShell 7 (pwsh).'
  }
  try { [Net.ServicePointManager]::Expect100Continue = $false } catch {}
  $script:TlsOptions = @(
    @{ n = 'TLS 1.2 + 1.3'; v = (3072 -bor 12288) },
    @{ n = 'Windows default'; v = 0 },
    @{ n = 'TLS 1.2 only'; v = 3072 },
    @{ n = 'TLS 1.3 only'; v = 12288 }
  )
}
function Set-Tls($o) {
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]$o.v; return $true } catch { return $false }
}

Write-Step 'Logging in'
$connected = $false; $lastErr = $null
$opts = if ($script:TlsOptions.Count) { $script:TlsOptions } else { @(@{ n = 'PowerShell 7 default'; v = $null }) }
foreach ($o in $opts) {
  if ($o.v -ne $null) { if (-not (Set-Tls $o)) { continue } }
  try { Connect-CC | Out-Null; $connected = $true; Write-Ok "Connected to $($script:Base) ($($o.n))"; break }
  catch {
    $lastErr = $_.Exception.Message
    if ($lastErr -like 'Login failed*') { break }
    Write-Skip "Connection with $($o.n) failed, trying the next setting..."
  }
}
if (-not $connected) {
  Write-Bad $lastErr
  Write-Bad 'Could not open a secure connection from this PC. Options: run this in PowerShell 7 (pwsh), or from another PC that can reach Catalyst Center.'
  return
}

$script:Group = 'platform'
$ver = Invoke-CC 'GET' '/dna/intent/api/v1/dnac-release'
if ($ver.ok) { Write-Ok "Catalyst Center release $($ver.data.response.displayVersion)" }

# ------------------------------------------------------------------ run
foreach ($g in $Groups) { $g.plan = if ($test) { 10 } else { $g.target }; $script:PlanTotal += $g.plan }
$mins = [int][math]::Ceiling($script:PlanTotal * ($GapMs + 300) / 60000)
Write-Step ("{0} Assurance calls planned (about {1} minutes). Keep this window open and the PC awake." -f $script:PlanTotal, $mins)
foreach ($g in $Groups) { Write-Host ("    {0,-62} {1,5} calls" -f $g.name, $g.plan) }

$script:T0 = Get-Date
$script:Lost = $false
$results = @{}
$gi = 0
foreach ($g in $Groups) {
  $gi++
  $script:Group = $g.key; $script:GroupName = $g.name
  Write-Step "$($g.name)  (group $gi of $($Groups.Count))"
  $before = $script:Done
  if ($g.key -eq '360') { $groupOk = Invoke-360Group $g.plan } else { $groupOk = Invoke-StaticGroup $g $g.plan }
  # keep the overall count honest if a group stopped early
  $script:PlanTotal -= ($g.plan - ($script:Done - $before))
  $results[$g.key] = $groupOk
  Write-Ok "$groupOk successful calls in this group"
  if ($script:Lost) { break }
}
$ProgressPreference = 'Continue'; Write-Progress -Activity 'CNOI Assurance workload' -Completed; $ProgressPreference = 'SilentlyContinue'

# ------------------------------------------------------------------ summary
$total = $script:Ok + $script:Err
$rate = if ($total) { [math]::Round($script:Err * 100.0 / $total, 1) } else { 0 }
$dur = (Get-Date) - $script:T0
Write-Step ('Finished in {0}m {1}s' -f [int][math]::Floor($dur.TotalMinutes), $dur.Seconds)
foreach ($g in $Groups) { Write-Host ("  {0,-62} {1,5} successful" -f $g.name, [int]$results[$g.key]) }
Write-Host ("  All calls: {0} successful, {1} errors ({2}%)" -f $script:Ok, $script:Err, $rate)
if ($script:LogFile) { Write-Host ''; Write-Host "  Call log (CSV, every call with timestamp and result): $($script:LogFile)" -ForegroundColor White }
Write-Host ''
Write-Host '  Issue resolution is done in the UI: Assurance > Issues > select > Resolve (or Ignore).'
Write-Host '  Cisco reads these counts through telemetry; the portal can take a few days to update.'
Write-Host ''
