// Key Vault module
// Stores SQL admin password as a secret
// Grants both App Service managed identities read access via RBAC
// Private endpoints in BOTH regions — UK South App Service and UK West App Service
// can each reach Key Vault via their own local private IP

param prefix string
param environmentName string
param region string
param secondaryRegion string
@secure()
param sqlAdminPassword string
param appServicePrincipalIdPrimary string
param appServicePrincipalIdSecondary string
param privateEndpointSubnetId string
param secondaryPrivateEndpointSubnetId string
param kvPrivateDnsZoneId string
param tags object

// Key Vault — RBAC auth model, no access policies
resource keyVault 'Microsoft.KeyVault/vaults@2023-02-01' = {
  name: '${prefix}-kv-${environmentName}'
  location: region
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Disabled'
  }
}

// SQL admin password — read by App Services at runtime via Key Vault reference
resource sqlPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  parent: keyVault
  name: 'sql-admin-password'
  properties: {
    value: sqlAdminPassword
  }
}

// Key Vault Secrets User (built-in) — read-only access to secret values
var kvSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

// Grant primary App Service (UK South) access to Key Vault secrets
resource kvRbacPrimary 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, appServicePrincipalIdPrimary, kvSecretsUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvSecretsUserRoleId)
    principalId: appServicePrincipalIdPrimary
    principalType: 'ServicePrincipal'
  }
}

// Grant secondary App Service (UK West) access to Key Vault secrets
resource kvRbacSecondary 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, appServicePrincipalIdSecondary, kvSecretsUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvSecretsUserRoleId)
    principalId: appServicePrincipalIdSecondary
    principalType: 'ServicePrincipal'
  }
}

// =============================================
// PRIMARY PRIVATE ENDPOINT — UK South
// =============================================

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-05-01' = {
  name: '${prefix}-pe-kv-${environmentName}'
  location: region
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${prefix}-pe-kv-connection'
        properties: {
          privateLinkServiceId: keyVault.id
          groupIds: ['vault']
        }
      }
    ]
  }
}

resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-05-01' = {
  parent: privateEndpoint
  name: 'kv-dns-zone-group'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-vaultcore-azure-net'
        properties: {
          privateDnsZoneId: kvPrivateDnsZoneId
        }
      }
    ]
  }
}

// =============================================
// SECONDARY PRIVATE ENDPOINT — UK West
// Closes the gap — UK West App Service now has its own
// local private IP for Key Vault. No VNet peering needed.
// =============================================

resource privateEndpointSecondary 'Microsoft.Network/privateEndpoints@2023-05-01' = {
  name: '${prefix}-pe-kv-secondary-${environmentName}'
  location: secondaryRegion
  tags: tags
  properties: {
    subnet: {
      id: secondaryPrivateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${prefix}-pe-kv-secondary-connection'
        properties: {
          privateLinkServiceId: keyVault.id
          groupIds: ['vault']
        }
      }
    ]
  }
}

resource privateDnsZoneGroupSecondary 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-05-01' = {
  parent: privateEndpointSecondary
  name: 'kv-dns-zone-group-secondary'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-vaultcore-azure-net'
        properties: {
          privateDnsZoneId: kvPrivateDnsZoneId
        }
      }
    ]
  }
}

// Outputs
output keyVaultId string = keyVault.id
output keyVaultName string = keyVault.name
output sqlPasswordSecretUri string = sqlPasswordSecret.properties.secretUri
