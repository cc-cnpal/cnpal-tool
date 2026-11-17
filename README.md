# CN-PAL Adoption Tool for Cisco Catalyst Center (Windows)

A local, read-only assessment tool for Cisco Catalyst Center. It connects with a
read-only (OBSERVER-ROLE) account, runs the API workload for the Catalyst Center
"Campus Network Programmability and Integration" (CN-PAL) adoption criteria, and
produces a Word assessment report.

Nothing is changed on Catalyst Center. Every call only reads data: GET requests,
plus POST requests to the Assurance "query" APIs, which return data without
changing anything.

## Download

**[Download the latest version (CNPAL-Tool-Windows.zip)](../../releases/latest/download/CNPAL-Tool-Windows.zip)**

Only download the tool from this page's **Releases** section.

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

The result must match the SHA-256 value listed in the release notes.

## Requirements

- Windows 10 or 11 (Intel/AMD or ARM)
- Network access from the laptop to Catalyst Center over HTTPS
- A Catalyst Center read-only account with Global site access
- Catalyst Center 2.3.7.7 or newer (2.3.7.11+ recommended)
