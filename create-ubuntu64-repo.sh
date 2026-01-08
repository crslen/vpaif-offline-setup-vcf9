#!/bin/bash
# ---------------------------------------------------------------------------------
# AGGRESSIVE UBUNTU MIRROR SCRIPT (64-bit Main/Restricted ONLY)
# ---------------------------------------------------------------------------------
# PURPOSE: 
# 1. Forcefully delete 'Universe' and 'Multiverse' (The source of the 600GB bloat).
# 2. Re-sync only the 'Main' and 'Restricted' repositories (~100-120GB).
# 3. Setup VCF-CLI.
# ---------------------------------------------------------------------------------
set -o pipefail

# 1. Load Configuration
if [ -f "./config/env.config" ]; then
    source ./config/env.config
else
    echo "Error: ./config/env.config not found."
    exit 1
fi

# Define VCF CLI Versions
VCF_CLI_VERSION="v9.0.0"
VCF_CLI_URL="https://packages.broadcom.com/artifactory/vcf-distro/vcf-cli/linux/amd64/${VCF_CLI_VERSION}/vcf-cli.tar.gz"
VCF_PLUGIN_BUNDLE_URL="https://packages.broadcom.com/artifactory/vcf-distro/vcf-cli-plugins/${VCF_CLI_VERSION}/VCF-Consumption-CLI-PluginBundle-Linux_AMD64.tar.gz"

# Install apt-mirror if missing
if ! command -v apt-mirror &> /dev/null; then
    apt update && apt install -y apt-mirror
fi

# ---------------------------------------------------------------------------------
# STEP 1: THE PURGE (Fixing the 600GB Issue)
# ---------------------------------------------------------------------------------
echo "!!! STARTING AGGRESSIVE CLEANUP !!!"
# Define the path to the data pool
# Standard apt-mirror path: $base_path/mirror/archive.ubuntu.com/ubuntu/pool
REPO_ROOT="$BASTION_REPO_DIR/mirror/archive.ubuntu.com/ubuntu"

if [ -d "$REPO_ROOT/pool" ]; then
    echo "Checking for 'Universe' (Community) repository bloat..."
    if [ -d "$REPO_ROOT/pool/universe" ]; then
        echo "  -> DELETING existing Universe repository (this may take a while)..."
        rm -rf "$REPO_ROOT/pool/universe"
        echo "  -> Universe deleted."
    fi

    echo "Checking for 'Multiverse' (Non-Free) repository bloat..."
    if [ -d "$REPO_ROOT/pool/multiverse" ]; then
        echo "  -> DELETING existing Multiverse repository..."
        rm -rf "$REPO_ROOT/pool/multiverse"
        echo "  -> Multiverse deleted."
    fi
    
    # Optional: Delete Backports if strictly not needed (usually safe to delete)
    # rm -rf "$REPO_ROOT/pool/main/b/backports-*" 
else
    echo "Repo pool not found yet. Skipping cleanup."
fi

echo "Cleanup complete. Storage should now be reclaimed."

# ---------------------------------------------------------------------------------
# STEP 2: CONFIGURE APT-MIRROR (Strict 64-bit Core Only)
# ---------------------------------------------------------------------------------
# Backup existing list
[ -f "/etc/apt/mirror.list" ] && mv /etc/apt/mirror.list /etc/apt/mirror.list-bak

cat > /etc/apt/mirror.list << EOF
############# config ##################
set base_path $BASTION_REPO_DIR
set nthreads     20
set _tilde 0
set defaultarch amd64
############# end config ##############

# -- CORE REPOSITORIES ONLY --
# jammy (Main + Restricted) is the minimal set for a working OS
deb http://archive.ubuntu.com/ubuntu jammy main restricted
deb http://archive.ubuntu.com/ubuntu jammy-security main restricted
deb http://archive.ubuntu.com/ubuntu jammy-updates main restricted

# Clean rule: Tells apt-mirror to list files that shouldn't be here
clean http://archive.ubuntu.com/ubuntu
EOF

# ---------------------------------------------------------------------------------
# STEP 3: START MIRRORING
# ---------------------------------------------------------------------------------
echo "Starting apt-mirror sync..."
apt-mirror

