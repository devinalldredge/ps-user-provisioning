# ps-user-provisioning

PowerShell automation for end-to-end user provisioning across Active Directory, Entra ID, and Microsoft 365. Built to replace a manual 45-minute joiner process with a single script execution.

## What it does

- Creates an Active Directory account with full attribute set (name, department, title, manager, office, OU placement)
- Triggers an AAD Connect delta sync and waits for Entra ID propagation
- Assigns the correct M365 license based on department or role
- Adds the user to all required AD security groups and M365/Teams groups
- Flags the account for Intune auto-enrollment via existing conditional access policy
- Sends the manager a formatted email with credentials and next steps
- Logs every action with timestamps to a local log file

## Requirements

| Requirement | Notes |
|---|---|
| PowerShell 5.1+ | Tested on 5.1 and 7.2 |
| ActiveDirectory module | RSAT or domain controller |
| MSOnline module | `Install-Module MSOnline` |
| ExchangeOnlineManagement | `Install-Module ExchangeOnlineManagement` |
| Domain Admin or delegated OU rights | For AD account creation |
| Exchange Admin or User Management Admin | For M365 group assignment |
| Network access to AAD Connect server | For remote sync trigger |

## Setup

**1. Clone the repo**
```powershell
git clone https://github.com/devinalldredge/ps-user-provisioning.git
cd ps-user-provisioning
```

**2. Copy Config.example.ps1 to Config.ps1 and fill in your values**
- `Domain` — your UPN suffix
- `AADConnectServer` — hostname of your AAD Connect server
- `LicenseSKUs` — run `Get-MsolAccountSku` to get your actual SKU IDs
- `Locations` — your office addresses and location-based AD groups
- `Departments` — OU paths, security groups, and M365 groups per department

**3. Install required modules**
```powershell
Install-Module -Name MSOnline -Force
Install-Module -Name ExchangeOnlineManagement -Force
```

**4. Run as admin from a machine with AD RSAT installed**

## Usage

```powershell
.\New-UserProvisioning.ps1 `
    -FirstName "Jane" `
    -LastName  "Smith" `
    -Department "Finance" `
    -JobTitle  "Senior Accountant" `
    -Manager   "jdoe" `
    -Location  "HQ"
```

Assign a specific license:
```powershell
.\New-UserProvisioning.ps1 -FirstName "Tom" -LastName "Brown" `
    -Department "IT" -JobTitle "Systems Engineer" `
    -Manager "admin" -Location "Remote" -LicenseSKU E3
```

Preview without making changes:
```powershell
.\New-UserProvisioning.ps1 -FirstName "Test" -LastName "User" `
    -Department "HR" -JobTitle "HR Coordinator" `
    -Manager "hrmanager" -Location "HQ" -WhatIf
```

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| FirstName | Yes | — | User's first name |
| LastName | Yes | — | User's last name |
| Department | Yes | — | Must match a key in Config.ps1 Departments |
| JobTitle | Yes | — | Written to AD title and M365 profile |
| Manager | Yes | — | SAMAccountName of the manager |
| Location | Yes | — | HQ, Remote, Branch1, Branch2 |
| LicenseSKU | No | BusinessPremium | BusinessPremium, E3, E5, F3 |

## Output

```
DisplayName   : Jane Smith
UPN           : jane.smith@contoso.com
SAM           : jsmith
TempPassword  : Kx7#mPqR2!
License       : BusinessPremium
Department    : Finance
Location      : HQ
ProvisionedAt : 2026-03-15 09:42:11
```

Logs are written to `C:\Logs\Provisioning\YYYY-MM-DD_provisioning.log`

## Duplicate username handling

If `jane.smith` already exists the script automatically tries `jane.smith1`, `jane.smith2`, etc. for both the UPN and SAMAccountName until it finds an available name.

## What it does NOT do

- Provision shared mailboxes or resource accounts
- Handle guest / B2B accounts
- Assign Intune device categories (handled by existing dynamic group rules)
- Create home drives or DFS shares

## Environment

Tested against:
- Windows Server 2019/2022 AD
- Microsoft 365 Business Premium and E3
- Entra ID (Azure AD) with AAD Connect v2
- Exchange Online with unified groups
- Intune with Windows Autopilot

## License

MIT
