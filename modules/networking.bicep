// Networking module
// Creates VNet with two subnets:
// 1. App subnet — for App Service VNet integration
// 2. Private endpoint subnet — for SQL private connectivity

param region string
param environmentName string
param prefix string
param vnetAddressSpace string
param appSubnetPrefix string
param privateEndpointSubnetPrefix string
param tags object

// VNet
resource vnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: '${prefix}-vnet-${environmentName}-${region}'
  location: region
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [vnetAddressSpace]
    }
    subnets: [
      {
        // App Service integration subnet
        name: '${prefix}-snet-app-${environmentName}-${region}'
        properties: {
          addressPrefix: appSubnetPrefix
          delegations: [
            {
              name: 'app-service-delegation'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
      {
        // Private endpoint subnet f0r SQL connectivity
        name: '${prefix}-snet-privateendpoint-${environmentName}-${region}'
        properties: {
          addressPrefix: privateEndpointSubnetPrefix
          // Must be disabled for private endpoints — Azure requirement
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

// Outputs — passed back to main.bicep for other modules to use
output vnetId string = vnet.id
output appSubnetId string = '${vnet.id}/subnets/${prefix}-snet-app-${environmentName}-${region}'
output privateEndpointSubnetId string = '${vnet.id}/subnets/${prefix}-snet-privateendpoint-${environmentName}-${region}'
