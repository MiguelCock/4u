#!/usr/bin/env bash
# Stops (does not delete) the Phase 1 EC2 instance between test sessions.
# Compute billing pauses while stopped; a small EBS storage charge
# continues. Everything on disk (Docker images, containers, the copied
# repo + .env files) survives - start.sh resumes it as-is, no setup redo.
set -euo pipefail

: "${AWS_REGION:=us-east-1}"
: "${INSTANCE_NAME_TAG:=4u-phase1-ec2}"

INSTANCE_ID="$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$INSTANCE_NAME_TAG" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text --region "$AWS_REGION")"

if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
  echo "No running instance tagged Name=$INSTANCE_NAME_TAG found." >&2
  exit 1
fi

aws ec2 stop-instances --instance-ids "$INSTANCE_ID" --region "$AWS_REGION" >/dev/null
echo "Stopping $INSTANCE_ID - compute billing pauses once it's fully stopped."
echo "Run start.sh to resume it later."
