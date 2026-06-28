@{
    RootModule = 'Fiducia.psm1'
    ModuleVersion = '0.1.0'
    GUID = 'f2a78921-522e-4a33-a1f6-5dd6b0fce8a1'
    Author = 'fiducia.cloud'
    CompanyName = 'fiducia.cloud'
    Copyright = '(c) fiducia.cloud. All rights reserved.'
    Description = 'Fiducia HTTP client for PowerShell.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @()
    CmdletsToExport = @()
    VariablesToExport = '*'
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('fiducia', 'coordination', 'locks', 'semaphores', 'kv')
            ProjectUri = 'https://github.com/fiducia-cloud/fiducia-clients/tree/main/clients/powershell'
        }
    }
}
