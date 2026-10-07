#!/usr/bin/env bash
# Resumes a stopped Phase 1 EC2 instance (see stop.sh). Does not create
# anything new - if no stopped instance is found, run provision.sh instead.
set -euo pipefail

: "${AWS_REGION:=us-east-1}"
: "${INSTANCE_NAME_TAG:=4u-phase1-ec2}"

INSTANCE_ID="$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$INSTANCE_NAME_TAG" "Name=instance-state-name,Values=stopped" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text --region "$AWS_REGION")"

if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
  echo "No stopped instance tagged Name=$INSTANCE_NAME_TAG found." >&2
  echo "(If none exists at all yet, run provision.sh instead.)" >&2
  exit 1
fi

aws ec2 start-instances --instance-ids "$INSTANCE_ID" --region "$AWS_REGION" >/dev/null
echo "Starting $INSTANCE_ID, waiting for it to reach 'running'..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"

PUBLIC_IP="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text --region "$AWS_REGION")"

cat <<EOF
Instance started: $INSTANCE_ID
Public IP: $PUBLIC_IP

If provision.sh allocated an Elastic IP for this instance, this is the
same permanent address every time (application/.env doesn't need
touching again). If ALLOCATE_EIP was set to false, this is a fresh
dynamic IP instead - update application/.env's API_GATEWAY_URL by hand.

Every service has restart: unless-stopped, so the containers should come
back on their own once Docker finishes starting on this instance - give
it a minute. If something didn't come back for any reason, the fallback
is still `ssh ... "cd ~/4u && sudo docker compose up -d"` (no rebuild
needed) - see README.md.
EOF
