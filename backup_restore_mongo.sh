#!/usr/bin/env bash
#
# Copyright 2022 IBM Corporation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

set -o errexit
set -o pipefail
set -o errtrace
set -o nounset

OC=${3:-oc}
YQ=${3:-yq}
ORIGINAL_NAMESPACE=$1
TARGET_NAMESPACE=$2
function main() {
    msg "MongoDB Backup and Restore v1.0.0"
    cleanup
    prereq
    prep_backup
    backup
    prep_restore
    restore
    cleanup
}

# verify that all pre-requisite CLI tools exist and parameters set
function prereq() {
    which "${OC}" || error "Missing oc CLI"
    which "${YQ}" || error "Missing yq"
    if [[ -z $ORIGINAL_NAMESPACE ]]; then
        export ORIGINAL_NAMESPACE=ibm-common-services
    fi
    if [[ -z $TARGET_NAMESPACE ]]; then
        error "TARGET_NAMESPACE not specified, please specify target namespace parameter and try again."
    else
        ${OC} create namespace $TARGET_NAMESPACE || info "Target namespace ${TARGET_NAMESPACE} already exists. Moving on..."
    fi

    #check if files are already present on machine before trying to download (airgap)
    #TODO add clarifying messages and check response code to make more transparent
    #backup files
    info "Checking for necessary backup files..."
    if [[ -f "mongodbbackup.yaml" ]]; then
        info "mongodbbackup.yaml already present"
    else
        info "mongodbbackup.yaml not found, downloading from https://raw.githubusercontent.com/IBM/ibm-common-service-operator/scripts/velero/backup/mongoDB/mongodbbackup.yaml"
        wget -O mongodbbackup.yaml https://raw.githubusercontent.com/IBM/ibm-common-service-operator/scripts/velero/backup/mongoDB/mongodbbackup.yaml || error "Failed to download mongodbbackup.yaml"
    fi

    if [[ -f "mongo-backup.sh" ]]; then
        info "mongo-backup.sh already present"
    else
        info "mongodbbackup.yaml not found, downloading from https://raw.githubusercontent.com/IBM/ibm-common-service-operator/scripts/velero/backup/mongoDB/mongo-backup.sh"
        wget -O mongo-backup.sh https://raw.githubusercontent.com/IBM/ibm-common-service-operator/scripts/velero/backup/mongoDB/mongo-backup.sh
    fi

    #Restore files
    info "Checking for necessary restore files..."
    if [[ -f "mongodbrestore.yaml" ]]; then
        info "mongodbrestore.yaml already present"
    else
        info "mongodbrestore.yaml not found, downloading from https://raw.githubusercontent.com/IBM/ibm-common-service-operator/scripts/velero/restore/mongoDB/mongodbrestore.yaml"
        wget https://raw.githubusercontent.com/IBM/ibm-common-service-operator/scripts/velero/restore/mongoDB/mongodbrestore.yaml || error "Failed to download mongodbrestore.yaml"
    fi

    if [[ -f "set_access.js" ]]; then
        info "set_access.js already present"
    else
        info "set_access.js not found, downloading from https://raw.githubusercontent.com/IBM/ibm-common-service-operator/scripts/velero/restore/mongoDB/set_access.js"
        wget https://raw.githubusercontent.com/IBM/ibm-common-service-operator/scripts/velero/restore/mongoDB/set_access.js || error "Failed to download set_access.js"
    fi

    if [[ -f "mongo-restore.sh" ]]; then
        info "mongo-restore.sh already present"
    else
        info "set_access.js not found, downloading from https://raw.githubusercontent.com/IBM/ibm-common-service-operator/scripts/velero/restore/mongoDB/mongo-restore.sh"
        wget https://raw.githubusercontent.com/IBM/ibm-common-service-operator/scripts/velero/restore/mongoDB/mongo-restore.sh || error "Failed to download mongo-restore.sh"
    fi

    success "Prerequisites present."
}

function prep_backup() {
    title " Preparing for Mongo backup in namespace $ORIGINAL_NAMESPACE "
    msg "-----------------------------------------------------------------------"
    
    local pvx=$(${OC} get pv | grep mongodbdir | awk 'FNR==1 {print $1}')
    local storageClassName=$("${OC}" get pv -o yaml ${pvx} | yq '.spec.storageClassName' | awk '{print}')
    
    ${OC} get sc -o yaml ${storageClassName} > sc.yaml
    ${YQ} -i '.metadata.name="backup-sc" | .reclaimPolicy = "Retain"' sc.yaml || error "Error changing the name or retentionPolicy for StorageClass"
    
    info "Checking for existing backup Storage Class"
    local scExist=$(${OC} get storageclass backup-sc -o yaml || echo "failed")

    if [[ $scExist == "failed" ]]; then
        info "Creating Storage Class for backup"
        ${OC} apply -f sc.yaml || error "Error creating StorageClass backup-sc"
    else
        info "Storage Class backup-sc present from previous attempt. Moving on..."
    fi
    
    info "Creating RBAC for backup"
    cat <<EOF | tee >(oc apply -f -) | cat
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: cs-br
subjects:
- kind: ServiceAccount
  name: default
  namespace: $ORIGINAL_NAMESPACE
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
EOF
    success "Backup prep complete"
}

