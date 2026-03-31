#!/usr/bin/env bash
set -euo pipefail

# lol
REGION="${1:-us-central1}"

# version tag... git sha if we have it, timestamp if we dont
VERSION=$(git rev-parse --short HEAD 2>/dev/null || date +"%Y%m%d-%H%M%S")
echo "[deploy] version: ${VERSION}"
echo ""

# ── 1. pick a project ─────────────────────────────────────────
# gcloud gives us json, we parse it with jq like adults

echo "[deploy] fetching gcp projects..."
PROJECTS_JSON=$(gcloud projects list --format="json" 2>/dev/null) || {
  echo "[deploy] cant fetch projects. are you authed? run gcloud auth login" >&2
  exit 1
}

PROJECT_COUNT=$(echo "${PROJECTS_JSON}" | jq length)
if [[ "${PROJECT_COUNT}" -eq 0 ]]; then
  echo "[deploy] no projects found. weird. aborting" >&2
  exit 1
fi

echo ""
echo "available gcp projects:"
echo "─────────────────────────────────────────────────────"
for i in $(seq 0 $((PROJECT_COUNT - 1))); do
  NAME=$(echo "${PROJECTS_JSON}" | jq -r ".[$i].name")
  ID=$(echo "${PROJECTS_JSON}" | jq -r ".[$i].projectId")
  printf "  [%d] %s (%s)\n" "$i" "${NAME}" "${ID}"
done
echo "─────────────────────────────────────────────────────"

read -rp $'\nenter the number of the project to deploy to: ' SELECTION

# validate the selection isnt garbage
if ! [[ "${SELECTION}" =~ ^[0-9]+$ ]] || [[ "${SELECTION}" -ge "${PROJECT_COUNT}" ]]; then
  echo "[deploy] invalid selection. aborting" >&2
  exit 1
fi

PROJECT_ID=$(echo "${PROJECTS_JSON}" | jq -r ".[${SELECTION}].projectId")
PROJECT_NAME=$(echo "${PROJECTS_JSON}" | jq -r ".[${SELECTION}].name")
gcloud config set project "${PROJECT_ID}" --quiet
echo ""
echo "[deploy] locked in: ${PROJECT_NAME} (${PROJECT_ID})"

# ── 2. gemini api key ─────────────────────────────────────────
# check env first because typing keys sucks

if [[ -z "${GOOGLE_API_KEY:-}" ]]; then
  echo ""
  read -rsp "enter your gemini api key (GOOGLE_API_KEY): " GOOGLE_API_KEY
  echo ""
fi

if [[ -z "${GOOGLE_API_KEY}" ]]; then
  echo "[deploy] no api key. cant do this without it" >&2
  exit 1
fi

# show last 4 chars so you know which key you fed it
echo "[deploy] api key: ****${GOOGLE_API_KEY: -4}"

# ── 3. iap access ─────────────────────────────────────────────
# who gets in... domain first then individual emails if you want

echo ""
CURRENT_ACCOUNT=$(gcloud config get-value account 2>/dev/null || echo "")
DEFAULT_DOMAIN="your-domain.com"
if [[ "${CURRENT_ACCOUNT}" == *"@"* ]]; then
  DEFAULT_DOMAIN="${CURRENT_ACCOUNT##*@}"
fi

read -rp "primary domain for iap access [${DEFAULT_DOMAIN}]: " IAP_DOMAIN
IAP_DOMAIN="${IAP_DOMAIN:-${DEFAULT_DOMAIN}}"
echo "[deploy] domain access: ${IAP_DOMAIN}"

read -rp "additional user emails, comma separated (enter for none): " IAP_USERS_INPUT

# turn the comma list into terraform list syntax
# this part is annoying but terraform wants what terraform wants
IAP_USERS_TF="[]"
if [[ -n "${IAP_USERS_INPUT}" ]]; then
  IAP_USERS_TF="["
  IFS=',' read -ra EMAILS <<< "${IAP_USERS_INPUT}"
  FIRST=true
  for email in "${EMAILS[@]}"; do
    trimmed=$(echo "${email}" | xargs)  # trim whitespace
    [[ -z "${trimmed}" ]] && continue
    ${FIRST} || IAP_USERS_TF+=", "
    IAP_USERS_TF+="\"${trimmed}\""
    FIRST=false
  done
  IAP_USERS_TF+="]"
