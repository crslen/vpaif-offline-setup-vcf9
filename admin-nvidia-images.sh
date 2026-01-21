#!/bin/bash
set -o pipefail
source ./config/env.config
mapfile -t container_images < <(jq -r '.containers[]' './config/images.json')
mapfile -t helm_charts < <(jq -r '.helm[]' './config/images.json')
mapfile -t llm < <(jq -c '.models.llm[]' './config/images.json')
mapfile -t embedding < <(jq -c '.models.embedding[]' './config/images.json')

# update docker to ignore harbor self-signed cert
sudo jq ". += {\"insecure-registries\":[\"${PLATFORM_REGISTRY}\"]}" /etc/docker/daemon.json > /tmp/temp.json && sudo mv /tmp/temp.json /etc/docker/daemon.json
sudo systemctl restart docker

# update certificate to ignore hrbor self-signed cert
mkdir -p certificates
openssl s_client -showcerts -servername $PLATFORM_REGISTRY -connect $PLATFORM_REGISTRY:443 </dev/null | sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' > ./certificates/$PLATFORM_REGISTRY.crt
sudo cp ./certificates/$PLATFORM_REGISTRY.crt /usr/local/share/ca-certificates/$PLATFORM_REGISTRY.crt
sudo update-ca-certificates

docker login ${PLATFORM_REGISTRY} -u "$PLATFORM_REGISTRY_USERNAME" -p "$PLATFORM_REGISTRY_PASSWORD"

# push images using vcf imgpkg
for image in "${container_images[@]}"; do
    echo $image
    image_name=$(echo "$image" | sed 's|.*/||;s|:.*||')
    tmp="${image%%@*}"
	image_upload="${tmp%:*}"
    echo "==> Start to push container file: $image_upload"
	# full_filename=$(basename "$file")
	# file_name="${full_filename%.tar}"
    newurl="$PLATFORM_REGISTRY"/"${image_upload#*/}"
    echo $newurl
    vcf imgpkg copy --tar "${DOWNLOAD_DIR_NVD_TAR}"/"$image_name".tar --to-repo $newurl --cosign-signatures --registry-ca-cert-path ./certificates/$PLATFORM_REGISTRY.crt --registry-username "${REGISTRY_USERNAME}" --registry-password "${REGISTRY_PASSWORD}"
done

# helm gpu-operator charts
for image in "${helm_charts[@]}"; do
    filename=""
    # echo "==> Pulling helm charts... $image"
    # helm fetch "$image" --destination "./resources" --username='$oauthtoken' --password="$NGC_API_KEY"

    # if [ $? -ne 0 ]; then
    #     pulling_error_message="$pulling_error_message\nFailed to download helm chart: $image"
    # fi
    filename=$(basename "$image")
    target=oci://"$PLATFORM_REGISTRY"/charts
    echo "==> Pushing helm chart $filename to $target"
	helm push "./resources/$filename" "$target" --insecure-skip-tls-verify --username "$PLATFORM_REGISTRY_USERNAME" --password "$PLATFORM_REGISTRY_PASSWORD"
done

# LLM model profiles
llm_output=()
for m in "${llm[@]}"; do
    name=$(echo "$m" | jq -r '.name')
    uri=$(echo "$m" | jq -r '.uri')

    profiles=$(echo "$m" | jq -c '.profiles[]')
    for profile in $profiles; do
        profile_name=$(echo "$profile" | jq -r '.profile_name')
        profile_id=$(echo "$profile" | jq -r '.profile_id')
        llm_output+=("$name, $uri, $profile_name, $profile_id")
    done
done

# Embedding model profiles
emb_output=()
for m in "${embedding[@]}"; do
    name=$(echo "$m" | jq -r '.name')
    uri=$(echo "$m" | jq -r '.uri')

    profiles=$(echo "$m" | jq -c '.profiles[]')
    for profile in $profiles; do
        profile_name=$(echo "$profile" | jq -r '.profile_name')
        profile_id=$(echo "$profile" | jq -r '.profile_id')
        emb_output+=("$name, $uri, $profile_name, $profile_id")
    done
done

# Push LLM files.
working_dir=$(pwd)
for item in "${llm_output[@]}"; do
    IFS=', ' read -r image_name uri profile_name profile_id <<< "$item"

    local_model_store_path="$working_dir/$BASTION_RESOURCES_DIR/$image_name/$profile_name"_model

    if [[ ! -d "$local_model_store_path" ]]; then
        echo "File not found: $local_model_store_path"
        continue
    fi
    cd "$local_model_store_path" || exit
    echo "==> Pushing model: $local_model_store_path to model store: \
        $PLATFORM_REGISTRY/model-store/$image_name/$profile_name"
    vcf pais models push --modelName "$image_name/$profile_name" --modelStore "$PLATFORM_REGISTRY/model-store" -t v1
done

# Push embedding tar file.
for item in "${emb_output[@]}"; do
    IFS=', ' read -r image_name uri profile_name profile_id <<< "$item"

    local_model_store_path="$working_dir/$BASTION_RESOURCES_DIR/$image_name/$profile_name"

    if [[ ! -d "$local_model_store_path" ]]; then
        echo "File not found: $local_model_store_path"
        continue
    fi
    cd "$local_model_store_path" || exit
    echo "==> Pushing model: $local_model_store_path  to model store: \
        $PLATFORM_REGISTRY/model-store/$image_name/$profile_name"
    vcf pais models push --modelName "$image_name/$profile_name" --modelStore "$PLATFORM_REGISTRY/model-store" -t v1
done

# todo - add push llm and embed (need pais)
