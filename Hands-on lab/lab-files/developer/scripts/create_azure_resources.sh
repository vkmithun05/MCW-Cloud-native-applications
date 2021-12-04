#!/bin/bash

function replace_json_field {
    tmpfile=/tmp/tmp.json; cp $1 "$tmpfile" && jq --arg mcwField "$2" --arg mcwValue "$3" '$mcwField |= $mcwValue' "$tmpfile" > $1 && mv "$tmpfile" $1 && rm -f "$tmpfile"
}

# Check if SUFFIX envvar exists
if [[ -z "${MCW_SUFFIX}" ]]; then
    echo "Please set the MCW_SUFFIX environment variable to a unique three character string."
    exit 1
fi

if [[ -z "${MCW_GITHUB_USERNAME}" ]]; then
    echo "Please set the MCW_GITHUB_USERNAME environment variable to your Github Username"
    exit 1
fi

if [[ -z "${MCW_GITHUB_TOKEN}" ]]; then
    echo "Please set the MCW_GITHUB_TOKEN environment variable to your Github Token"
    exit 1
fi

if [[ -z "${MCW_GITHUB_URL}" ]]; then
    MCW_GITHUB_URL=https://github.com/$MCW_GITHUB_USERNAME/Fabmedical
fi

if [[ -z "${MCW_PRIMARY_LOCATION}" ]]; then
    MCW_PRIMARY_LOCATION="eastus"
    MCW_PRIMARY_LOCATION_NAME="East US"
fi

if [[ -z "${MCW_SECONDARY_LOCATION}" ]]; then
    MCW_SECONDARY_LOCATION="westus"
    MCW_SECONDARY_LOCATION_NAME="West US"
fi

cd ~
mkdir -p ~/bin

# Install the git-credential-env npm package
npm install git-credential-env
ln -s ~/node_modules/git-credential-env/helper.js ~/bin/git-credential-env

# Install the github-secrets-cli npm package
npm install @anomalyhq/github-secrets-cli
ln -s ~/node_modules/@anomalyhq/github-secrets-cli/bin/run ~/bin/ghs

# Create resource group
az group create -l "${MCW_PRIMARY_REGION}" -n "fabmedical-${MCW_SUFFIX}"

# Create SSH key
if [[ ! -e ~/.ssh ]]; then
    mkdir ~/.ssh
fi

ssh-keygen -t RSA -b 2048 -C admin@fabmedical -N "" -f ~/.ssh/fabmedical

SSH_PUBLIC_KEY=$(cat ~/.ssh/fabmedical.pub)

# Create Fabmedical repository
if [[ ! -e ~/Fabmedical ]]; then
    mkdir ~/Fabmedical
    cd ~/Fabmedical
    cp -r ~/MCW-Cloud-native-applications/Hands-on\ lab/lab-files/developer/* ./
fi

# Committing repository
cd ~/Fabmedical
git init
git add .
git commit -m "Initial Commit"
git remote add origin $MCW_GITHUB_URL
git config --global credential.helper "env --username=MCW_GITHUB_USERNAME --password=MCW_GITHUB_TOKEN"
git branch -m master main
git push -u origin main

# Configuring github workflows
cd ~/Fabmedical
sed -i "s/\[SUFFIX\]/$MCW_SUFFIX/g" ./.github/workflows/content-init.yml
sed -i "s/\[SUFFIX\]/$MCW_SUFFIX/g" ./.github/workflows/content-api.yml
sed -i "s/\[SUFFIX\]/$MCW_SUFFIX/g" ./.github/workflows/content-web.yml

# Configure ARM deployment
cd ~/Fabmedical/scripts
replace_json_field "azuredeploy.parameters.json" .parameters.Suffix.value $MCW_SUFFIX
replace_json_field "azuredeploy.parameters.json" .parameters.VirtualMachineAdminPublicKeyLinux.value $SSH_PUBLIC_KEY
replace_json_field "azuredeploy.parameters.json" .parameters.CosmosLocation.value $MCW_PRIMARY_LOCATION
replace_json_field "azuredeploy.parameters.json" .parameters.CosmosLocationName.value $MCW_PRIMARY_LOCATION_NAME
replace_json_field "azuredeploy.parameters.json" .parameters.CosmosPairedLocation.value $MCW_SECONDARY_LOCATION
replace_json_field "azuredeploy.parameters.json" .parameters.CosmosPairedLocationName.value $MCW_SECONDARY_LOCATION_NAME

# Create ARM deployment
az deployment group create --resource-group fabmedical-$MCW_SUFFIX --template-file ./azuredeploy.json --parameters azuredeploy.parameters.json

# Get ACR credentials and add them as secrets to Github
ACR_CREDENTIALS=$(az acr credential show -n fabmedical$MCW_SUFFIX)
ACR_USERNAME=$(jq -r -n '$input.username' --argjson input "$ACR_CREDENTIALS")
ACR_PASSWORD=$(jq -r -n '$input.passwords[0].value' --argjson input "$ACR_CREDENTIALS")
AZURE_CREDENTIALS=$(az ad sp create-for-rbac --sdk-auth)
ghs secrets:set --input="$ACR_USERNAME" --org="$MCW_GITHUB_USERNAME" --repo="Fabmedical" --secret="ACR_USERNAME" -t="$MCW_GITHUB_TOKEN"
ghs secrets:set --input="$ACR_PASSWORD" --org="$MCW_GITHUB_USERNAME" --repo="Fabmedical" --secret="ACR_PASSWORD" -t="$MCW_GITHUB_TOKEN"
ghs secrets:set --input="$AZURE_CREDENTIALS" --org="$MCW_GITHUB_USERNAME" --repo="Fabmedical" --secret="AZURE_CREDENTIALS" -t="$MCW_GITHUB_TOKEN"

# Get public IP of build agent VM
VM_PUBLIC_IP=$(az vm show -d -g fabmedical-$MCW_SUFFIX -n fabmedical-$MCW_SUFFIX --query publicIps -o tsv)
echo "Command to create an active session to the build agent VM:"
echo ""
echo "    ssh -i .ssh/fabmedical adminfabmedical@$VM_PUBLIC_IP"
