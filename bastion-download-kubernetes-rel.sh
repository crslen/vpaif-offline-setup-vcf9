#!/bin/bash
set -o pipefail
source ./config/env.config

if ! command -v jq >/dev/null 2>&1 ; then
  echo "JQ not installed. Exiting...."
  exit 1
fi
if ! command -v wget >/dev/null 2>&1 ; then
  echo "wget not installed. Exiting...."
  exit 1
fi

# Create the download directory if it doesn't exist
mkdir -p "$DOWNLOAD_VKR_OVA"
mkdir -p "$DOWNLOAD_DLVM_OVA"

echo
echo "The VMware subscribed content library has the following Kubernetes Release images ... "
echo
curl -s https://wp-content.vmware.com/v2/latest/items.json |jq -r '.items[]| .created + "\t" + .name'|sort

echo
echo "The list shown above is sorted by release date with the corrosponding names of the"
echo "Kubernetes Release in the second column."
read -p "Enter the name of the Kubernetes Release OVA that you want to download and zip for offline upload: " tkgrimage

echo
echo "Downloading all files for the TKG image: ${tkgrimage} ..."
echo
wget -q --show-progress --no-parent -r -nH --cut-dirs=2 --reject="index.html*" https://wp-content.vmware.com/v2/latest/"${tkgrimage}"/

echo "Compressing downloaded files..."
tar -cvzf "${tkgrimage}".tar.gz "${tkgrimage}"


echo
echo "Cleaning up..."
[ -d "${tkgrimage}" ] && rm -rf "${tkgrimage}"
mv "${tkgrimage}".tar.gz "${DOWNLOAD_VKR_OVA}" 

# copy tar/yaml to admin host
if [[ $SYNC_DIRECTORIES == "True" ]]; then
  sshpass -p "$HTTP_PASSWORD" rsync -avz {kubernetes-releases-ova,dlvm-releases-ova} $HTTP_USERNAME@$HTTP_HOST:$ADMIN_RESOURCES_DIR
fi
