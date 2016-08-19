#!/bin/bash
#___INFO__MARK_BEGIN__
#############################################################################
#
#  This code is the Property, a Trade Secret and the Confidential Information
#  of Univa Corporation.
#
#  Copyright Univa Corporation. All Rights Reserved. Access is Restricted.
#
#  It is provided to you under the terms of the
#  Univa Term Software License Agreement.
#
#  If you have any questions, please contact our Support Department.
#
#  www.univa.com
#
###########################################################################
#___INFO__MARK_END__

GCLOUD_CMD=gcloud

#to get around using cygwin
if [ $(uname | grep -i 'win') ]; then
	GCLOUD_CMD=gcloud.cmd
	IAM_TEMP_FILE=`mktemp -p .` || exit 1
else
	GCLOUD_CMD=gcloud
	IAM_TEMP_FILE=`mktemp -t` || exit 1
fi

#pick up project info from gcloud settings
PROJECT=$($GCLOUD_CMD info | grep project | awk '{print $2}' | sed -e "s/\\[//g;s/\\]//g")

readonly SERVICE_ACCOUNT=nextflow-installer
readonly ACCOUNT_NAME="Generated-NextFlow-Account"
SERVICE_ACCOUNT_EMAIL=${SERVICE_ACCOUNT_EMAIL:-$SERVICE_ACCOUNT@$PROJECT.iam.gserviceaccount.com}
JSON_KEY_NAME=ServiceAccount.json
EXISTING_CREDS=$SERVICE_ACCOUNT

PROJECTS_CMD="$GCLOUD_CMD beta"
IAM_CMD="$GCLOUD_CMD beta"

# The purpose of this function is to activate a service account, create one if necessary
function activate_service_account() {

    REVOKE=0
    # Set our project
    $GCLOUD_CMD config set project $PROJECT > /dev/null 2>&1

    # There is some inconsistency and latency in IAM-service accout apis.  For example if the service account is removed from IAM
    # and key file $JSON_KEY_NAME exist and used in 'auth activate-service-account $SERVICE_ACCOUNT_EMAIL --key-file $JSON_KEY_NAME'
    # then it succeeds, when it should fail as the account does not exist.  It may be consistent and robust if we simply add new account
    # and ignore-move to backup- the existing $JSON_KEY_NAME  

    mv $JSON_KEY_NAME $JSON_KEY_NAME-$(date +%Y-%m-%d:%H:%M:%S) > /dev/null 2>/dev/null

    $GCLOUD_CMD auth login --brief

    # Before we proceed make sure this is a valid project
    if ! $PROJECTS_CMD projects describe $PROJECT > /dev/null 2>&1; then
         echo "The project $PROJECT does not exist or you are not authorized to use it.  Exiting." >&2
         exit 2
    fi
    # Try getting the account again
    if $IAM_CMD iam service-accounts list 2> /dev/null | grep "$SERVICE_ACCOUNT_EMAIL" > /dev/null 2>&1; then
         # Already have an account... make a new key
         echo "Found existing $SERVICE_ACCOUNT_EMAIL account."
    else
         # Create a new account for our navops user
         echo "Creating new service account $SERVICE_ACCOUNT_EMAIL..."
         $IAM_CMD iam service-accounts create $SERVICE_ACCOUNT --display-name=$ACCOUNT_NAME > /dev/null

         # Now give the new account permissions
         echo "Adding $SERVICE_ACCOUNT_EMAIL as a project editor..."
         $PROJECTS_CMD projects get-iam-policy $PROJECT --format=json | (python update-iam-policy.py $SERVICE_ACCOUNT_EMAIL>$IAM_TEMP_FILE)
         $PROJECTS_CMD projects set-iam-policy $PROJECT $IAM_TEMP_FILE > /dev/null
    fi

    # Check if we have a key in our path that we can activate
    if ! $GCLOUD_CMD auth activate-service-account $SERVICE_ACCOUNT_EMAIL --key-file $JSON_KEY_NAME 2>/dev/null; then
        echo "Creating json key for service account $SERVICE_ACCOUNT_EMAIL..."
        $IAM_CMD iam service-accounts keys create --iam-account $SERVICE_ACCOUNT_EMAIL --key-file-type=json $JSON_KEY_NAME
    fi

    # Only revoke if we used a user account to create our new service account
    if [ $REVOKE -eq 1 ]; then
        # Revoking all accounts to get rid of user account
        $GCLOUD_CMD auth revoke --all 2> /dev/null || true

        # (Re)activate service account
        $GCLOUD_CMD auth activate-service-account $SERVICE_ACCOUNT_EMAIL --key-file $JSON_KEY_NAME
    fi
}

echo "Checking if deployment exist"
if $GCLOUD_CMD deployment-manager deployments list 2> /dev/null | grep nextflow > /dev/null 2>&1; then
	echo "Error: Deployment already exist" >&2
	exit 1
fi

echo "Creating service account and key.."
activate_service_account
rm $IAM_TEMP_FILE

echo "Creating deployment.."
$GCLOUD_CMD deployment-manager deployments create nextflow --config=nextflow.yaml

if [ $? -ne 0 ]; then
	echo " Deployment failed. ">&2
	exit 1
fi

echo "Uploading key "

ntries=0
maxtries=3
uploadok=1
while [ $ntries -lt $maxtries ]
do
	sleep 60
	$GCLOUD_CMD compute copy-files ./ServiceAccount.json unicloud-k8s-installer:/tmp 2>/dev/null
	uploadok=$?
	if [ $uploadok -ne 0 ]; then
		echo "Upload failed, trying again "
		((ntries++))
	else
		break
	fi
done 

if [ $uploadok -ne 0 ]; then
	echo "Attempts to upload service account key failed. Deleting deployment" >&2
	$GCLOUD_CMD deployment-manager deployments delete nextflow -q
	exit 1
fi

echo "Launching cluster.  Please check GCP console"
