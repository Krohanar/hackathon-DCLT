param(
    [string]$Region = "us-east-1",
    [string]$AccountId = "106978078844",
    [string]$ClusterName = "solidarytech-production",
    [string]$NodeGroupName = "solidarytech-production-default-ng",
    [string]$DbInstanceIdentifier = "solidarytech-production-postgres",
    [string]$DynamoDbTableName = "SolidaryTechVolunteers",
    [string]$SqsQueueName = "solidary-donations"
)

$ErrorActionPreference = "Stop"

function Write-Utf8File {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Content
    )

    $Directory = Split-Path -Parent $Path

    if ($Directory) {
        New-Item `
            -ItemType Directory `
            -Force `
            -Path $Directory |
        Out-Null
    }

    $Utf8WithoutBom = [System.Text.UTF8Encoding]::new($false)

    [System.IO.File]::WriteAllText(
        $Path,
        $Content,
        $Utf8WithoutBom
    )
}

function Invoke-AwsJson {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$OutputPath
    )

    Write-Host ""
    Write-Host "AWS CLI: aws $($Arguments -join ' ')" -ForegroundColor Cyan

    $RawOutput = & aws @Arguments 2>&1
    $ExitCode = $LASTEXITCODE

    $TextOutput = $RawOutput -join [Environment]::NewLine

    if ($ExitCode -ne 0) {
        throw @"
Comando AWS falhou.

Comando:
aws $($Arguments -join ' ')

Saída:
$TextOutput
"@
    }

    Write-Utf8File `
        -Path $OutputPath `
        -Content $TextOutput

    if ([string]::IsNullOrWhiteSpace($TextOutput)) {
        return $null
    }

    return $TextOutput | ConvertFrom-Json
}

function Convert-AwsNumber {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return 0.0
    }

    return [double]::Parse(
        $Value,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
}

function Invoke-CommandSnapshot {
    param(
        [Parameter(Mandatory)]
        [string]$Description,

        [Parameter(Mandatory)]
        [scriptblock]$Command,

        [Parameter(Mandatory)]
        [string]$OutputPath
    )

    Write-Host ""
    Write-Host $Description -ForegroundColor Cyan

    try {
        $Output = & $Command 2>&1
        $Text = $Output -join [Environment]::NewLine

        Write-Utf8File `
            -Path $OutputPath `
            -Content $Text

        Write-Host "Salvo em: $OutputPath"
    }
    catch {
        $ErrorText = $_ | Out-String

        Write-Utf8File `
            -Path $OutputPath `
            -Content $ErrorText

        Write-Warning "$Description falhou. O erro foi salvo no arquivo."
    }
}

$RepositoryRoot = (Get-Location).Path
$RunDate = Get-Date -Format "yyyy-MM-dd-HHmmss"

$OutputDirectory = Join-Path `
    $RepositoryRoot `
    "docs\finops\data\$RunDate"

New-Item `
  -ItemType Directory `
  -Force `
  -Path $OutputDirectory |
Out-Null

Write-Host "========================================="
Write-Host "SOLIDARYTECH - COLETA FINOPS"
Write-Host "========================================="
Write-Host "Diretório: $OutputDirectory"
Write-Host "Região:    $Region"
Write-Host "Conta:     $AccountId"

# ------------------------------------------------------------
# 1. Identidade AWS
# ------------------------------------------------------------

$IdentityPath = Join-Path $OutputDirectory "aws-identity.json"

$Identity = Invoke-AwsJson `
    -Arguments @(
        "sts",
        "get-caller-identity",
        "--output",
        "json"
    ) `
    -OutputPath $IdentityPath

if ($Identity.Account -ne $AccountId) {
    throw @"
A AWS CLI está autenticada na conta errada.

Esperado: $AccountId
Atual:    $($Identity.Account)
"@
}

# ------------------------------------------------------------
# 2. Datas para Cost Explorer
# ------------------------------------------------------------

$Today = (Get-Date).Date

$MonthStart = Get-Date `
    -Year $Today.Year `
    -Month $Today.Month `
    -Day 1

$Tomorrow = $Today.AddDays(1)

# Fim exclusivo: primeiro dia do mês posterior ao próximo.
# Exemplo em julho: 1º de setembro.
$ForecastEnd = $MonthStart.AddMonths(2)

$MonthStartText = $MonthStart.ToString("yyyy-MM-dd")
$TomorrowText = $Tomorrow.ToString("yyyy-MM-dd")
$TodayText = $Today.ToString("yyyy-MM-dd")
$ForecastEndText = $ForecastEnd.ToString("yyyy-MM-dd")

# ------------------------------------------------------------
# 3. Custo do mês atual, agrupado por serviço
# ------------------------------------------------------------

$CurrentCostPath = Join-Path `
    $OutputDirectory `
    "current-month-by-service.json"

$CurrentCost = Invoke-AwsJson `
    -Arguments @(
        "ce",
        "get-cost-and-usage",
        "--time-period",
        "Start=$MonthStartText,End=$TomorrowText",
        "--granularity",
        "MONTHLY",
        "--metrics",
        "UNBLENDED_COST",
        "--group-by",
        "Type=DIMENSION,Key=SERVICE",
        "--output",
        "json"
    ) `
    -OutputPath $CurrentCostPath

$CurrentCostRows = @()

foreach ($Result in $CurrentCost.ResultsByTime) {
    foreach ($Group in $Result.Groups) {
        $CurrentCostRows += [PSCustomObject]@{
            PeriodStart = $Result.TimePeriod.Start
            PeriodEnd   = $Result.TimePeriod.End
            Service     = $Group.Keys[0]
            CostUSD     = Convert-AwsNumber `
                $Group.Metrics.UnblendedCost.Amount
            Unit        = $Group.Metrics.UnblendedCost.Unit
        }
    }
}

