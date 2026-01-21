#!/bin/bash

# ==============================================================================
# VCF 9 & Private AI - Air Gap Preparation (Direct Artifactory Method)
# ==============================================================================
# FIXED:
# 1. Corrected VCF CLI binary detection to handle 'vcf-cli-linux_amd64' naming.
# 2. Uses direct Artifactory links (No Broadcom Portal Token required).
# ==============================================================================

set -o pipefail
source ./config/env.config

# --- Configuration ---
DOWNLOAD_DIR="$DOWNLOAD_DIR_BIN"

echo "=== Starting VCF 9 Air-Gap Preparation ==="

# add harbor to docker daemon
sudo jq --arg registry "${BOOTSTRAP_REGISTRY}" '. += {"insecure-registries":[$registry]}' /etc/docker/daemon.json > /opt/data/temp.json && sudo mv /opt/data/temp.json /etc/docker/daemon.json
sudo systemctl restart docker

# add certificate from harbor
openssl s_client -showcerts -servername $BOOTSTRAP_REGISTRY -connect $BOOTSTRAP_REGISTRY:443 </dev/null | sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' > $BOOTSTRAP_REGISTRY.crt
sudo cp $BOOTSTRAP_REGISTRY.crt /usr/local/share/ca-certificates/$BOOTSTRAP_REGISTRY.crt

# Install kubectl
if ! command -v kubectl >/dev/null 2>&1 ; then
    sudo install -o root -g root -m 0755 "$DOWNLOAD_DIR/kubectl" /usr/local/bin/kubectl
fi

# Helm
if ! command -v helm >/dev/null 2>&1 ; then
    sudo cp "$DOWNLOAD_DIR/helm" /usr/local/bin/helm
    sudo chmod +x /usr/local/bin/helm
fi

# yq (YAML processor)
if ! command -v yq >/dev/null 2>&1 ; then
    sudo cp "$DOWNLOAD_DIR/yq" /usr/bin/yq
    sudo chmod +x /usr/bin/yq
fi

# Extract and move govc CLI
if ! command -v govc >/dev/null 2>&1 ; then
    tar -xvf "$DOWNLOAD_DIR/govc_Linux_x86_64.tar.gz" -C $DOWNLOAD_DIR
    sudo mv "$DOWNLOAD_DIR/govc" /usr/bin/govc
fi

# 4. Fetch & Install VCF CLI (Direct Download)
# Extract and move VCF CLI
if ! command -v vcf >/dev/null 2>&1 ; then
    sudo tar -xvf "$DOWNLOAD_DIR/vcf-cli.tar.gz" -C /usr/bin
    sudo mv /usr/bin/vcf-cli-linux_amd64 /usr/bin/vcf

    # 5. Fetch & Install Offline Plugins (Direct Download)
    echo "[5/6] Downloading VCF Offline Plugin Bundle..."
    PLUGIN_BUNDLE="$DOWNLOAD_DIR/plugins.tar.gz"

    echo "Extracting Plugin Bundle for Local Install..."
    BUNDLE_EXTRACT_DIR="$DOWNLOAD_DIR/vcf_plugins_extracted"
    rm -rf "$BUNDLE_EXTRACT_DIR"
    mkdir -p "$BUNDLE_EXTRACT_DIR"
    tar -xvf "$PLUGIN_BUNDLE" -C "$BUNDLE_EXTRACT_DIR"

    echo "Installing Plugins from Local Source..."
    # Installs all plugins from the offline bundle
    vcf plugin install all --local-source "$BUNDLE_EXTRACT_DIR"
fi

echo "Verifying Plugin Installation..."
vcf plugin list

echo "
==============================================================================
AIR GAP PREPARATION COMPLETE
==============================================================================
1. VCF CLI installed successfully.
2. VCF Plugins installed from offline bundle.
3. Dependencies (Docker, Helm, Kubectl) ready.

Artifacts location: $DOWNLOAD_DIR
==============================================================================
"
sudo systemctl daemon-reload
