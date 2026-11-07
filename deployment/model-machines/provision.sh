#!/usr/bin/env bash
# Launches the extra machines that only run the photo model (A3, #175). The lab
# refuses anything above .large, so more capacity means more machines. Re-running
# is safe: it reuses the security group and any machine that already exists.
#
#   ./provision.sh        # or MODEL_MACHINES=2 ./provision.sh
#
# Then run deploy.sh. See README.md, including the cost of leaving these running.
set -euo pipefail

: "${AWS_REGION:=us-east-1}"
: "${MODEL_MACHINES:=1}"
# A faster clock than a t3, and no CPU credits for the model to burn through.
: "${INSTANCE_TYPE:=c5.large}"
: "${MAIN_NAME_TAG:=4u-phase1-ec2}"
: "${SECURITY_GROUP_NAME:=4u-model-sg}"
: "${KEY_NAME:=4u-phase1-key}"
# The lab's own profile, which has what SSM needs. It can only be set at launch.
: "${IAM_INSTANCE_PROFILE:=LabInstanceProfile}"
# The AMI's snapshot is 30 GB, and it refuses less.
: "${ROOT_VOLUME_GB:=32}"

aws_ec2() { aws ec2 "$@" --region "$AWS_REGION"; }

read -r MAIN_SG AMI_ID SUBNET_ID <<<"$(aws_ec2 describe-instances \
  --filters "Name=tag:Name,Values=$MAIN_NAME_TAG" \
  "Name=instance-state-name,Values=running,stopped" \
  --query 'Reservations[0].Instances[0].[SecurityGroups[0].GroupId,ImageId,SubnetId]' \
  --output text)"
if [[ -z "${MAIN_SG:-}" || "$MAIN_SG" == "None" ]]; then
  echo "No machine tagged Name=$MAIN_NAME_TAG found." >&2
  exit 1
fi
VPC_ID="$(aws_ec2 describe-subnets --subnet-ids "$SUBNET_ID" \
  --query 'Subnets[0].VpcId' --output text)"

echo "== Security group =="
SG_ID="$(aws_ec2 describe-security-groups \
  --filters "Name=group-name,Values=$SECURITY_GROUP_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text)"
if [[ "$SG_ID" == "None" ]]; then
  SG_ID="$(aws_ec2 create-security-group \
    --group-name "$SECURITY_GROUP_NAME" \
    --description "4u model machines - port 80 from the main machine only" \
    --vpc-id "$VPC_ID" --query 'GroupId' --output text)"
  # /search_similar has no authentication: only positioning, on the main
  # machine, may reach it. There's no public port at all, and SSH goes over SSM.
  aws_ec2 authorize-security-group-ingress --group-id "$SG_ID" \
    --protocol tcp --port 80 --source-group "$MAIN_SG" >/dev/null
  echo "Created $SG_ID."
else
  echo "Reusing $SG_ID."
fi

USER_DATA="$(cat <<'EOS'
#!/bin/bash
dnf install -y docker rsync amazon-ssm-agent
systemctl enable --now docker
systemctl enable --now amazon-ssm-agent
usermod -aG docker ec2-user
mkdir -p /usr/local/lib/docker/cli-plugins
curl -sSL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
BUILDX_TAG=$(curl -sL https://api.github.com/repos/docker/buildx/releases/latest | grep -o '"tag_name": *"[^"]*"' | cut -d'"' -f4)
curl -sSL "https://github.com/docker/buildx/releases/download/${BUILDX_TAG}/buildx-${BUILDX_TAG}.linux-amd64" \
  -o /usr/local/lib/docker/cli-plugins/docker-buildx
chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx
EOS
)"
ROOT_DEVICE="$(aws_ec2 describe-images --image-ids "$AMI_ID" \
  --query 'Images[0].RootDeviceName' --output text)"

echo "== Machines =="
for number in $(seq 1 "$MODEL_MACHINES"); do
  name="4u-model-$number"
  existing="$(aws_ec2 describe-instances \
    --filters "Name=tag:Name,Values=$name" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text)"
  if [[ "$existing" != "None" ]]; then
    echo "$name exists: $existing."
    continue
  fi
  id="$(aws_ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --subnet-id "$SUBNET_ID" \
    --security-group-ids "$SG_ID" \
    --iam-instance-profile "Name=$IAM_INSTANCE_PROFILE" \
    --block-device-mappings "[{\"DeviceName\":\"$ROOT_DEVICE\",\"Ebs\":{\"VolumeSize\":$ROOT_VOLUME_GB,\"VolumeType\":\"gp3\"}}]" \
    --user-data "$USER_DATA" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$name}]" \
    --query 'Instances[0].InstanceId' --output text)"
  echo "$name launched: $id."
done

echo "Docker and SSM install in the background: give them a few minutes, then run deploy.sh."
echo "These cost money while running. Stop them with stop.sh when you're done."
