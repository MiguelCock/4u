#!/usr/bin/env bash
# Stops every model machine and waits until they have stopped, because they cost
# money while running. Positioning falls back to the main machine's model. Their
# disks and private addresses stay, so start.sh brings them back as they were.
set -euo pipefail

: "${AWS_REGION:=us-east-1}"

IDS="$(aws ec2 describe-instances --region "$AWS_REGION" \
  --filters 'Name=tag:Name,Values=4u-model-*' 'Name=instance-state-name,Values=pending,running' \
  --query 'Reservations[].Instances[].InstanceId' --output text)"
if [[ -z "$IDS" ]]; then
  echo "No model machines are running."
  exit 0
fi

# shellcheck disable=SC2086
aws ec2 stop-instances --region "$AWS_REGION" --instance-ids $IDS >/dev/null
# shellcheck disable=SC2086
aws ec2 wait instance-stopped --region "$AWS_REGION" --instance-ids $IDS
echo "Stopped: $IDS"
