#!/bin/bash
set -xeo pipefail
source ./config/env.config

if ! command -v jq >/dev/null 2>&1 ; then
  echo "JQ not installed. Exiting...."
  exit 1
fi

if ! command -v wget >/dev/null 2>&1 ; then
  echo "wget not installed. Exiting...."
  exit 1
fi

if ! command -v govc >/dev/null 2>&1 ; then
  echo "govc not installed. Exiting...."
  exit 1
fi

source ./config/env.config

export GOVC_URL=$VCENTER_HOSTNAME
export GOVC_USERNAME=$VCENTER_USERNAME
export GOVC_PASSWORD=$VCENTER_PASSWORD
export GOVC_INSECURE=true
export GOVC_DATASTORE=$CL_DATASTORE
export GOVC_CLUSTER=$K8S_SUP_CLUSTER
export GOVC_RESOURCE_POOL=

############################ WIP

# upload to content library VKS
results=$(govc library.ls $CL_VKS)
if [ $results > /dev/null 2>&1 ]; then
  echo "Library '$CL_VKS' already exists."
else
  # If the library does not exist, create it
  echo "Library '$CL_VKS' does not exist. Creating it..."
  govc library.create $CL_VKS

# Save original directory
pushd . > /dev/null

  cd $DOWNLOAD_VKR_OVA
  FILE_WITH_EXTENSION=$(ls *.tar.gz)
  FILENAME=${FILE_WITH_EXTENSION%.tar.gz}
  echo $FILENAME
  echo $FILE_WITH_EXTENSION
  tar xvf $FILE_WITH_EXTENSION --transform 's|.*/||'
  mv ubuntu-ova.ovf $FILENAME.ovf
  rm ubuntu-ova.mf
  echo "Importing OVF"
  govc library.import $CL_VKS $FILENAME.ovf
  echo "Cleaning up"
  find . -type f | grep -v "$FILE_WITH_EXTENSION" | xargs rm -fr

  # Go back to original directory
  popd > /dev/null
fi


# upload to content library DLVM
results=$(govc library.ls $CL_DLVM)
echo $results
if [ $results > /dev/null 2>&1 ]; then
  echo "Library '$CL_DLVM' already exists."
else
  # If the library does not exist, create it
  echo "Library '$CL_DLVM' does not exist. Creating it..."
  govc library.create $CL_DLVM
fi

# Save original directory
pushd . > /dev/null

cd $DOWNLOAD_DLVM_OVA
FILE_WITH_EXTENSION=$(ls *.ova)
FILENAME=${FILE_WITH_EXTENSION%.ova}
tar xvf $FILE_WITH_EXTENSION --transform 's|.*/||'
echo "Importing OVF"
govc library.import $CL_DLVM $FILENAME.ova
echo "Cleaning up"
find . -type f | grep -v "$FILE_WITH_EXTENSION" | xargs rm -fr

# Go back to original directory
popd > /dev/null