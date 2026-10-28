param(
    [Parameter(Mandatory)] [switch] $Fixture,
    [int] $Port = 8787,
    [string] $StateDirectory = '.governance-state/demo'
)
. (Join-Path $PSScriptRoot 'governance/common.ps1')
if (-not $Fixture) { throw 'This coordinator is an explicit synthetic fixture POC. Real MuleSoft integration is separate.' }
Invoke-GovernanceCli -CliArguments @('serve', '--fixture', '--embedded-agent', '--port', "$Port", '--state', $StateDirectory)
