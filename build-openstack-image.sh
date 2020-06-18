#!/bin/bash
set -euxo pipefail

# Get OS data.
source /etc/os-release

# Set up variables for the osbuild repository.
S3_URL=https://osbuild-composer-repos.s3.us-east-2.amazonaws.com/osbuild/osbuild-composer
OSBUILD_RELEASE_PATH=release-version-15/61fce0c
OS_STRING=${ID}${VERSION_ID//./}

# Add a repository for the recent osbuild release.
sudo tee /etc/yum.repos.d/osbuild-mock.repo << EOF
[osbuild-mock]
name=osbuild recent release
baseurl=${S3_URL}/${OSBUILD_RELEASE_PATH}/${OS_STRING}
enabled=1
gpgcheck=0
# Default dnf repo priority is 99. Lower number means higher priority.
priority=5
EOF

# RHEL 8.3 content is not on the CDN yet, so use internal repositories.
if [[ $OS_STRING == rhel83 ]]; then
    sudo curl -Lsk --retry 5 \
        --output /etc/yum.repos.d/rhel83nightly.repo \
        https://gitlab.cee.redhat.com/snippets/2147/raw
    sudo mkdir -p /etc/osbuild-composer/repositories
    sudo curl -Lsk --retry 5 \
        --output /etc/osbuild-composer/repositories/rhel-8.json \
        https://gitlab.cee.redhat.com/snippets/2361/raw
fi

# Install packages.
sudo dnf -qy install composer-cli jq osbuild-composer python3-pip

# Install openstackclient so we can upload the built images.
sudo pip3 -qq install python-openstackclient

# Start osbuild-composer.
sudo systemctl enable --now osbuild-composer.socket

# Push the blueprint.
sudo composer-cli blueprints push blueprints/openstack-ci.toml
sudo composer-cli blueprints depsolve imagebuilder-ci-openstack

# Start the compose and get the
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
sudo composer-cli compose image ${COMPOSE_ID} > /dev/null
COMPOSE_IMAGE_FILENAME=$(basename $(find . -maxdepth 1 -type f -name "*.qcow2"))

# Prepare the OpenStack login credentials.
mkdir -p ~/.config/openstack
cp $OPENSTACK_CREDS ~/.config/openstack/clouds.yaml

# Upload the image into PSI OpenStack.
CHECKSUM=($(md5sum $COMPOSE_IMAGE_FILENAME))
TIMESTAMP=$(date +"%Y-%m-%d %H:%M")
IMAGE_NAME="${ID}-${VERSION_ID} ${TIMESTAMP} (imagebuilder)"
openstack --os-cloud psi image create \
    --checksum $CHECKSUM \
    --container-format bare \
    --disk-format qcow2 \
    --private \
    --file $COMPOSE_IMAGE_FILENAME \
    ${IMAGE_NAME}

# Verify that it uploaded successfully.
openstack --os-cloud psi image show \"${IMAGE_NAME}\"
