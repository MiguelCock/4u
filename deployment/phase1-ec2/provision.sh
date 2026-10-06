#!/usr/bin/env bash
# Creates everything needed for the Phase 1 EC2 deployment (issue #90):
# a security group (HTTPS on 80/443 from anywhere - see #92; no inbound
# SSH port at all - see #116), an SSH key pair (if you don't already
# have one), a static Elastic IP, and the instance itself with Docker +
# the Compose plugin + the SSM agent pre-installed via user-data. Also
# auto-writes application/.env's API_GATEWAY_URL and
# deployment/phase1-ec2/.env's DOMAIN to a free sslip.io hostname
# derived from the Elastic IP, so the app and the Caddy TLS sidecar are
# both pre-configured with no manual copy-paste step. Re-running this
# script is safe and reuses everything that already exists - the
# security group, key pair, Elastic IP, *and* the instance itself (if
# one is already running, it re-applies the security-group/HTTPS
# migration to it instead of launching a second one; if one exists but
# is stopped, it tells you to run start.sh first rather than launching
# a duplicate).
#
# SSH access is over AWS Systems Manager Session Manager, not a direct
# TCP connection to port 22 - see README.md for the one-time local
# setup (session-manager-plugin + an SSH config block). This needs the
# instance to carry an IAM instance profile with AmazonSSMManagedInstanceCore
# attached, which can only be set at *launch* time on this AWS Academy
# Learner Lab account (confirmed live: ec2:AssociateIamInstanceProfile -
# attaching one to an already-running instance - is explicitly denied
# for the student role, while specifying one on run-instances isn't) -
# see IAM_INSTANCE_PROFILE below.
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
: "${SECURITY_GROUP_NAME:=4u-phase1-sg}"
: "${INSTANCE_NAME_TAG:=4u-phase1-ec2}"
# AWS Academy Learner Lab's pre-provisioned role+instance-profile - already
# has AmazonSSMManagedInstanceCore attached (confirmed live), so SSM Session
# Manager works with no new IAM creation (which is restricted on this
# account type anyway). A non-Academy account needs its own role+profile
# with that managed policy attached instead - override this to match.
: "${IAM_INSTANCE_PROFILE:=LabInstanceProfile}"
# No longer opened to the public internet (see #92 - HTTPS via Caddy on
# 80/443 is the only public entry point now). Still used for the gateway
# container's own port mapping - local dev, CI, and SSH-tunnel debugging.
: "${GATEWAY_PORT:=8000}"
# The AL2023 AMI's own root snapshot has grown over time - confirmed live
# that a current AMI rejects anything below 30GB outright
# ("InvalidBlockDeviceMapping: ... expect size >= 30GB"), not just the
# original 2GB-default concern this used to be sized against (building 6
# Docker images, including torch/torchvision for backend-ai-training, needs
# real headroom beyond that snapshot minimum too). 32GB covers both with a
# little margin; re-check this if a future AMI update raises the minimum
# again.
: "${ROOT_VOLUME_GB:=32}"
# EC2 public IPs change on every stop/start cycle - without a static
# Elastic IP, application/.env's API_GATEWAY_URL would need hand-editing
# after every restart (confirmed live: it does change). An Elastic IP
# has a small extra AWS cost while the instance is stopped, but makes
# the app's config a one-time "set and forget." Set to "false" to skip
# it and go back to the old dynamic-IP behavior.
: "${ALLOCATE_EIP:=true}"
: "${EIP_NAME_TAG:=4u-phase1-ec2}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ENV_FILE="$SCRIPT_DIR/../../application/.env"
APP_ENV_EXAMPLE="$SCRIPT_DIR/../../application/.env.example"

echo "== Verifying AWS credentials =="
aws sts get-caller-identity --region "$AWS_REGION" >/dev/null

VPC_ID="$(aws ec2 describe-vpcs --filters Name=is-default,Values=true \
  --query 'Vpcs[0].VpcId' --output text --region "$AWS_REGION")"

echo "== Security group =="
SG_ID="$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$SECURITY_GROUP_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION" 2>/dev/null || true)"

if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
  SG_ID="$(aws ec2 create-security-group \
    --group-name "$SECURITY_GROUP_NAME" \
    --description "4u Phase 1 EC2 - HTTPS gateway only, no inbound SSH (see #116)" \
    --vpc-id "$VPC_ID" --query 'GroupId' --output text --region "$AWS_REGION")"
  echo "Created security group $SG_ID."
else
  echo "Reusing existing security group $SG_ID."
fi

