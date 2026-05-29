#Requires -Modules ActiveDirectory, MSOnline, ExchangeOnlineManagement

<#
.SYNOPSIS
    Provisions a new user across AD, M365, and Intune.

.DESCRIPTION
    Automates the full joiner workflow:
      - Creates the AD account with standard attributes
      - Syncs to Entra ID via AAD Connect (or waits for sync)
      - Assigns M365 license
      - Adds user to specified security and M365 groups
      - Sets manager, department, and office attributes
      - Sends a welcome email to the manager with temp credentials
      - Logs all actions to a local log file

.PARAMETER FirstName
    User's first name.

.PARAMETER LastName
    User's last name.

.PARAMETER Department
    Department the user belongs to. Must match an entry in $DepartmentConfig.

.PARAMETER JobTitle
    User's job title. Written to AD and M365 profile.

.PARAMETER Manager
    SAMAccountName of the user's manager.

.PARAMETER Location
    Office location. Accepted: HQ, Remote, Branch1, Branch2

.PARAMETER LicenseSKU
    M365 license to assign. Defaults to BusinessPremium.
    Accepted: BusinessPremium, E3, E5, F3

.EXAMPLE
    .\New-UserProvisioning.ps1 -FirstName "Jane" -LastName "Smith" `
        -Department "Finance" -JobTitle "Accountant" `
        -Manager "jdoe" -Location "HQ"

.NOTES
    Requires: AD module, MSOnline, ExchangeOnlineManagement
    Run as: Domain Admin or delegated OU admin + Exchange Admin
    Log path: C:\Logs\Provisioning\
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory)] [string] $FirstName,
    [Parameter(Mandatory)] [string] $LastName,
    [Parameter(Mandatory)] [string] $Department,
    [Parameter(Mandatory)] [string] $JobTitle,
    [Parameter(Mandatory)] [string] $Manager,
    [Parameter(Mandatory)]
    [ValidateSet('HQ','Remote','Branch1','Branch2')]
    [string] $Location,
    [ValidateSet('BusinessPremium','E3','E5','F3')]
    [string] $LicenseSKU = 'BusinessPremium'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\Config.ps1"

$LogDir  = 'C:\Logs\Provisioning'
$LogFile = Join-Path $LogDir "$(Get-Date -Format 'yyyy-MM-dd')_provisioning.log"

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')] [string]$Level = 'INFO')
    $entry = "[{0}] [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    Add-Content -Path $LogFile -Value $entry
    switch ($Level) {
        'WARN'  { Write-Warning $Message }
        'ERROR' { Write-Error   $Message }
        default { Write-Host    $entry -ForegroundColor Cyan }
    }
}

function New-RandomPassword {
    $upper   = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower   = [char[]]'abcdefghjkmnpqrstuvwxyz'
    $numbers = [char[]]'23456789'
    $special = [char[]]'!@#$%^&*'
    $all     = $upper + $lower + $numbers + $special
    $pwd     = ($upper   | Get-Random) `
             + ($lower   | Get-Random) `
             + ($numbers | Get-Random) `
             + ($special | Get-Random) `
             + (-join (1..8 | ForEach-Object { $all | Get-Random }))
    return -join ($pwd.ToCharArray() | Get-Random -Count $pwd.Length)
}

function Get-UPN {
    param([string]$First, [string]$Last)
    $base = "$($First.ToLower()).$($Last.ToLower())"
    $upn  = "$base@$($Config.Domain)"
    $i    = 1
    while (Get-ADUser -Filter "UserPrincipalName -eq '$upn'" -ErrorAction SilentlyContinue) {
        $upn = "$base$i@$($Config.Domain)"
        $i++
    }
    return $upn
}

function Get-SAMAccountName {
    param([string]$First, [string]$Last)
    $base = ($First.Substring(0,1) + $Last).ToLower() -replace '[^a-z0-9]',''
    if ($base.Length -gt 20) { $base = $base.Substring(0,20) }
    $sam = $base
    $i   = 1
    while (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue) {
        $sam = "$base$i"
        $i++
    }
    return $sam
}

Write-Log "Starting provisioning for $FirstName $LastName"

if (-not $Config.Departments.ContainsKey($Department)) {
    Write-Log "Department '$Department' not found in config." 'ERROR'
    throw "Invalid department."
}
$DeptConfig = $Config.Departments[$Department]

$ManagerObj = Get-ADUser -Identity $Manager -Properties EmailAddress -ErrorAction Stop
Write-Log "Manager resolved: $($ManagerObj.Name) <$($ManagerObj.EmailAddress)>"

$OfficeInfo  = $Config.Locations[$Location]
$SAM         = Get-SAMAccountName -First $FirstName -Last $LastName
$UPN         = Get-UPN            -First $FirstName -Last $LastName
$Password    = New-RandomPassword
$SecurePwd   = ConvertTo-SecureString $Password -AsPlainText -Force
$DisplayName = "$FirstName $LastName"

Write-Log "SAM: $SAM | UPN: $UPN"

# -- 1. Create AD account
Write-Log "Creating AD account..."

$ADParams = @{
    Name                  = $DisplayName
    GivenName             = $FirstName
    Surname               = $LastName
    SamAccountName        = $SAM
    UserPrincipalName     = $UPN
    DisplayName           = $DisplayName
    Department            = $Department
    Title                 = $JobTitle
    Manager               = $ManagerObj.DistinguishedName
    Office                = $OfficeInfo.OfficeName
    StreetAddress         = $OfficeInfo.Street
    City                  = $OfficeInfo.City
    State                 = $OfficeInfo.State
    PostalCode            = $OfficeInfo.Zip
    Country               = 'US'
    Company               = $Config.CompanyName
    AccountPassword       = $SecurePwd
    ChangePasswordAtLogon = $true
    Enabled               = $true
    Path                  = $DeptConfig.OU
    EmailAddress          = $UPN
}

