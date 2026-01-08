#!/bin/bash
# create ubuntu jammy mirror
set -o pipefail

# Ensure configuration is loaded
if [ -f "./config/env.config" ]; then
    source ./config/env.config
else
    echo "Error: ./config/env.config not found."
    exit 1
fi

echo "Updating apt and installing apt-mirror..."
apt update
apt install -y apt-mirror

# Backup existing mirror list
if [ -f "/etc/apt/mirror.list" ]; then
    mv /etc/apt/mirror.list /etc/apt/mirror.list-bak
fi

# Create mirror.list file with 64-bit (amd64) restriction
cat > /etc/apt/mirror.list << EOF
############# config ##################
#
set base_path $BASTION_REPO_DIR
set nthreads     20
set _tilde 0
# Force 64-bit architecture
set defaultarch amd64
#
############# end config ##############

deb http://archive.ubuntu.com/ubuntu jammy main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu jammy-security main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu jammy-updates main restricted universe multiverse
#deb http://archive.ubuntu.com/ubuntu jammy-proposed main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu jammy-backports main restricted universe multiverse
EOF

echo "Starting apt-mirror..."
apt-mirror

# Fix errors / Manual Downloads
echo "Running manual fixes for icons and CNF metadata..."

# Set the base directory for icons
base_dir="$BASTION_REPO_DIR/mirror/archive.ubuntu.com/ubuntu/dists"

# Download dep11 icons
# Ensure the directory exists before entering
if [ -d "$base_dir" ]; then
    cd $base_dir
    for dist in jammy jammy-updates jammy-security jammy-backports; do
      for comp in main multiverse universe; do
        # Ensure target directory exists
        mkdir -p "$dist/$comp/dep11"
        for size in 48 64 128; do
            wget -q "http://archive.ubuntu.com/ubuntu/dists/$dist/$comp/dep11/icons-${size}x${size}@2.tar.gz" -O "$dist/$comp/dep11/icons-${size}x${size}@2.tar.gz"
        done
      done
    done
else
    echo "Warning: Mirror directory $base_dir not found. Skipping icon download."
fi

# Change to /var/tmp directory for temp downloads
cd /var/tmp

# Download commands and binaries (AMD64 ONLY)
# Removed i386 commands and binary-i386 folders
for p in "${1:-jammy}"{,-{security,updates,backports}}/{main,restricted,universe,multiverse}; do
  >&2 echo "Processing: ${p}"
  wget -q -c -r -np -R "index.html*" "http://archive.ubuntu.com/ubuntu/dists/${p}/cnf/Commands-amd64.xz"
done

# Copy the downloaded files to the appropriate location
echo "Copying manual downloads to repo..."
cp -av archive.ubuntu.com/ubuntu/ "$BASTION_REPO_DIR/mirror/archive.ubuntu.com/ubuntu"

# Copy to http server in AG
if [[ $SYNC_DIRECTORIES == "True" ]]; then
  echo "Syncing to remote server..."
  sshpass -p "$HTTP_PASSWORD" rsync -avz "$BASTION_REPO_DIR/mirror/archive.ubuntu.com/ubuntu" "$HTTP_USERNAME@$HTTP_HOST:$REPO_LOCATION/debs"
fi

echo "Mirror sync complete."