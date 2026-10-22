$ErrorActionPreference = 'Stop'
$global:ecopinBootstrapTestCommands = [System.Collections.Generic.List[object]]::new()
$global:ecopinBootstrapTestPolicies = @{}
function global:aws {
    $arguments = @($args)
    $global:ecopinBootstrapTestCommands.Add($arguments)
    $global:LASTEXITCODE = 0
    if ($arguments[0] -eq 'sts') { return '{"Account":"035074951255"}' }
    if ($arguments[0] -eq 'iam' -and $arguments[1] -eq 'list-open-id-connect-providers') { return '{"OpenIDConnectProviderList":[]}' }
    if ($arguments[0] -eq 'ec2' -and $arguments[1] -eq 'describe-iam-instance-profile-associations') { return '{"IamInstanceProfileAssociations":[]}' }
    if ($arguments[1] -in @('get-role','get-instance-profile','head-bucket','describe-document')) {
        $global:LASTEXITCODE = 1; return
    }
    foreach ($flag in @('--policy-document','--assume-role-policy-document','--content')) {
        $position = [array]::IndexOf($arguments, $flag)
        if ($position -ge 0) {
            $path = $arguments[$position + 1].Substring(7)
            $global:ecopinBootstrapTestPolicies[(Split-Path -Leaf $path)] = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        }
    }
    return '{}'
}
try {
    & "$PSScriptRoot/bootstrap.ps1"
    if ($global:ecopinBootstrapTestCommands.Count -lt 20) { throw 'Expected full provisioning plan' }
    $trust = $global:ecopinBootstrapTestPolicies['ecopin-backend-github-deploy-trust.json']
    if ($trust.Statement[0].Condition.StringEquals.'token.actions.githubusercontent.com:sub' -ne 'repo:klacom@170255538/ecopin_backend_node@1256316967:ref:refs/heads/master') { throw 'Backend trust must be branch- and identity-scoped' }
    $ml = $global:ecopinBootstrapTestPolicies['ecopin-ml-github-deploy-policy.json']
    if ($ml.Statement[2].Resource.Count -ne 3) { throw 'ML role must target exactly three functions' }
    $document = $global:ecopinBootstrapTestPolicies['document.json']
    if ($document.parameters.Release.allowedPattern -ne '^[0-9a-f]{40}$') { throw 'Release parameter must reject shell injection' }
    Write-Output 'Bootstrap contract checks passed without calling AWS.'
} finally {
    Remove-Item Function:\aws
    Remove-Variable ecopinBootstrapTestCommands,ecopinBootstrapTestPolicies -Scope Global
}
