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
New public IP: $PUBLIC_IP

Note: the public IP changes on every start/stop cycle (no Elastic IP is
used here - it has its own small cost if left unattached, not worth it
for this phase). Re-point anything using the old IP.
EOF
