# Catalyst Center Status Report - PowerShell edition (no .exe)
# For PCs where antivirus or application control blocks the Windows .exe build.
#
# Usage (PowerShell), after running cnpal-assurance.ps1 on the same PC:
#   irm https://raw.githubusercontent.com/cc-cnpal/cnpal-tool/main/cnpal-report.ps1 | iex
#
# Writes an HTML status report: platform, device inventory (site assignment,
# reachability, device families), issues resolved or ignored in the last 30
# days, Catalyst Center sign-ins, and the API activity recorded in the call logs
# (Documents\CNOI-Assurance). A combined call-log CSV is written alongside it.
#
# READ-ONLY: only GET calls and the login are sent. Nothing is changed.

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$Version = '1.0.0'
$GapMs   = 300
$AllowedPOST = @('/dna/system/api/v1/auth/token', '/api/system/v1/auth/token')

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


$script:IsPS7 = $PSVersionTable.PSVersion.Major -ge 7
$script:Token = $null; $script:Base = $null
$script:LastCall = Get-Date '2000-01-01'

function Invoke-CC([string]$method, [string]$path) {
  Assert-ReadOnly $method $path
  $wait = $GapMs - ((Get-Date) - $script:LastCall).TotalMilliseconds
  if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]$wait) }
  $script:LastCall = Get-Date
  $req = @{ Method = $method; Uri = ($script:Base + $path); TimeoutSec = 120
            Headers = @{ 'X-Auth-Token' = $script:Token; 'Accept' = 'application/json' } }
  if ($script:IsPS7) { $req.SkipCertificateCheck = $true } else { $req.UseBasicParsing = $true }
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    try { return @{ ok = $true; data = (Invoke-RestMethod @req) } }
    catch {
      $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch {}
      if ($code -eq 429 -and $attempt -lt 3) { Start-Sleep -Seconds 30; continue }
      if ($code -eq 401 -and $attempt -lt 3) { Connect-CC | Out-Null; $req.Headers['X-Auth-Token'] = $script:Token; continue }
      return @{ ok = $false; code = $code }
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

function Get-Count($r) {
  if (-not $r.ok) { return $null }
  $d = $r.data
  foreach ($k in 'response', 'count', 'totalCount') {
    $v = $d.$k
    if ($v -is [int] -or $v -is [long] -or $v -is [double]) { return [int]$v }
    if ($v -and ($v.count -is [int] -or $v.count -is [long])) { return [int]$v.count }
  }
  return $null
}

function Enc($s) { return [Net.WebUtility]::HtmlEncode([string]$s) }
function Pct($a, $b) { if ($b) { return [math]::Round($a * 100.0 / $b, 1) } else { return 0 } }

$Areas = [ordered]@{
  health   = 'Network health (Assurance health, events, licensing)'
  client   = 'Client health and endpoint analytics'
  '360'    = 'Device and client 360 views'
  audit    = 'Audit logs'
  platform = 'Platform'
}

# ------------------------------------------------------------------ start
Clear-Host
Write-Host "Catalyst Center Status Report - PowerShell edition v$Version" -ForegroundColor White
Write-Host 'Read-only: only GET calls are sent. Nothing on Catalyst Center is changed.'
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
$customer = (Read-Host 'Customer name for the report title (optional, press Enter to skip)').Trim()
$serial   = (Read-Host 'Serial number from Help (?) > About (optional, press Enter to skip)').Trim()
$member   = (Read-Host 'Member ID from Help (?) > About (optional, press Enter to skip)').Trim()

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


$now = Get-Date
$from = $now.AddDays(-30)
$startMs = Get-EpochMs $from; $endMs = Get-EpochMs $now

Write-Step 'Collecting platform and inventory'
$release = ''
$r = Invoke-CC 'GET' '/dna/intent/api/v1/dnac-release'
if ($r.ok) { $release = $r.data.response.displayVersion; Write-Ok "Release $release" }

$devices = New-Object System.Collections.ArrayList
for ($off = 1; $off -le 20000; $off += 500) {
  $r = Invoke-CC 'GET' "/dna/intent/api/v1/network-device?offset=$off&limit=500"
  if (-not $r.ok) { break }
  $arr = @($r.data.response)
  foreach ($d in $arr) { [void]$devices.Add($d) }
  if ($arr.Count -lt 500) { break }
}
$total = $devices.Count
$tc = Get-Count (Invoke-CC 'GET' '/dna/intent/api/v1/network-device/count')
if ($tc -ne $null -and $tc -gt $total) { $total = $tc }
Write-Ok "$total devices in inventory"

$unassigned = Get-Count (Invoke-CC 'GET' '/dna/intent/api/v1/networkDevices/notAssignedToSite/count')
$assignSrc = 'networkDevices/notAssignedToSite/count'
if ($unassigned -eq $null) {
  $n = 0; $okList = $false
  for ($off = 1; $off -le 20000; $off += 500) {
    $r = Invoke-CC 'GET' "/dna/intent/api/v1/networkDevices/notAssignedToSite?offset=$off&limit=500"
    if (-not $r.ok) { break }
    $okList = $true; $arr = @($r.data.response); $n += $arr.Count
    if ($arr.Count -lt 500) { break }
  }
  if ($okList) { $unassigned = $n; $assignSrc = 'networkDevices/notAssignedToSite' }
}
$assigned = if ($unassigned -ne $null) { $total - $unassigned } else { $null }
if ($assigned -ne $null) { Write-Ok ("{0} of {1} devices assigned to a site ({2}%)" -f $assigned, $total, (Pct $assigned $total)) } else { Write-Bad 'Site assignment count not available on this release.' }

$reach = @{}; $fam = @{}; $mgd = @{}
foreach ($d in $devices) {
  $k = if ($d.reachabilityStatus) { [string]$d.reachabilityStatus } else { 'Unknown' }; $reach[$k] = 1 + [int]$reach[$k]
  $f = if ($d.family) { [string]$d.family } else { 'Other' }; $fam[$f] = 1 + [int]$fam[$f]
  $m = if ($d.managementState) { [string]$d.managementState } else { 'Unknown' }; $mgd[$m] = 1 + [int]$mgd[$m]
}

Write-Step 'Collecting issues resolved or ignored in the last 30 days'
$resolved = $null; $ignored = $null; $issueSrc = ''
$a = Get-Count (Invoke-CC 'GET' "/dna/data/api/v1/assuranceIssues/count?status=resolved&startTime=$startMs&endTime=$endMs")
$b = Get-Count (Invoke-CC 'GET' "/dna/data/api/v1/assuranceIssues/count?status=ignored&startTime=$startMs&endTime=$endMs")
if ($a -ne $null -or $b -ne $null) { $resolved = [int]$a; $ignored = [int]$b; $issueSrc = 'Assurance issues API' }
else {
  $r1 = Invoke-CC 'GET' "/dna/intent/api/v1/issues?issueStatus=RESOLVED&startTime=$startMs&endTime=$endMs"
  $r2 = Invoke-CC 'GET' "/dna/intent/api/v1/issues?issueStatus=IGNORED&startTime=$startMs&endTime=$endMs"
  if ($r1.ok -or $r2.ok) { $resolved = @($r1.data.response).Count; $ignored = @($r2.data.response).Count; $issueSrc = 'Issues API' }
}
if ($resolved -ne $null) { Write-Ok "Resolved $resolved, ignored $ignored" } else { Write-Bad 'Issue counts not available.' }

Write-Step 'Collecting Catalyst Center sign-ins (audit log, last 30 days)'
$logins = New-Object System.Collections.ArrayList; $scanned = 0; $auditOk = $false
for ($off = 1; $off -le 3000; $off += 25) {
  $r = Invoke-CC 'GET' "/dna/data/api/v1/event/event-series/audit-logs?startTime=$startMs&endTime=$endMs&limit=25&offset=$off"
  if (-not $r.ok) { break }
  $auditOk = $true
  $arr = if ($r.data -is [array]) { $r.data } elseif ($r.data.response) { @($r.data.response) } else { @($r.data) }
  foreach ($it in $arr) {
    $scanned++
    $desc = [string]$(if ($it.description) { $it.description } elseif ($it.name) { $it.name } else { $it.details })
    if ($desc -notmatch 'log(ged)? ?in|sign(ed)? ?in|login' -or $desc -match 'fail|invalid|denied|unsuccessful') { continue }
    $usr = [string]$(if ($it.userId) { $it.userId } elseif ($it.user) { $it.user } else { $it.userName })
    $ts = $null; try { $ts = ([datetime]'1970-01-01T00:00:00Z').ToUniversalTime().AddMilliseconds([double]$it.timestamp).ToLocalTime() } catch {}
    [void]$logins.Add([pscustomobject]@{ user = $usr; time = $ts; desc = $desc })
  }
  if ($arr.Count -lt 25) { break }
}
if ($auditOk) { Write-Ok "$($logins.Count) sign-ins found in $scanned audit entries" } else { Write-Bad 'Audit log not available.' }

Write-Step 'Reading the API call logs'
$docs = [Environment]::GetFolderPath('MyDocuments')
if (-not $docs) { $docs = $env:USERPROFILE }; if (-not $docs) { $docs = $HOME }; if (-not $docs) { $docs = [IO.Path]::GetTempPath() }
$dir = Join-Path $docs 'CNOI-Assurance'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$hn = ($script:Base -replace '^https?://', '') -replace '[^A-Za-z0-9.-]', '_'
$rows = New-Object System.Collections.ArrayList
$files = @(Get-ChildItem -Path $dir -Filter ("api-call-log-{0}-*.csv" -f $hn) -ErrorAction SilentlyContinue)
$cutUtc = $now.ToUniversalTime().AddDays(-30)
foreach ($f in $files) {
  try {
    foreach ($row in (Import-Csv -Path $f.FullName)) {
      $t = [datetime]::MinValue
      if (-not [datetime]::TryParse($row.timestamp_utc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$t)) { continue }
      if ($t -lt $cutUtc) { continue }
      $row | Add-Member -NotePropertyName t -NotePropertyValue $t -Force
      [void]$rows.Add($row)
    }
  } catch { Write-Bad "Could not read $($f.Name)" }
}
$rows = @($rows | Sort-Object t)
$okRows = @($rows | Where-Object { $_.result -eq 'success' })
$errRows = $rows.Count - $okRows.Count
Write-Ok "$($rows.Count) calls in $($files.Count) log file(s)"

$byArea = [ordered]@{}
foreach ($k in $Areas.Keys) { $byArea[$k] = @{ ok = 0; err = 0; eps = @{} } }
$byDay = [ordered]@{}; $byEp = @{}
foreach ($row in $rows) {
  $g = if ($byArea.Contains($row.group)) { $row.group } else { 'platform' }
  if ($row.result -eq 'success') { $byArea[$g].ok++ } else { $byArea[$g].err++ }
  $byArea[$g].eps[$row.endpoint] = 1
  $day = $row.t.ToLocalTime().ToString('yyyy-MM-dd')
  if (-not $byDay.Contains($day)) { $byDay[$day] = @{ ok = 0; err = 0 } }
  if ($row.result -eq 'success') { $byDay[$day].ok++ } else { $byDay[$day].err++ }
  $key = "$($row.method) $($row.endpoint)"
  if (-not $byEp.ContainsKey($key)) { $byEp[$key] = @{ ok = 0; err = 0; ms = 0 } }
  if ($row.result -eq 'success') { $byEp[$key].ok++ } else { $byEp[$key].err++ }
  $byEp[$key].ms += [int]$row.response_ms
}

# ------------------------------------------------------------------ write
$stamp = $now.ToString('yyyyMMdd-HHmmss')
$combined = Join-Path $dir "api-call-log-combined-$hn-$stamp.csv"
$rows | Select-Object timestamp_utc, timestamp_local, method, endpoint, http_status, result, response_ms, group |
  Export-Csv -Path $combined -NoTypeInformation -Encoding UTF8

function Tbl($head, $lines) {
  $h = ($head | ForEach-Object { "<th>$(Enc $_)</th>" }) -join ''
  $b = ($lines | ForEach-Object { '<tr>' + (($_ | ForEach-Object { "<td>$(Enc $_)</td>" }) -join '') + '</tr>' }) -join "`n"
  return "<table><tr>$h</tr>$b</table>"
}
$title = 'Catalyst Center Status Report' + $(if ($customer) { " - $customer" } else { '' })
$na = 'Not available'
$sb = New-Object Text.StringBuilder
[void]$sb.Append(@"
<!DOCTYPE html><html><head><meta charset="utf-8"><title>$(Enc $title)</title>
<style>body{font-family:Segoe UI,Arial,sans-serif;margin:32px;color:#1d2733;max-width:1100px}
h1{font-size:24px;margin-bottom:4px}h2{font-size:17px;margin-top:30px;border-bottom:2px solid #e3e8ee;padding-bottom:4px}
.sub{color:#5b6773;font-size:13px}table{border-collapse:collapse;margin:8px 0 4px;font-size:13px}
th,td{border:1px solid #d8dee5;padding:5px 10px;text-align:left}th{background:#f2f5f8}
.kpis{display:flex;gap:14px;flex-wrap:wrap}.kpi{border:1px solid #d8dee5;border-radius:6px;padding:10px 16px;min-width:150px}
.kpi b{display:block;font-size:22px}.note{color:#5b6773;font-size:12px}</style></head><body>
<h1>$(Enc $title)</h1>
<div class="sub">Catalyst Center $(Enc $script:Base) &middot; generated $(Enc $now.ToString('yyyy-MM-dd HH:mm')) &middot; reporting period $(Enc $from.ToString('yyyy-MM-dd')) to $(Enc $now.ToString('yyyy-MM-dd'))</div>
<h2>1. Summary</h2><div class="kpis">
<div class="kpi">Devices in inventory<b>$total</b></div>
<div class="kpi">Assigned to a site<b>$(if ($assigned -ne $null) { "$(Pct $assigned $total)%" } else { $na })</b></div>
<div class="kpi">Issues resolved / ignored (30 days)<b>$(if ($resolved -ne $null) { "$resolved / $ignored" } else { $na })</b></div>
<div class="kpi">API calls recorded (30 days)<b>$($rows.Count)</b></div>
<div class="kpi">API success rate<b>$(if ($rows.Count) { "$(Pct $okRows.Count $rows.Count)%" } else { $na })</b></div>
</div>
<h2>2. Platform</h2>
"@)
[void]$sb.Append((Tbl @('Item', 'Value') @(
  ,@('Catalyst Center address', $script:Base)
  ,@('Release', $(if ($release) { $release } else { $na }))
  ,@('Serial number', $(if ($serial) { "$serial (entered from Help > About)" } else { $na }))
  ,@('Member ID', $(if ($member) { "$member (entered from Help > About)" } else { $na }))
)))
[void]$sb.Append('<h2>3. Device inventory</h2>')
[void]$sb.Append((Tbl @('Item', 'Devices', 'Share') @(
  ,@('Devices in inventory', $total, '100%')
  ,@('Assigned to a site', $(if ($assigned -ne $null) { $assigned } else { $na }), $(if ($assigned -ne $null) { "$(Pct $assigned $total)%" } else { '' }))
  ,@('Not assigned to a site', $(if ($unassigned -ne $null) { $unassigned } else { $na }), $(if ($unassigned -ne $null) { "$(Pct $unassigned $total)%" } else { '' }))
)))
[void]$sb.Append('<p class="note">Site assignment source: ' + (Enc $assignSrc) + '.</p>')
[void]$sb.Append((Tbl @('Reachability', 'Devices', 'Share') @($reach.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { ,@($_.Key, $_.Value, "$(Pct $_.Value $devices.Count)%") })))
[void]$sb.Append((Tbl @('Management state', 'Devices') @($mgd.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { ,@($_.Key, $_.Value) })))
[void]$sb.Append((Tbl @('Device family', 'Devices') @($fam.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { ,@($_.Key, $_.Value) })))
[void]$sb.Append('<h2>4. Issue management (last 30 days)</h2>')
if ($resolved -ne $null) {
  [void]$sb.Append((Tbl @('Status', 'Issues') @(
    ,@('Resolved', $resolved)
    ,@('Ignored', $ignored)
    ,@('Total closed', ($resolved + $ignored))
  )))
  [void]$sb.Append('<p class="note">Source: ' + (Enc $issueSrc) + '.</p>')
} else { [void]$sb.Append("<p>$na on this release.</p>") }
[void]$sb.Append('<h2>5. Catalyst Center sign-ins (last 30 days)</h2>')
if ($auditOk) {
  $users = $logins | Group-Object user | Sort-Object Count -Descending
  [void]$sb.Append("<p>$($logins.Count) sign-ins by $(@($users).Count) user(s), from $scanned audit log entries.</p>")
  if ($logins.Count) {
    [void]$sb.Append((Tbl @('User', 'Sign-ins', 'Last sign-in') @($users | ForEach-Object { $last = ($_.Group | Sort-Object time -Descending | Select-Object -First 1).time; ,@($_.Name, $_.Count, $(if ($last) { $last.ToString('yyyy-MM-dd HH:mm') } else { '' })) })))
  }
} else { [void]$sb.Append("<p>$na on this release.</p>") }
[void]$sb.Append('<h2>6. API activity (last 30 days)</h2>')
[void]$sb.Append("<p>API calls recorded by the read-only PowerShell client on this PC: $($rows.Count) calls, $($okRows.Count) successful, $errRows errors ($(Pct $errRows $rows.Count)%). Every call is listed with its timestamp in the attached CSV file.</p>")
[void]$sb.Append((Tbl @('Area', 'Successful calls', 'Errors', 'Endpoints') @($byArea.Keys | Where-Object { ($byArea[$_].ok + $byArea[$_].err) -gt 0 } | ForEach-Object { ,@($Areas[$_], $byArea[$_].ok, $byArea[$_].err, $byArea[$_].eps.Count) })))
[void]$sb.Append((Tbl @('Day', 'Successful calls', 'Errors') @($byDay.Keys | ForEach-Object { ,@($_, $byDay[$_].ok, $byDay[$_].err) })))
[void]$sb.Append((Tbl @('Endpoint', 'Successful', 'Errors', 'Avg response (ms)') @($byEp.GetEnumerator() | Sort-Object { $_.Value.ok } -Descending | ForEach-Object { $n = $_.Value.ok + $_.Value.err; ,@($_.Key, $_.Value.ok, $_.Value.err, $(if ($n) { [int]($_.Value.ms / $n) } else { 0 })) })))
[void]$sb.Append("<p class=`"note`">Call log file: $(Enc (Split-Path $combined -Leaf)). Client: read-only PowerShell edition (GET requests only).</p></body></html>")
$report = Join-Path $dir "Catalyst-Center-Status-Report-$hn-$stamp.html"
[IO.File]::WriteAllText($report, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))

# ------------------------------------------------------------------ GBM check (screen only)
function Line($label, $val, $target, $met) {
  $mark = if ($met) { 'MET    ' } else { 'NOT MET' }
  $col = if ($met) { 'Green' } else { 'Yellow' }
  Write-Host ("  {0}  {1,-44} {2,10}   target {3}" -f $mark, $label, $val, $target) -ForegroundColor $col
}
Write-Step 'GBM check against Adopt (shown here only, not in the report)'
Line 'Network health API calls (30 days)' $byArea['health'].ok '600' ($byArea['health'].ok -ge 600)
Line 'Client health API calls (30 days)'  $byArea['client'].ok '600' ($byArea['client'].ok -ge 600)
Line '360 view API calls (30 days)'        $byArea['360'].ok '2000' ($byArea['360'].ok -ge 2000)
Line 'Audit log API calls (30 days)'       $byArea['audit'].ok '500' ($byArea['audit'].ok -ge 500)
Line 'API error rate'                      "$(Pct $errRows $rows.Count)%" '< 3%' ((Pct $errRows $rows.Count) -lt 3)
if ($resolved -ne $null) { Line 'Issues resolved or ignored (30 days)' ($resolved + $ignored) '100' (($resolved + $ignored) -ge 100) }
if ($assigned -ne $null) { Line 'Devices assigned to a site' "$(Pct $assigned $total)%" '75%' ((Pct $assigned $total) -ge 75) }
Write-Host '  API counts come from the call logs on this PC; calls made from other PCs are not included.' -ForegroundColor DarkGray
Write-Host ''
Write-Host "  Report:   $report" -ForegroundColor White
Write-Host "  Call log: $combined" -ForegroundColor White
try { Invoke-Item $report } catch {}
