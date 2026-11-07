#!/usr/bin/env bash
# Puts the current photo model on every running model machine (provision.sh).
# Qdrant's key comes from the main machine, over SSH, so it's never in the repo or
# on a command line. Prints what backend-positioning's AI_TRAINING_URLS should be.
set -euo pipefail

: "${AWS_REGION:=us-east-1}"
: "${MAIN_NAME_TAG:=4u-phase1-ec2}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RSYNC_EXCLUDES=(--exclude .venv --exclude .env --exclude __pycache__
  --exclude .pytest_cache --exclude .ruff_cache)

instance_ids() {
  aws ec2 describe-instances --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=$1" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' --output text
}

MAIN_ID="$(instance_ids "$MAIN_NAME_TAG")"
MODEL_IDS="$(instance_ids '4u-model-*')"
if [[ -z "$MODEL_IDS" ]]; then
  echo "No running model machines." >&2
  exit 1
fi

for id in $MODEL_IDS; do
  host="ec2-user@$id"
  echo "== $id =="
  ssh -n "$host" 'mkdir -p ~/4u/deployment/model-machines'
  rsync -az "${RSYNC_EXCLUDES[@]}" "$REPO/packages" "$REPO/backend-ai-training" "$host:4u/"
  rsync -az "$REPO/deployment/model-machines/compose.yml" "$host:4u/deployment/model-machines/"
  # shellcheck disable=SC2029
  ssh -n "ec2-user@$MAIN_ID" "grep -E '^QDRANT_(URL|KEY)=' 4u/backend-ai-training/.env" |
    ssh "$host" 'umask 077; cat > ~/4u/deployment/model-machines/.env'
  ssh -n "$host" 'cd ~/4u/deployment/model-machines &&
    sudo docker compose up -d --build &&
    sudo docker image prune -f >/dev/null'
done

echo
echo "AI_TRAINING_URLS=$(aws ec2 describe-instances --region "$AWS_REGION" \
  --instance-ids $MODEL_IDS \
  --query 'Reservations[].Instances[].PrivateIpAddress' --output text |
  tr '\t' '\n' | sed 's|^|http://|' | paste -sd, -)"