# ---------------------------------------------------------------------------------
# STEP 4: EXECUTE CLEAN SCRIPT
# ---------------------------------------------------------------------------------
# apt-mirror generates a script to delete obsolete files but doesn't run it automatically.
# We must run it to keep the repo slim.
CLEAN_SCRIPT="$BASTION_REPO_DIR/var/clean.sh"
if [ -f "$CLEAN_SCRIPT" ]; then
    echo "Running apt-mirror cleanup script to remove obsolete indices..."
    /bin/bash "$CLEAN_SCRIPT"
fi

# ---------------------------------------------------------------------------------
# STEP 5: MANUAL FIXES (Icons & CNF)
# ---------------------------------------------------------------------------------
echo "Downloading metadata (Icons & CNF)..."
base_dir="$REPO_ROOT/dists"

if [ -d "$base_dir" ]; then
    cd "$base_dir"
    for dist in jammy jammy-updates jammy-security; do
      for comp in main restricted; do
        mkdir -p "$dist/$comp/dep11"
        for size in 48 64 128; do
            wget -q -N "http://archive.ubuntu.com/ubuntu/dists/$dist/$comp/dep11/icons-${size}x${size}@2.tar.gz" -O "$dist/$comp/dep11/icons-${size}x${size}@2.tar.gz"
        done
      done
    done
fi

cd /var/tmp
# Only download CNF for amd64
for p in "${1:-jammy}"{,-{security,updates}}/{main,restricted}; do
  wget -q -c -r -np -R "index.html*" "http://archive.ubuntu.com/ubuntu/dists/${p}/cnf/Commands-amd64.xz"
done

echo "Moving manual downloads..."
cp -av archive.ubuntu.com/ubuntu/ "$REPO_ROOT/../../"

# ---------------------------------------------------------------------------------
# STEP 6: VCF-CLI SETUP
# ---------------------------------------------------------------------------------
echo "Setting up VCF-CLI..."
VCF_REPO_DIR="$BASTION_REPO_DIR/vcf-cli"
mkdir -p "$VCF_REPO_DIR"
cd "$VCF_REPO_DIR"

wget -q -c "$VCF_CLI_URL" -O vcf-cli.tar.gz
wget -q -c "$VCF_PLUGIN_BUNDLE_URL" -O vcf-plugins-bundle.tar.gz

echo "Installing VCF-CLI locally..."
tar -xf vcf-cli.tar.gz
# Find binary regardless of potential naming variations
if [ -f "vcf-cli-linux-amd64" ]; then
    BINARY_NAME="vcf-cli-linux-amd64"
elif [ -f "vcf-cli" ]; then
    BINARY_NAME="vcf-cli"
else
    BINARY_NAME=$(find . -type f -name "vcf-cli*" | head -n 1)
fi

if [ -n "$BINARY_NAME" ]; then
    chmod +x "$BINARY_NAME"
    cp "$BINARY_NAME" /usr/local/bin/vcf
    
    echo "Installing Plugins..."
    mkdir -p /tmp/vcf-bundle
    tar -xf vcf-plugins-bundle.tar.gz -C /tmp/vcf-bundle
    vcf plugin install all --local-source /tmp/vcf-bundle
    rm -rf /tmp/vcf-bundle
else
    echo "WARNING: Could not locate extracted VCF binary. Check download."
fi

# ---------------------------------------------------------------------------------
# STEP 7: REMOTE SYNC (With Delete)
# ---------------------------------------------------------------------------------
if [[ $SYNC_DIRECTORIES == "True" ]]; then
  echo "Syncing to remote (DELETING REMOTE BLOAT)..."
  # --delete is crucial here. It makes the remote side match your new slim local side.
  sshpass -p "$HTTP_PASSWORD" rsync -avz --delete "$REPO_ROOT/" "$HTTP_USERNAME@$HTTP_HOST:$REPO_LOCATION/debs/ubuntu"
  sshpass -p "$HTTP_PASSWORD" rsync -avz "$VCF_REPO_DIR" "$HTTP_USERNAME@$HTTP_HOST:$REPO_LOCATION/tools"
fi

echo "DONE. Your repo should now be optimized (~120GB)."
