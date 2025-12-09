#!/bin/bash
set -euo pipefail

# Enable debug logging
exec > >(tee /var/log/user-data.log)
exec 2>&1
echo "Starting GitHub runner setup at $(date)"

REPO="${repo}"
REGION="${region}"
SECRET_NAME="${secret_name}"
RUNNER_DIR="/home/ec2-user/actions-runner"
RUNNER_VERSION="${runner_version}"
REPO_LABEL="$${REPO//\//-}"
LABELS="ephemeral,$REPO_LABEL"

# Install dependencies
echo "Installing dependencies..."
yum update -y
yum install -y jq git amazon-ssm-agent
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent

# create user and work dir
echo "Setting up ec2-user..."
id -u ec2-user &>/dev/null || useradd -m ec2-user
mkdir -p "$RUNNER_DIR"
chown ec2-user:ec2-user "$RUNNER_DIR"
cd "$RUNNER_DIR"

# fetch GH PAT from Secrets Manager
echo "Fetching GitHub PAT from Secrets Manager..."
GH_PAT_JSON=$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" --region "$REGION" --query SecretString --output text)
GH_PAT=$(echo "$GH_PAT_JSON" | jq -r .token)
if [ -z "$GH_PAT" ] || [ "$GH_PAT" = "null" ]; then
  echo "ERROR: Failed to read GH PAT" >&2
  exit 1
fi
echo "Successfully retrieved GitHub PAT"

# obtain registration token (short-lived)
echo "Obtaining GitHub registration token..."
REG_RESP=$(curl -s -X POST -H "Authorization: token $GH_PAT" -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$REPO/actions/runners/registration-token")
REG_TOKEN=$(echo "$REG_RESP" | jq -r .token)
if [ -z "$REG_TOKEN" ] || [ "$REG_TOKEN" = "null" ]; then
  echo "ERROR: Failed to get registration token: $REG_RESP" >&2
  exit 1
fi
echo "Successfully obtained registration token"

# download and extract runner
echo "Downloading GitHub Actions runner v$RUNNER_VERSION..."
ARCHIVE="actions-runner-linux-x64-$RUNNER_VERSION.tar.gz"
curl -o "$ARCHIVE" -L "https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/$ARCHIVE"
tar xzf "$ARCHIVE"
chown -R ec2-user:ec2-user .
echo "Runner extracted successfully"

# Install runner dependencies (required for .NET Core 6.0)
echo "Installing runner dependencies..."
# Amazon Linux 2023 requires manual libicu installation
yum install -y libicu
echo "Runner dependencies installed"

# configure runner as persistent (handles multiple jobs)
echo "Configuring runner with labels: $LABELS..."
sudo -u ec2-user bash -c "./config.sh --unattended --url https://github.com/$REPO --token $REG_TOKEN --labels $LABELS --work _work"
echo "Runner configured successfully"

# install and start as service
echo "Installing and starting runner service..."
./svc.sh install ec2-user
./svc.sh start
echo "Runner service started"

# Create unregister script that fetches a fresh removal token at shutdown
cat > /usr/local/bin/unregister-runner.sh << 'UNREG'
#!/bin/bash
set -e
cd /home/ec2-user/actions-runner || exit 0

# Fetch PAT from Secrets Manager
GH_PAT_JSON=$(aws secretsmanager get-secret-value --secret-id "${secret_name}" --region "${region}" --query SecretString --output text 2>/dev/null)
GH_PAT=$(echo "$GH_PAT_JSON" | jq -r .token 2>/dev/null)

if [ -n "$GH_PAT" ] && [ "$GH_PAT" != "null" ]; then
  # Get removal token
  REMOVE_RESP=$(curl -s -X POST -H "Authorization: token $GH_PAT" -H "Accept: application/vnd.github+json" "https://api.github.com/repos/${repo}/actions/runners/remove-token" 2>/dev/null)
  REMOVE_TOKEN=$(echo "$REMOVE_RESP" | jq -r .token 2>/dev/null)
  
  if [ -n "$REMOVE_TOKEN" ] && [ "$REMOVE_TOKEN" != "null" ]; then
    ./config.sh remove --unattended --token "$REMOVE_TOKEN" 2>/dev/null || true
  fi
fi
UNREG

chmod +x /usr/local/bin/unregister-runner.sh

cat > /etc/systemd/system/unregister-runner.service << 'UNIT'
[Unit]
Description=Unregister GitHub runner on shutdown
DefaultDependencies=no
Before=shutdown.target

[Service]
Type=oneshot
ExecStart=/bin/true
ExecStop=/usr/local/bin/unregister-runner.sh
RemainAfterExit=yes
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable unregister-runner.service
systemctl start unregister-runner.service

echo "GitHub runner setup completed successfully at $(date)"