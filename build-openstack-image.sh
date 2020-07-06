#!/bin/bash
set -euo pipefail

# Ensure cloud-init has finished running.
while true; do
    if [[ -f /var/lib/cloud/instance/boot-finished ]]; then
        break
    fi
    echo "Waiting for cloud-init to finish running..."
    sleep 5
done

# Colorful output.
function greenprint {
    echo -e "\033[1;32m${1}\033[0m"
}

# Get OS data.
source /etc/os-release

# Set up variables for the image name.
TIMESTAMP=$(date +"%Y%m%d%H%M")
IMAGE_NAME="imagebuilder-ci-${ID}-${VERSION_ID}-${TIMESTAMP}"

# Set up variables for the osbuild repository.
S3_URL=https://osbuild-composer-repos.s3.us-east-2.amazonaws.com/osbuild/osbuild-composer
OS_STRING=${ID}${VERSION_ID//./}

# Set the osbuild-composer release.
# Currently v16: 534c508c41687b09e173deb60f65f25c195fcfa9
OSBUILD_RELEASE_PATH=master/534c508

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

# Set up a directory to hold osbuild-composer overrides.
sudo mkdir -p /etc/osbuild-composer/repositories

# Use the fastest internal Fedora mirrors.
if [[ $OS_STRING == fedora31 ]]; then
    sudo curl -Ls --retry 5 --output /etc/osbuild-composer/repositories/fedora-31.json \
        https://raw.githubusercontent.com/osbuild/osbuild-composer/master/test/internal-repos/fedora-31.json
fi
if [[ $OS_STRING == fedora32 ]]; then
    sudo curl -Ls --retry 5 --output /etc/osbuild-composer/repositories/fedora-32.json \
        https://raw.githubusercontent.com/osbuild/osbuild-composer/master/test/internal-repos/fedora-32.json
fi

# Use production RHEL 8.2 content for now.
# See https://github.com/osbuild/osbuild-composer/commit/fe9f2c55b8952e4a636ba021b5fe953e7f06a32c
if [[ $OS_STRING == rhel82 ]]; then
    greenprint "🌙 Restoring RHEL 8.2 released content repositories"
    sudo curl -Lsk --retry 5 \
        --output /etc/osbuild-composer/repositories/rhel-8.json \
        https://raw.githubusercontent.com/osbuild/osbuild-composer/master/test/external-repos/rhel-8.json
fi

# RHEL 8.3 content is not on the CDN yet, so use internal repositories.
if [[ $OS_STRING == rhel83 ]]; then
    greenprint "🌙 Setting up RHEL 8.3 nightly repositories"
    sudo curl -Lsk --retry 5 \
        --output /etc/yum.repos.d/rhel83nightly.repo \
        https://gitlab.cee.redhat.com/snippets/2147/raw
    sudo curl -Lsk --retry 5 \
        --output /etc/osbuild-composer/repositories/rhel-8.json \
        https://gitlab.cee.redhat.com/snippets/2361/raw
fi

# Disable modular repositories
greenprint "❌ Remove modular repositories"
if [[ $ID == fedora ]]; then
    sudo rm -fv /etc/yum.repos.d/fedora*modular*
fi

# Install packages.
greenprint "📥 Installing packages with dnf"
sudo dnf -y install composer-cli gcc jq osbuild-composer python3-devel python3-pip

# Install openstackclient so we can upload the built images.
greenprint "📥 Installing openstackclient"
sudo pip3 -q install python-openstackclient

# Start osbuild-composer.
greenprint "🚀 Starting obuild-composer"
sudo systemctl enable --now osbuild-composer.socket
sudo composer-cli status show

# Push the blueprint.
greenprint "🚚 Loading blueprint"
sudo composer-cli sources list
sudo composer-cli blueprints push blueprints/openstack-ci.toml

# Depsolve the blueprint.
# NOTE(mhayden): Try this twice since the first run sometimes times out.
greenprint "⚙ Solving dependencies in blueprint"
DEPSOLVE_CMD="sudo composer-cli blueprints depsolve imagebuilder-ci-openstack"
if ! $DEPSOLVE_CMD; then
    echo "💣 First depsolve attempt failed - trying again."
    $DEPSOLVE_CMD
fi

# Start the compose and get the ID.
greenprint "🛠 Starting compose"
sudo composer-cli --json compose start imagebuilder-ci-openstack openstack \
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

# Download the image.
greenprint "📥 Downloading the image"
sudo composer-cli compose image ${COMPOSE_ID} > /dev/null
COMPOSE_IMAGE_FILENAME=$(basename $(find . -maxdepth 1 -type f -name "*.qcow2"))

# Prepare the OpenStack login credentials.
mkdir -p ~/.config/openstack
cp $OPENSTACK_CREDS ~/.config/openstack/clouds.yaml

# Upload the image into PSI OpenStack.
greenprint "📤 Uploading the image to PSI OpenStack"
openstack --os-cloud psi image create \
    --format json \
    --container-format bare \
    --disk-format qcow2 \
    --private \
    --file $COMPOSE_IMAGE_FILENAME \
    ${IMAGE_NAME}

# Verify that it uploaded successfully.
greenprint "🔎 Verifying image"
openstack --os-cloud psi image show --format json ${IMAGE_NAME}
