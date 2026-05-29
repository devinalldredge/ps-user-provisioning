#Requires -Modules ActiveDirectory, MSOnline, ExchangeOnlineManagement

# user provisioning script
# run as domain admin
# needs MSOnline and ExchangeOnlineManagement modules installed first
#   Install-Module MSOnline
#   Install-Module ExchangeOnlineManagement

param (
    [Parameter(Mandatory)] [string] $FirstName,
    [Parameter(Mandatory)] [string] $LastName,
    [Parameter(Mandatory)] [string] $Department,
    [Parameter(Mandatory)] [string] $JobTitle,
    [Parameter(Mandatory)] [string] $Manager,
    [Parameter(Mandatory)] [string] $Location,
    [string] $LicenseSKU = 'BusinessPremium'
)

. "$PSScriptRoot\Config.ps1"

# log everything to a file, makes it easier to see what happened if something breaks
$LogDir  = 'C:\Logs\Provisioning'
$LogFile = Join-Path $LogDir "$(Get-Date -Format 'yyyy-MM-dd')_provisioning.log"

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $entry = "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $LogFile -Value $entry
    if ($Level -eq 'WARN') { Write-Warning $Message }
    elseif ($Level -eq 'ERROR') { Write-Error $Message }
    else { Write-Host $entry }
}

# generate a random password that meets most complexity requirements
# upper + lower + number + special, then shuffle
function New-RandomPassword {
    $chars = @{
        upper   = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZ'
        lower   = [char[]]'abcdefghjkmnpqrstuvwxyz'
        numbers = [char[]]'23456789'
        special = [char[]]'!@#$%^&*'
    }
    $all = $chars.upper + $chars.lower + $chars.numbers + $chars.special
    $pwd = ($chars.upper | Get-Random) + ($chars.lower | Get-Random) +
           ($chars.numbers | Get-Random) + ($chars.special | Get-Random) +
           (-join (1..8 | ForEach-Object { $all | Get-Random }))
    return -join ($pwd.ToCharArray() | Get-Random -Count $pwd.Length)
}

# build UPN, handle duplicates by appending a number
# e.g. if john.smith exists, try john.smith1, john.smith2, etc
function Get-UPN {
    param([string]$First, [string]$Last)
    $base = "$($First.ToLower()).$($Last.ToLower())"
    $upn = "$base@$($Config.Domain)"
    $i = 1
    while (Get-ADUser -Filter "UserPrincipalName -eq '$upn'" -ErrorAction SilentlyContinue) {
        $upn = "$base$i@$($Config.Domain)"
        $i++
    }
    return $upn
}

function Get-SAM {
    param([string]$First, [string]$Last)
    # first initial + last name, max 20 chars, lowercase
    $base = ($First.Substring(0,1) + $Last).ToLower() -replace '[^a-z0-9]',''
    if ($base.Length -gt 20) { $base = $base.Substring(0,20) }
    $sam = $base
    $i = 1
    while (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue) {
        $sam = "$base$i"
        $i++
    }
    return $sam
}


Write-Log "Starting provisioning: $FirstName $LastName / $Department / $Location"

# validate department exists in config
if (-not $Config.Departments.ContainsKey($Department)) {
    Write-Log "Unknown department: $Department" 'ERROR'
    throw "Department not found in config. Check Config.ps1."
}
$dept = $Config.Departments[$Department]

# make sure the manager account actually exists before we do anything
$mgr = Get-ADUser -Identity $Manager -Properties EmailAddress -ErrorAction Stop
Write-Log "Manager: $($mgr.Name)"

$office      = $Config.Locations[$Location]
$sam         = Get-SAM -First $FirstName -Last $LastName
$upn         = Get-UPN -First $FirstName -Last $LastName
$pwd         = New-RandomPassword
$secpwd      = ConvertTo-SecureString $pwd -AsPlainText -Force
$displayName = "$FirstName $LastName"

Write-Log "UPN: $upn | SAM: $sam"


# ---- create the AD account ----

