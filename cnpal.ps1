# CN-PAL Adoption Tool - PowerShell edition (no .exe)
# For PCs where application control blocks the Windows .exe build.
#
# Usage (PowerShell):
#   irm https://raw.githubusercontent.com/cc-cnpal/cnpal-tool/main/cnpal.ps1 | iex
#
# Makes the Catalyst Center "Campus Network Programmability and Integration"
# API calls (Use / Engage / Adopt): GET calls across many endpoints, plus
# non-GET calls to the Assurance "query" APIs, which only return data.
#
# READ-ONLY: every request is checked before it is sent. Only GET, the login,
# and the Assurance query/analytics POST APIs listed below are allowed.
# Nothing on Catalyst Center is changed, even with an admin account.
# Nothing is installed. Runs about 4-6 minutes.

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$Version = '1.0.2'

# ------------------------------------------------------------------ targets
# Adopt needs 100 GET across >=10 endpoints and 50 non-GET across >=4 endpoints
# in 30 days, with < 3% API errors. These targets leave a margin.
$TargetGET  = 160
$TargetPOST = 80
$GapMs      = 600      # pause between calls

# ------------------------------------------------------------------ endpoints
$GetEndpoints = @(
  '/dna/intent/api/v1/network-device/count',
  '/dna/intent/api/v1/network-health',
  '/dna/intent/api/v1/client-health',
  '/dna/intent/api/v1/site-health?limit=25',
  '/dna/intent/api/v1/network-device?offset=1&limit=25',
  '/dna/intent/api/v1/interface/count',
  '/dna/intent/api/v1/dnac-release',
  '/dna/intent/api/v1/issues?issueStatus=ACTIVE',
  '/dna/intent/api/v1/device-health?limit=25',
  '/dna/intent/api/v1/sites/count',
  '/dna/intent/api/v1/site/count',
  '/dna/data/api/v1/clients/count',
  '/dna/data/api/v1/networkDevices/count',
  '/dna/intent/api/v1/topology/site-topology',
  '/dna/intent/api/v1/topology/vlan/vlan-names',
  '/dna/intent/api/v1/compliance/count',
  '/dna/intent/api/v1/discovery/count',
  '/dna/intent/api/v1/onboarding/pnp-device/count',
  '/dna/intent/api/v1/template-programmer/project',
  '/dna/intent/api/v1/tag/count',
  '/dna/intent/api/v1/network',
  '/dna/intent/api/v1/image/importation',
  '/dna/intent/api/v1/enterprise-ssid',
  '/dna/intent/api/v1/dnac-packages'
)
$WantGetEndpoints = 14   # stop probing once this many work (keeps errors low)

# POST APIs that only read data. Each has two body styles; the time window
# changes on every call, so every non-GET call is different.
$PostEndpoints = @(
  @{ p='/dna/data/api/v1/clients/query/count';                  b=@('tw','filters') },
  @{ p='/dna/data/api/v1/networkDevices/query/count';           b=@('tw','filters') },
  @{ p='/dna/data/api/v1/clients/query';                        b=@('page','tw') },
  @{ p='/dna/data/api/v1/networkDevices/query';                 b=@('page','tw') },
  @{ p='/dna/data/api/v1/interfaces/query/count';               b=@('tw','filters') },
  @{ p='/dna/data/api/v1/assuranceIssues/query/count';          b=@('tw','filters') },
  @{ p='/dna/data/api/v1/interfaces/query';                     b=@('page','tw') },
  @{ p='/dna/data/api/v1/assuranceIssues/query';                b=@('page','tw') },
  @{ p='/dna/data/api/v1/clients/summaryAnalytics';             b=@('tw','groupType') },
  @{ p='/dna/data/api/v1/siteHealthSummaries/summaryAnalytics'; b=@('tw','attrHealth') },
  @{ p='/dna/data/api/v1/networkDevices/summaryAnalytics';      b=@('tw','groupFamily') },
  @{ p='/dna/data/api/v1/clients/topNAnalytics';                b=@('topOs','topType') },
  @{ p='/dna/data/api/v1/clients/trendAnalytics';               b=@('trendHour','trendDay') },
  @{ p='/dna/data/api/v1/assuranceIssues/summaryAnalytics';     b=@('tw','groupPriority') }
)
$WantPostEndpoints = 6

$AllowedPOST = @('/dna/system/api/v1/auth/token', '/api/system/v1/auth/token')
foreach ($e in $PostEndpoints) { $AllowedPOST += $e.p }

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

