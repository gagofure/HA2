targetScope = 'subscription'

// General parameters
param environmentName string
param prefix string

// Resource group names
param resourceGroupName string
param secondaryResourceGroupName string

// Regions
param primaryRegion string
param secondaryRegion string

// Primary networking
param vnetAddressSpace string
param appSubnetPrefix string
param privateEndpointSubnetPrefix string

// Secondary networking
param secondaryVnetAddressSpace string
param secondaryAppSubnetPrefix string
param secondaryPrivateEndpointSubnetPrefix string

// SQL
param sqlAdminLogin string
@secure()
param sqlAdminPassword string

param tags object

// =============================================
// RESOURCE GROUPS
// =============================================

resource rg 'Microsoft.Resources/resourceGroups@2022-09-01' = {
  name: resourceGroupName
  location: primaryRegion
  tags: tags
}

resource rg2 'Microsoft.Resources/resourceGroups@2022-09-01' = {
  name: secondaryResourceGroupName
  location: secondaryRegion
  tags: tags
}

// =============================================
// STORAGE
// =============================================

module storage 'modules/storage.bicep' = {
  name: 'storage-deployment'
  scope: rg
  params: {
    region: primaryRegion
    storageAccountName: '${prefix}st${environmentName}${uniqueString(rg.id)}'
    tags: tags
  }
}

// =============================================
// NETWORKING
// =============================================

// UK South
module networkingUKS 'modules/networking.bicep' = {
  name: 'networking-uks-deployment'
  scope: rg
  params: {
    region: primaryRegion
    environmentName: environmentName
    prefix: prefix
    vnetAddressSpace: vnetAddressSpace
    appSubnetPrefix: appSubnetPrefix
    privateEndpointSubnetPrefix: privateEndpointSubnetPrefix
    tags: tags
  }
}

// UK West
module networkingUKW 'modules/networking.bicep' = {
  name: 'networking-ukw-deployment'
  scope: rg2
  params: {
    region: secondaryRegion
    environmentName: environmentName
    prefix: prefix
    vnetAddressSpace: secondaryVnetAddressSpace
    appSubnetPrefix: secondaryAppSubnetPrefix
    privateEndpointSubnetPrefix: secondaryPrivateEndpointSubnetPrefix
    tags: tags
  }
}

// =============================================
// APP SERVICES
// =============================================

// UK South
module appServiceUKS 'modules/appservice.bicep' = {
  name: 'appservice-uks-deployment'
  scope: rg
  params: {
    region: primaryRegion
    environmentName: environmentName
    prefix: prefix
    appSubnetId: networkingUKS.outputs.appSubnetId
    tags: tags
    resourceTags: {
      region: 'uksouth'
      role: 'primary'
    }
  }
}

// UK West
module appServiceUKW 'modules/appservice.bicep' = {
  name: 'appservice-ukw-deployment'
  scope: rg2
  params: {
    region: secondaryRegion
    environmentName: environmentName
    prefix: prefix
    appSubnetId: networkingUKW.outputs.appSubnetId
    tags: tags
    resourceTags: {
      region: 'ukwest'
      role: 'secondary'
    }
  }
}

// =============================================
// PRIVATE DNS
// =============================================

module privateDns 'modules/privateDns.bicep' = {
  name: 'privateDns-deployment'
  scope: rg
  params: {
    primaryVnetId: networkingUKS.outputs.vnetId
    secondaryVnetId: networkingUKW.outputs.vnetId
    tags: tags
  }
}

// =============================================
// KEY VAULT
// =============================================

module keyVault 'modules/keyvault.bicep' = {
  name: 'keyvault-deployment'
  scope: rg
  params: {
    prefix: prefix
    environmentName: environmentName
    region: primaryRegion
    secondaryRegion: secondaryRegion
    sqlAdminPassword: sqlAdminPassword
    appServicePrincipalIdPrimary: appServiceUKS.outputs.managedIdentityPrincipalId
    appServicePrincipalIdSecondary: appServiceUKW.outputs.managedIdentityPrincipalId
    privateEndpointSubnetId: networkingUKS.outputs.privateEndpointSubnetId
    secondaryPrivateEndpointSubnetId: networkingUKW.outputs.privateEndpointSubnetId
    kvPrivateDnsZoneId: privateDns.outputs.kvPrivateDnsZoneId
    tags: tags
  }
}

// =============================================
// SQL
// =============================================

// Secondary SQL Server — UK West
// Deployed first because primary needs its resource ID
module sqlSecondary 'modules/sqlSecondary.bicep' = {
  name: 'sql-secondary-deployment'
  scope: rg2
  params: {
    secondaryRegion: secondaryRegion
    environmentName: environmentName
    prefix: prefix
    sqlAdminLogin: sqlAdminLogin
    sqlAdminPassword: sqlAdminPassword
    secondaryPrivateEndpointSubnetId: networkingUKW.outputs.privateEndpointSubnetId
    privateDnsZoneId: privateDns.outputs.privateDnsZoneId
    tags: tags
  }
}
// Primary SQL Server + Database + Failover Group + Private Endpoint
module sql 'modules/sql.bicep' = {
  name: 'sql-deployment'
  scope: rg
  params: {
    primaryRegion: primaryRegion
    environmentName: environmentName
    prefix: prefix
    sqlAdminLogin: sqlAdminLogin
    sqlAdminPassword: sqlAdminPassword
    primaryPrivateEndpointSubnetId: networkingUKS.outputs.privateEndpointSubnetId
    secondarySqlServerId: sqlSecondary.outputs.secondarySqlServerId
    privateDnsZoneId: privateDns.outputs.privateDnsZoneId
    tags: tags
  }
}

// =============================================
// FRONT DOOR
// =============================================

module frontDoor 'modules/frontDoor.bicep' = {
  name: 'frontdoor-deployment'
  scope: rg
  params: {
    prefix: prefix
    environmentName: environmentName
    primaryAppHostname: appServiceUKS.outputs.appServiceHostname
    secondaryAppHostname: appServiceUKW.outputs.appServiceHostname
    tags: tags
  }
}

// =============================================
// OUTPUTS
// =============================================

output primaryAppServiceUrl string = appServiceUKS.outputs.appServiceHostname
output secondaryAppServiceUrl string = appServiceUKW.outputs.appServiceHostname
output sqlFailoverGroupEndpoint string = sql.outputs.failoverGroupEndpoint
output sqlDatabaseName string = sql.outputs.databaseName
output keyVaultName string = keyVault.outputs.keyVaultName
output frontDoorEndpoint string = frontDoor.outputs.frontDoorEndpoint
