#!/bin/bash
# create ubuntu jammy mirror
set -o pipefail
source ./config/env.config

apt update
apt install -y apt-mirror
mv /etc/apt/mirror.list /etc/apt/mirror.list-bak

# create mirror.list file
cat > /etc/apt/mirror.list << EOF
############# config ##################
#
# set base_path    /var/spool/apt-mirror
#
# set mirror_path  $base_path/mirror
# set skel_path    $base_path/skel
# set var_path     $base_path/var
# set cleanscript $var_path/clean.sh
set defaultarch  amd64
# set postmirror_script $var_path/postmirror.sh
# set run_postmirror 0
set base_path $BASTION_REPO_DIR
set nthreads     20
set _tilde 0
#
############# end config ##############

deb http://archive.ubuntu.com/ubuntu jammy main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu jammy-security main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu jammy-updates main restricted universe multiverse
# deb http://archive.ubuntu.com/ubuntu jammy-proposed main restricted universe multiverse
# deb http://archive.ubuntu.com/ubuntu jammy-backports main restricted universe multiverse
EOF

# start mirroring
apt-mirror

# fix errors
# Set the base directory
base_dir="$BASTION_REPO_DIR/mirror/archive.ubuntu.com/ubuntu/dists"
# Change to the base directory
cd $base_dir
# Download dep11 icons
for dist in jammy jammy-updates jammy-security jammy-backports; do
  for comp in main multiverse universe; do
    for size in 48 64 128; do
wget http://archive.ubuntu.com/ubuntu/dists/$dist/$comp/dep11/icons-${size}x${size}@2.tar.gz -O $dist/$comp/dep11/icons-${size}x${size}@2.tar.gz
    done
  done
done
# Change to /var/tmp directory
cd /var/tmp
# Download commands and binaries
for p in "${1:-jammy}"{,-{security,updates,backports}}/{main,restricted,universe,multiverse}; do
  >&2 echo "${p}"
  wget -q -c -r -np -R "index.html*" "http://archive.ubuntu.com/ubuntu/dists/${p}/cnf/Commands-amd64.xz"
  # wget -q -c -r -np -R "index.html*" "http://archive.ubuntu.com/ubuntu/dists/${p}/cnf/Commands-i386.xz"
  # wget -q -c -r -np -R "index.html*" "http://archive.ubuntu.com/ubuntu/dists/${p}/binary-i386/"
done
# Copy the downloaded files to the appropriate location

cp -av archive.ubuntu.com/ubuntu/ $BASTION_REPO_DIR/mirror/archive.ubuntu.com/ubuntu

#copy to http server in AG
if [[ $SYNC_DIRECTORIES == "True" ]]; then
  sshpass -p "$HTTP_PASSWORD" rsync -avz $BASTION_REPO_DIR/mirror/archive.ubuntu.com/ubuntu $HTTP_USERNAME@$HTTP_HOST:$REPO_LOCATION/ubuntu
fi