function New-Body([string]$style, [int]$i) {
  $end   = (Get-Date).AddMinutes(-5 - ($i % 50))
  $start = $end.AddHours(-3)
  $tw = @{ startTime = (Get-EpochMs $start); endTime = (Get-EpochMs $end) }
  switch ($style) {
    'filters'       { $tw.filters = @() }
    'page'          { $tw.page = @{ limit = 10; offset = 1 } }
    'groupType'     { $tw.groupBy = @('type') }
    'attrHealth'    { $tw.attributes = @('networkDeviceGoodHealthPercentage') }
    'groupFamily'   { $tw.groupBy = @('family') }
    'topOs'         { $tw.topN = 5; $tw.groupBy = @('osType') }
    'topType'       { $tw.topN = 5; $tw.groupBy = @('type') }
    'trendHour'     { $tw.trendInterval = '1hour' }
    'trendDay'      { $tw.trendInterval = '1day' }
    'groupPriority' { $tw.groupBy = @('priority') }
  }
  return ($tw | ConvertTo-Json -Depth 5 -Compress)
}

$script:IsPS7 = $PSVersionTable.PSVersion.Major -ge 7
$script:Ok = 0; $script:Err = 0; $script:Token = $null; $script:Base = $null
$script:LastCall = Get-Date '2000-01-01'

function Invoke-CC([string]$method, [string]$path, [string]$body = $null) {
  Assert-ReadOnly $method $path
  $wait = $GapMs - ((Get-Date) - $script:LastCall).TotalMilliseconds
  if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]$wait) }
  $script:LastCall = Get-Date
  $req = @{ Method = $method; Uri = ($script:Base + $path); TimeoutSec = 90; ContentType = 'application/json'
             Headers = @{ 'X-Auth-Token' = $script:Token; 'Accept' = 'application/json' } }
  if ($body) { $req.Body = $body }
  if ($script:IsPS7) { $req.SkipCertificateCheck = $true } else { $req.UseBasicParsing = $true }
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
      $r = Invoke-RestMethod @req
      $script:Ok++
      return @{ ok = $true; data = $r }
    } catch {
      $code = 0
      try { $code = [int]$_.Exception.Response.StatusCode } catch {}
      if ($code -eq 429 -and $attempt -lt 3) { Write-Bad 'Rate-limited by Catalyst Center, waiting 30 s...'; Start-Sleep -Seconds 30; continue }
      if ($code -eq 401 -and $attempt -lt 3) { Connect-CC | Out-Null; $req.Headers['X-Auth-Token'] = $script:Token; continue }
      $script:Err++
      $msg = if ($code) { "HTTP $code" } else { $_.Exception.Message }
      return @{ ok = $false; code = $code; msg = $msg }
    }
  }
}

function Connect-CC {
  $user = $script:Cred.UserName
  $pass = $script:Cred.GetNetworkCredential().Password
  $pair = "${user}:${pass}"
  $b64 = $null
  try { $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair)) } catch {}
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

# ------------------------------------------------------------------ start
Clear-Host
Write-Host "CN-PAL Adoption Tool - PowerShell edition v$Version" -ForegroundColor White
Write-Host 'Read-only: only GET and Assurance query calls are sent. Nothing on Catalyst Center is changed.'
Write-Host "PowerShell $($PSVersionTable.PSVersion) - $($ExecutionContext.SessionState.LanguageMode) language mode"
Write-Host ''

$hostIn = Read-Host 'Catalyst Center address (IP or hostname)'
$hostIn = $hostIn.Trim().TrimEnd('/')
if ($hostIn -notmatch '^https?://') { $hostIn = 'https://' + $hostIn }
$script:Base = $hostIn
$script:Cred = Get-Credential -Message 'Catalyst Center username and password (a read-only OBSERVER account is enough)'
if (-not $script:Cred) { Write-Bad 'No credentials entered. Stopping.'; return }

