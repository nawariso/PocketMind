param(
    [Parameter(Position = 0, Mandatory)] [ValidateSet('request', 'status', 'retry', 'cancel')] [string] $Action,
    [Parameter(Mandatory)] [string] $ConfigPath,
    [ValidateSet('huggingface', 'ollama')] [string] $Source = 'huggingface',
    [string] $ModelId,
    [string] $Revision = 'main',
    [string] $Artifact = 'model.gguf',
    [string] $Alias,
    [string] $TargetId = 'local',
    [string] $AccessGroupId = 'testers',
    [string] $Purpose = 'Local governance POC',
    [string] $JobId,
    [string] $IdempotencyKey
)
. (Join-Path $PSScriptRoot 'governance/common.ps1')
$cli = @($Action, '--config', $ConfigPath)
if ($Action -eq 'request') {
    if (-not $ModelId -or -not $Alias) { throw 'request requires -ModelId and -Alias.' }
    $cli += @('--source', $Source, '--model-id', $ModelId, '--revision', $Revision,
        '--artifact', $Artifact, '--alias', $Alias, '--target-id', $TargetId,
        '--group', $AccessGroupId, '--purpose', $Purpose)
    if ($IdempotencyKey) { $cli += @('--idempotency-key', $IdempotencyKey) }
}
else {
    if (-not $JobId) { throw "$Action requires -JobId." }
    $cli += @('--job-id', $JobId)
}
Invoke-GovernanceCli -CliArguments $cli
