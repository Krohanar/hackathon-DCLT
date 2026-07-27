$ErrorActionPreference = "Stop"

function Assert-LastCommandSucceeded {
    param([string]$Step)

    if ($LASTEXITCODE -ne 0) {
        throw "Falha na etapa: $Step. ExitCode: $LASTEXITCODE"
    }
}

$Region = "us-east-1"
$AccountId = aws sts get-caller-identity --query Account --output text
Assert-LastCommandSucceeded "Obter AccountId"

$Registry = "$AccountId.dkr.ecr.$Region.amazonaws.com"
$GitSha = git rev-parse --short HEAD
Assert-LastCommandSucceeded "Obter Git SHA"

Write-Host "Conta AWS: $AccountId"
Write-Host "Região: $Region"
Write-Host "Registry: $Registry"
Write-Host "Tag da versão: $GitSha"

Write-Host "Limpando login antigo do Docker..."
docker logout $Registry | Out-Null
docker logout "https://$Registry" | Out-Null

Write-Host "Fazendo login no ECR..."
cmd /c "aws ecr get-login-password --region $Region | docker login --username AWS --password-stdin $Registry"
Assert-LastCommandSucceeded "Login no ECR"

$Services = @(
    @{
        Name = "ngo-service"
        Context = "ngo-service"
        Repository = "solidarytech/ngo-service"
    },
    @{
        Name = "donation-service"
        Context = "donation-service"
        Repository = "solidarytech/donation-service"
    },
    @{
        Name = "volunteer-service"
        Context = "volunteer-service"
        Repository = "solidarytech/volunteer-service"
    }
)

foreach ($Service in $Services) {
    $Name = $Service.Name
    $Context = $Service.Context
    $Repository = $Service.Repository

    $LocalImage = "solidarytech-$Name`:$GitSha"
    $RemoteImageSha = "$Registry/$Repository`:$GitSha"
    $RemoteImageLatest = "$Registry/$Repository`:latest"

    Write-Host ""
    Write-Host "========================================"
    Write-Host "Buildando $Name"
    Write-Host "Contexto: $Context"
    Write-Host "Imagem local: $LocalImage"
    Write-Host "Imagem remota SHA: $RemoteImageSha"
    Write-Host "Imagem remota latest: $RemoteImageLatest"
    Write-Host "========================================"

    docker build -t $LocalImage ./$Context
    Assert-LastCommandSucceeded "Docker build $Name"

    docker tag $LocalImage $RemoteImageSha
    Assert-LastCommandSucceeded "Docker tag SHA $Name"

    docker tag $LocalImage $RemoteImageLatest
    Assert-LastCommandSucceeded "Docker tag latest $Name"

    docker push $RemoteImageSha
    Assert-LastCommandSucceeded "Docker push SHA $Name"

    docker push $RemoteImageLatest
    Assert-LastCommandSucceeded "Docker push latest $Name"
}

Write-Host ""
Write-Host "Push concluído de verdade. Imagens enviadas para o ECR:"
foreach ($Service in $Services) {
    $Repository = $Service.Repository
    Write-Host "- $Registry/$Repository`:$GitSha"
    Write-Host "- $Registry/$Repository`:latest"
}
