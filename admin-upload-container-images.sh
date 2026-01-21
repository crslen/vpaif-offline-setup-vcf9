#!/bin/bash
set -o pipefail
source ./config/env.config

# The main code
if [ "$1" == "bootstrap" ]; then
	echo "Bootstrap Supervisor Services"
	REGISTRY_NAME=${BOOTSTRAP_REGISTRY}
	REGISTRY_IP=${BOOTSTRAP_REGISTRY_IP}
	REGISTRY_URL=${BOOTSTRAP_REGISTRY}/${BOOTSTRAP_SUPSVC_REPO}
	REGISTRY_URL1=${BOOTSTRAP_REGISTRY}/${PLATFORM_VCFPKG_REPO}
	REGISTRY_USERNAME=${BOOTSTRAP_REGISTRY_USERNAME}
	REGISTRY_PASSWORD=${BOOTSTRAP_REGISTRY_PASSWORD}
elif [ "$1" == "platform" ]; then
	echo "Platform Supervisor Services"
	REGISTRY_NAME=${PLATFORM_REGISTRY}
	REGISTRY_IP=${PLATFORM_REGISTRY_IP}
	REGISTRY_URL=${PLATFORM_REGISTRY}/${PLATFROM_SUPSVC_REPO}
	REGISTRY_URL1=${PLATFORM_REGISTRY}/${PLATFORM_VCFPKG_REPO}
	REGISTRY_USERNAME=${PLATFORM_REGISTRY_USERNAME}
	REGISTRY_PASSWORD=${PLATFORM_REGISTRY_PASSWORD}
fi

# upload vcf cli plugin to harbor
# vcf imgpkg copy --tar "$DOWNLOAD_DIR_BIN"/plugins.tar.gz --to-repo "${REGISTRY_URL1}" --cosign-signatures --registry-username "${REGISTRY_USERNAME}" --registry-password "${REGISTRY_PASSWORD}"
# vcf plugin upload-bundle --tar "$DOWNLOAD_DIR_BIN"/plugins.tar.gz --to-repo "${REGISTRY_URL1}"

IPs=$(getent hosts "${REGISTRY_NAME}" | awk '{ print $1 }')
if [[ -z "${IPs}" ]]; then
	echo "Error: Could not resolve the IP address for ${REGISTRY_NAME}. Please validate!!"
	exit 1
fi

found=false
for ip in "${IPs[@]}"; do
  	if [[ "$ip" == "${REGISTRY_IP}" ]]; then
		found=true
		break
  	fi
done

if [ "$found" = false ]; then
  	echo "Error: Could not resolve the IP address ${REGISTRY_IP} for ${REGISTRY_NAME}. Please validate!!"
  	exit 1
fi

# get certificate from harbor
openssl s_client -showcerts -servername $REGISTRY_NAME -connect $REGISTRY_NAME:443 </dev/null | sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' > ./certificates/$REGISTRY_NAME.crt

