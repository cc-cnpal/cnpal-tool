# CN-PAL Adoption Tool for Cisco Catalyst Center (Windows)

A local, read-only assessment tool for Cisco Catalyst Center. It connects with a
read-only (OBSERVER-ROLE) account, runs the API workload for the Catalyst Center
"Campus Network Programmability and Integration" (CN-PAL) adoption criteria, and
produces a Word assessment report.

Nothing is changed on Catalyst Center. Every call only reads data: GET requests,
plus POST requests to the Assurance "query" APIs, which return data without
changing anything.

## Read-only guarantee

The tool cannot change anything on Catalyst Center, even with a read-write or admin account. Every
request is checked before it is sent: only GET, the login, and the Assurance "query" APIs (which only
return data) are allowed. PUT, PATCH, DELETE and any other POST are refused locally and never sent.

## Quick start (one command)

Open **PowerShell** and run:

```powershell
irm https://raw.githubusercontent.com/cc-cnpal/cnpal-tool/main/run.ps1 | iex
```

It downloads the latest version, extracts it to `%LOCALAPPDATA%\CNPAL-Tool\app` and opens the
dashboard in your browser. Nothing is installed. Run the same command again to update.

## If the .exe is blocked ("Access is denied")

Some company PCs block downloaded programs. Use the PowerShell edition instead: no .exe, nothing
installed, same read-only calls for the Campus Network Programmability and Integration use case
(GET calls plus Assurance query calls), about 4 minutes:

```powershell
irm https://raw.githubusercontent.com/cc-cnpal/cnpal-tool/main/cnpal.ps1 | iex
```

It asks for the Catalyst Center address and a username/password (a read-only account is enough).

For the Campus Network Observability and Insights (Assurance) use case, use the PowerShell Assurance
edition: the same read-only GET calls as the CNOI Workload button (network health, client health, Device/Client
360, audit logs), about 1 hour. Every call is logged to a CSV in `Documents\CNOI-Assurance`. Type `T` at the
run-type prompt for a quick 10-calls-per-group test.

```powershell
irm https://raw.githubusercontent.com/cc-cnpal/cnpal-tool/main/cnpal-assurance.ps1 | iex
```

## Dashboard

Four buttons: **CN-PAL Workload**, **CNOI Workload** (Observability & Insights), **GBM Internal Report**
(assessment with lifecycle criteria) and **Cisco Report** (status report). On the Connect page you can enter
the Catalyst Center serial number and Member ID from Help (?) > About; both reports show them.

## Status report

**Generate status report** writes a Catalyst Center status report (Word) with the platform release, device
inventory (site assignment, reachability, manageability, software versions), assurance health, API activity by
area, issues resolved or ignored in the last 30 days, and Catalyst Center sign-ins from the platform's audit log.
CSV files alongside it: `api-call-log.csv` (every request with timestamp, endpoint and HTTP status),
`issues-closed-30d.csv`, `ui-logins-30d.csv` and `devices.csv`. A status report is also written automatically
when an Assurance run finishes.

## macOS

Download [CNPAL-Tool-macOS.zip](../../raw/main/dist/CNPAL-Tool-macOS.zip), unzip it and double-click `Start.command`.

## Assurance mode

For the Catalyst Center Assurance use case, connect and click **Run Assurance workload** on the
"Assurance use case" card. It makes about 4,000 read-only GET calls over roughly one hour, covering
the Engage and Adopt API targets for Network Health, Client Health, Device/Client 360 and Audit Logs.
A live progress bar shows calls done, pending, elapsed time and time remaining. Keep the window open and the laptop awake until it finishes.

## Download

**[Download the latest version (CNPAL-Tool-Windows.zip)](../../raw/main/dist/CNPAL-Tool-Windows.zip)**

Only download the tool from this page (the `dist` folder of this repository).

## Run it

1. Right-click the zip and choose **Extract All...**
2. Open the extracted folder and double-click **Start.bat**.
3. If Windows shows "Windows protected your PC", click **More info**, then **Run anyway** (one-time step; the tool is not code-signed).
4. Your browser opens the dashboard. Enter the Catalyst Center address, the read-only username and password, and the customer name, then click **Connect**.
5. Run **Workload + report**, then click **Download Word report**.

Leave the command window open while you use the tool; closing it stops the tool.

## Check the download (optional)

In PowerShell, in the folder where you saved the zip:

```powershell
Get-FileHash .\CNPAL-Tool-Windows.zip -Algorithm SHA256
```

The result must match the value in [dist/SHA256.txt](dist/SHA256.txt).

## Requirements

- Windows 10 or 11 (Intel/AMD or ARM)
- Network access from the laptop to Catalyst Center over HTTPS
- A Catalyst Center read-only account with Global site access
- Catalyst Center 2.3.7.7 or newer (2.3.7.11+ recommended)
