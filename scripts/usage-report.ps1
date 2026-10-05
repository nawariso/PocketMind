param(
    [ValidateRange(1, 3650)] [int] $Days = 30,
    [string[]] $Compare = @('gpt-4o-mini', 'gpt-4.1-mini', 'claude-haiku-4-5', 'claude-sonnet-4-5'),
    # Optional local cost inputs (USD). Omit them to report tokens and commercial equivalents only.
    [ValidateRange(0, 1e7)] [double] $HardwareCost = 0,
    [ValidateRange(1, 600)] [int] $LifetimeMonths = 36,
    [ValidateRange(0, 5000)] [double] $AvgWatts = 0,
    [ValidateRange(0, 100)] [double] $ElectricityPerKwh = 0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'common.ps1')

$envValues = @{}
foreach ($line in Get-Content -LiteralPath (Join-Path $script:PocRepoRoot '.env')) {
    if ($line -match '^\s*([A-Z0-9_]+)=(.*)$') { $envValues[$matches[1]] = $matches[2] }
}

# Real usage recorded by LiteLLM: tokens and request wall time per physical model.
$sql = @"
select model, count(*), coalesce(sum(prompt_tokens),0), coalesce(sum(completion_tokens),0),
       coalesce(sum(extract(epoch from ("endTime" - "startTime"))),0),
       min("startTime")::date, max("startTime")::date
from "LiteLLM_SpendLogs"
where "startTime" >= now() - interval '$Days days' and model <> '' and total_tokens > 0
group by model order by 3 desc
"@
$rows = & docker exec pocketmind-postgres psql -U $envValues['POSTGRES_USER'] -d $envValues['POSTGRES_DB'] -At -F '|' -c $sql
if ($LASTEXITCODE -ne 0) { throw 'Could not read LiteLLM usage from PostgreSQL.' }
$usage = @(foreach ($r in $rows) {
    $f = $r -split '\|'
    [pscustomobject]@{ Model = $f[0] -replace '^ollama_chat/', ''; Calls = [int]$f[1]; InTok = [long]$f[2]; OutTok = [long]$f[3]; Seconds = [double]$f[4] }
})
if ($usage.Count -eq 0) { Write-Host "No usage recorded in the last $Days days."; return }

Write-Host "`nLocal usage, last $Days days (measured by LiteLLM)" -ForegroundColor Cyan
$usage | Format-Table Model, Calls, InTok, OutTok, @{ n = 'BusySec'; e = { [math]::Round($_.Seconds, 1) } } -AutoSize

$inTotal = ($usage | Measure-Object InTok -Sum).Sum
$outTotal = ($usage | Measure-Object OutTok -Sum).Sum
$busyHours = (($usage | Measure-Object Seconds -Sum).Sum) / 3600

# Commercial prices come from LiteLLM's bundled price table, not from hand-typed values.
$py = "import json,sys,litellm;m=litellm.model_cost;print(json.dumps({k:[m[k]['input_cost_per_token'],m[k]['output_cost_per_token']] for k in sys.argv[1:] if k in m}))"
$prices = (& docker exec pocketmind-litellm python3 -c $py @Compare) | ConvertFrom-Json

Write-Host "Same tokens at commercial prices (LiteLLM price table)" -ForegroundColor Cyan
$comparison = foreach ($name in $Compare) {
    $p = $prices.$name
    if ($null -eq $p) { Write-Warning "No price for '$name' in LiteLLM price table; skipped."; continue }
    [pscustomobject]@{ Model = $name; InUsdPerM = $p[0] * 1e6; OutUsdPerM = $p[1] * 1e6; CostUsd = [math]::Round($inTotal * $p[0] + $outTotal * $p[1], 4) }
}
$comparison | Format-Table -AutoSize

if ($HardwareCost -gt 0 -or $AvgWatts -gt 0) {
    $amortized = $HardwareCost / ($LifetimeMonths * 30.4375) * $Days
    $electricity = ($AvgWatts / 1000) * $busyHours * $ElectricityPerKwh
    $local = $amortized + $electricity
    Write-Host "Local cost for the same period (from your inputs)" -ForegroundColor Cyan
    Write-Host ("  Hardware amortization: {0:N4} USD ({1:N0} over {2} months)" -f $amortized, $HardwareCost, $LifetimeMonths)
    Write-Host ("  Electricity: {0:N4} USD ({1} W x {2:N3} busy hours x {3}/kWh)" -f $electricity, $AvgWatts, $busyHours, $ElectricityPerKwh)
    Write-Host ("  Total: {0:N4} USD = {1:N4} USD per 1M tokens" -f $local, ($local / (($inTotal + $outTotal) / 1e6)))
    Write-Host 'Hardware is amortized over calendar time, so low usage makes local look expensive per token. Busy hours exclude idle time.'
}
Write-Host 'Quality, latency, privacy, and model capability are not included in this cost comparison.'