HEADER_CONTENTTYPE="Content-Type: application/json"
################################################
# Login to VCenter and get Session ID
###############################################
SESSION_ID=$(curl -sk -X POST https://${VCENTER_HOSTNAME}/api/session --user ${VCENTER_USERNAME})
if [ -z "${SESSION_ID}" ]
then
	echo "Error: Could not connect to the VCenter. Please validate!!"
	exit 1
fi
echo Authenticated successfully to VC with Session ID - "${SESSION_ID}" ...
HEADER_SESSIONID="vmware-api-session-id: ${SESSION_ID}"

# ################################################
# # Get Supervisor details from vCenter
# ###############################################
# echo "Searching for Supervisor on Cluster ${K8S_SUP_CLUSTER} ..."
# response=$(curl -ks --write-out "%{http_code}" --output /tmp/temp_cluster.json -X GET -H "${HEADER_SESSIONID}" https://"${VCENTER_HOSTNAME}"/api/vcenter/namespace-management/supervisors/summaries?config_status=RUNNING&kubernetes_status=READY)
# if [[ "${response}" -ne 200 ]] ; then
#   	echo "Error: Could not fetch clusters. Please validate!!"
# 	exit 1
# fi

# SUPERVISOR_ID=$(jq -r --arg K8S_SUP_CLUSTER "$K8S_SUP_CLUSTER" '.items[] | select(.info.name == $K8S_SUP_CLUSTER) | .supervisor' /tmp/temp_cluster.json)
# if [ -z "${SUPERVISOR_ID}" ]
# then
# 	echo "Error: Could not find the Supervisor Cluster ${K8S_SUP_CLUSTER}. Please validate!!"
# 	exit 1
# fi

# ################################################
# # Add the registry to the vCenter
# ###############################################
# echo "Found Supervisor Cluster ${K8S_SUP_CLUSTER} with Supervisor ID - ${SUPERVISOR_ID} ..."
# export REGISTRY_CACERT=$(jq -sR . "${REGISTRY_CERT_FOLDER}"/"${REGISTRY_NAME}".crt)
# export REGISTRY_NAME
# export REGISTRY_PASSWORD
# export REGISTRY_USERNAME

# envsubst < ./config/registry-spec.json > temp_registry.json
# echo "Adding Registry ${REGISTRY_NAME} to ${VCENTER_HOSTNAME} ..."
# response=$(curl -ks --write-out "%{http_code}" --output /tmp/status.json  -X POST -H "${HEADER_SESSIONID}" -H "${HEADER_CONTENTTYPE}" -d "@temp_registry.json" https://"${VCENTER_HOSTNAME}"/api/vcenter/namespace-management/supervisors/"${SUPERVISOR_ID}"/container-image-registries)
# echo $response
# if [[ "${response}" -ne 200 ]] ; then
# 	echo "Error: Could not add registry to Supervisor. This may happen if the registry has been previously added. Please validate!!"
# fi
echo $DOWNLOAD_DIR_YML

for file in "${DOWNLOAD_DIR_YML}"/*.y*ml; do
	echo $file
	full_filename=$(basename "$file")
	file_name="${full_filename%.y*ml}"
	# stripped=$(echo -n "$file_name" | sed 's/supsvc-//g') # strip the supsvc- from filename
    image=$(yq -P '(.|select(.kind == "Package").spec.template.spec.fetch[].imgpkgBundle.image)' "$file")
	tmp="${image%%@*}"
	image_upload="${tmp%:*}"

    if [ "$image" ];then
		if [[ "$image" == *"${REGISTRY_URL}"* ]]; then
			echo Now uploading "${DOWNLOAD_DIR_TAR}"/"$file_name".tar to "${image_upload}"
			vcf imgpkg copy --tar "${DOWNLOAD_DIR_TAR}"/"$file_name".tar --to-repo $image_upload --cosign-signatures --registry-ca-cert-path ./certificates/$REGISTRY_NAME.crt --registry-username "${REGISTRY_USERNAME}" --registry-password "${REGISTRY_PASSWORD}"
		fi
	fi
done

# Install nginx
cd $NGINX_OFFLINE
sudo dpkg -i *.deb
################################################
# setup nginx
################################################
sudo cat > /etc/nginx/conf.d/mirror.conf << EOF
server {
 listen 80;
 server_name $HTTP_HOST;
 root $REPO_LOCATION/ubuntu/mirror/archive.ubuntu.com/ubuntu;

location / {
	# Enables directory listing so apt can browse the files
	autoindex on;
	autoindex_exact_size off;
	autoindex_localtime on;

	# Optional: Prevents caching of package metadata
	add_header Cache-Control "no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0";
}
}
EOF
sudo systemctl restart nginx

################################################
# copy the kubernetes deployment files to the 
# nginx location to be downloaded during deployments.
################################################
# cp gpu-operator/gpu-operator* $REPO_LOCATION/debs/