$CurrentCostRows = $CurrentCostRows |
    Sort-Object CostUSD -Descending

$CurrentCostCsv = Join-Path `
    $OutputDirectory `
    "current-month-by-service.csv"

$CurrentCostRows |
Export-Csv `
  -Path $CurrentCostCsv `
  -NoTypeInformation `
  -Encoding UTF8

$CurrentMonthTotal = (
    $CurrentCostRows |
    Measure-Object `
      -Property CostUSD `
      -Sum
).Sum

# ------------------------------------------------------------
# 4. Forecast oficial do Cost Explorer
# ------------------------------------------------------------

$ForecastSucceeded = $false
$ForecastRows = @()
$ForecastError = $null

try {
    $ForecastPath = Join-Path `
        $OutputDirectory `
        "forecast-monthly.json"

    $Forecast = Invoke-AwsJson `
        -Arguments @(
            "ce",
            "get-cost-forecast",
            "--time-period",
            "Start=$TodayText,End=$ForecastEndText",
            "--metric",
            "UNBLENDED_COST",
            "--granularity",
            "MONTHLY",
            "--prediction-interval-level",
            "80",
            "--output",
            "json"
        ) `
        -OutputPath $ForecastPath

    foreach ($Result in $Forecast.ForecastResultsByTime) {
        $ForecastRows += [PSCustomObject]@{
            PeriodStart = $Result.TimePeriod.Start
            PeriodEnd   = $Result.TimePeriod.End
            MeanUSD     = Convert-AwsNumber $Result.MeanValue
            LowerUSD    = Convert-AwsNumber `
                $Result.PredictionIntervalLowerBound
            UpperUSD    = Convert-AwsNumber `
                $Result.PredictionIntervalUpperBound
        }
    }

    $ForecastCsv = Join-Path `
        $OutputDirectory `
        "forecast-monthly.csv"

    $ForecastRows |
    Export-Csv `
      -Path $ForecastCsv `
      -NoTypeInformation `
      -Encoding UTF8

    $ForecastSucceeded = $true
}
catch {
    $ForecastError = $_ | Out-String

    Write-Utf8File `
        -Path (
            Join-Path `
                $OutputDirectory `
                "forecast-error.txt"
        ) `
        -Content $ForecastError

    Write-Warning @"
O Cost Explorer não produziu forecast.

Isso pode ocorrer quando a conta ainda não possui histórico suficiente.
O Forecast bottom-up da arquitetura ainda será calculado.
"@
}

