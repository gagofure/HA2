// Secondary SQL Server — UK West
// Receives replicated data from primary via failover group
// If primary goes down, this becomes the new primary automatically

param secondaryRegion string
param environmentName string
param prefix string
param sqlAdminLogin string
@secure()
param sqlAdminPassword string
param secondaryPrivateEndpointSubnetId string
param privateDnsZoneId string
param tags object

resource secondarySqlServer 'Microsoft.Sql/servers@2023-02-01-preview' = {
  name: '${prefix}-sql-${environmentName}-${secondaryRegion}'
  location: secondaryRegion
  tags: tags
  properties: {
    administratorLogin: sqlAdminLogin
    administratorLoginPassword: sqlAdminPassword
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Disabled'
  }
}

// Private Endpoint — gives secondary SQL a private IP inside UK West VNet
resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-05-01' = {
  name: '${prefix}-pe-sql-secondary-${environmentName}'
  location: secondaryRegion
  tags: tags
  properties: {
    subnet: {
      id: secondaryPrivateEndpointSubnetId  // ← UK West private endpoint subnet
    }
    privateLinkServiceConnections: [
      {
        name: '${prefix}-pe-sql-secondary-connection'
        properties: {
          privateLinkServiceId: secondarySqlServer.id
          groupIds: ['sqlServer']
        }
      }
    ]
  }
}

resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-05-01' = {
  parent: privateEndpoint
  name: 'sql-dns-zone-group'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-database-windows-net'
        properties: {
          privateDnsZoneId: privateDnsZoneId
        }
      }
    ]
  }
}

output secondarySqlServerId string = secondarySqlServer.id
