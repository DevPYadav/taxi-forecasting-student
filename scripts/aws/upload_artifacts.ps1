<#
.SYNOPSIS
  Upload the baked build artifacts CodeBuild needs into the CI/CD S3 bucket.

.DESCRIPTION
  The self-contained API image bakes in mlruns/, mlflow.db and the demand-history
  parquet, which are gitignored and therefore absent from CodeBuild's checkout.
  This uploads them to the CI/CD artifacts bucket (Terraform output
  `cicd_artifacts_bucket`) so the CodeBuild `build` phase can pull them.

  Re-run this whenever you retrain the models locally.

.EXAMPLE
  .\scripts\aws\upload_artifacts.ps1 -Region us-east-1
  .\scripts\aws\upload_artifacts.ps1 -Bucket "<your-artifact-bucket>"
#>

[CmdletBinding()]
param(
    [string]$Region = "us-east-1",
    # CI/CD artifacts bucket. If omitted, read from the Terraform output.
    [string]$Bucket
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$TfDir = Join-Path $RepoRoot "infra/terraform"

function Assert-Tool($name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "Required tool '$name' not found on PATH."
    }
}

Assert-Tool aws
Set-Location $RepoRoot

if (-not $Bucket) {
    Assert-Tool terraform
    Write-Host "==> Reading CI/CD artifacts bucket from Terraform output" -ForegroundColor Cyan
    $Bucket = (terraform -chdir="$TfDir" output -raw cicd_artifacts_bucket).Trim()
}
if (-not $Bucket) { throw "Could not determine the CI/CD artifacts bucket." }

foreach ($p in @("mlruns", "mlflow.db", "data/processed/demand_hourly.parquet")) {
    if (-not (Test-Path $p)) {
        throw "Missing '$p'. Train the models first (python scripts/train_models.py)."
    }
}

Write-Host "==> Uploading artifacts to s3://$Bucket" -ForegroundColor Cyan
aws s3 sync mlruns "s3://$Bucket/mlruns" --region $Region --only-show-errors
aws s3 cp mlflow.db "s3://$Bucket/mlflow.db" --region $Region --only-show-errors
aws s3 cp data/processed/demand_hourly.parquet "s3://$Bucket/demand_hourly.parquet" --region $Region --only-show-errors

Write-Host "OK: artifacts uploaded to s3://$Bucket" -ForegroundColor Green
