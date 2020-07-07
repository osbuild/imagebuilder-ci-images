#!/bin/bash
set -euo pipefail

# Colorful output.
function greenprint {
    echo -e "\033[1;32m${1}\033[0m"
}

# Get OS data.
source /etc/os-release

# Set up the name for the image.
TIMESTAMP=$(date +"%Y%m%d%H%M")
IMAGE_NAME="imagebuilder-ci-${ID}-${VERSION_ID}-${TIMESTAMP}"

# Set up variables for the osbuild repository.
S3_URL=https://osbuild-composer-repos.s3.us-east-2.amazonaws.com/osbuild/osbuild-composer
OSBUILD_RELEASE_PATH=master/0c6848f
OS_STRING=${ID}${VERSION_ID//./}

# Add a repository for the recent osbuild release.
greenprint "🏭 Adding osbuild repository from recent release"
sudo tee /etc/yum.repos.d/osbuild-mock.repo << EOF
[osbuild-mock]
name=osbuild recent release
baseurl=${S3_URL}/${OSBUILD_RELEASE_PATH}/${OS_STRING}
enabled=1
gpgcheck=0
# Default dnf repo priority is 99. Lower number means higher priority.
priority=5
EOF

# Ensure RHEL 8.2 is registered.
if [[ $OS_STRING == rhel82 ]]; then
    greenprint "🪙 Registering RHEL 8"
    subscription-manager register \
        --username="$RHN_CREDS_USR" --password="$RHN_CREDS_PSW" \
        --auto-attach
    subscription-manager repos \
        --enable=codeready-builder-for-rhel-8-x86_64-rpms
fi

# RHEL 8.3 content is not on the CDN yet, so use internal repositories.
if [[ $OS_STRING == rhel83 ]]; then
    greenprint "🌙 Setting up RHEL 8.3 nightly repositories"
    sudo curl -Lsk --retry 5 \
        --output /etc/yum.repos.d/rhel83nightly.repo \
        https://gitlab.cee.redhat.com/snippets/2147/raw
    sudo mkdir -p /etc/osbuild-composer/repositories
    sudo curl -Lsk --retry 5 \
        --output /etc/osbuild-composer/repositories/rhel-8.json \
        https://gitlab.cee.redhat.com/snippets/2361/raw
fi

# Install packages.
greenprint "📥 Installing packages with dnf"
sudo dnf -qy install composer-cli jq osbuild-composer python3-pip

# Apply lorax patch to work around pytoml issues in RHEL 8.x.
# See BZ 1843704 or https://github.com/weldr/lorax/pull/1030 for more details.
if [[ $ID == rhel ]]; then
    sudo sed -r -i 's#toml.load\(args\[3\]\)#toml.load(open(args[3]))#' \
        /usr/lib/python3.6/site-packages/composer/cli/compose.py
    sudo rm -f /usr/lib/python3.6/site-packages/composer/cli/compose.pyc
fi

# Start osbuild-composer.
greenprint "🚀 Starting obuild-composer"
sudo systemctl enable --now osbuild-composer.socket

# Write an AWS TOML file
tee /tmp/aws.toml > /dev/null << EOF
provider = "aws"

[settings]
accessKeyID = "${AWS_ACCESS_KEY_ID}"
secretAccessKey = "${AWS_SECRET_ACCESS_KEY}"
bucket = "${AWS_BUCKET}"
region = "${AWS_REGION}"
key = "${IMAGE_NAME}"
EOF

# Push the blueprint.
greenprint "🚚 Loading blueprint"
sudo composer-cli sources list
sudo composer-cli blueprints push blueprints/aws-ci.toml
sudo composer-cli blueprints depsolve imagebuilder-ci-aws > /dev/null

# Get worker unit file so we can watch the journal.
WORKER_UNIT=$(sudo systemctl list-units | egrep -o "osbuild.*worker.*\.service")
sudo journalctl -af -n 1 -u ${WORKER_UNIT} &
WORKER_JOURNAL_PID=$!

# Start the compose and get the ID.
greenprint "🛠 Starting compose"
sudo composer-cli --json compose start imagebuilder-ci-aws ami $IMAGE_NAME /tmp/aws.toml \
    | tee /tmp/compose-start.json
COMPOSE_ID=$(jq -r '.build_id' /tmp/compose-start.json)

# Wait for the compose to finish.
while true; do
    sudo composer-cli --json compose info ${COMPOSE_ID} | tee /tmp/compose_info.json > /dev/null
    COMPOSE_STATUS=$(jq -r '.queue_status' /tmp/compose_info.json)

    # Is the compose finished?
    if [[ $COMPOSE_STATUS != RUNNING ]] && [[ $COMPOSE_STATUS != WAITING ]]; then
        break
    fi

    # Wait 30 seconds and try again.
    sleep 30
done

# Did the compose finish with success?
if [[ $COMPOSE_STATUS != FINISHED ]]; then
    echo "Something went wrong with the compose. 😢"
    sudo composer-cli compose log $COMPOSE_ID
    exit 1
fi

# Stop watching the worker journal.
sudo kill ${WORKER_JOURNAL_PID}