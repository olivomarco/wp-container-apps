# Wordpress on Azure Container Apps, MySQL Flexible Server, Azure Storage

This document outlines a setup of an (almost) production-ready installation of Wordpress using Azure services.
In particular, we will use the following:

- Azure Container Apps, to deploy containers in a serverless way, using also scale-to-zero functionality
- Azure MySQL Flexible Server, as a PaaS database
- Azure Storage Account (blob), to store files uploaded to Wordpress
- Azure Container Registry, to store our container image
- we will also use Virtual Networks in order to keep our database private and not exposed to the internet

## Architecture

This diagram explains the architecture we are going to setup:

![Wordpress Architecture diagram on Azure](/assets/architecture.png)

## Setup steps

Here a short summary of the various commands and outputs is provided. Please refer to [this script](/deploy.sh) for a complete working script to do unsupervised deployment.

### Set variables, create resource group

After opening a new bash shell, we will define some variables using some randomic numbers (to avoid name conflicts):

```bash
id=$(shuf -i 0-10000 -n 1)
RG_NAME=rg-wordpress-$id
LOCATION=westeurope
CONTAINERAPP_ENV=wordpress-env-$id
CONTAINERAPP=wordpress
IMAGE_NAME=demo/wordpress:latest
ACR_NAME=acrwordpressdemo$id
MYSQL_SERVER_NAME=wordpressmysql-$id
STORAGE_NAME=sawordpress$id
WORDPRESS_USERNAME=wpuser
WORDPRESS_PASSWORD=$(tr -dc 'A-Za-z0-9!"#$%&'\''()*+,-./:;<=>?@[\]^_`{|}~' < /dev/urandom | head -c 15 ; echo)
```

and we will create our resource group:

```bash
az group create --name $RG_NAME --location $LOCATION
```

Feel free to adjust variables above accordingly to your needs: they will be used throught the following steps.

### Create Virtual Network (VNET) and subnets

Our setup ensures that our DB never gets exposed to the Internet. To do this, we need a VNET (Virtual Network) and a couple of subnets in it:

- our first subnet, named `subnet-capps`, will be the subnet dedicated to Azure Container Apps
- the second subnet, named `subnet-db`, will be the subnet dedicated to our MySQL database

Creating this VNET is simple as running:

```bash
az network vnet create --name vnet-wordpress --resource-group $RG_NAME --location $LOCATION
az network vnet subnet create --resource-group $RG_NAME --vnet-name vnet-wordpress --name subnet-capps --address-prefixes 10.0.0.0/23
az network vnet subnet create --resource-group $RG_NAME --vnet-name vnet-wordpress --name subnet-db --address-prefixes 10.0.2.0/24
```

We will also need to take note in a variable of the actual resource ID of our `subnet-capps` subnet:

```bash
capps_id=$(az network vnet subnet show --vnet-name vnet-wordpress --resource-group $RG_NAME --name subnet-capps --output tsv --query 'id' | tr -d '\r\n')
```

### Create container registry

We will then create an Azure Container Registry in order to build and store our custom Wordpress image. In fact, Wordpress source-code provided in this repository has been adapted a bit in order to be able to run inside Azure Container Apps.

The following changes were made to the default installation package you can get from [wordpress.org](https://wordpress.org):

- Created a custom [.htaccess](/public/.htaccess) file
- Configured a custom [wp-config.php](/public/wp-config.php) file
- Downloaded [Microsoft Azure Storage for Wordpress plugin](https://wordpress.org/plugins/windows-azure-storage/) and [WP Super Cache plugin](https://it.wordpress.org/plugins/wp-super-cache/) inside [plugins folder](/public/wp-content/plugins/)
- Configured a custom [wp-config.php](/public/wp-config.php) file
- Configured a custom [wp-cache-config.php](/public/wp-content/wp-cache-config.php) file

That's it.

To create Azure Container Registry and build our image run the following commands:

```bash
az acr create --name $ACR_NAME --resource-group $RG_NAME --sku Basic --admin-enabled true
ACR_USERNAME=$(az acr credential show --name $ACR_NAME --output tsv --query "username" | tr -d '\r\n')
ACR_PASSWORD=$(az acr credential show --name $ACR_NAME --output tsv --query "passwords[0].value" | tr -d '\r\n')
az acr login --name $ACR_NAME --username $ACR_USERNAME --password $ACR_PASSWORD