# Idempotent by existence check, not just bare authorize/revoke calls - both
# error under `set -euo pipefail` if the rule is already there/already gone,
# which matters on every re-run (not just first creation), since an
# already-provisioned instance's security group needs this same migration
# applied to it (#92: HTTPS via Caddy on 80/443 replaces the old plain-HTTP
# exposure on $GATEWAY_PORT).
_has_ingress_rule() {
  local port="$1"
  local count
  count="$(aws ec2 describe-security-groups --group-ids "$SG_ID" --region "$AWS_REGION" \
    --query "length(SecurityGroups[0].IpPermissions[?ToPort==\`$port\` && contains(IpRanges[].CidrIp, '0.0.0.0/0')])" \
    --output text)"
  [[ "$count" != "0" ]]
}

# Every CIDR currently allowed in on port 22, whatever it is - unlike
# _has_ingress_rule above this isn't scoped to one specific CIDR, since the
# whole problem (#116) is a pile of stale operator-IP/32 rules accumulated
# from past manual fixes, not a single well-known one.
_port22_cidrs() {
  aws ec2 describe-security-groups --group-ids "$SG_ID" --region "$AWS_REGION" \
    --query 'SecurityGroups[0].IpPermissions[?ToPort==`22`].IpRanges[].CidrIp' --output text
}

for port in 80 443; do
  if _has_ingress_rule "$port"; then
    echo "Ingress for port $port already present."
  else
    aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
      --protocol tcp --port "$port" --cidr 0.0.0.0/0 --region "$AWS_REGION" >/dev/null
    echo "Opened port $port (0.0.0.0/0) for HTTPS."
  fi
done

if _has_ingress_rule "$GATEWAY_PORT"; then
  aws ec2 revoke-security-group-ingress --group-id "$SG_ID" \
    --protocol tcp --port "$GATEWAY_PORT" --cidr 0.0.0.0/0 --region "$AWS_REGION" >/dev/null
  echo "Closed old port $GATEWAY_PORT public exposure (now served over HTTPS instead)."
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

echo "== Checking for an existing instance =="
INSTANCE_ID="$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$INSTANCE_NAME_TAG" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text --region "$AWS_REGION" 2>/dev/null || true)"

if [[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "None" ]]; then
  # Without this check, re-running provision.sh would launch a *second*
  # instance (it has no other existing-instance guard) and, below, steal the
  # Elastic IP away from the one currently serving real traffic - fine for a
  # from-scratch run, not fine for migrating an already-live deployment onto
  # HTTPS (#92).
  LAUNCHED_NEW=false
  STATE="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' --output text --region "$AWS_REGION")"
  if [[ "$STATE" != "running" ]]; then
    echo "Instance $INSTANCE_ID (tagged Name=$INSTANCE_NAME_TAG) exists but is '$STATE', not running." >&2
    echo "Run start.sh first, then re-run this script - provision.sh won't launch a second instance." >&2
    exit 1
  fi
  echo "Found existing running instance $INSTANCE_ID - applying the security-group/HTTPS setup to it instead of launching a new one."

  # ec2:AssociateIamInstanceProfile is explicitly denied for the student
  # role on this AWS Academy Learner Lab account (confirmed live) - an
  # instance profile can only be set at launch, not retrofitted onto an
  # already-running instance. Warn rather than fail: the rest of this
  # script (SG/EIP/env wiring) still works fine without SSM access.
  EXISTING_PROFILE="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text --region "$AWS_REGION" 2>/dev/null || true)"
  if [[ -z "$EXISTING_PROFILE" || "$EXISTING_PROFILE" == "None" || "$EXISTING_PROFILE" != *"/$IAM_INSTANCE_PROFILE" ]]; then
    echo "WARNING: this instance doesn't have the '$IAM_INSTANCE_PROFILE' IAM instance profile attached, so SSM-based SSH access (#116) won't work for it." >&2
    echo "An instance profile can only be set at launch - terminate this instance and re-run provision.sh to pick it up on a fresh one." >&2
  fi
else
  LAUNCHED_NEW=true
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
dnf install -y docker rsync amazon-ssm-agent
systemctl enable --now docker
systemctl enable --now amazon-ssm-agent
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
  --iam-instance-profile "Name=$IAM_INSTANCE_PROFILE" \
  --block-device-mappings "[{\"DeviceName\":\"$ROOT_DEVICE_NAME\",\"Ebs\":{\"VolumeSize\":$ROOT_VOLUME_GB,\"VolumeType\":\"gp3\"}}]" \
  --user-data "$USER_DATA" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME_TAG}]" \
  --query 'Instances[0].InstanceId' --output text --region "$AWS_REGION")"

echo "Instance $INSTANCE_ID launching, waiting for it to reach 'running'..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"
fi

echo "== SSH access (via SSM Session Manager, not direct port 22 - see #116) =="
SSM_REGISTERED="$(aws ssm describe-instance-information --region "$AWS_REGION" \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'length(InstanceInformationList)' --output text 2>/dev/null || echo 0)"
if [[ "$SSM_REGISTERED" != "0" ]]; then
  STALE_PORT22_CIDRS="$(_port22_cidrs)"
  if [[ -n "$STALE_PORT22_CIDRS" ]]; then
    for cidr in $STALE_PORT22_CIDRS; do
      aws ec2 revoke-security-group-ingress --group-id "$SG_ID" \
        --protocol tcp --port 22 --cidr "$cidr" --region "$AWS_REGION" >/dev/null
      echo "Revoked stale SSH-from-$cidr rule (SSM confirmed registered for $INSTANCE_ID)."
    done
  else
    echo "No stale port 22 rules to clean up."
  fi
else
  echo "SSM isn't registered for $INSTANCE_ID yet (the agent installs via user-data - this can take a minute or two on a fresh instance)."
  echo "Any existing port 22 rules are left alone for now - re-run this script once 'aws ssm describe-instance-information' shows this instance, to clean them up."
fi

PUBLIC_IP="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text --region "$AWS_REGION")"

if [[ "$ALLOCATE_EIP" == "true" ]]; then
  echo "== Elastic IP =="
  EIP_ALLOC_ID="$(aws ec2 describe-addresses \
    --filters "Name=tag:Name,Values=$EIP_NAME_TAG" \
    --query 'Addresses[0].AllocationId' --output text --region "$AWS_REGION" 2>/dev/null || true)"
  if [[ -z "$EIP_ALLOC_ID" || "$EIP_ALLOC_ID" == "None" ]]; then
    EIP_ALLOC_ID="$(aws ec2 allocate-address --domain vpc \
      --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=$EIP_NAME_TAG}]" \
      --query 'AllocationId' --output text --region "$AWS_REGION")"
    echo "Allocated new Elastic IP (allocation $EIP_ALLOC_ID)."
  else
    echo "Reusing existing Elastic IP (allocation $EIP_ALLOC_ID)."
  fi
  aws ec2 associate-address --instance-id "$INSTANCE_ID" --allocation-id "$EIP_ALLOC_ID" \
    --region "$AWS_REGION" >/dev/null
  PUBLIC_IP="$(aws ec2 describe-addresses --allocation-ids "$EIP_ALLOC_ID" \
    --query 'Addresses[0].PublicIp' --output text --region "$AWS_REGION")"
  echo "Associated Elastic IP $PUBLIC_IP with $INSTANCE_ID - this IP is now permanent across stop/start."

  # sslip.io resolves "<ip-with-dashes>.sslip.io" straight back to the IP -
  # free, real, publicly-resolvable DNS with no domain purchase or Route53
  # access needed (the latter is commonly restricted on AWS Academy Learner
  # Lab accounts anyway - see README.md). Derived from the IP rather than
  # pointed at it, so a delete.sh + re-provision.sh cycle (new IP) needs no
  # manual DNS re-pointing - the new domain just falls out of the new IP.
  DOMAIN="${PUBLIC_IP//./-}.sslip.io"

  echo "== Updating application/.env =="
  if [[ ! -f "$APP_ENV_FILE" ]]; then
    if [[ -f "$APP_ENV_EXAMPLE" ]]; then
      cp "$APP_ENV_EXAMPLE" "$APP_ENV_FILE"
    else
      touch "$APP_ENV_FILE"
    fi
  fi
  if grep -q '^API_GATEWAY_URL=' "$APP_ENV_FILE" 2>/dev/null; then
    sed -i "s|^API_GATEWAY_URL=.*|API_GATEWAY_URL=https://$DOMAIN|" "$APP_ENV_FILE"
  else
    echo "API_GATEWAY_URL=https://$DOMAIN" >> "$APP_ENV_FILE"
  fi
  echo "Set API_GATEWAY_URL=https://$DOMAIN in $APP_ENV_FILE"

  # Deliberately NOT written to the repo root - docker compose auto-loads a
  # root .env for every invocation, including the operator's own local dev
  # `docker compose up`, which would silently flip on the "https" profile
  # and attempt real ACME against a domain that doesn't route to the
  # operator's machine. This file stays here and gets copied to the
  # instance's own repo root (~/4u/.env) during deploy - see README.md -
  # where that auto-load behavior is exactly what's wanted.
  REMOTE_ENV_FILE="$SCRIPT_DIR/.env"
  {
    echo "DOMAIN=$DOMAIN"
    echo "COMPOSE_PROFILES=https"
  } > "$REMOTE_ENV_FILE"
  echo "Wrote $REMOTE_ENV_FILE - copy this to the instance's ~/4u/.env during deploy (see README.md)."
else
  echo "ALLOCATE_EIP=false - skipping application/.env wiring and HTTPS setup (sslip.io/Caddy both need a stable IP)."
fi

cat <<EOF

== Done ==
Instance ID: $INSTANCE_ID
Public IP:   $PUBLIC_IP$([ "$ALLOCATE_EIP" == "true" ] && echo " (Elastic IP - permanent)")
SSH:         ssh ec2-user@$INSTANCE_ID  (over SSM - see README.md's one-time local setup if this is your first time)
$([ "$ALLOCATE_EIP" == "true" ] && echo "HTTPS domain: https://$DOMAIN (Let's Encrypt cert issued automatically on first deploy)")

$([ "$LAUNCHED_NEW" == "true" ] && echo "Docker and the SSM agent are installing via user-data in the background -
give it a minute or two before SSHing in. " )Next steps (copying the repo +
.env files, including the new deployment/phase1-ec2/.env for HTTPS, and
starting the stack) are in README.md.
EOF
