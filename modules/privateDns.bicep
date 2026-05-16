// Private DNS module
// Global resources — serve both UK South and UK West VNets
// SQL:  resolves SQL hostnames to private IPs inside the VNets
// KV:   resolves Key Vault hostnames to private IPs inside the VNets

param primaryVnetId string
param secondaryVnetId string
param tags object

// ── SQL ──────────────────────────────────────────────────────────────────────

// Private DNS Zone — privatelink.database.windows.net
// Uses environment().suffixes so the name stays correct in sovereign clouds
resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink${environment().suffixes.sqlServerHostname}'
  location: 'global'
  tags: tags
}

// Link SQL DNS zone to UK South VNet
resource dnsLinkPrimary 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: 'dns-link-primary'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: primaryVnetId
    }
    registrationEnabled: false // auto-registration not needed — records added by DNS zone groups
  }
}

// Link SQL DNS zone to UK West VNet
resource dnsLinkSecondary 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: 'dns-link-secondary'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: secondaryVnetId
    }
    registrationEnabled: false
  }
}

// ── KEY VAULT ─────────────────────────────────────────────────────────────────

// Private DNS Zone — privatelink.vaultcore.azure.net
// Note: cannot use environment().suffixes here — keyvaultDns returns .vault.azure.net
// but the private link zone uses vaultcore.azure.net (different subdomain)
resource kvPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.vaultcore.azure.net'
  location: 'global'
  tags: tags
}

// Link KV DNS zone to UK South VNet
resource kvDnsLinkPrimary 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: kvPrivateDnsZone
  name: 'kv-dns-link-primary'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: primaryVnetId
    }
    registrationEnabled: false
  }
}

// Link KV DNS zone to UK West VNet — needed so secondary App Service can also resolve KV
resource kvDnsLinkSecondary 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: kvPrivateDnsZone
  name: 'kv-dns-link-secondary'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: secondaryVnetId
    }
    registrationEnabled: false
  }
}

// Outputs — passed back to main.bicep for SQL and KV modules to use
output privateDnsZoneId string = privateDnsZone.id
output kvPrivateDnsZoneId string = kvPrivateDnsZone.id
