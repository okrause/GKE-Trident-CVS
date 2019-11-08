#!/bin/bash

if [ "$CLOUD_SHELL" != true ]; then
    echo "Please run from Google Cloud Shell."
    exit 1
fi

# Change here for different service account name
service_account_name="cvs-api-sa"

PROJECT_ID=$(gcloud config list --format 'value(core.project)')
SA_EMAIL="${service_account_name}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "Going to create service account: ${service_account_name} in project: ${PROJECT_ID}"
echo "Press enter to proceed, or CTRL-C to abort."

read dummy

# Create new service account
gcloud beta iam service-accounts create ${service_account_name} \
    --description "Admin SA for CVS API access" \
    --display-name ${service_account_name}

# Bind service account to netappcloudvolumes.admin role
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member="serviceAccount:${SA_EMAIL}" \
    --role='roles/netappcloudvolumes.admin'

# Retrieve key for service account
gcloud iam service-accounts keys create ${service_account_name}.json --iam-account ${SA_EMAIL}

echo "Your key file is: $(pwd)/${service_account_name}.json"