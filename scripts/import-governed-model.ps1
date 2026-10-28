param(
    [Parameter(Mandatory)] [string] $ConfigPath,
    [Parameter(Mandatory)] [string] $ManifestPath,
    [Parameter(Mandatory)] [string] $BundlePath,
    [Parameter(Mandatory)] [string] $Alias,
    [Parameter(Mandatory)] [string] $AccessGroupId,
    [ValidateSet('cpu', 'nvidia')] [string] $Profile = 'cpu',
    [switch] $CheckOnly
)
. (Join-Path $PSScriptRoot 'governance/common.ps1')
$cli = @('import', '--config', $ConfigPath, '--manifest', $ManifestPath,
    '--bundle', $BundlePath, '--alias', $Alias, '--group', $AccessGroupId, '--profile', $Profile)
if ($CheckOnly) { $cli += '--check-only' }
Invoke-GovernanceCli -CliArguments $cli
