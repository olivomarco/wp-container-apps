#!/bin/bash

# fail script if something fails
set -o pipefail
set -e
# print out all commands executed (for debugging purposes)
set -x

# set some variables
id=$(shuf -i 0-10000 -n 1)
RG_NAME=rg-wordpress-$id
LOCATION=westeurope
CONTAINERAPP_ENV=wordpress-env-$id
CONTAINERAPP=wordpress
IMAGE_NAME=demo/wordpress:latest
ACR_NAME=acrwordpressdemo$id
WORDPRESS_USERNAME=wpuser
WORDPRESS_PASSWORD=$(tr -dc 'A-Za-z0-9!"#$%&'\''()*+,-./:;<=>?@[\]^_`{|}~' < /dev/urandom | head -c 15 ; echo)
MYSQL_SERVER_NAME=wordpressmysql-$id
STORAGE_NAME=sawordpress$id

# create rg
az group create --name $RG_NAME --location $LOCATION

# create vnet and 2 subnets (one for Wordpress and one for our DB)
az network vnet create --name vnet-wordpress --resource-group $RG_NAME --location $LOCATION
az network vnet subnet create --resource-group $RG_NAME --vnet-name vnet-wordpress --name subnet-capps --address-prefixes 10.0.0.0/23
az network vnet subnet create --resource-group $RG_NAME --vnet-name vnet-wordpress --name subnet-db --address-prefixes 10.0.2.0/24
capps_id=$(az network vnet subnet show --vnet-name vnet-wordpress --resource-group $RG_NAME --name subnet-capps --output tsv --query 'id' | tr -d '\r\n')

# create azure container registry
az acr create --name $ACR_NAME --resource-group $RG_NAME --sku Basic --admin-enabled true
ACR_USERNAME=$(az acr credential show --name $ACR_NAME --output tsv --query "username" | tr -d '\r\n')
ACR_PASSWORD=$(az acr credential show --name $ACR_NAME --output tsv --query "passwords[0].value" | tr -d '\r\n')
az acr login --name $ACR_NAME --username $ACR_USERNAME --password $ACR_PASSWORD

# build & push docker image
az acr build --registry $ACR_NAME --image $IMAGE_NAME --file Dockerfile .

# create azure mysql flexible server
az mysql flexible-server create --location $LOCATION --resource-group $RG_NAME \
    --name $MYSQL_SERVER_NAME --admin-user "$WORDPRESS_USERNAME" --admin-password "$WORDPRESS_PASSWORD" \
    --sku-name Standard_B1ms --tier Burstable \
    --storage-size 32 \
    --version 5.7 \
    --storage-auto-grow Enabled \
    --database-name wordpress \
    --vnet vnet-wordpress --subnet subnet-db \
    --yes

# create azure storage account, a blob and extract primary access key
az storage account create --name $STORAGE_NAME \
    --resource-group $RG_NAME --location $LOCATION \
    --sku Standard_LRS --kind StorageV2
az storage container create --name "uploads" \
    --public-access blob \
    --account-name $STORAGE_NAME \
    --resource-group $RG_NAME
STORAGE_KEY=$(az storage account keys list --resource-group $RG_NAME --account-name $STORAGE_NAME --output tsv --query '[0].value' | tr -d '\r\n')

# create azure container apps environment and deploy our container
az containerapp env create --name $CONTAINERAPP_ENV \
    --resource-group $RG_NAME \
    --location $LOCATION \
    --infrastructure-subnet-resource-id $capps_id
# containerapp environment takes time to become available for deployment...
while [ $(az containerapp env show --resource-group $RG_NAME --name $CONTAINERAPP_ENV --output tsv --query 'properties.provisioningState' | tr -d '\r\n') != "Succeeded" ] ; do
    echo "waiting for container app environment to be ready"
    sleep 5
done
az containerapp create --name $CONTAINERAPP \
    --resource-group $RG_NAME \
    --environment $CONTAINERAPP_ENV \
    --image $ACR_NAME.azurecr.io/$IMAGE_NAME \
    --registry-server $ACR_NAME.azurecr.io \
    --registry-username "$ACR_USERNAME" \
    --registry-password "$ACR_PASSWORD" \
    --target-port 80 \
    --ingress external \
    --cpu 0.5 --memory 1.0Gi \
    --min-replicas 0 --max-replicas 4 \
    --secrets wordpressdatabaseuser="$WORDPRESS_USERNAME" \
              wordpressdatabasepassword="$WORDPRESS_PASSWORD" \
              wordpressdatabasename=wordpress \
              wordpressdatabasehost="$MYSQL_SERVER_NAME.mysql.database.azure.com" \
              azureaccountname="$STORAGE_NAME" \
              azureaccountkey="$STORAGE_KEY" \
    --env-vars DATABASE_USERNAME=secretref:wordpressdatabaseuser \
               DATABASE_PASSWORD=secretref:wordpressdatabasepassword \
               DATABASE_NAME=secretref:wordpressdatabasename \
               DATABASE_HOST=secretref:wordpressdatabasehost \
               MICROSOFT_AZURE_ACCOUNT_NAME=secretref:azureaccountname \
               MICROSOFT_AZURE_ACCOUNT_KEY=secretref:azureaccountkey \
               MICROSOFT_AZURE_CONTAINER="uploads" \
               MICROSOFT_AZURE_USE_FOR_DEFAULT_UPLOAD=1
URL=$(az containerapp show --name $CONTAINERAPP --resource-group $RG_NAME --output tsv --query 'properties.configuration.ingress.fqdn' | tr -d '\r\n')
echo "wordpress responds at https://$URL"
