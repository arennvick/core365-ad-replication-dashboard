🌐 core365 cloud — AD Replication Health Dashboard

🚀 Real-time Active Directory replication monitoring using PowerShell + HTML
Visualize replication health, detect failures instantly, and simplify troubleshooting


✨ Overview
Active Directory replication issues are often invisible until they become critical.
This project transforms raw replication data into a live, visual dashboard that makes it easy to:
✅ See replication topology clearly
✅ Detect failures and stale links instantly
✅ Monitor domain controller health in real time
✅ Share a clean dashboard with your team

🎯 Why This Exists
Traditional tools like repadmin and dcdiag are powerful — but:

❌ Hard to read quickly
❌ Not visual
❌ Not ideal during incidents

👉 This dashboard solves that by turning complex replication data into actionable insights

🧠 What It Does
The script:

🔍 Discovers all domain controllers
📡 Collects replication partner metadata
⚙️ Runs repadmin /replsummary
✅ Evaluates replication health
🌐 Generates a modern HTML dashboard
🔄 Continuously refreshes in real-time


📊 Dashboard Features
🟦 1. KPI Summary
Quick overview of:

Domain Controllers
Replication Links
Healthy / Stale / Failed
Overall Health Score


🌍 2. Live Topology View

Domain Controllers grouped by AD Site
Directional replication paths
Color-coded health:

🟢 Healthy
🟠 Stale
🔴 Failed




🏢 3. Site-to-Site Summary

Replication between AD sites
Highlights worst link condition per site pair


🚨 4. Failures & Warnings Panel

Critical issues surfaced immediately
No need to scan large outputs


🖥️ 5. Domain Controller Health
Each DC is classified as:

✅ Healthy
⚠️ Warning
❌ Critical


📋 6. Full Replication Details
Includes:

Partition
Result codes
Last success time
Failure counts


🧾 7. Raw Replication Data
Includes native:
repadmin /replsummary


⚙️ Requirements

PowerShell 5.1 or PowerShell 7+
ActiveDirectory module
repadmin available
AD read permissions


🚀 Usage
▶️ Run in live mode (recommended)
PowerShell.\AD-Replication-Dashboard-v2.1.1.ps1Show more lines

▶️ Run once
PowerShell.\AD-Replication-Dashboard-v2.1.1.ps1 -RunOnceShow more lines

▶️ Custom settings
PowerShell.\AD-Replication-Dashboard-v2.1.1.ps1 -AutoRefreshSeconds 120 -StaleThresholdHours 4Show more lines

▶️ Output to shared location
PowerShell.\AD-Replication-Dashboard-v2.1.1.ps1 -OutputPath "\\Server\Dashboards\AD-Repl.html"Show more lines

🔄 How Live Mode Works

Collects replication data
Generates HTML dashboard
Opens in browser
Waits configured interval
Refreshes data
Updates dashboard

⚠️ Important:
The script must continue running — browser refresh alone does not update data.

🌐 Access From Other Machines
Option 1: Shared Folder

Save HTML to network share
Open via UNC path

Option 2: Internal Web Server (Best)

Publish to IIS
Access via internal URL


🛠️ Use Cases
✔ AD health monitoring
✔ Troubleshooting replication issues
✔ Post-change validation
✔ Multi-site environments
✔ Operations dashboards
✔ Audit and reporting

⚠️ Troubleshooting
ActiveDirectory module missing
Install RSAT or run from a server with AD tools installed

repadmin not found
Run on a system with AD DS tools

Dashboard not updating
Script is not running — restart live mode

Domain controller shows as failed
Check:

Network connectivity
DNS resolution
Permissions


🔒 Safe Sharing
Before publishing screenshots:
Remove or replace:

Domain names
Server names
IP addresses
File paths


📸 Screenshots (Recommended)
Create a folder:
assets/

Add:

script-run.png
dashboard.png
topology.png


🧩 Deployment Ideas
✅ Quick Setup

Run on one server
Share via network


🔥 Production Setup

Run on management server
Publish via IIS
Share internal dashboard URL
