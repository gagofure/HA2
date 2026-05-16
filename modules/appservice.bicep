param region string
param environmentName string
param prefix string
param appSubnetId string
param tags object 
param resourceTags object

// App Service Plan — the underlying compute
resource appServicePlan 'Microsoft.Web/serverfarms@2022-09-01' = {
  name: '${prefix}-asp-${environmentName}-${region}'
  location: region
  tags: union(tags, resourceTags)
  kind: 'linux'
  sku: {
    name: 'P1v3'
    tier: 'PremiumV3'
  }
  properties: {
    reserved: true // Required for Linux
  }
}

// App Service
resource appService 'Microsoft.Web/sites@2022-09-01' = {
  name: '${prefix}-app-${environmentName}-${region}'
  location: region
  tags: union(tags, resourceTags)
  kind: 'app,linux'
  identity: {
    type: 'SystemAssigned' // Managed identity — no stored credentials
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      minTlsVersion: '1.2'
      http20Enabled: true
      ftpsState: 'Disabled'
      vnetRouteAllEnabled: true
    }
  }
}

// VNet integration — connects App Service to our VNet
// Allows App Service to reach SQL via private endpoint
resource vnetIntegration 'Microsoft.Web/sites/networkConfig@2022-09-01' = {
  parent: appService
  name: 'virtualNetwork'
  properties: {
    subnetResourceId: appSubnetId
    swiftSupported: true
  }
}

// Outputs
output appServiceHostname string = appService.properties.defaultHostName
output appServiceId string = appService.id
output managedIdentityPrincipalId string = appService.identity.principalId
