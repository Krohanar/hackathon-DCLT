param(
    [string]$RegionCode = "us-east-1",
    [double]$HoursPerMonth = 730,
    [int]$NodeCount = 4,
    [double]$NodeEbsTotalGb = 80,
    [double]$RdsStorageGb = 20,
    [double]$EcrStorageGb = 0.8575,
    [double]$VariableServicesContingency = 1.00
)

$ErrorActionPreference = "Stop"

$InvariantCulture = [System.Globalization.CultureInfo]::InvariantCulture

function Convert-ToDouble {
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    return [double]::Parse(
        $Value,
        $InvariantCulture
    )
}

function Get-AwsPricingProducts {
    param(
        [Parameter(Mandatory)]
        [string]$ServiceCode,

        [Parameter(Mandatory)]
        [array]$Filters
    )

    $Arguments = @(
        "pricing"
        "get-products"
        "--service-code"
        $ServiceCode
        "--region"
        "us-east-1"
        "--no-paginate"
        "--output"
        "json"
        "--filters"
    )

    foreach ($Filter in $Filters) {
        $Arguments += (
            "Type=TERM_MATCH,Field={0},Value={1}" -f `
                $Filter.Field,
                $Filter.Value
        )
    }

    Write-Host ""
    Write-Host "Consultando preços de $ServiceCode..." -ForegroundColor Cyan

    $RawOutput = & aws @Arguments 2>&1
    $ExitCode = $LASTEXITCODE

    if ($ExitCode -ne 0) {
        throw @"
A consulta de preços falhou.

Comando:
aws $($Arguments -join " ")

Saída:
$($RawOutput -join [Environment]::NewLine)
"@
    }

    $Response = (
        $RawOutput -join [Environment]::NewLine
    ) |
    ConvertFrom-Json

    $Products = @()

    foreach ($PriceListItem in $Response.PriceList) {
        $Products += (
            $PriceListItem |
            ConvertFrom-Json
        )
    }

    return $Products
}

function Get-OnDemandPrice {
    param(
        [Parameter(Mandatory)]
        [string]$ServiceCode,

        [Parameter(Mandatory)]
        [array]$Filters,

        [Parameter(Mandatory)]
        [string]$ExpectedUnit,

        [string]$DescriptionPattern = ".*"
    )

    $Products = Get-AwsPricingProducts `
        -ServiceCode $ServiceCode `
        -Filters $Filters

    $Candidates = @()

    foreach ($Product in $Products) {
        if ($null -eq $Product.terms.OnDemand) {
            continue
        }

        foreach (
            $TermProperty in
            $Product.terms.OnDemand.PSObject.Properties
        ) {
            $Term = $TermProperty.Value

            foreach (
                $DimensionProperty in
                $Term.priceDimensions.PSObject.Properties
            ) {
                $Dimension = $DimensionProperty.Value

                if ($Dimension.unit -ne $ExpectedUnit) {
                    continue
                }

                $PriceText = [string]$Dimension.pricePerUnit.USD

                if ([string]::IsNullOrWhiteSpace($PriceText)) {
                    continue
                }

                $Price = Convert-ToDouble $PriceText

                if ($Price -le 0) {
                    continue
                }

                $Candidates += [PSCustomObject]@{
                    Price       = $Price
                    Unit        = $Dimension.unit
                    Description = [string]$Dimension.description
                    Sku         = [string]$Product.product.sku
                    Family      = [string]$Product.product.productFamily
                    Attributes  = $Product.product.attributes
                }
            }
        }
    }

    $MatchingCandidates = @(
        $Candidates |
        Where-Object {
            $_.Description -match $DescriptionPattern
        } |
        Sort-Object Price
    )

    if ($MatchingCandidates.Count -eq 0) {
        Write-Host ""
        Write-Host "Candidatos encontrados:" -ForegroundColor Yellow

        $Candidates |
        Select-Object Price, Unit, Description, Sku |
        Format-Table -AutoSize

        throw @"
Nenhum preço correspondeu ao padrão:
$DescriptionPattern
"@
    }

    return $MatchingCandidates[0]
}

$Ec2Price = Get-OnDemandPrice `
    -ServiceCode "AmazonEC2" `
    -Filters @(
        @{
            Field = "productFamily"
            Value = "Compute Instance"
        }
        @{
            Field = "regionCode"
            Value = $RegionCode
        }
        @{
            Field = "instanceType"
            Value = "t3.small"
        }
        @{
            Field = "operatingSystem"
            Value = "Linux"
        }
        @{
            Field = "tenancy"
            Value = "Shared"
        }
        @{
            Field = "preInstalledSw"
            Value = "NA"
        }
        @{
            Field = "capacitystatus"
            Value = "Used"
        }
    ) `
    -ExpectedUnit "Hrs" `
    -DescriptionPattern "t3\.small"

$EbsPrice = Get-OnDemandPrice `
    -ServiceCode "AmazonEC2" `
    -Filters @(
        @{
            Field = "productFamily"
            Value = "Storage"
        }
        @{
            Field = "regionCode"
            Value = $RegionCode
        }
        @{
            Field = "volumeApiName"
            Value = "gp3"
        }
    ) `
    -ExpectedUnit "GB-Mo" `
    -DescriptionPattern "General Purpose|gp3"

$RdsInstancePrice = Get-OnDemandPrice `
    -ServiceCode "AmazonRDS" `
    -Filters @(
        @{
            Field = "productFamily"
            Value = "Database Instance"
        }
        @{
            Field = "regionCode"
            Value = $RegionCode
        }
        @{
            Field = "instanceType"
            Value = "db.t3.micro"
        }
        @{
            Field = "databaseEngine"
            Value = "PostgreSQL"
        }
        @{
            Field = "deploymentOption"
            Value = "Single-AZ"
        }
    ) `
    -ExpectedUnit "Hrs" `
    -DescriptionPattern "db\.t3\.micro"

$RdsStoragePrice = Get-OnDemandPrice `
    -ServiceCode "AmazonRDS" `
    -Filters @(
        @{
            Field = "productFamily"
            Value = "Database Storage"
        }
        @{
            Field = "regionCode"
            Value = $RegionCode
        }
        @{
            Field = "databaseEngine"
            Value = "PostgreSQL"
        }
        @{
            Field = "deploymentOption"
            Value = "Single-AZ"
        }
        @{
            Field = "volumeType"
            Value = "General Purpose-GP3"
        }
    ) `
    -ExpectedUnit "GB-Mo" `
    -DescriptionPattern "General Purpose|gp3"

$EksHourlyPrice = 0.10
$Ipv4HourlyPrice = 0.005
$EcrGbMonthPrice = 0.10

$ForecastRows = @(
    [PSCustomObject]@{
        Component = "EKS control plane"
        Configuration = "1 cluster"
        Calculation = "$HoursPerMonth h x USD $EksHourlyPrice"
        MonthlyUsd = $HoursPerMonth * $EksHourlyPrice
    }

    [PSCustomObject]@{
        Component = "EC2 worker nodes"
        Configuration = "$NodeCount x t3.small On-Demand"
        Calculation = "$NodeCount x $HoursPerMonth h x USD $($Ec2Price.Price)"
        MonthlyUsd = (
            $NodeCount *
            $HoursPerMonth *
            $Ec2Price.Price
        )
    }

    [PSCustomObject]@{
        Component = "EBS dos worker nodes"
        Configuration = "$NodeEbsTotalGb GB gp3"
        Calculation = "$NodeEbsTotalGb GB x USD $($EbsPrice.Price)"
        MonthlyUsd = (
            $NodeEbsTotalGb *
            $EbsPrice.Price
        )
    }

    [PSCustomObject]@{
        Component = "IPv4 público"
        Configuration = "$NodeCount endereços"
        Calculation = "$NodeCount x $HoursPerMonth h x USD $Ipv4HourlyPrice"
        MonthlyUsd = (
            $NodeCount *
            $HoursPerMonth *
            $Ipv4HourlyPrice
        )
    }

    [PSCustomObject]@{
        Component = "RDS PostgreSQL"
        Configuration = "1 x db.t3.micro Single-AZ"
        Calculation = "$HoursPerMonth h x USD $($RdsInstancePrice.Price)"
        MonthlyUsd = (
            $HoursPerMonth *
            $RdsInstancePrice.Price
        )
    }

    [PSCustomObject]@{
        Component = "RDS storage"
        Configuration = "$RdsStorageGb GB gp3"
        Calculation = "$RdsStorageGb GB x USD $($RdsStoragePrice.Price)"
        MonthlyUsd = (
            $RdsStorageGb *
            $RdsStoragePrice.Price
        )
    }

    [PSCustomObject]@{
        Component = "ECR privado"
        Configuration = "$EcrStorageGb GB"
        Calculation = "$EcrStorageGb GB x USD $EcrGbMonthPrice"
        MonthlyUsd = (
            $EcrStorageGb *
            $EcrGbMonthPrice
        )
    }

    [PSCustomObject]@{
        Component = "Serviços variáveis"
        Configuration = "S3, SQS, DynamoDB, Secrets e APIs"
        Calculation = "Contingência conservadora"
        MonthlyUsd = $VariableServicesContingency
    }
)

$ForecastRows = $ForecastRows |
ForEach-Object {
    [PSCustomObject]@{
        Component     = $_.Component
        Configuration = $_.Configuration
        Calculation   = $_.Calculation
        MonthlyUsd    = [math]::Round(
            $_.MonthlyUsd,
            2
        )
    }
}

$MonthlyTotal = (
    $ForecastRows |
    Measure-Object `
        -Property MonthlyUsd `
        -Sum
).Sum

$AnnualTotal = $MonthlyTotal * 12

Write-Host ""
Write-Host "============================================="
Write-Host "SOLIDARYTECH - FORECAST MENSAL"
Write-Host "============================================="

$ForecastRows |
Format-Table `
    Component,
    Configuration,
    MonthlyUsd `
    -AutoSize

Write-Host ""
Write-Host (
    "Total mensal: USD {0:N2}" -f $MonthlyTotal
)

Write-Host (
    "Total anual:  USD {0:N2}" -f $AnnualTotal
)

$OutputDirectory = ".\docs\finops"

New-Item `
    -ItemType Directory `
    -Force `
    -Path $OutputDirectory |
Out-Null

$ForecastRows |
Export-Csv `
    -Path (
        Join-Path `
            $OutputDirectory `
            "forecast-monthly.csv"
    ) `
    -NoTypeInformation `
    -Encoding UTF8

$Summary = [PSCustomObject]@{
    GeneratedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    MonthlyUsd  = [math]::Round($MonthlyTotal, 2)
    AnnualUsd   = [math]::Round($AnnualTotal, 2)
    Ec2Hourly   = $Ec2Price.Price
    EbsGbMonth  = $EbsPrice.Price
    RdsHourly   = $RdsInstancePrice.Price
    RdsGbMonth  = $RdsStoragePrice.Price
}

$Summary |
ConvertTo-Json |
Set-Content `
    -Path (
        Join-Path `
            $OutputDirectory `
            "forecast-summary.json"
    ) `
    -Encoding utf8

Write-Host ""
Write-Host "Arquivos criados:"
Write-Host "docs\finops\forecast-monthly.csv"
Write-Host "docs\finops\forecast-summary.json"
