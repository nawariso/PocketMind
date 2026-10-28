$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-GovernanceCli {
    param([Parameter(Mandatory)] [string[]] $CliArguments)
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Push-Location -LiteralPath $repoRoot
    try {
        & python -X utf8 -m governance @CliArguments
        if ($LASTEXITCODE -ne 0) { throw "Governance command failed (exit $LASTEXITCODE)." }
    }
    finally { Pop-Location }
}