az acr build --registry $ACR_NAME --image $IMAGE_NAME --file Dockerfile .
```

### Deploy Database

Wordpress needs a MySQL DB. Luckily, Azure offers a managed MySQL database we can use and completely avoid messing up with virtual machines and MySQL installation.

We can deploy our database with the following commands:

```bash
az mysql flexible-server create --location $LOCATION --resource-group $RG_NAME \
    --name $MYSQL_SERVER_NAME --admin-user "$WORDPRESS_USERNAME" --admin-password "$WORDPRESS_PASSWORD" \
    --sku-name Standard_B1ms --tier Burstable \
    --storage-size 32 \
    --version 5.7 \
    --storage-auto-grow Enabled \
    --database-name wordpress \
    --vnet vnet-wordpress --subnet subnet-db \
    --yes
```

### Create blob container

Wordpress also needs a persistent filesystem in which all multimedia and attachments are uploaded by bloggers. By default, a local folder inside the Wordpress installation is used.

This does not fit with the runtime model we are using, since we are using a container, serverless infrastructure that does not persist filesystem contents between different runs.

One solution to the problem is to use a [plugin for Wordpress developed by Microsoft](https://wordpress.org/plugins/windows-azure-storage/) that changes the behaviour of Wordpress and uploads content to an Azure Storage Account (blob container) and makes Wordpress serve all static (uploaded) content from here.

With these commands:

```bash
az storage account create --name $STORAGE_NAME \
    --resource-group $RG_NAME --location $LOCATION \
    --sku Standard_LRS --kind StorageV2
az storage container create --name "uploads" \
    --public-access blob \
    --account-name $STORAGE_NAME \
    --resource-group $RG_NAME
STORAGE_KEY=$(az storage account keys list --resource-group $RG_NAME --account-name $STORAGE_NAME --output tsv --query '[0].value' | tr -d '\r\n')
```

we will create our storage account and blob container and save in a local variable our storage key, that will be passed as a secret to our container application.

### Deploy container apps

And now, before going live, let's run the final deployment commands. We need to create a container app environment which is capable of hosting multiple containers and that must be integrated inside the VNET we created before.

For doing so, we will run:

```bash
az containerapp env create --name $CONTAINERAPP_ENV \
    --resource-group $RG_NAME \
    --location $LOCATION \
    --infrastructure-subnet-resource-id $capps_id
```

Please note that when execution of this command ends, the container app environment could be still in a non-ready-to-use state. We have to wait for a few minutes before running this command:

```bash
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
```

which will bring up our Wordpress container and pass all the necessary environment variables and settings that Wordpress expects (most of them are read via the [custom wp-config.php file](/public/wp-config.php))

After this command runs, you should have this situation inside your resource group on Azure:

![Deployed resouces on Azure for Wordpress](/assets/deployed_resources.png)

By running this command in your shell:

```bash
az containerapp show --name $CONTAINERAPP --resource-group $RG_NAME --output tsv --query 'properties.configuration.ingress.fqdn'
```

you will get the URL at which Wordpress is live. Connect to it immediately to complete your Wordpress setup.

### Final Wordpress configuration steps

After running through the usual Wordpress installation screen:

![Wordpress installation screen](/assets/wp_install.png)

and logging in to `wp-admin` with the user you create in the installation step, go to plugins and enable "Microsoft Azure Storage for WordPress":

![Enable Microsoft Azure Storage plugin](/assets/azure_storage_plugin.png)

That's it. Wordpress is up and running, and fully configured.

## Conclusions

This article provided a step-by-step guide on how to leverage on Azure Container Apps and some other Azure services to setup a running installation of Wordpress that can be used in production, with scale to zero functionality and minimal effort of operations.

Further developments of this architecture could include deployment to multiple regions and WAF protection through usage of Azure Front Door, and leveraging on Front Door features and Wordpress plugins (such as WP Super Cache, which is installed in the package that we are providing) in order to setup a CDN for content and multimedia, so that users can benefit from low-latency no matter where they are.