# ------------------------------------------------------------
# 5. EKS e nodes
# ------------------------------------------------------------

$EksCluster = Invoke-AwsJson `
    -Arguments @(
        "eks",
        "describe-cluster",
        "--name",
        $ClusterName,
        "--region",
        $Region,
        "--output",
        "json"
    ) `
    -OutputPath (
        Join-Path $OutputDirectory "eks-cluster.json"
    )

$EksNodeGroup = Invoke-AwsJson `
    -Arguments @(
        "eks",
        "describe-nodegroup",
        "--cluster-name",
        $ClusterName,
        "--nodegroup-name",
        $NodeGroupName,
        "--region",
        $Region,
        "--output",
        "json"
    ) `
    -OutputPath (
        Join-Path $OutputDirectory "eks-nodegroup.json"
    )

$Ec2Nodes = Invoke-AwsJson `
    -Arguments @(
        "ec2",
        "describe-instances",
        "--region",
        $Region,
        "--filters",
        "Name=tag:eks:cluster-name,Values=$ClusterName",
        "Name=instance-state-name,Values=pending,running,stopping,stopped",
        "--output",
        "json"
    ) `
    -OutputPath (
        Join-Path $OutputDirectory "ec2-eks-nodes.json"
    )

# ------------------------------------------------------------
# 6. RDS
# ------------------------------------------------------------

$Rds = Invoke-AwsJson `
    -Arguments @(
        "rds",
        "describe-db-instances",
        "--db-instance-identifier",
        $DbInstanceIdentifier,
        "--region",
        $Region,
        "--output",
        "json"
    ) `
    -OutputPath (
        Join-Path $OutputDirectory "rds.json"
    )

# ------------------------------------------------------------
# 7. EBS
# ------------------------------------------------------------

$EbsVolumes = Invoke-AwsJson `
    -Arguments @(
        "ec2",
        "describe-volumes",
        "--region",
        $Region,
        "--filters",
        "Name=status,Values=available,in-use",
        "--output",
        "json"
    ) `
    -OutputPath (
        Join-Path $OutputDirectory "ebs-volumes.json"
    )

# ------------------------------------------------------------
# 8. NAT Gateways e IPs públicos
# ------------------------------------------------------------

$NatGateways = Invoke-AwsJson `
    -Arguments @(
        "ec2",
        "describe-nat-gateways",
        "--region",
        $Region,
        "--filter",
        "Name=state,Values=available,pending",
        "--output",
        "json"
    ) `
    -OutputPath (
        Join-Path $OutputDirectory "nat-gateways.json"
    )

$ElasticIps = Invoke-AwsJson `
    -Arguments @(
        "ec2",
        "describe-addresses",
        "--region",
        $Region,
        "--output",
        "json"
    ) `
    -OutputPath (
        Join-Path $OutputDirectory "elastic-ips.json"
    )

# ------------------------------------------------------------
# 9. Load Balancers
# ------------------------------------------------------------

$LoadBalancers = Invoke-AwsJson `
    -Arguments @(
        "elbv2",
        "describe-load-balancers",
        "--region",
        $Region,
        "--output",
        "json"
    ) `
    -OutputPath (
        Join-Path $OutputDirectory "load-balancers.json"
    )

# ------------------------------------------------------------
# 10. DynamoDB
# ------------------------------------------------------------

$DynamoDb = Invoke-AwsJson `
    -Arguments @(
        "dynamodb",
        "describe-table",
        "--table-name",
        $DynamoDbTableName,
        "--region",
        $Region,
        "--output",
        "json"
    ) `
    -OutputPath (
        Join-Path $OutputDirectory "dynamodb.json"
    )

# ------------------------------------------------------------
# 11. SQS
# ------------------------------------------------------------