# TLS (Windows PowerShell 5.1): accept the Catalyst Center certificate (often
# self-signed) and allow TLS 1.2 and 1.3. If the first login attempt fails at the
# TLS level, other protocol settings are tried automatically.
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
    # Clear a script-block callback left in this window by an older run; it
    # breaks every HTTPS connection when called on a background thread.
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
  # 3072 = TLS 1.2, 12288 = TLS 1.3, 0 = let Windows decide
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
  try {
    Connect-CC | Out-Null
    $connected = $true
    Write-Ok "Connected to $($script:Base) ($($o.n))"
    break
  } catch {
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

$ver = Invoke-CC 'GET' '/dna/intent/api/v1/dnac-release'
if ($ver.ok) {
  $dv = $ver.data.response.displayVersion
  Write-Ok "Catalyst Center release $dv"
}

# ------------------------------------------------------------------ probe GET
Write-Step "Finding working GET endpoints (need 10, using up to $WantGetEndpoints)"
$goodGet = @()
foreach ($e in $GetEndpoints) {
  if ($goodGet.Count -ge $WantGetEndpoints) { break }
  if ($e -eq '/dna/intent/api/v1/dnac-release' -and $ver.ok) { $goodGet += $e; Write-Ok "GET $e"; continue }
  $r = Invoke-CC 'GET' $e
  if ($r.ok) { $goodGet += $e; Write-Ok "GET $(($e -split '\?')[0])" } else { Write-Skip "GET $(($e -split '\?')[0]) not available ($($r.msg)), skipped" }
}

# ------------------------------------------------------------------ probe POST
Write-Step "Finding working non-GET (query) endpoints (need 4, using up to $WantPostEndpoints)"
$goodPost = @()
$i = 0
foreach ($e in $PostEndpoints) {
  if ($goodPost.Count -ge $WantPostEndpoints) { break }
  $okStyle = $null
  foreach ($style in $e.b) {
    $r = Invoke-CC 'POST' $e.p (New-Body $style $i); $i++
    if ($r.ok) { $okStyle = $style; break }
    if ($r.code -eq 404 -or $r.code -eq 405 -or $r.code -eq 403) { break }
  }
  if ($okStyle) { $goodPost += @{ p = $e.p; s = $okStyle }; Write-Ok "POST $($e.p)" } else { Write-Skip "POST $($e.p) not available, skipped" }
}

if ($goodGet.Count -lt 10) { Write-Bad "Only $($goodGet.Count) GET endpoints work (Adopt needs 10). Continuing; Engage needs 5." }
if ($goodPost.Count -lt 4) { Write-Bad "Only $($goodPost.Count) query endpoints work (Adopt needs 4). Continuing; Engage needs 2." }
if ($goodGet.Count -eq 0 -and $goodPost.Count -eq 0) { Write-Bad 'No endpoint responds. Check the account rights.'; return }

# ------------------------------------------------------------------ workload
$getDone = 0; $postDone = 0
$plan = $TargetGET + $TargetPOST
$t0 = Get-Date
$gi = 0; $pi = 0; $n = 0
Write-Step "Making $TargetGET GET and $TargetPOST non-GET calls"
while (($getDone -lt $TargetGET -and $goodGet.Count) -or ($postDone -lt $TargetPOST -and $goodPost.Count)) {
  $doPost = ($postDone -lt $TargetPOST -and $goodPost.Count) -and (($n % 3 -eq 2) -or $getDone -ge $TargetGET -or -not $goodGet.Count)
  if ($doPost) {
    $e = $goodPost[$pi % $goodPost.Count]; $pi++
    $r = Invoke-CC 'POST' $e.p (New-Body $e.s ($pi + 7))
    if ($r.ok) { $postDone++ }
  } else {
    $e = $goodGet[$gi % $goodGet.Count]; $gi++
    $r = Invoke-CC 'GET' $e
    if ($r.ok) { $getDone++ }
  }
  $n++
  if ($script:Err -gt 12 -and $script:Err -gt ($script:Ok * 0.02)) { Write-Bad 'Too many errors; stopping to protect the API error rate.'; break }
  $done = $getDone + $postDone
  $el = ((Get-Date) - $t0).TotalSeconds
  $left = if ($done -gt 5) { [int](($plan - $done) * $el / $done) } else { -1 }
  $pct = [int]($done * 100 / $plan)
  $status = "$done / $plan calls  ($getDone GET, $postDone non-GET)  errors $($script:Err)  " + $(if ($left -ge 0) { "about $([int]($left/60))m $($left%60)s left" } else { 'estimating...' })
  Write-Progress -Activity 'CN-PAL API workload (read-only)' -Status $status -PercentComplete ([math]::Min(100,$pct))
  if ($n % 30 -eq 0) { Write-Host "  $status" }
}
Write-Progress -Activity 'CN-PAL API workload (read-only)' -Completed

# ------------------------------------------------------------------ summary
$total = $script:Ok + $script:Err
$rate = if ($total) { [math]::Round($script:Err * 100.0 / $total, 1) } else { 0 }
Write-Step 'Finished'
Write-Host ("  GET calls:      {0,4}  across {1} endpoints   (Engage 50 across 5, Adopt 100 across 10)" -f ($getDone + $goodGet.Count), $goodGet.Count)
Write-Host ("  Non-GET calls:  {0,4}  across {1} endpoints   (Engage 10 across 2, Adopt 50 across 4)" -f ($postDone + $goodPost.Count), $goodPost.Count)
Write-Host ("  Errors:         {0,4}  ({1}% of {2} calls; Engage < 5%, Adopt < 3%)" -f $script:Err, $rate, $total)
Write-Host ''
Write-Host '  Cisco reads these counts through telemetry; the LCI portal can take 1-2 days to update.'
Write-Host '  Run this again about every 3 weeks to keep the 30-day counts up.'
Write-Host ''
