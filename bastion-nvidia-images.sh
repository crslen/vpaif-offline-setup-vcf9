#!/bin/bash
set -o pipefail
source ./config/env.config
mapfile -t container_images < <(jq -r '.containers[]' './config/images.json')
mapfile -t helm_charts < <(jq -r '.helm[]' './config/images.json')
mapfile -t llm < <(jq -c '.models.llm[]' './config/images.json')
mapfile -t embedding < <(jq -c '.models.embedding[]' './config/images.json')

# update docker to ignore harbor self-signed cert
sudo jq ". += {\"insecure-registries\":[\"${BOOTSTRAP_REGISTRY}\"]}" /etc/docker/daemon.json > /tmp/temp.json && sudo mv /tmp/temp.json /etc/docker/daemon.json
sudo systemctl restart docker

# update certificate to ignore hrbor self-signed cert
openssl s_client -showcerts -servername $BOOTSTRAP_REGISTRY -connect $BOOTSTRAP_REGISTRY:443 </dev/null | sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' > ./certificates/$BOOTSTRAP_REGISTRY.crt
sudo cp ./certificates/$BOOTSTRAP_REGISTRY.crt /usr/local/share/ca-certificates/$BOOTSTRAP_REGISTRY.crt
sudo update-ca-certificates

docker login ${BOOTSTRAP_REGISTRY} -u "$BOOTSTRAP_REGISTRY_USERNAME" -p "$BOOTSTRAP_REGISTRY_PASSWORD"
docker login nvcr.io -u '$oauthtoken' -p "$NGC_API_KEY"

# pull images using docker
for image in "${container_images[@]}"; do
    echo "==> Start to pull container image: $image"
    image_name=$(echo "$image" | sed 's|.*/||;s|:.*||')
    if [ ! -f "$DOWNLOAD_DIR_NVD_TAR"/"$image_name".tar ]; then
        vcf imgpkg copy -i "$image" --to-tar "$DOWNLOAD_DIR_NVD_TAR"/"$image_name".tar --cosign-signatures
    fi
done

# helm gpu-operator chart
for image in "${helm_charts[@]}"; do
    filename=""
    echo "==> Pulling helm charts... $image"
    helm fetch "$image" --destination "./resources" --username='$oauthtoken' --password="$NGC_API_KEY"

    if [ $? -ne 0 ]; then
        pulling_error_message="$pulling_error_message\nFailed to download helm chart: $image"
    fi
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

# Pull all LLM model files
mkdir $BASTION_RESOURCES_DIR
for item in "${llm_output[@]}"; do
    IFS=', ' read -r image_name uri profile_name profile_id <<< "$item"

    local_model_cache_path="$BASTION_RESOURCES_DIR/$image_name/$profile_name"_cache
    local_model_store_path="$BASTION_RESOURCES_DIR/$image_name/$profile_name"_model

    echo "==> Pulling model: $image_name profile: $profile_name to $local_model_cache_path"

    docker run -it --rm --name="$image_name" \
        -v "$local_model_cache_path":/opt/nim/.cache \
        -v "$local_model_store_path":/model-repo \
        -e NGC_API_KEY="$NGC_API_KEY" \
        -e NIM_CPU_ONLY=1 \
        $( [ -n "$HTTP_PROXY" ] && [ -n "$HTTPS_PROXY" ] && echo " -e http_proxy=$HTTP_PROXY -e https_proxy=$HTTPS_PROXY -e no_proxy=$NO_PROXY" ) \
        -u "$(id -u)" \
        "$uri" \
        bash -c "create-model-store --profile $profile_id --model-store /model-repo"
    if [ $? -ne 0 ]; then
        pulling_error_message="$pulling_error_message\nFailed to download model profile: $profile_name"
    fi
done

working_dir=$(pwd)

# Pull all embedding model files
cd $working_dir
for item in "${emb_output[@]}"; do
    IFS=', ' read -r image_name uri profile_name profile_id <<< "$item"

    local_model_cache_path="$BASTION_RESOURCES_DIR/$image_name/$profile_name"_cache
    local_model_store_path="$BASTION_RESOURCES_DIR/$image_name/$profile_name"_model

    mkdir -p $local_model_cache_path
    mkdir -p $local_model_store_path

    echo "==> Pulling model: $image_name profile: $profile_name to $local_model_cache_path"
    docker run -it --rm --name="$image_name" \
        -v "$local_model_cache_path":/opt/nim/.cache \
        -v "$local_model_store_path":/model-repo \
        -e NGC_API_KEY="$NGC_API_KEY" \
        -e NIM_CPU_ONLY=1 \
        $( [ -n "$HTTP_PROXY" ] && [ -n "$HTTPS_PROXY" ] && echo " -e http_proxy=$HTTP_PROXY -e https_proxy=$HTTPS_PROXY -e no_proxy=$NO_PROXY" ) \
        -u "$(id -u)" \
        "$uri" \
        bash -c "download-to-cache --profile $profile_id"

    if [ $? -ne 0 ]; then
        pulling_error_message="$pulling_error_message\nFailed to download model profile: $profile_name"
    fi

    # tar all embedding model files
    path="$BASTION_RESOURCES_DIR/$profile_name.tgz"
    tar -czvf $path $local_model_cache_path
    mkdir -p "$BASTION_RESOURCES_DIR/$image_name/$profile_name"
    mv $path "$BASTION_RESOURCES_DIR/$image_name/$profile_name"
    echo "Archived: $path"
done
