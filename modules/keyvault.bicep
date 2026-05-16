// Key Vault module
// Stores SQL admin password as a secret
// Grants both App Service managed identities read access via RBAC
// Private endpoint restricts access to the primary VNet only

param prefix string
param environmentName string
param region string
@secure()
param sqlAdminPassword string
param appServicePrincipalIdPrimary string
param appServicePrincipalIdSecondary string
param privateEndpointSubnetId string
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
    enableRbacAuthorization: true // RBAC replaces legacy access policies
    enableSoftDelete: true
    softDeleteRetentionInDays: 7  // minimum; increase to 90 for prod
    publicNetworkAccess: 'Disabled' // private endpoint is the only access path
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
    principalType: 'ServicePrincipal' // managed identity — not a user or group
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

// Private Endpoint — gives Key Vault a private IP inside the primary VNet
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
          groupIds: ['vault'] // group ID for Key Vault private link
        }
      }
    ]
  }
}

// DNS zone group — registers KV private IP in the private DNS zone automatically
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

// Outputs
output keyVaultId string = keyVault.id
output keyVaultName string = keyVault.name
output sqlPasswordSecretUri string = sqlPasswordSecret.properties.secretUri
