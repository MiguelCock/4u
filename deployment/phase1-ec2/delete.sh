#!/usr/bin/env bash
# Permanently terminates the Phase 1 EC2 instance, releases its Elastic
# IP, and deletes the security group provision.sh created. Destructive -
# everything on the instance's disk is gone; standing back up means
# provision.sh plus redoing the manual setup (copying the repo + .env
# files) in README.md, and application/.env will get a *new* Elastic IP
# (releasing one doesn't reserve it for next time). The EC2 key pair (in
# AWS and the local .pem file) is left alone, since provision.sh will
# reuse it next time.
set -euo pipefail

: "${AWS_REGION:=us-east-1}"
: "${INSTANCE_NAME_TAG:=4u-phase1-ec2}"
: "${SECURITY_GROUP_NAME:=4u-phase1-sg}"
: "${EIP_NAME_TAG:=4u-phase1-ec2}"

echo "This will PERMANENTLY terminate the instance tagged Name=$INSTANCE_NAME_TAG,"
echo "release its Elastic IP, and delete the '$SECURITY_GROUP_NAME' security group."
read -r -p "Type 'delete' to confirm: " CONFIRM
if [[ "$CONFIRM" != "delete" ]]; then
  echo "Aborted - nothing changed."
  exit 1
fi

INSTANCE_ID="$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$INSTANCE_NAME_TAG" "Name=instance-state-name,Values=running,stopped,stopping" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text --region "$AWS_REGION")"

if [[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "None" ]]; then
  aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$AWS_REGION" >/dev/null
  echo "Terminating $INSTANCE_ID, waiting..."
  aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"
else
  echo "No instance tagged Name=$INSTANCE_NAME_TAG found to terminate."
fi

EIP_ALLOC_ID="$(aws ec2 describe-addresses \
  --filters "Name=tag:Name,Values=$EIP_NAME_TAG" \
  --query 'Addresses[0].AllocationId' --output text --region "$AWS_REGION" 2>/dev/null || true)"

if [[ -n "$EIP_ALLOC_ID" && "$EIP_ALLOC_ID" != "None" ]]; then
  aws ec2 release-address --allocation-id "$EIP_ALLOC_ID" --region "$AWS_REGION"
  echo "Released Elastic IP (allocation $EIP_ALLOC_ID) - it has its own small cost while allocated and unattached, so this isn't reused, only the security group/key pair are."
else
  echo "No Elastic IP tagged Name=$EIP_NAME_TAG found to release."
fi

SG_ID="$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$SECURITY_GROUP_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION" 2>/dev/null || true)"

if [[ -n "$SG_ID" && "$SG_ID" != "None" ]]; then
  if aws ec2 delete-security-group --group-id "$SG_ID" --region "$AWS_REGION" 2>/dev/null; then
    echo "Deleted security group $SG_ID."
  else
    echo "Could not delete security group $SG_ID (it may still be referenced elsewhere) - remove it manually if needed." >&2
  fi
fi

echo "Done. Re-run provision.sh to stand a fresh instance back up."
