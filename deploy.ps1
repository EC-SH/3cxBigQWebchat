param(
    [string]$Region = "us-central1"
)

Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

$Version = git rev-parse --short HEAD 2>$null
if (-not $Version) {
    $Version = Get-Date -Format "yyyyMMdd-HHmmss"
}
Write-Host "Deploy Version: $Version" -ForegroundColor Gray
Write-Host ""

# ── 1. Interactive Project Selection ───────────────────────────

Write-Host "Fetching available GCP projects..." -ForegroundColor Cyan
$projectsRaw = gcloud projects list --format="json" 2>&1

if (-not $projectsRaw -or $LASTEXITCODE -ne 0) {
    Write-Host "Failed to fetch projects. Are you authenticated? Run 'gcloud auth login'." -ForegroundColor Red
    exit 1
}

$projectsJson = $projectsRaw | ConvertFrom-Json

Write-Host ""
Write-Host "Available GCP Projects:" -ForegroundColor Yellow
Write-Host "─────────────────────────────────────────────────────" -ForegroundColor DarkGray
for ($i = 0; $i -lt $projectsJson.Count; $i++) {
    $name = $projectsJson[$i].name
    $id   = $projectsJson[$i].projectId
    Write-Host "  [$i] " -NoNewline -ForegroundColor DarkCyan
    Write-Host "$name " -NoNewline -ForegroundColor White
    Write-Host "($id)" -ForegroundColor DarkGray
}
Write-Host "─────────────────────────────────────────────────────" -ForegroundColor DarkGray

$selection = Read-Host "`nEnter the number of the project to deploy to"

if ($selection -match '^\d+$' -and [int]$selection -ge 0 -and [int]$selection -lt $projectsJson.Count) {
    $ProjectID = $projectsJson[[int]$selection].projectId
    $ProjectName = $projectsJson[[int]$selection].name
    Write-Host ""
    Write-Host "Locked in: $ProjectName ($ProjectID)" -ForegroundColor Green
} else {
    Write-Host "`nInvalid selection. Aborting." -ForegroundColor Red
    exit 1
}

# ── 2. Prompt for Gemini API Key ──────────────────────────────

$ApiKey = $env:GOOGLE_API_KEY
if (-not $ApiKey) {
    Write-Host ""
    $ApiKey = Read-Host "Enter your Gemini API key (GOOGLE_API_KEY)"
    if (-not $ApiKey) {
        Write-Host "No API key provided. Aborting." -ForegroundColor Red
        exit 1
    }
}
Write-Host "API key: ****$($ApiKey.Substring($ApiKey.Length - 4))" -ForegroundColor DarkGray

# ── 3. IAP Access Prompt ────────────────────────────────────────

Write-Host ""
$currentUserInfo = gcloud config get-value account 2>$null
$defaultDomain = "your-domain.com"
if ($currentUserInfo -like "*@*") {
    $defaultDomain = $currentUserInfo.Split("@")[1]
}

$IapDomain = Read-Host "Enter the primary domain to grant IAP access (Default: $defaultDomain)"
if (-not $IapDomain) {
    $IapDomain = $defaultDomain
}
Write-Host "Granting top-level access to: domain:$IapDomain" -ForegroundColor Green

$IapUsersInput = Read-Host "Enter any additional user emails to grant access to (comma-separated, press Enter for none)"
$IapUsersStr = "[]"
if ($IapUsersInput) {
    $users = $IapUsersInput.Split(',') | ForEach-Object { "$($_.Trim())" } | Where-Object { $_ -ne "" }
    if ($users.Count -gt 0) {
        $IapUsersStr = "[" + ($users | ForEach-Object { "`"$_`"" }) -join ", " + "]"
    }
}
if ($IapUsersStr -ne "[]") {
    Write-Host "Additional users: $IapUsersStr" -ForegroundColor DarkGray
}

# ── 4. Enable APIs ────────────────────────────────────────────

Write-Host ""
Write-Host "Enabling GCP APIs..." -ForegroundColor Cyan
gcloud services enable `
    cloudbuild.googleapis.com `
    artifactregistry.googleapis.com `
    run.googleapis.com `
    iap.googleapis.com `
    secretmanager.googleapis.com `
    --project $ProjectID

Write-Host "Ensuring IAP service identity exists..." -ForegroundColor Cyan
gcloud beta services identity create --service=iap.googleapis.com --project $ProjectID 2>$null

# ── 5. Ensure Artifact Registry ───────────────────────────────

$repoName = "sentinel-repo"
$repoCheck = gcloud artifacts repositories describe $repoName --location=$Region --project=$ProjectID 2>$null

if (-not $repoCheck) {
    Write-Host "Creating Artifact Registry repository..." -ForegroundColor Yellow
    gcloud artifacts repositories create $repoName `
        --repository-format=docker `
        --location=$Region `
        --description="Sentinel frontend and backend images" `
        --project=$ProjectID
} else {
    Write-Host "Artifact Registry repository exists." -ForegroundColor DarkGray
}

$backendImage  = "$Region-docker.pkg.dev/$ProjectID/$repoName/sentinel-backend:$Version"
$frontendImage = "$Region-docker.pkg.dev/$ProjectID/$repoName/sentinel-frontend:$Version"

# ── 6. Build Backend ──────────────────────────────────────────

Write-Host ""
Write-Host "Building backend image via buildpacks..." -ForegroundColor Yellow
Write-Host "  Image: $backendImage" -ForegroundColor DarkGray
gcloud builds submit .\backend --pack image=$backendImage --project $ProjectID

if ($LASTEXITCODE -ne 0) {
    Write-Host "Backend build failed. Aborting." -ForegroundColor Red
    exit 1
}

# ── 7. Build Frontend ─────────────────────────────────────────

Write-Host ""
Write-Host "Building frontend image via buildpacks..." -ForegroundColor Yellow
Write-Host "  Image: $frontendImage" -ForegroundColor DarkGray
gcloud builds submit .\frontend --pack image=$frontendImage --project $ProjectID

if ($LASTEXITCODE -ne 0) {
    Write-Host "Frontend build failed. Aborting." -ForegroundColor Red
    exit 1
}

# ── 8. Terraform Apply ────────────────────────────────────────

Write-Host ""
Write-Host "Applying Terraform infrastructure..." -ForegroundColor Yellow
Push-Location .\terraform

terraform init -input=false

terraform apply `
    -var="project_id=$ProjectID" `
    -var="region=$Region" `
    -var="frontend_image=$frontendImage" `
    -var="backend_image=$backendImage" `
    -var="google_api_key=$ApiKey" `
    -var="iap_domain=$IapDomain" `
    -var="iap_users=$IapUsersStr" `
    -auto-approve

if ($LASTEXITCODE -ne 0) {
    Write-Host "Terraform apply failed." -ForegroundColor Red
    Pop-Location
    exit 1
}

$frontendUrl = terraform output -raw frontend_url
Pop-Location

# ── 9. Summary ────────────────────────────────────────────────

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  Deployment Complete" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  Project:   $ProjectName ($ProjectID)" -ForegroundColor White
Write-Host "  Version:   $Version" -ForegroundColor White
Write-Host "  Frontend:  $frontendUrl" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
Write-Host "The frontend is protected by IAP. Primary domain access granted to '$IapDomain'." -ForegroundColor DarkGray
if ($IapUsersStr -ne "[]") {
    Write-Host "Additional access granted to: $IapUsersStr" -ForegroundColor DarkGray
}
Write-Host ""
