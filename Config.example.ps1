# Config.example.ps1
# Copy this file to Config.ps1 and fill in your environment values.
# Config.ps1 is excluded from source control via .gitignore

$Config = @{

    CompanyName       = 'Your Company Name'
    Domain            = 'yourdomain.com'
    UsageLocation     = 'US'
    NotificationEmail = 'it@yourdomain.com'
    SMTPRelay         = 'smtp.yourdomain.com'
    AADConnectServer  = 'AADCONNECT-HOSTNAME'
    BaseGroup         = 'GRP-AllUsers'

    # Run: Connect-MsolService; Get-MsolAccountSku | Select SkuPartNumber, AccountSkuId
    LicenseSKUs = @{
        BusinessPremium = 'tenant:SPB'
        E3              = 'tenant:ENTERPRISEPACK'
        E5              = 'tenant:ENTERPRISEPREMIUM'
        F3              = 'tenant:FLOW_FREE'
    }

    Locations = @{
        HQ = @{
            OfficeName = 'Headquarters'
            Street     = '123 Main St'
            City       = 'Your City'
            State      = 'CA'
            Zip        = '00000'
            Group      = 'GRP-Location-HQ'
        }
        Remote = @{
            OfficeName = 'Remote'
            Street     = ''
            City       = ''
            State      = ''
            Zip        = ''
        }
    }

    Departments = @{
        IT = @{
            OU         = 'OU=IT,OU=Users,DC=yourdomain,DC=com'
            Groups     = @('GRP-IT','GRP-VPN-Users')
            M365Groups = @('IT Team','All Staff')
        }
    }
}
