# ps-user-provisioning

PowerShell script to automate new user provisioning across AD, Entra ID, and M365.

Replaces the manual process of creating accounts, assigning licenses, and adding group memberships.
Was taking 30-45 min per user doing it by hand, this gets it down to one command.

## What it does

- Creates the AD account and puts it in the right OU
- Triggers an AAD Connect delta sync
- Waits for the user to appear in Entra ID then assigns the M365 license
- Adds to AD security groups and M365/Teams groups based on department
- Emails the manager with the temp credentials
- Logs everything to C:\Logs\Provisioning\

## Requirements

- PowerShell 5.1+
- ActiveDirectory module (RSAT)
- MSOnline: `Install-Module MSOnline`
- ExchangeOnlineManagement: `Install-Module ExchangeOnlineManagement`
- Domain admin or delegated OU rights
- Network access to the AAD Connect server

## Setup

1. Clone or download the repo
2. Copy `Config.example.ps1` to `Config.ps1`
3. Fill in your environment values (domain, OU paths, groups, license SKUs, etc)
4. Run from a machine that has AD RSAT installed

To get your license SKU IDs:
```powershell
Connect-MsolService
Get-MsolAccountSku | Select SkuPartNumber, AccountSkuId
```

## Usage

```powershell
.\New-UserProvisioning.ps1 -FirstName "Jane" -LastName "Smith" `
    -Department "Finance" -JobTitle "Accountant" `
    -Manager "jdoe" -Location "HQ"
```

With a specific license:
```powershell
.\New-UserProvisioning.ps1 -FirstName "Tom" -LastName "Brown" `
    -Department "IT" -JobTitle "Systems Engineer" `
    -Manager "jsmith" -Location "Remote" -LicenseSKU E3
```

## Notes

- Duplicate usernames are handled automatically (jane.smith -> jane.smith1 etc)
- If the AAD Connect sync can't be triggered remotely it'll just wait 3 min for the scheduled cycle
- M365 group failures are non-fatal and logged as warnings
- Config.ps1 is gitignored so your real environment details don't end up here

## TODO

- Add support for shared mailbox provisioning
- Better handling when the M365 license pool is empty
- Maybe add a -WhatIf mode at some point