if ($PSCmdlet.ShouldProcess($UPN, 'Create AD User')) {
    New-ADUser @ADParams
    Write-Log "AD account created: $UPN"
}

if ($DeptConfig.ContainsKey('PhoneExtPrefix')) {
    Set-ADUser -Identity $SAM -OfficePhone "$($DeptConfig.PhoneExtPrefix)0000"
}

Add-ADGroupMember -Identity $Config.BaseGroup -Members $SAM
Write-Log "Added to base group: $($Config.BaseGroup)"

foreach ($group in $DeptConfig.Groups) {
    try {
        Add-ADGroupMember -Identity $group -Members $SAM
        Write-Log "Added to group: $group"
    } catch {
        Write-Log "Could not add to group '$group': $_" 'WARN'
    }
}

if ($OfficeInfo.ContainsKey('Group')) {
    Add-ADGroupMember -Identity $OfficeInfo.Group -Members $SAM
    Write-Log "Added to location group: $($OfficeInfo.Group)"
}

# -- 2. Trigger AAD Connect sync
Write-Log "Triggering AAD Connect delta sync..."
try {
    Invoke-Command -ComputerName $Config.AADConnectServer -ScriptBlock {
        Import-Module ADSync
        Start-ADSyncSyncCycle -PolicyType Delta
    }
    Write-Log "Sync triggered on $($Config.AADConnectServer)"
} catch {
    Write-Log "Could not trigger sync remotely. Initiate manually or wait for scheduled cycle." 'WARN'
}

Write-Log "Waiting for Entra ID propagation (90s)..."
Start-Sleep -Seconds 90

# -- 3. Assign M365 license
Write-Log "Connecting to MSOnline..."
Connect-MsolService

$MsolUser = $null
$attempts = 0
while (-not $MsolUser -and $attempts -lt 6) {
    $MsolUser = Get-MsolUser -UserPrincipalName $UPN -ErrorAction SilentlyContinue
    if (-not $MsolUser) {
        Write-Log "Entra ID user not found yet, retrying in 30s... ($attempts/6)" 'WARN'
        Start-Sleep -Seconds 30
    }
    $attempts++
}

if (-not $MsolUser) {
    Write-Log "User did not appear in Entra ID after 3min. Assign license manually." 'ERROR'
    throw "Entra ID sync timeout for $UPN"
}

$SKU = $Config.LicenseSKUs[$LicenseSKU]
Set-MsolUser -UserPrincipalName $UPN -UsageLocation $Config.UsageLocation
Set-MsolUserLicense -UserPrincipalName $UPN -AddLicenses $SKU
Write-Log "License assigned: $LicenseSKU ($SKU)"

# -- 4. M365 group memberships
Write-Log "Connecting to Exchange Online..."
Connect-ExchangeOnline -ShowBanner:$false

foreach ($m365group in $DeptConfig.M365Groups) {
    try {
        Add-UnifiedGroupLinks -Identity $m365group -LinkType Members -Links $UPN
        Write-Log "Added to M365 group: $m365group"
    } catch {
        Write-Log "Could not add to M365 group '$m365group': $_" 'WARN'
    }
}

# -- 5. Intune enrollment note
Write-Log "Intune: user will be auto-enrolled on next device sign-in via AAD Join policy."
Write-Log "Verify enrollment policy scope includes group: $($Config.BaseGroup)"

# -- 6. Welcome email to manager
Write-Log "Sending welcome email to manager: $($ManagerObj.EmailAddress)"

$EmailBody = @"
Hi $($ManagerObj.GivenName),

$FirstName $LastName's account has been provisioned and is ready.

Account details
---------------
Username      : $UPN
Temp password : $Password
(User will be prompted to change on first login)

What's been set up
------------------
- Active Directory account (OU: $($DeptConfig.OU))
- M365 license: $LicenseSKU
- Security groups: $($DeptConfig.Groups -join ', ')
- M365 groups: $($DeptConfig.M365Groups -join ', ')
- Office location: $($OfficeInfo.OfficeName)

Next steps
----------
- Provide the temp password to $FirstName directly (do not forward this email)
- Confirm device enrollment in Intune within 24hrs of first sign-in
- Submit a ticket if any additional application access is needed

-- IT Systems
"@

Send-MailMessage `
    -To         $ManagerObj.EmailAddress `
    -From       $Config.NotificationEmail `
    -Subject    "New account ready: $DisplayName" `
    -Body       $EmailBody `
    -SmtpServer $Config.SMTPRelay

Write-Log "Welcome email sent to $($ManagerObj.EmailAddress)"

# -- 7. Summary
Write-Log "Provisioning complete for $DisplayName"
Write-Log "--------------------------------------------"
Write-Log "UPN      : $UPN"
Write-Log "SAM      : $SAM"
Write-Log "License  : $LicenseSKU"
Write-Log "Location : $Location"
Write-Log "Log file : $LogFile"
Write-Log "--------------------------------------------"

[PSCustomObject]@{
    DisplayName   = $DisplayName
    UPN           = $UPN
    SAM           = $SAM
    TempPassword  = $Password
    License       = $LicenseSKU
    Department    = $Department
    Location      = $Location
    ProvisionedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
}