$newUserParams = @{
    Name                  = $displayName
    GivenName             = $FirstName
    Surname               = $LastName
    SamAccountName        = $sam
    UserPrincipalName     = $upn
    DisplayName           = $displayName
    Department            = $Department
    Title                 = $JobTitle
    Manager               = $mgr.DistinguishedName
    Office                = $office.OfficeName
    StreetAddress         = $office.Street
    City                  = $office.City
    State                 = $office.State
    PostalCode            = $office.Zip
    Country               = 'US'
    Company               = $Config.CompanyName
    AccountPassword       = $secpwd
    ChangePasswordAtLogon = $true
    Enabled               = $true
    Path                  = $dept.OU
    EmailAddress          = $upn
}

New-ADUser @newUserParams
Write-Log "AD account created"

# base group all users get added to (used for intune enrollment scope)
Add-ADGroupMember -Identity $Config.BaseGroup -Members $sam

# dept groups
foreach ($g in $dept.Groups) {
    try {
        Add-ADGroupMember -Identity $g -Members $sam
        Write-Log "Added to: $g"
    } catch {
        Write-Log "Couldn't add to $g - $($_.Exception.Message)" 'WARN'
    }
}

# location group if defined
if ($office.ContainsKey('Group')) {
    Add-ADGroupMember -Identity $office.Group -Members $sam
}


# ---- sync to entra / wait for it to show up ----

# kick off a delta sync on the AAD connect server
# sometimes this fails if run remotely so we catch it and just wait longer
try {
    Invoke-Command -ComputerName $Config.AADConnectServer -ScriptBlock {
        Import-Module ADSync
        Start-ADSyncSyncCycle -PolicyType Delta
    }
    Write-Log "AAD Connect sync triggered"
    Start-Sleep -Seconds 90
} catch {
    Write-Log "Couldn't trigger AAD Connect sync remotely, waiting 3min for scheduled sync" 'WARN'
    Start-Sleep -Seconds 180
}


# ---- assign M365 license ----

Connect-MsolService

# poll until the user shows up in entra, give it up to 5 minutes
$msolUser = $null
$attempts = 0
while (-not $msolUser -and $attempts -lt 10) {
    Start-Sleep -Seconds 30
    $msolUser = Get-MsolUser -UserPrincipalName $upn -ErrorAction SilentlyContinue
    $attempts++
}

if (-not $msolUser) {
    Write-Log "User never showed up in Entra ID - assign license manually" 'ERROR'
    throw "Entra sync timeout"
}

Set-MsolUser -UserPrincipalName $upn -UsageLocation $Config.UsageLocation
Set-MsolUserLicense -UserPrincipalName $upn -AddLicenses $Config.LicenseSKUs[$LicenseSKU]
Write-Log "License assigned: $LicenseSKU"


# ---- M365 groups ----

Connect-ExchangeOnline -ShowBanner:$false

foreach ($g in $dept.M365Groups) {
    try {
        Add-UnifiedGroupLinks -Identity $g -LinkType Members -Links $upn
        Write-Log "Added to M365 group: $g"
    } catch {
        # non-fatal, log it and move on
        Write-Log "M365 group add failed for $g - $($_.Exception.Message)" 'WARN'
    }
}


# ---- email manager ----

# TODO: move this to a proper email template file at some point
$body = @"
Hi $($mgr.GivenName),

$displayName is all set.

Username: $upn
Temp password: $pwd

They'll be asked to change it on first login. Please give it to them directly,
don't forward this email.

Groups: $($dept.Groups -join ', ')
License: $LicenseSKU
Office: $($office.OfficeName)

Let IT know if anything looks wrong or they need extra access.

- IT
"@

try {
    Send-MailMessage -To $mgr.EmailAddress -From $Config.NotificationEmail `
        -Subject "Account ready: $displayName" -Body $body -SmtpServer $Config.SMTPRelay
    Write-Log "Email sent to $($mgr.EmailAddress)"
} catch {
    Write-Log "Failed to send email: $($_.Exception.Message)" 'WARN'
}


# ---- done ----

Write-Log "Done: $displayName / $upn"

[PSCustomObject]@{
    Name      = $displayName
    UPN       = $upn
    SAM       = $sam
    Password  = $pwd
    License   = $LicenseSKU
    Dept      = $Department
    Location  = $Location
    Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
}
