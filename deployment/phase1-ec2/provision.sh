#!/usr/bin/env bash
# Creates everything needed for the Phase 1 EC2 deployment (issue #90):
# a security group (SSH from your IP only + the gateway's port from
# anywhere), an SSH key pair (if you don't already have one), and the
# instance itself with Docker + the Compose plugin pre-installed via
# user-data. Re-running this script is safe - it reuses the security
# group and key pair if they already exist, but will create a second
# instance if one is already running (use start.sh to resume a stopped
# one instead of provisioning a new one).
set -euo pipefail

: "${AWS_REGION:=us-east-1}"
# Real local measurement (see README.md "Instance sizing") showed ~0.8GB
# of real container memory under light use, before OS/Docker overhead,
# and the *build* step (installing torch/torchvision/opencv for
# backend-ai-training) needs meaningfully more than that transiently.
# t3.medium (4GB) avoids OOM during `docker compose up --build`; see the
# README for how to size down to t3.small afterward if you want to
# stretch the $50 credit further.
: "${INSTANCE_TYPE:=t3.medium}"
: "${KEY_NAME:=4u-phase1-key}"
: "${KEY_OUTPUT_DIR:=$HOME/.ssh}"
: "${SSH_CIDR:=}"
: "${SECURITY_GROUP_NAME:=4u-phase1-sg}"
: "${INSTANCE_NAME_TAG:=4u-phase1-ec2}"
: "${GATEWAY_PORT:=8000}"
# The AL2023 AMI's default root volume is only 2GB - nowhere near enough
# to build 6 Docker images (Python base layers + torch/torchvision for
# backend-ai-training). Confirmed by hitting "No space left on device"
# mid-build against the real 2GB default. 20GB comfortably covers the
# full stack's images + build cache with room to rebuild after code
# changes, and is still within the AWS free tier's 30GB/month EBS
# allowance.
: "${ROOT_VOLUME_GB:=20}"

echo "== Verifying AWS credentials =="
aws sts get-caller-identity --region "$AWS_REGION" >/dev/null

if [[ -z "$SSH_CIDR" ]]; then
  MY_IP="$(curl -s https://checkip.amazonaws.com)"
  SSH_CIDR="${MY_IP}/32"
  echo "Auto-detected your public IP for SSH access: $SSH_CIDR"
fi

VPC_ID="$(aws ec2 describe-vpcs --filters Name=is-default,Values=true \
  --query 'Vpcs[0].VpcId' --output text --region "$AWS_REGION")"

echo "== Security group =="
SG_ID="$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$SECURITY_GROUP_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION" 2>/dev/null || true)"

if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
  SG_ID="$(aws ec2 create-security-group \
    --group-name "$SECURITY_GROUP_NAME" \
    --description "4u Phase 1 EC2 - SSH from operator IP + gateway port only" \
    --vpc-id "$VPC_ID" --query 'GroupId' --output text --region "$AWS_REGION")"
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
    --protocol tcp --port 22 --cidr "$SSH_CIDR" --region "$AWS_REGION" >/dev/null
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
    --protocol tcp --port "$GATEWAY_PORT" --cidr 0.0.0.0/0 --region "$AWS_REGION" >/dev/null
  echo "Created security group $SG_ID (SSH from $SSH_CIDR, gateway port $GATEWAY_PORT from anywhere)."
else
  echo "Reusing existing security group $SG_ID."
fi

echo "== SSH key pair =="
KEY_FILE="$KEY_OUTPUT_DIR/${KEY_NAME}.pem"
if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  mkdir -p "$KEY_OUTPUT_DIR"
  aws ec2 create-key-pair --key-name "$KEY_NAME" \
    --query 'KeyMaterial' --output text --region "$AWS_REGION" > "$KEY_FILE"
  chmod 400 "$KEY_FILE"
  echo "Created new key pair, saved to $KEY_FILE (outside the repo - keep it safe, AWS won't let you download it again)."
else
  echo "Reusing existing key pair '$KEY_NAME' (expecting $KEY_FILE to still be on this machine)."
fi

echo "== Latest Amazon Linux 2023 AMI =="
AMI_ID="$(aws ec2 describe-images --owners amazon \
  --filters "Name=name,Values=al2023-ami-*-x86_64" "Name=state,Values=available" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text --region "$AWS_REGION")"
ROOT_DEVICE_NAME="$(aws ec2 describe-images --image-ids "$AMI_ID" \
  --query 'Images[0].RootDeviceName' --output text --region "$AWS_REGION")"
echo "Using AMI $AMI_ID (root device $ROOT_DEVICE_NAME, resizing to ${ROOT_VOLUME_GB}GB)"

# Deliberately installs Docker + build tooling only - no secrets, no repo
# clone. Real .env files get copied over SSH afterward (see README.md);
# EC2 user-data is visible via the instance metadata service and stored
# in plain text in your AWS account history, so real secrets must never
# go through it.
#
# buildx and rsync aren't in AL2023's base `docker` package/image -
# confirmed live ("compose build requires buildx 0.17.0 or later" and
# "rsync: command not found" the first time this was actually run).
USER_DATA="$(cat <<'EOS'
#!/bin/bash
dnf install -y docker rsync
systemctl enable --now docker
usermod -aG docker ec2-user
mkdir -p /usr/local/lib/docker/cli-plugins
curl -sSL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
ARCH=$(uname -m)
case $ARCH in x86_64) BARCH=amd64 ;; aarch64) BARCH=arm64 ;; esac
# buildx has no version-less "latest" download alias (unlike compose) -
# its asset names embed the version, so the tag is resolved first.
BUILDX_TAG=$(curl -sL https://api.github.com/repos/docker/buildx/releases/latest | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4)
curl -sSL "https://github.com/docker/buildx/releases/download/${BUILDX_TAG}/buildx-${BUILDX_TAG}.linux-${BARCH}" \
  -o /usr/local/lib/docker/cli-plugins/docker-buildx
chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx
EOS
)"

echo "== Launching instance ($INSTANCE_TYPE) =="
INSTANCE_ID="$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --security-group-ids "$SG_ID" \
  --block-device-mappings "[{\"DeviceName\":\"$ROOT_DEVICE_NAME\",\"Ebs\":{\"VolumeSize\":$ROOT_VOLUME_GB,\"VolumeType\":\"gp3\"}}]" \
  --user-data "$USER_DATA" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME_TAG}]" \
  --query 'Instances[0].InstanceId' --output text --region "$AWS_REGION")"

echo "Instance $INSTANCE_ID launching, waiting for it to reach 'running'..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"

PUBLIC_IP="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text --region "$AWS_REGION")"

cat <<EOF

== Done ==
Instance ID: $INSTANCE_ID
Public IP:   $PUBLIC_IP
SSH:         ssh -i $KEY_FILE ec2-user@$PUBLIC_IP

Docker is installing via user-data in the background - give it a minute or
two before SSHing in. Next steps (copying the repo + .env files, starting
the stack) are in README.md.
EOF
