#!/bin/bash
set -o pipefail
source ./config/env.config

# --- Dependency Checks ---

if ! command -v curl >/dev/null 2>&1 ; then
    echo "curl missing. Please install curl."
    exit 1
fi

if ! command -v wget >/dev/null 2>&1 ; then
    echo "wget missing. Please install wget."
    exit 1
fi

# VCF 9 relies on standalone imgpkg (Carvel) rather than 'tanzu imgpkg'
if ! command -v imgpkg >/dev/null 2>&1 ; then
    echo "imgpkg missing. Attempting to download..."
    # You may want to pin this version to match your VCF 9 Bill of Materials
    wget -q -O /tmp/imgpkg https://github.com/carvel-dev/imgpkg/releases/download/v0.42.0/imgpkg-linux-amd64
    chmod +x /tmp/imgpkg
    sudo mv /tmp/imgpkg /usr/local/bin/
    echo "imgpkg installed."
fi

if ! command -v yq >/dev/null 2>&1 ; then
    echo "yq missing. Please install yq CLI version 4.x from https://github.com/mikefarah/yq/releases"
    exit 1
else
    if ! yq -P > /dev/null 2>&1 ; then 
        echo "yq version 4.x required. Please install yq version 4.x from https://github.com/mikefarah/yq/releases."
        exit 1
    fi
fi

# Create the download directories if they don't exist
mkdir -p "$DOWNLOAD_DIR_YML"
mkdir -p "$DOWNLOAD_DIR_TAR"
mkdir -p "$DOWNLOAD_DIR_BIN"

# --- Main Download Logic ---

# 1. Download VCF CLI
# Note: $VCF_CLI_URL must be defined in your env.config pointing to the Broadcom Support Portal download link
echo "Downloading VCF CLI and Standard Packages..."

if [ -z "$VCF_CLI_URL" ]; then
    echo "Warning: VCF_CLI_URL is not set in env.config. Skipping VCF CLI download."
else
    wget -q -O "$DOWNLOAD_DIR_BIN"/vcf-cli-linux-amd64.tar.gz "$VCF_CLI_URL"
    tar -xzvf "$DOWNLOAD_DIR_BIN"/vcf-cli-linux-amd64.tar.gz -C "$DOWNLOAD_DIR_BIN"
    # Find the binary in the extracted folder and move it
    find "$DOWNLOAD_DIR_BIN" -name "vcf" -type f -exec sudo cp {} /usr/local/bin/ \;
    chmod +x /usr/local/bin/vcf
fi

# 2. Download Standard Packages Bundle (TKG packages) using standalone imgpkg
echo "Downloading Standard Packages Bundle..."
imgpkg copy -b projects.registry.vmware.com/tkg/packages/standard/repo:"$TANZU_STANDARD_REPO_VERSION" \
    --to-tar "$DOWNLOAD_DIR_BIN"/standard-packages.tar \
    --registry-verify-certs=false

# 3. Supervisor Services Configuration (Updated Broadcom Links)
echo "Downloading all Supervisor Services configuration files..."

# TKG Service
wget -q -O "$DOWNLOAD_DIR_YML"/supsvc-tkg-service.yaml          'https://packages.broadcom.com/artifactory/vsphere-distro/vsphere/iaas/kubernetes-service/3.3.0-package.yaml'

# CCI Service
wget -q -O "$DOWNLOAD_DIR_YML"/supsvc-cci-supervisor-service.yaml 'https://projects.packages.broadcom.com/artifactory/supervisor-services/cci-supervisor-service/v1.0.2/cci-supervisor-service.yml'
wget -q -O "$DOWNLOAD_DIR_YML"/supsvc-cci-values.yaml             'https://projects.packages.broadcom.com/artifactory/supervisor-services/cci-supervisor-service/v1.0.2/values.yml'
wget -q -O "$DOWNLOAD_DIR_YML"/supsvc_config_from_automation.py   'https://projects.packages.broadcom.com/artifactory/supervisor-services/cci-supervisor-service/v1.0.2/service_config_from_automation.py'