function backup() {
    title " Backing up MongoDB in namespace $ORIGINAL_NAMESPACE "
    msg "-----------------------------------------------------------------------"

    chmod +x mongo-backup.sh
    ./mongo-backup.sh true

    local jobPod=$(${OC} get pods -n $ORIGINAL_NAMESPACE | grep mongodb-backup | awk '{ print $1 }')
    local fileName="backup_from_${ORIGINAL_NAMESPACE}_for_${TARGET_NAMESPACE}.log"
    ${OC} logs $jobPod -n $ORIGINAL_NAMESPACE > $fileName
    info "Backup logs can be found in $fileName. Job pod will be cleaned up."

    info "Verify cs-mongodump PVC exists..."
    local return_value=$("${OC}" get pvc -n $ORIGINAL_NAMESPACE | grep cs-mongodump || echo failed)
    if [[ $return_value == "failed" ]]; then
        error "Backup PVC cs-mongodump not found"
    else
        return_value="reset"
        info "Backup PVC cs-mongodump found"
        return_value=$("${OC}" get pvc cs-mongodump -n $ORIGINAL_NAMESPACE -o yaml | yq '.spec.storageClassName' | awk '{print}')
        if [[ "$return_value" != "backup-sc" ]]; then
            error "Backup PVC cs-mongodump not bound to persistent volume provisioned by correct storage class. Provisioned by \"${return_value}\" instead of \"backup-sc\""
            #TODO probably need to handle this situation as the script may not be able to handle it as is
            #should be an edge case though as script is designed to attach to specific pv
        else
            info "Backup PVC cs-mongodump successfully bound to persistent volume provisioned by backup-sc storage class."
        fi
    fi

    success "MongoDB successfully backed up"
}

function prep_restore() {
    title " Pepare for restore in namespace $TARGET_NAMESPACE "
    msg "-----------------------------------------------------------------------"
    ${OC} get pvc -n ${ORIGINAL_NAMESPACE} cs-mongodump -o yaml > cs-mongodump-copy.yaml
    local pvx=$(${OC} get pv | grep cs-mongodump | awk '{print $1}')
    export PVX=${pvx}
    ${OC} delete job mongodb-backup -n ${ORIGINAL_NAMESPACE}
    ${OC} patch pvc -n ${ORIGINAL_NAMESPACE} cs-mongodump --type=merge -p '{"metadata": {"finalizers":null}}'
    ${OC} delete pvc -n ${ORIGINAL_NAMESPACE} cs-mongodump
    ${OC} patch pv -n ${ORIGINAL_NAMESPACE} ${pvx} --type=merge -p '{"spec": {"claimRef":null}}'
    
    #Check if the backup PV has come available yet
    #need to error handle, if a pv/pvc from a previous attempt exists in any ns it will mess this up
    #if cs-mongdump pvc already exists in the target namespace, it will break
    #Not sure if these checks are something to incorporate into the script or include in a troubleshooting section of the doc
    #On a fresh run where you don't have to worry about any existing pv or pvc, it works perfectly
    #New cleanup function running before and after completion should solve this problem
    local pvStatus=$("${OC}" get pv -o yaml ${pvx}| yq '.status.phase' | awk '{print}')
    local retries=6
    echo "PVX: ${pvx} PV status: ${pvStatus}"
    while [ $retries != 0 ]
    do
        if [[ "${pvStatus}" != "Available" ]]; then
            retries=$(( $retries - 1 ))
            info "Persitent Volume ${pvx} not available yet. Retries left: ${retries}. Waiting 30 seconds..."
            sleep 30s
            pvStatus=$("${OC}" get pv -o yaml ${pvx}| yq '.status.phase' | awk '{print}')
            echo "PVX: ${pvx} PV status: ${pvStatus}"
        else
            info "Persitent Volume ${pvx} available. Moving on..."
            break
        fi
    done

    #edit the cs-mongodump-copy.yaml pvc file and apply it in the target namespace
    export TARGET_NAMESPACE=$TARGET_NAMESPACE
    ${YQ} -i '.metadata.namespace=strenv(TARGET_NAMESPACE)' cs-mongodump-copy.yaml
    ${OC} apply -f cs-mongodump-copy.yaml
    
    #Check PV status to make sure it binds to the right PVC
    #If more than one pv provisioned by the sc created in this script exists, this part will break as it lists all of the pvs provisioned by backup-sc as $PVX
    pvStatus=$("${OC}" get pv -o yaml ${pvx}| yq '.status.phase' | awk '{print}')
    retries=6
    while [ $retries != 0 ]
    do
        if [[ "${pvStatus}" != "Bound" ]]; then
            retries=$(( $retries - 1 ))
            info "Persitent Volume ${pvx} not bound yet. Retries left: ${retries}. Waiting 30 seconds..."
            sleep 30s
            pvStatus=$("${OC}" get pv -o yaml ${pvx}| yq '.status.phase' | awk '{print}')
        else
            info "Persitent Volume ${pvx} bound. Checking PVC..."
            boundPV=$("${OC}" get pvc cs-mongodump -n ${TARGET_NAMESPACE} -o yaml | yq '.spec.volumeName' | awk '{print}')
            if [[ "${boundPV}" != "${pvx}" ]]; then
                error "Error binding cs-mongodump PVC to backup PV ${pvx}. Bound to ${boundPV} instead."
            else
                info "PVC cs-mongodump successfully bound to backup PV ${pvx}"
                break
            fi
        fi
    done

    success "Preparation for Restore completed successfully."
    
}

