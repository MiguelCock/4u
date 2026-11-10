#!/usr/bin/env bash
# Starts every stopped model machine and waits for each model to answer. They cost
# money while running, so start them for an event or a test, then run stop.sh.
set -euo pipefail

: "${AWS_REGION:=us-east-1}"

IDS="$(aws ec2 describe-instances --region "$AWS_REGION" \
  --filters 'Name=tag:Name,Values=4u-model-*' 'Name=instance-state-name,Values=stopped' \
  --query 'Reservations[].Instances[].InstanceId' --output text)"
if [[ -z "$IDS" ]]; then
  echo "No stopped model machines."
  exit 0
fi

# shellcheck disable=SC2086
aws ec2 start-instances --region "$AWS_REGION" --instance-ids $IDS >/dev/null
# shellcheck disable=SC2086
aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids $IDS

for id in $IDS; do
  for _ in $(seq 1 40); do
    if ssh -n -o ConnectTimeout=15 "ec2-user@$id" 'curl -sf -m 5 http://localhost/ >/dev/null' 2>/dev/null; then
      echo "$id is answering."
      continue 2
    fi
    sleep 15
  done
  echo "$id didn't answer. Positioning falls back to the main machine's model." >&2
done
echo "These cost money while running. Run stop.sh when you're done."
