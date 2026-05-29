# ps-user-provisioning

Automates new user provisioning across AD, Entra ID, and M365. Builds the account, syncs to Entra, assigns the license, adds group memberships, and emails the manager. Was doing all this manually and it was taking forever.

Copy `Config.example.ps1` to `Config.ps1` and fill in your environment before running.

```powershell
.\New-UserProvisioning.ps1 -FirstName "Jane" -LastName "Smith" `
    -Department "Finance" -JobTitle "Accountant" `
    -Manager "jdoe" -Location "HQ"
```

Needs MSOnline and ExchangeOnlineManagement modules installed, and RSAT on whatever machine you run it from.

Logs go to `C:\Logs\Provisioning\`

TODO: shared mailbox support, handle empty license pool better
