#!/usr/bin/env bash
# deploy-secrets.sh — Push secrets from .env to DigitalOcean App Platform via doctl
#
# Usage:
#   ./scripts/deploy-secrets.sh              # uses .env
#   ./scripts/deploy-secrets.sh .env.prod    # uses custom env file
#   APP_ID=abc123 ./scripts/deploy-secrets.sh  # skip auto-detection

set -euo pipefail

ENV_FILE="${1:-.env}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_YAML="$PROJECT_DIR/app.yaml"

# ---------- validation ----------

if ! command -v doctl &>/dev/null; then
  echo "Error: doctl is not installed. Install it from https://docs.digitalocean.com/reference/doctl/how-to/install/"
  exit 1
fi

if ! command -v yq &>/dev/null; then
  echo "Error: yq is not installed. Install with: brew install yq"
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: $ENV_FILE not found. Copy .env.example to .env and fill in your values."
  exit 1
fi

# ---------- load .env ----------

load_env() {
  local file="$1"
  while IFS= read -r line; do
    # skip comments and empty lines
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    # export KEY=VALUE
    eval "export ${line?}"
  done < "$file"
}

load_env "$ENV_FILE"

# ---------- find app ----------

APP_NAME=$(yq '.name' "$APP_YAML")

if [[ -z "${APP_ID:-}" ]]; then
  echo "Looking up app '$APP_NAME' ..."
  APP_ID=$(doctl apps list --format ID,Spec.Name --no-header | awk -v name="$APP_NAME" '$2 == name { print $1 }')
  if [[ -z "$APP_ID" ]]; then
    echo "Error: No app named '$APP_NAME' found. Create it first with: doctl apps create --spec $APP_YAML"
    exit 1
  fi
  echo "Found app: $APP_ID"
fi

# ---------- secret keys from app.yaml ----------

# Extract keys that have type: SECRET in app.yaml
SECRET_KEYS=$(yq '.workers[0].envs[] | select(.type == "SECRET") | .key' "$APP_YAML")

# ---------- build updated spec ----------

echo ""
echo "Injecting secrets into app spec..."

# Get current spec
SPEC=$(doctl apps spec get "$APP_ID" --format json)

for key in $SECRET_KEYS; do
  value="${!key:-}"

  if [[ -z "$value" || "$value" == "ChangeMe" ]]; then
    echo "  SKIP  $key (not set or placeholder)"
    continue
  fi

  # Update the env value in the spec using jq
  SPEC=$(echo "$SPEC" | jq \
    --arg key "$key" \
    --arg val "$value" \
    '(.workers[0].envs[] | select(.key == $key)) |= . + {value: $val}')

  echo "  SET   $key"
done

# Also sync non-secret values from .env that exist in app.yaml
NON_SECRET_KEYS=$(yq '.workers[0].envs[] | select(.type != "SECRET" and .type != null) | .key' "$APP_YAML" 2>/dev/null || true)
PLAIN_KEYS=$(yq '.workers[0].envs[] | select(has("type") | not) | .key' "$APP_YAML")
ALL_PLAIN_KEYS="$NON_SECRET_KEYS $PLAIN_KEYS"

for key in $ALL_PLAIN_KEYS; do
  value="${!key:-}"
  [[ -z "$value" ]] && continue

  SPEC=$(echo "$SPEC" | jq \
    --arg key "$key" \
    --arg val "$value" \
    '(.workers[0].envs[] | select(.key == $key)) |= . + {value: $val}')

  echo "  SYNC  $key=$value"
done

# ---------- apply ----------

echo ""
echo "Updating app $APP_NAME ($APP_ID)..."

echo "$SPEC" | doctl apps update "$APP_ID" --spec - --format ID,DefaultIngress --no-header

echo ""
echo "Done! Secrets deployed. The app will redeploy automatically."
echo "Monitor with: doctl apps logs $APP_ID --follow"