# Harbor
wget -q -O "$DOWNLOAD_DIR_YML"/supsvc-harbor.yaml           'https://projects.packages.broadcom.com/artifactory/supervisor-services/harbor/v2.9.1/harbor.yml'
wget -q -O "$DOWNLOAD_DIR_YML"/supsvc-harbor-values.yaml    'https://projects.packages.broadcom.com/artifactory/supervisor-services/harbor/v2.9.1/harbor-data-values.yml'

# Contour
wget -q -O "$DOWNLOAD_DIR_YML"/supsvc-contour.yaml          'https://projects.packages.broadcom.com/artifactory/supervisor-services/contour/v1.28.2/contour.yml'

# External DNS
wget -q -O "$DOWNLOAD_DIR_YML"/supsvc-externaldns.yaml      'https://projects.packages.broadcom.com/artifactory/supervisor-services/external-dns/v0.13.4/external-dns.yml'

# NSX Management Proxy
wget -q -O "$DOWNLOAD_DIR_YML"/supsvc-nsxmgmt.yaml          'https://projects.packages.broadcom.com/artifactory/supervisor-services/nsx-management-proxy/v0.2.1/nsx-management-proxy.yml'

# ArgoCD (Community/GitHub)
wget -q -O "$DOWNLOAD_DIR_YML"/supsvc-argocd-operator.yaml  'https://raw.githubusercontent.com/vsphere-tmm/Supervisor-Services/refs/heads/main/supervisor-services-labs/argocd-operator/v0.12.0/argocd-operator.yaml'

# --- Image Processing ---

echo
echo "Downloading Supervisor Services images using imgpkg..."
echo

for file in "$DOWNLOAD_DIR_YML"/*.yaml; do
    full_filename=$(basename "$file")
    file_name="${full_filename%.yaml}"   
    
    # Extract image using yq
    image=$(yq -P '(.|select(.kind == "Package").spec.template.spec.fetch[].imgpkgBundle.image)' "$file")

    if [ "$image" ] && [ "$image" != "null" ]; then
        echo "Now downloading $image..."
        
        # Switched from 'tanzu imgpkg copy' to 'imgpkg copy'
        # Added --registry-verify-certs=false for flexibility with internal/self-signed registries
        imgpkg copy -b "$image" \
            --to-tar "$DOWNLOAD_DIR_TAR"/"$file_name".tar \
            --cosign-signatures \
            --registry-verify-certs=false

        # Get the name of the image and replace URL with new harbor location
        if [ "$file_name" == "supsvc-contour" ] || [ "$file_name" == "supsvc-harbor" ]; then
            newurl="$BOOTSTRAP_REGISTRY"/"${BOOTSTRAP_SUPSVC_REPO}"/"${image##*/}"
        else
            newurl="$PLATFORM_REGISTRY"/"${PLATFORM_SUPSVC_REPO}"/"${image##*/}"
        fi
        
        echo "Updating Supervisor Service config file image to $newurl..."
        a=$newurl yq -P '(.|select(.kind == "Package").spec.template.spec.fetch[].imgpkgBundle.image = env(a))' -i "$file"
    fi
done

# --- Sync to Admin Host ---

if [[ $SYNC_DIRECTORIES == "True" ]]; then
    echo "Syncing files to admin host..."
    # Sync supervisor services and the bin directory containing VCF CLI/Tools
    sshpass -p "$HTTP_PASSWORD" rsync -avz {supervisor-services*,"$DOWNLOAD_DIR_BIN"} "$HTTP_USERNAME"@"$HTTP_HOST":"$ADMIN_RESOURCES_DIR"

    # Copy yq and imgpkg binaries to admin host
    sshpass -p "$HTTP_PASSWORD" rsync -avz /usr/bin/yq "$HTTP_USERNAME"@"$HTTP_HOST":"$ADMIN_RESOURCES_DIR"
    sshpass -p "$HTTP_PASSWORD" rsync -avz /usr/local/bin/imgpkg "$HTTP_USERNAME"@"$HTTP_HOST":"$ADMIN_RESOURCES_DIR"
fi