$QueueUrlRaw = & aws `
    sqs get-queue-url `
    --queue-name $SqsQueueName `
    --region $Region `
    --query "QueueUrl" `
    --output text

if ($LASTEXITCODE -ne 0) {
    throw "Não foi possível obter a URL da fila SQS."
}

$QueueUrl = ($QueueUrlRaw -join "").Trim()

$SqsAttributes = Invoke-AwsJson `
    -Arguments @(
        "sqs",
        "get-queue-attributes",
        "--queue-url",
        $QueueUrl,
        "--attribute-names",
        "All",
        "--region",
        $Region,
        "--output",
        "json"
    ) `
    -OutputPath (
        Join-Path $OutputDirectory "sqs.json"
    )

# ------------------------------------------------------------
# 12. ECR e armazenamento das imagens
# ------------------------------------------------------------

$EcrRepositories = Invoke-AwsJson `
    -Arguments @(
        "ecr",
        "describe-repositories",
        "--registry-id",
        $AccountId,
        "--region",
        $Region,
        "--output",
        "json"
    ) `
    -OutputPath (
        Join-Path $OutputDirectory "ecr-repositories.json"
    )

$EcrRows = @()

foreach ($Repository in $EcrRepositories.repositories) {
    $RepositoryName = $Repository.repositoryName

    $ImageDetailsRaw = & aws `
        ecr describe-images `
        --repository-name $RepositoryName `
        --registry-id $AccountId `
        --region $Region `
        --filter tagStatus=ANY `
        --output json 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Não foi possível consultar imagens de $RepositoryName."
        continue
    }

    $ImageDetailsText = $ImageDetailsRaw -join [Environment]::NewLine
    $ImageDetails = $ImageDetailsText | ConvertFrom-Json

    $TotalBytes = 0

    foreach ($Image in $ImageDetails.imageDetails) {
        if ($null -ne $Image.imageSizeInBytes) {
            $TotalBytes += [double]$Image.imageSizeInBytes
        }
    }

    $EcrRows += [PSCustomObject]@{
        Repository = $RepositoryName
        ImageCount = @($ImageDetails.imageDetails).Count
        SizeBytes  = $TotalBytes
        SizeMB     = [math]::Round(
            $TotalBytes / 1MB,
            2
        )
        SizeGB     = [math]::Round(
            $TotalBytes / 1GB,
            4
        )
    }
}

$EcrRows |
Export-Csv `
  -Path (
      Join-Path `
          $OutputDirectory `
          "ecr-storage.csv"
  ) `
  -NoTypeInformation `
  -Encoding UTF8

# ------------------------------------------------------------
# 13. S3
# ------------------------------------------------------------

$S3Buckets = Invoke-AwsJson `
    -Arguments @(
        "s3api",
        "list-buckets",
        "--output",
        "json"
    ) `
    -OutputPath (
        Join-Path $OutputDirectory "s3-buckets.json"
    )

# ------------------------------------------------------------
# 14. CloudWatch Logs
# ------------------------------------------------------------

$LogGroups = Invoke-AwsJson `
    -Arguments @(
        "logs",
        "describe-log-groups",
        "--region",
        $Region,
        "--output",
        "json"
    ) `
    -OutputPath (
        Join-Path $OutputDirectory "cloudwatch-log-groups.json"
    )

# ------------------------------------------------------------
# 15. Auditoria das tags obrigatórias
# ------------------------------------------------------------

$TaggedResources = Invoke-AwsJson `
    -Arguments @(
        "resourcegroupstaggingapi",
        "get-resources",
        "--region",
        $Region,
        "--tag-filters",
        "Key=Project,Values=SolidaryTech",
        "Key=Environment,Values=Production",
        "Key=CostCenter,Values=NGO-Core",
        "--output",
        "json"
    ) `
    -OutputPath (
        Join-Path $OutputDirectory "tagged-resources.json"
    )

try {
    $CostAllocationTags = Invoke-AwsJson `
        -Arguments @(
            "ce",
            "list-cost-allocation-tags",
            "--status",
            "ACTIVE",
            "--output",
            "json"
        ) `
        -OutputPath (
            Join-Path `
                $OutputDirectory `
                "active-cost-allocation-tags.json"
        )
}
catch {
    Write-Warning @"
Não foi possível consultar as Cost Allocation Tags ativas.
As tags aplicadas aos recursos ainda foram coletadas normalmente.
"@
}

