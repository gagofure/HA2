// SQL module
// Primary SQL server, database, failover group, private endpoint

param primaryRegion string
param environmentName string
param prefix string
param sqlAdminLogin string
@secure()
param sqlAdminPassword string
param primaryPrivateEndpointSubnetId string
param secondarySqlServerId string
param privateDnsZoneId string
param tags object

// Primary SQL Server — UK South
resource primarySqlServer 'Microsoft.Sql/servers@2023-02-01-preview' = {
  name: '${prefix}-sql-${environmentName}-${primaryRegion}'
  location: primaryRegion
  tags: tags
  properties: {
    administratorLogin: sqlAdminLogin
    administratorLoginPassword: sqlAdminPassword
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Disabled'
  }
}

// SQL Database
resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-02-01-preview' = {
  parent: primarySqlServer
  name: '${prefix}-db-${environmentName}'
  location: primaryRegion
  tags: tags
  sku: {
    name: 'GP_Gen5_2'
    tier: 'GeneralPurpose'
    family: 'Gen5'
    capacity: 2
  }
  properties: {
    requestedBackupStorageRedundancy: 'Geo'
  }
}

// Auto Failover Group
resource failoverGroup 'Microsoft.Sql/servers/failoverGroups@2023-02-01-preview' = {
  parent: primarySqlServer
  name: '${prefix}-fog-${environmentName}'
  tags: tags
  properties: {
    partnerServers: [
      {
        id: secondarySqlServerId
      }
    ]
    readWriteEndpoint: {
      failoverPolicy: 'Automatic'
      failoverWithDataLossGracePeriodMinutes: 60
    }
    databases: [
      sqlDatabase.id
    ]
  }
}

// Private Endpoint — gives SQL a private IP inside the VNet
resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-05-01' = {
  name: '${prefix}-pe-sql-${environmentName}'
  location: primaryRegion
  tags: tags
  properties: {
    subnet: {
      id: primaryPrivateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${prefix}-pe-sql-connection'
        properties: {
          privateLinkServiceId: primarySqlServer.id
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

// Outputs
output failoverGroupEndpoint string = '${prefix}-fog-${environmentName}${environment().suffixes.sqlServerHostname}'
output primarySqlServerId string = primarySqlServer.id
output databaseName string = sqlDatabase.name