fi

if [[ "${IAP_USERS_TF}" != "[]" ]]; then
  echo "[deploy] additional users: ${IAP_USERS_TF}"
fi

# ── 4. apis ────────────────────────────────────────────────────
# enable everything we need before terraform gets mad about it

echo ""
echo "[deploy] enabling apis..."
REQUIRED_APIS=(
  cloudbuild.googleapis.com
  artifactregistry.googleapis.com
  run.googleapis.com
  iap.googleapis.com
  secretmanager.googleapis.com
)

for api in "${REQUIRED_APIS[@]}"; do
  gcloud services enable "${api}" --project="${PROJECT_ID}" --quiet
done

# iap needs its service identity to exist or the iam bindings explode
gcloud beta services identity create \
  --service=iap.googleapis.com \
  --project="${PROJECT_ID}" 2>/dev/null || true

# ── 5. artifact registry ──────────────────────────────────────
# create it if it doesnt exist, ignore if it does. idempotent king

REPO="sentinel-repo"
REPO_PATH="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}"

if ! gcloud artifacts repositories describe "${REPO}" \
  --location="${REGION}" \
  --project="${PROJECT_ID}" &>/dev/null; then
  echo "[deploy] creating artifact registry repo..."
  gcloud artifacts repositories create "${REPO}" \
    --repository-format=docker \
    --location="${REGION}" \
    --description="sentinel frontend and backend images" \
    --project="${PROJECT_ID}"
else
  echo "[deploy] artifact registry repo exists"
fi

BACKEND_IMAGE="${REPO_PATH}/sentinel-backend:${VERSION}"
FRONTEND_IMAGE="${REPO_PATH}/sentinel-frontend:${VERSION}"

# ── 6. build backend ──────────────────────────────────────────
# buildpacks not dockerfiles. we've been over this

echo ""
echo "[deploy] building backend..."
echo "[deploy]   image: ${BACKEND_IMAGE}"
gcloud builds submit ./backend \
  --pack image="${BACKEND_IMAGE}" \
  --project="${PROJECT_ID}" --quiet

# ── 7. build frontend ─────────────────────────────────────────
# same thing but the other one

echo ""
echo "[deploy] building frontend..."
echo "[deploy]   image: ${FRONTEND_IMAGE}"
gcloud builds submit ./frontend \
  --pack image="${FRONTEND_IMAGE}" \
  --project="${PROJECT_ID}" --quiet

# ── 8. terraform ───────────────────────────────────────────────
# auto-approve because the human already picked the project
# thats the confirmation. we dont ask twice

echo ""
echo "[deploy] applying terraform..."
pushd terraform >/dev/null

terraform init -upgrade -input=false

terraform apply -auto-approve \
  -var="project_id=${PROJECT_ID}" \
  -var="region=${REGION}" \
  -var="frontend_image=${FRONTEND_IMAGE}" \
  -var="backend_image=${BACKEND_IMAGE}" \
  -var="google_api_key=${GOOGLE_API_KEY}" \
  -var="iap_domain=${IAP_DOMAIN}" \
  -var="iap_users=${IAP_USERS_TF}"

FRONTEND_URL=$(terraform output -raw frontend_url 2>/dev/null || echo "unknown")
popd >/dev/null

# ── 9. done ────────────────────────────────────────────────────
# thats it. go click the link

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  deploy complete"
echo "═══════════════════════════════════════════════════════"
echo "  project:   ${PROJECT_NAME} (${PROJECT_ID})"
echo "  version:   ${VERSION}"
echo "  frontend:  ${FRONTEND_URL}"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "frontend is behind iap. domain access: ${IAP_DOMAIN}"
if [[ "${IAP_USERS_TF}" != "[]" ]]; then
  echo "additional access: ${IAP_USERS_TF}"
fi
echo ""
