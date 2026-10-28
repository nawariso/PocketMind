param(
    [Parameter(Mandatory)] [string] $ConfigPath,
    [ValidateSet('cpu', 'nvidia')] [string] $Profile = 'cpu',
    [switch] $Fixture,
    [switch] $Once
)
. (Join-Path $PSScriptRoot 'governance/common.ps1')
$cli = @('agent', '--config', $ConfigPath, '--profile', $Profile)
if ($Fixture) { $cli += '--fixture' }
if ($Once) { $cli += '--once' }
Invoke-GovernanceCli -CliArguments $cli