# ------------------------------------------------------------
# 16. Uso Kubernetes para Rightsizing
# ------------------------------------------------------------

Invoke-CommandSnapshot `
    -Description "Coletando kubectl top nodes..." `
    -Command {
        kubectl top nodes
    } `
    -OutputPath (
        Join-Path $OutputDirectory "kubectl-top-nodes.txt"
    )

Invoke-CommandSnapshot `
    -Description "Coletando kubectl top pods..." `
    -Command {
        kubectl top pods `
          -A `
          --containers
    } `
    -OutputPath (
        Join-Path $OutputDirectory "kubectl-top-pods-containers.txt"
    )

Invoke-CommandSnapshot `
    -Description "Coletando Deployments e recursos Kubernetes..." `
    -Command {
        kubectl get deployments `
          -n solidarytech `
          -o json
    } `
    -OutputPath (
        Join-Path $OutputDirectory "solidarytech-deployments.json"
    )

# ------------------------------------------------------------
# 17. Resumo
# ------------------------------------------------------------

$NodeGroup = $EksNodeGroup.nodegroup
$Database = $Rds.DBInstances[0]

$NodeInstanceTypes = (
    $NodeGroup.instanceTypes -join ", "
)

$NatGatewayCount = @(
    $NatGateways.NatGateways
).Count

$LoadBalancerCount = @(
    $LoadBalancers.LoadBalancers
).Count

$EbsTotalGB = (
    $EbsVolumes.Volumes |
    Measure-Object `
      -Property Size `
      -Sum
).Sum

$TaggedResourceCount = @(
    $TaggedResources.ResourceTagMappingList
).Count

$SummaryLines = @(
    "SolidaryTech - Resumo da coleta FinOps"
    "Data: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    ""
    "Conta AWS: $($Identity.Account)"
    "Região: $Region"
    ""
    "CUSTO ATUAL"
    ('Custo do mês até agora: USD {0:N2}' -f $CurrentMonthTotal)
    ""
    "EKS"
    "Cluster: $ClusterName"
    "Versão: $($EksCluster.cluster.version)"
    "Node group: $NodeGroupName"
    "Tipo(s) de instância: $NodeInstanceTypes"
    "Capacity type: $($NodeGroup.capacityType)"
    "Desired nodes: $($NodeGroup.scalingConfig.desiredSize)"
    "Minimum nodes: $($NodeGroup.scalingConfig.minSize)"
    "Maximum nodes: $($NodeGroup.scalingConfig.maxSize)"
    "Disco configurado por node: $($NodeGroup.diskSize) GB"
    ""
    "RDS"
    "Identificador: $($Database.DBInstanceIdentifier)"
    "Classe: $($Database.DBInstanceClass)"
    "Engine: $($Database.Engine)"
    "Versão: $($Database.EngineVersion)"
    "Multi-AZ: $($Database.MultiAZ)"
    "Storage: $($Database.AllocatedStorage) GB"
    "Storage type: $($Database.StorageType)"
    ""
    "REDE E ARMAZENAMENTO"
    "NAT Gateways: $NatGatewayCount"
    "Load Balancers: $LoadBalancerCount"
    "EBS total encontrado: $EbsTotalGB GB"
    ""
    "TAGGING"
    "Recursos encontrados com as 3 tags obrigatórias: $TaggedResourceCount"
    ""
    "FORECAST COST EXPLORER"
    "Forecast disponível: $ForecastSucceeded"
)

if (-not $ForecastSucceeded) {
    $SummaryLines += "Erro salvo em forecast-error.txt"
}

$SummaryText = $SummaryLines -join [Environment]::NewLine

Write-Utf8File `
    -Path (
        Join-Path $OutputDirectory "finops-summary.txt"
    ) `
    -Content $SummaryText

Write-Host ""
Write-Host "========================================="
Write-Host "COLETA CONCLUÍDA"
Write-Host "========================================="
Write-Host $SummaryText
Write-Host ""
Write-Host "Arquivos gerados em:"
Write-Host $OutputDirectory
