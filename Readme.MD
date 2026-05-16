## step 1

az deployment sub create \
  --location uksouth \
  --name ha2-dev-deployment \
  --template-file main.bicep \
  --parameters @dev.parameters.json
