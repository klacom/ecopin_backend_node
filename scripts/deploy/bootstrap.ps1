$ErrorActionPreference = 'Stop'
$region = 'ap-southeast-1'
$account = '035074951255'
$bucket = "ecopin-deploy-$account-$region"
$instance = 'i-09848ea939a21db3c'
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ('ecopin-bootstrap-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $scratch | Out-Null
function Invoke-Aws([string[]]$Arguments) {
    $result = & aws @Arguments --region $region --output json
    if ($LASTEXITCODE -ne 0) { throw "AWS command failed: $($Arguments[0..1] -join ' ')" }
    if ($result) { return ($result | ConvertFrom-Json) }
}
function JsonFile($Name, $Value) {
    $path = Join-Path $scratch $Name
    $Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
    return "file://$path"
}
function Ensure-Role($Name, $Trust, $Policy) {
    & aws iam get-role --role-name $Name --output json 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Invoke-Aws -Arguments @('iam','create-role','--role-name',$Name,'--assume-role-policy-document',(JsonFile "$Name-trust.json" $Trust)) | Out-Null
    } else {
        Invoke-Aws -Arguments @('iam','update-assume-role-policy','--role-name',$Name,'--policy-document',(JsonFile "$Name-trust.json" $Trust)) | Out-Null
    }
    Invoke-Aws -Arguments @('iam','put-role-policy','--role-name',$Name,'--policy-name','EcoPinDeployment','--policy-document',(JsonFile "$Name-policy.json" $Policy)) | Out-Null
}
function GitHub-Trust($Repository, $Branch, $RepositoryId) {
    return @{Version='2012-10-17';Statement=@(@{Effect='Allow';Action='sts:AssumeRoleWithWebIdentity';
        Principal=@{Federated="arn:aws:iam::${account}:oidc-provider/token.actions.githubusercontent.com"};
        Condition=@{StringEquals=@{'token.actions.githubusercontent.com:aud'='sts.amazonaws.com';
        'token.actions.githubusercontent.com:sub'="repo:klacom@170255538/${Repository}@${RepositoryId}:ref:refs/heads/$Branch"}}})}
}
try {
    $identity = Invoke-Aws -Arguments @('sts','get-caller-identity')
    if ($identity.Account -ne $account) { throw 'Wrong AWS account; refusing to provision.' }
    $providers = Invoke-Aws -Arguments @('iam','list-open-id-connect-providers')
    if (-not ($providers.OpenIDConnectProviderList.Arn -contains "arn:aws:iam::${account}:oidc-provider/token.actions.githubusercontent.com")) {
        Invoke-Aws -Arguments @('iam','create-open-id-connect-provider','--url','https://token.actions.githubusercontent.com','--client-id-list','sts.amazonaws.com') | Out-Null
    }
    & aws s3api head-bucket --bucket $bucket --region $region 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Invoke-Aws -Arguments @('s3api','create-bucket','--bucket',$bucket,'--create-bucket-configuration',"LocationConstraint=$region") | Out-Null
    }
    Invoke-Aws -Arguments @('s3api','put-public-access-block','--bucket',$bucket,'--public-access-block-configuration','BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true') | Out-Null
    Invoke-Aws -Arguments @('s3api','put-bucket-versioning','--bucket',$bucket,'--versioning-configuration','Status=Enabled') | Out-Null
    Invoke-Aws -Arguments @('s3api','put-bucket-encryption','--bucket',$bucket,'--server-side-encryption-configuration',
        (JsonFile 'encryption.json' @{Rules=@(@{ApplyServerSideEncryptionByDefault=@{SSEAlgorithm='AES256'}})})) | Out-Null
    Invoke-Aws -Arguments @('s3api','put-bucket-policy','--bucket',$bucket,'--policy',
        (JsonFile 'bucket-policy.json' @{Version='2012-10-17';Statement=@(@{Effect='Deny';Principal='*';Action='s3:*';
        Resource=@("arn:aws:s3:::$bucket","arn:aws:s3:::$bucket/*");Condition=@{Bool=@{'aws:SecureTransport'='false'}}})})) | Out-Null
    $document = @{schemaVersion='2.2';description='Deploy one immutable EcoPin release; no arbitrary shell parameters.';
        parameters=@{Release=@{type='String';allowedPattern='^[0-9a-f]{40}$'}};
        mainSteps=@(@{action='aws:runShellScript';name='deploy';inputs=@{timeoutSeconds='900';
        runCommand=@('runuser -u ubuntu -- /opt/ecopin/deploy-backend.sh "{{ Release }}"')}})}
    & aws ssm describe-document --name EcoPin-DeployBackend --region $region 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Invoke-Aws -Arguments @('ssm','create-document','--name','EcoPin-DeployBackend','--document-type','Command','--content',(JsonFile 'document.json' $document)) | Out-Null
    }
    $backendPolicy = @{Version='2012-10-17';Statement=@(
        @{Effect='Allow';Action=@('s3:PutObject');Resource="arn:aws:s3:::$bucket/backend/*"},
        @{Effect='Allow';Action='ssm:SendCommand';Resource=@("arn:aws:ssm:${region}:${account}:document/EcoPin-DeployBackend","arn:aws:ec2:${region}:${account}:instance/$instance")},
        @{Effect='Allow';Action='ssm:GetCommandInvocation';Resource='*'})}
    Ensure-Role 'ecopin-backend-github-deploy' (GitHub-Trust 'ecopin_backend_node' 'master' '1256316967') $backendPolicy
    $repositories = @('clip-validation-lambda','ecopin-vrp-service','hotspot-forecasting')
    $functions = @('clip-validator','ecopin-vrp-service','ecopin-temp-hotspot-forecasting-aka-spatial-analysis')
    $mlPolicy = @{Version='2012-10-17';Statement=@(
        @{Effect='Allow';Action='ecr:GetAuthorizationToken';Resource='*'},
        @{Effect='Allow';Action=@('ecr:BatchCheckLayerAvailability','ecr:InitiateLayerUpload','ecr:UploadLayerPart','ecr:CompleteLayerUpload','ecr:PutImage','ecr:BatchGetImage','ecr:GetDownloadUrlForLayer','ecr:DescribeImages');
            Resource=@($repositories | ForEach-Object { "arn:aws:ecr:${region}:${account}:repository/$_" })},
        @{Effect='Allow';Action=@('lambda:GetFunction','lambda:GetFunctionConfiguration','lambda:UpdateFunctionCode','lambda:InvokeFunction');
            Resource=@($functions | ForEach-Object { "arn:aws:lambda:${region}:${account}:function:$_" })},
        @{Effect='Allow';Action='ecr-public:GetAuthorizationToken';Resource='*'},
        @{Effect='Allow';Action='sts:GetServiceBearerToken';Resource='*';Condition=@{StringEquals=@{'sts:AWSServiceName'='ecr-public.amazonaws.com'}}})}
    Ensure-Role 'ecopin-ml-github-deploy' (GitHub-Trust 'ecopin_ml_models' 'main' '1338119715') $mlPolicy
    $ec2Trust = @{Version='2012-10-17';Statement=@(@{Effect='Allow';Action='sts:AssumeRole';Principal=@{Service='ec2.amazonaws.com'}})}
    $ec2Policy = @{Version='2012-10-17';Statement=@(@{Effect='Allow';Action='s3:GetObject';Resource="arn:aws:s3:::$bucket/backend/*"})}
    Ensure-Role 'ecopin-backend-instance' $ec2Trust $ec2Policy
    Invoke-Aws -Arguments @('iam','attach-role-policy','--role-name','ecopin-backend-instance','--policy-arn','arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore') | Out-Null
    & aws iam get-instance-profile --instance-profile-name ecopin-backend-instance 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Invoke-Aws -Arguments @('iam','create-instance-profile','--instance-profile-name','ecopin-backend-instance') | Out-Null
        Invoke-Aws -Arguments @('iam','add-role-to-instance-profile','--instance-profile-name','ecopin-backend-instance','--role-name','ecopin-backend-instance') | Out-Null
    }
    $associations = Invoke-Aws -Arguments @('ec2','describe-iam-instance-profile-associations','--filters',"Name=instance-id,Values=$instance")
    if (-not $associations.IamInstanceProfileAssociations) {
        # IAM profile creation is eventually consistent with EC2.
        foreach ($attempt in 1..6) {
            try {
                Invoke-Aws -Arguments @('ec2','associate-iam-instance-profile','--instance-id',$instance,'--iam-instance-profile',"Arn=arn:aws:iam::${account}:instance-profile/ecopin-backend-instance") | Out-Null
                break
            } catch {
                if ($attempt -eq 6) { throw }
                Start-Sleep -Seconds 10
            }
        }
    }
    Write-Output 'Deployment roles, private artifact bucket and fixed SSM command are ready.'
} finally {
    # Only delete this invocation's verified temporary directory.
    $resolvedScratch = (Resolve-Path -LiteralPath $scratch).Path
    $resolvedTemp = (Resolve-Path -LiteralPath ([System.IO.Path]::GetTempPath())).Path.TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    if ((Split-Path -Parent $resolvedScratch) -eq $resolvedTemp -and (Split-Path -Leaf $resolvedScratch) -like 'ecopin-bootstrap-*') {
        Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
    }
}
