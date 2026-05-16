// Azure Front Door Premium with WAF
// Routes traffic between UK South and UK West App Services
// Active-active with automatic health-based failover

param prefix string
param environmentName string
param primaryAppHostname string
param secondaryAppHostname string
param tags object

// =============================================
// WAF POLICY
// Protects against OWASP Top 10 attacks
// =============================================

resource wafPolicy 'Microsoft.Network/FrontDoorWebApplicationFirewallPolicies@2022-05-01' = {
  name: '${prefix}waf${environmentName}'
  location: 'global'
  tags: tags
  sku: {
    name: 'Premium_AzureFrontDoor'
  }
  properties: {
    policySettings: {
      mode: 'Prevention'  // Blocks threats — use Detection for testing
      enabledState: 'Enabled'
    }
    managedRules: {
      managedRuleSets: [
        {
          ruleSetType: 'Microsoft_DefaultRuleSet'
          ruleSetVersion: '2.1'
          ruleSetAction: 'Block'
        }
        {
          ruleSetType: 'Microsoft_BotManagerRuleSet'
          ruleSetVersion: '1.1'
          ruleSetAction: 'Block'
        }
      ]
    }
  }
}

// =============================================
// FRONT DOOR PROFILE
// =============================================

resource frontDoorProfile 'Microsoft.Cdn/profiles@2023-05-01' = {
  name: '${prefix}-afd-${environmentName}'
  location: 'global'
  tags: tags
  sku: {
    name: 'Premium_AzureFrontDoor'
  }
}

// =============================================
// FRONT DOOR ENDPOINT
// Public URL users connect to
// =============================================

resource frontDoorEndpoint 'Microsoft.Cdn/profiles/afdEndpoints@2023-05-01' = {
  parent: frontDoorProfile
  name: '${prefix}-endpoint-${environmentName}'
  location: 'global'
  tags: tags
  properties: {
    enabledState: 'Enabled'
  }
}

// =============================================
// ORIGIN GROUP
// Defines pool of backend App Services + health probes
// =============================================

resource originGroup 'Microsoft.Cdn/profiles/originGroups@2023-05-01' = {
  parent: frontDoorProfile
  name: 'app-origin-group'
  properties: {
    loadBalancingSettings: {
      sampleSize: 4
      successfulSamplesRequired: 3
      additionalLatencyInMilliseconds: 50
    }
    healthProbeSettings: {
      probePath: '/'
      probeProtocol: 'Https'
      probeRequestType: 'HEAD'
      probeIntervalInSeconds: 30
    }
    sessionAffinityState: 'Disabled'
  }
}

// =============================================
// ORIGIN — UK South App Service
// =============================================

resource originPrimary 'Microsoft.Cdn/profiles/originGroups/origins@2023-05-01' = {
  parent: originGroup
  name: 'origin-uksouth'
  properties: {
    hostName: primaryAppHostname
    httpPort: 80
    httpsPort: 443
    originHostHeader: primaryAppHostname
    priority: 1
    weight: 500
    enabledState: 'Enabled'
    enforceCertificateNameCheck: true
  }
}

// =============================================
// ORIGIN — UK West App Service
// =============================================

resource originSecondary 'Microsoft.Cdn/profiles/originGroups/origins@2023-05-01' = {
  parent: originGroup
  name: 'origin-ukwest'
  properties: {
    hostName: secondaryAppHostname
    httpPort: 80
    httpsPort: 443
    originHostHeader: secondaryAppHostname
    priority: 1  // Same priority as primary — active-active
    weight: 500
    enabledState: 'Enabled'
    enforceCertificateNameCheck: true
  }
}

// =============================================
// SECURITY POLICY — attaches WAF to Front Door
// =============================================

resource securityPolicy 'Microsoft.Cdn/profiles/securityPolicies@2023-05-01' = {
  parent: frontDoorProfile
  name: '${prefix}-security-${environmentName}'
  properties: {
    parameters: {
      type: 'WebApplicationFirewall'
      wafPolicy: {
        id: wafPolicy.id
      }
      associations: [
        {
          domains: [
            {
              id: frontDoorEndpoint.id
            }
          ]
          patternsToMatch: ['/*']
        }
      ]
    }
  }
}

// =============================================
// ROUTE — maps incoming traffic to origin group
// =============================================

resource route 'Microsoft.Cdn/profiles/afdEndpoints/routes@2023-05-01' = {
  parent: frontDoorEndpoint
  name: 'default-route'
  dependsOn: [
    originPrimary
    originSecondary
  ]
  properties: {
    originGroup: {
      id: originGroup.id
    }
    patternsToMatch: ['/*']
    httpsRedirect: 'Enabled'
    supportedProtocols: ['Https']
    forwardingProtocol: 'HttpsOnly'
    linkToDefaultDomain: 'Enabled'
    enabledState: 'Enabled'
  }
}

// =============================================
// OUTPUTS
// =============================================

output frontDoorEndpoint string = frontDoorEndpoint.properties.hostName
output frontDoorProfileId string = frontDoorProfile.id