function restore () {
    title " Restore copy of backup in namespace $TARGET_NAMESPACE "
    msg "-----------------------------------------------------------------------"
    #export csnamespace to reflect the new target namespace
    #restore script is setup to look for CS_NAMESPACE and is used in other backup/restore processes unrelated to this script
    export CS_NAMESPACE=$TARGET_NAMESPACE

    chmod +x mongo-restore.sh
    ./mongo-restore.sh

    local jobPod=$(${OC} get pods -n $TARGET_NAMESPACE | grep mongodb-restore | awk '{ print $1 }')
    local fileName="restore_to_${TARGET_NAMESPACE}_from_${ORIGINAL_NAMESPACE}.log"
    ${OC} logs $jobPod -n $TARGET_NAMESPACE > $fileName
    info "Restore logs can be found in $fileName. Job pod will be cleaned up."

    success "Restore completed successfully in namespace $TARGET_NAMESPACE"

}

function cleanup(){
    title " Cleaning up resources created during backup restore process "
    msg "-----------------------------------------------------------------------"
    
    info "Deleting pvc and pv used in backup restore process"
    
    #clean up backup resources
    local return_value=$("${OC}" get pvc -n $ORIGINAL_NAMESPACE | grep cs-mongodump || echo failed)
    if [[ $return_value != "failed" ]]; then
    #delete backup items in original namespace
        ${OC} delete job mongodb-backup -n ${ORIGINAL_NAMESPACE} || info "Backup job already deleted. Moving on..."
        ${OC} patch pvc cs-mongodump -n $ORIGINAL_NAMESPACE --type=merge -p '{"metadata": {"finalizers":null}}'
        ${OC} delete pvc cs-mongodump -n $ORIGINAL_NAMESPACE
    else
        info "Resources used in backup already cleaned up. Moving on..."
    fi

    #clean up restore resources
    local return_value=$("${OC}" get pvc -n $TARGET_NAMESPACE | grep cs-mongodump || echo failed)
    if [[ $return_value != "failed" ]]; then
    #delete retore items in target namespace
        local boundPV=$(${OC} get pvc cs-mongodump -n $TARGET_NAMESPACE -o yaml | yq '.spec.volumeName' | awk '{print}')
        ${OC} delete job mongodb-restore -n ${TARGET_NAMESPACE} || info "Restore job already deleted. Moving on..."
        ${OC} patch pvc cs-mongodump -n $TARGET_NAMESPACE --type=merge -p '{"metadata": {"finalizers":null}}'
        ${OC} delete pvc cs-mongodump -n $TARGET_NAMESPACE
        ${OC} patch pv $boundPV --type=merge -p '{"metadata": {"finalizers":null}}'
        ${OC} delete pv $boundPV
    else
        info "Resources used in restore already cleaned up. Moving on..."
    fi

    local rbac=$(${OC} get clusterrolebinding cs-br -n $ORIGINAL_NAMESPACE || echo failed)
    if [[ $rbac != "failed" ]]; then
        info "Deleting RBAC from backup restore process"
        ${OC} delete clusterrolebinding cs-br -n $ORIGINAL_NAMESPACE
    fi

    local scExist=$(${OC} get sc backup-sc -n $ORIGINAL_NAMESPACE || echo failed)
    if [[ $scExist != "failed" ]]; then
        info "Deleting storage class used in backup restore process"
        ${OC} delete sc backup-sc
    fi

    success "Cleanup complete."

}

function msg() {
    printf '%b\n' "$1"
}

function success() {
    msg "\33[32m[✔] ${1}\33[0m"
}

function error() {
    msg "\33[31m[✘] ${1}\33[0m"
    exit 1
}

function title() {
    msg "\33[34m# ${1}\33[0m"
}

function info() {
    msg "[INFO] ${1}"
}

# --- Run ---

main $*