# HA2 Platform — Azure High Availability Infrastructure

Multi-region, highly available Azure infrastructure built entirely with Bicep. Application workloads run active-active across **UK South** (primary) and **UK West** (secondary) with automatic failover at both the application tier (Azure Front Door) and the data tier (SQL Auto-Failover Group). All backend data stores are accessible only through private endpoints — no public internet path exists to SQL or Key Vault.

---

## Table of Contents

- [Architecture](#architecture)
- [Traffic Flow](#traffic-flow)
- [Network Topology](#network-topology)
- [Deployment Order](#deployment-order)
- [Project Structure](#project-structure)
- [Modules](#modules)
- [Design Decisions](#design-decisions)
- [Resource Naming](#resource-naming)
- [IP Address Ranges](#ip-address-ranges)
- [Deployment](#deployment)
- [Outputs](#outputs)
- [Security Posture](#security-posture)

---

## Architecture

```
                          ┌──────────────────────────────┐
                          │           Internet            │
                          └──────────────┬───────────────┘
                                         │ HTTPS
                          ┌──────────────▼───────────────┐
                          │      Azure Front Door         │
                          │          Premium              │
                          │                               │
                          │  WAF — Prevention Mode        │
                          │  OWASP DRS 2.1 (Block)        │
                          │  Bot Manager 1.1  (Block)     │
                          │                               │
                          │  Active-Active Load Balancing │
                          │  Health Probe: HTTPS / 30s    │
                          └──────────┬───────────┬────────┘
                                     │           │
                                     │ HTTPS     │ HTTPS
                          ┌──────────▼─┐       ┌─▼──────────────┐
                          │  UK South  │       │   UK West       │
                          │ App Service│       │  App Service    │
                          │ P1v3 Linux │       │  P1v3 Linux     │
                          │ System-MI  │       │  System-MI      │
                          │ HTTPS only │       │  HTTPS only     │
                          └─────┬──────┘       └──────┬──────────┘
                                │ VNet Integration   │ VNet Integration
                                │ vnetRouteAllEnabled│ vnetRouteAllEnabled
                          ┌─────▼──────┐       ┌─────▼──────────┐
                          │ UK South   │       │  UK West       │
                          │   VNet     │       │    VNet        │
                          │10.0.0.0/16 │       │ 10.1.0.0/16    │
                          │  (dev)     │       │   (dev)        │
                          │            │       │                │
                          │ App Subnet │       │ App Subnet     │
                          │ PE Subnet  │       │ PE Subnet      │
                          └─────┬──────┘       └─────┬──────────┘
                                │ Private              │ Private
                                │ Endpoints            │ Endpoint
                ┌───────────────┼───────────┐          │
                │               │           │          │
          ┌─────▼────┐    ┌─────▼────┐ ┌────▼────┐ ┌──▼─────────┐
          │   SQL    │    │   Key    │ │ Storage │ │   SQL      │
          │ Primary  │    │  Vault   │ │ (UK     │ │ Secondary  │
          │ UK South │    │ UK South │ │ South)  │ │ UK West    │
          │          │    │ Secrets  │ │ LRS     │ │            │
          │ Public:  │    │ Public:  │ │ HTTPS   │ │ Public:    │
          │ Disabled │    │ Disabled │ │ only    │ │ Disabled   │
          └─────┬────┘    └──────────┘ └─────────┘ └────┬───────┘
                │                                       │
                └────────── Failover Group ─────────────┘
                            Automatic
                            60 min grace period
                            (control plane, not network)

  ┌──────────────────────────────────────────────────────────────┐
  │  Private DNS Zones (Global — Linked to BOTH VNets)           │
  │                                                              │
  │  privatelink.database.windows.net    → SQL private IPs       │
  │  privatelink.vaultcore.azure.net     → Key Vault private IP  │
  └──────────────────────────────────────────────────────────────┘
```

**Key points the diagram shows:**

- Each App Service connects to its **own** local VNet (App Services cannot integrate with a VNet in a different region)
- Private endpoints sit inside the **PE subnet** of each VNet
- Private DNS zones are **global** resources linked to **both** VNets — this is how UK West App Service resolves SQL hostnames to UK West private IPs
- The SQL Failover Group is a **control-plane** relationship managed by Azure — not a network connection between the two VNets
- The two VNets are **completely independent** — there is no VNet peering

---

## Traffic Flow

How a user request travels through the system end-to-end:

```
  User
   │
   │  HTTPS
   ▼
┌──────────────────────────────────────────────────────────────┐
│  Azure Front Door (Global Anycast)                           │
│                                                              │
│  1. WAF inspection (OWASP + Bot rules)                       │
│  2. Health-probe routing — sends to healthy origin only      │
│  3. Active-active load balancing (weight 500 / priority 1)   │
│  4. HTTPS-only forwarding — HTTP redirected at edge          │
└──────────────────────────────┬───────────────────────────────┘
                               │  HTTPS to origin hostname
                    ┌──────────▼──────────┐
                    │    App Service       │
                    │  (UK South or West)  │
                    └──────────┬──────────┘
                               │  VNet Integration
                               │  (all egress routed through VNet
                               │   via vnetRouteAllEnabled: true)
                    ┌──────────▼──────────┐
                    │  Private DNS Zone   │
                    │  Resolves SQL/KV    │
                    │  hostnames to       │
                    │  private IPs        │
                    └──────────┬──────────┘
                               │
             ┌─────────────────┼──────────────────┐
             │                 │                  │
     ┌───────▼──────┐  ┌───────▼──────┐           │
     │  SQL via     │  │  Key Vault   │           │
     │  Failover    │  │  via Private │           │
     │  Group EP    │  │  Endpoint    │           │
     └──────────────┘  └──────────────┘           │
```

---

## Network Topology

Each region has a VNet with two subnets. The regions are isolated — there is no VNet peering. DNS zones are global and linked to both VNets.

```
  ┌─────────────────────────────────────────────────────────────────┐
  │  UK South VNet  (dev: 10.0.0.0/16  │  prod: 10.2.0.0/16)        │
  │                                                                 │
  │  ┌──────────────────────────────┐                               │
  │  │  App Subnet                  │  Delegated to                 │
  │  │  dev:  10.0.1.0/24           │  Microsoft.Web/serverFarms    │
  │  │  prod: 10.2.1.0/24           │  App Service VNet integration │
  │  └──────────────────────────────┘                               │
  │                                                                 │
  │  ┌──────────────────────────────┐                               │
  │  │  Private Endpoint Subnet     │  privateEndpointNetworkPolicies│
  │  │  dev:  10.0.2.0/24           │  = Disabled (Azure req.)      │
  │  │  prod: 10.2.2.0/24           │                               │
  │  │                              │  Hosts private endpoints for: │
  │  │                              │  • SQL Primary                │
  │  │                              │  • Key Vault                  │
  │  └──────────────────────────────┘                               │
  └─────────────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────────────┐
  │  UK West VNet  (dev: 10.1.0.0/16  │  prod: 10.3.0.0/16)         │
  │                                                                 │
  │  ┌──────────────────────────────┐                               │
  │  │  App Subnet                  │  Delegated to                 │
  │  │  dev:  10.1.1.0/24           │  Microsoft.Web/serverFarms    │
  │  │  prod: 10.3.1.0/24           │                               │
  │  └──────────────────────────────┘                               │
  │                                                                 │
  │  ┌──────────────────────────────┐                               │
  │  │  Private Endpoint Subnet     │  Hosts private endpoints for: │
  │  │  dev:  10.1.2.0/24           │  • SQL Secondary              │
  │  │  prod: 10.3.2.0/24           │                               │
  │  └──────────────────────────────┘                               │
  └─────────────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────────────┐
  │  Private DNS Zones  (global — linked to both VNets)             │
  │                                                                 │
  │  privatelink.database.windows.net  →  SQL private IPs           │
  │  privatelink.vaultcore.azure.net   →  Key Vault private IP      │
  └─────────────────────────────────────────────────────────────────┘
```

---

## Deployment Order

Bicep resolves these automatically via output references. The order below shows the logical dependency chain:

```
  1. Resource Groups (rg, rg2)
        │
        ▼
  2. Networking — UK South + UK West (parallel)
     Storage Account
     Private DNS Zones (SQL + KV)
        │
        ▼
  3. App Services — UK South + UK West (parallel)
     (needed for managed identity principal IDs)
        │
        ▼
  4. Key Vault
     (needs App Service managed identity principal IDs
      and KV Private DNS zone ID)
        │
        ▼
  5. SQL Secondary — UK West
     (deployed before primary so its resource ID
      is available for the failover group)
        │
        ▼
  6. SQL Primary — UK South
     (creates failover group referencing secondary server ID)
        │
        ▼
  7. Front Door + WAF
     (needs both App Service hostnames)
```

---

## Project Structure

```
HA2/
├── main.bicep                  # Subscription-scoped entry point
├── dev.parameters.json         # Dev environment parameters
├── prod.parameters.json        # Prod environment parameters
└── modules/
    ├── networking.bicep        # VNet + subnets (reused for both regions)
    ├── appservice.bicep        # App Service Plan + App Service + VNet integration
    ├── storage.bicep           # Storage account
    ├── privateDns.bicep        # Private DNS zones for SQL and Key Vault
    ├── keyvault.bicep          # Key Vault + secret + RBAC + private endpoint
    ├── sql.bicep               # Primary SQL server + database + failover group + PE
    ├── sqlSecondary.bicep      # Secondary SQL server + private endpoint
    └── frontDoor.bicep         # Front Door Premium + WAF + origins + route
```

---

## Modules

### `networking.bicep`
Reused for both UK South and UK West. Creates a VNet with two subnets:
- **App subnet** — delegated to `Microsoft.Web/serverFarms` for App Service VNet integration
- **Private endpoint subnet** — hosts SQL and KV private endpoints; `privateEndpointNetworkPolicies: Disabled` as required by Azure

Outputs `vnetId`, `appSubnetId`, and `privateEndpointSubnetId` for downstream modules.

### `appservice.bicep`
Reused for both regions. Creates:
- App Service Plan — `P1v3` PremiumV3 Linux
- App Service — Linux, HTTPS-only, TLS 1.2, HTTP/2, FTPS disabled
- System-assigned managed identity — used for Key Vault access without stored credentials
- VNet integration — binds the app to the app subnet; `vnetRouteAllEnabled: true` ensures DNS queries go through the VNet so private DNS zones resolve correctly

### `storage.bicep`
Standard LRS storage account in UK South. HTTPS-only, TLS 1.2, no public blob access. Name is deterministic and globally unique via `uniqueString(rg.id)` — the same resource group always produces the same hash, so redeployments don't create new storage accounts.

### `privateDns.bicep`
Creates two global private DNS zones, each linked to both VNets:
- `privatelink.database.windows.net` — for SQL private endpoints
- `privatelink.vaultcore.azure.net` — for Key Vault private endpoint

Linking to both VNets means both App Services (UK South and UK West) can resolve private hostnames correctly.

### `keyvault.bicep`
Creates:
- Key Vault with RBAC authorization, soft delete enabled, public access disabled
- `sql-admin-password` secret — stored at deploy time from the `@secure()` parameter
- **Key Vault Secrets User** role assignment for both App Service managed identities — read-only secret access
- Private endpoint in the UK South PE subnet
- DNS zone group — automatically registers the KV private IP in the KV DNS zone

### `sql.bicep`
Creates:
- Primary SQL Server — UK South, TLS 1.2, public access disabled
- SQL Database — `GP_Gen5_2` General Purpose (required for failover groups), geo-redundant backup
- Auto-Failover Group — automatic policy, 60-minute grace period, references secondary server by resource ID
- Private endpoint + DNS zone group in the UK South PE subnet

### `sqlSecondary.bicep`
Creates:
- Secondary SQL Server — UK West; receives replicated data via failover group
- Private endpoint + DNS zone group in the UK West PE subnet

The secondary is deployed before the primary because `sql.bicep` needs `secondarySqlServerId` to create the failover group.

### `frontDoor.bicep`
Creates:
- WAF Policy — Prevention mode, OWASP Default Rule Set 2.1, Bot Manager 1.1; both set to Block
- Front Door Premium profile
- Endpoint — the public hostname users connect to
- Origin group — both App Services as origins, equal priority and weight (active-active)
- Health probes — HTTPS HEAD to `/` every 30 seconds; unhealthy origins are automatically removed
- Security policy — attaches WAF to the endpoint across all routes (`/*`)
- Route — HTTPS-only, redirects HTTP, forwards to origin group

---

## Design Decisions

### Active-Active Front Door (not Active-Passive)
Both App Service origins have `priority: 1` and `weight: 500`. Traffic is distributed equally across both regions under normal conditions. Health probes remove an unhealthy origin automatically.

**Why:** Better resource utilisation — both regions handle real load at all times. Lower average latency — users closer to UK West are served locally rather than always routing to UK South.

**Trade-off:** Both App Services must stay in sync on application state. Sticky sessions are disabled by design; the application must be stateless or use a shared session store.

---

### SQL Auto-Failover Group with 60-Minute Grace Period
The failover policy is `Automatic` with `failoverWithDataLossGracePeriodMinutes: 60`.

**Why:** A pure automatic failover with no grace period would trigger on brief network blips, causing unnecessary data-loss events. 60 minutes gives the primary time to recover from transient faults before Azure promotes the secondary, balancing availability against RPO.

**Trade-off:** In a genuine regional outage, failover won't complete until the 60-minute threshold is reached. Reduce this if your RPO requirement is tighter.

---

### General Purpose GP_Gen5_2 SQL SKU
Standard (S1) and Basic DTU tiers do not support Auto-Failover Groups or active geo-replication. `GP_Gen5_2` (General Purpose, Gen5, 2 vCores) is the minimum SKU in the vCore model that supports geo-replication.

**Why:** Geo-replication is a hard requirement for the secondary region. Standard tier was initially chosen but does not support this feature.

---

### Private Endpoints for SQL and Key Vault — No Public Access
Both SQL servers and Key Vault have `publicNetworkAccess: 'Disabled'`. Access is only possible through private endpoints inside the VNets.

**Why:** Eliminates the internet attack surface on sensitive data stores entirely. Even with strong authentication, public endpoints are exploitable through credential stuffing, misconfigured firewall rules, or zero-days. Removing the public path is a stronger guarantee than restricting it.

**Trade-off:** Management tools (SSMS, Azure Portal query editor, KV portal browser) require VPN or Azure Bastion to reach the private endpoints. Direct public access for developers is not possible.

---

### `vnetRouteAllEnabled: true` on App Services
Without this, regional VNet integration only routes RFC-1918 traffic through the VNet. Azure's DNS server (`168.63.129.16`) is not RFC-1918, so DNS queries leave the VNet — meaning private DNS zones are never consulted and SQL/KV hostnames resolve to their disabled public IPs.

**Why:** This single property is what makes private DNS zone resolution work from App Service. Without it, the private endpoint infrastructure deploys successfully but the App Service cannot reach SQL or Key Vault at runtime.

---

### Key Vault RBAC Model (not Access Policies)
`enableRbacAuthorization: true` replaces the legacy access policy model with Azure RBAC.

**Why:** RBAC integrates with Azure AD and is managed consistently alongside all other Azure role assignments. Access policies are vault-scoped and require a separate management plane; RBAC assignments are centrally auditable, support Privileged Identity Management (PIM), and do not require modifying the vault resource itself to grant or revoke access.

---

### System-Assigned Managed Identity on App Services
Each App Service has `identity.type: 'SystemAssigned'`. This identity is granted `Key Vault Secrets User` on the vault.

**Why:** No credentials are stored anywhere — no connection strings, no client secrets, no certificates to rotate. The managed identity is tied to the App Service lifecycle and revoked automatically when the app is deleted. This is the recommended approach for any Azure service-to-service authentication.

---

### Secondary SQL Deployed Before Primary
In `main.bicep`, `sqlSecondary` is declared before `sql`. The primary module takes `secondarySqlServerId` as a parameter.

**Why:** The failover group resource in `sql.bicep` must reference the secondary server's resource ID at creation time. Bicep resolves this via `sqlSecondary.outputs.secondarySqlServerId` — declaring the secondary first makes the dependency explicit and ensures ARM deploys it first.

---

### Non-Overlapping VNet Address Spaces Across Environments
Dev uses `10.0.x`/`10.1.x`; prod uses `10.2.x`/`10.3.x`.

**Why:** Even though dev and prod are in separate resource groups and subscriptions today, overlapping CIDR ranges would block any future VNet peering, VPN gateway, or hub-and-spoke connectivity without re-addressing. Unique ranges preserve optionality at zero cost.

---

### Separate Resource Groups per Region
Primary resources (`rg`) and secondary resources (`rg2`) are in separate resource groups.

**Why:** Allows RBAC to be scoped per region, supports independent lifecycle management (e.g. tear down secondary independently), and maps cleanly to Bicep's `scope` parameter on each module. It also aligns with Azure's recommendation for multi-region deployments.

---

### Front Door Premium (not Standard)
`Premium_AzureFrontDoor` SKU is used for both the WAF policy and the Front Door profile.

**Why:** Premium is required to attach managed WAF rule sets (OWASP DRS, Bot Manager). Standard WAF only supports custom rules. Premium also supports Private Link origins — a requirement if App Services are later locked down to accept traffic only from Front Door.

---

### WAF in Prevention Mode
`policySettings.mode: 'Prevention'` actively blocks requests that match rules. `Detection` mode only logs.

**Why:** A WAF in Detection mode provides no protection — it only informs. Prevention mode is the correct posture for production. If a rule causes false positives on legitimate traffic, the specific rule can be excluded rather than downgrading the whole policy to Detection.

---

### Key Vault Password Reference in Parameters (Post-Bootstrap)
`prod.parameters.json` and `dev.parameters.json` reference the SQL password from the Key Vault created by this template, rather than storing it as a value.

**Why:** Storing secrets in parameters files risks committing them to source control. Key Vault references are resolved by the ARM deployment engine at deploy time — the secret value never appears in the parameters file, deployment logs, or pipeline outputs.

**Bootstrap requirement:** On the very first deployment the KV does not yet exist, so the reference cannot resolve. Pass the password directly via `--parameters sqlAdminPassword="<value>"` on that first run only.

---

## Resource Naming

All resources follow the pattern `{prefix}-{type}-{environment}-{region}`.

| Resource | Dev Example |
|----------|-------------|
| Resource Group (primary) | `ha2rgdevappname` |
| Resource Group (secondary) | `ha2rg2devappname` |
| VNet | `ha2-vnet-dev-uksouth` |
| App Subnet | `ha2-snet-app-dev-uksouth` |
| PE Subnet | `ha2-snet-privateendpoint-dev-uksouth` |
| App Service Plan | `ha2-asp-dev-uksouth` |
| App Service | `ha2-app-dev-uksouth` |
| SQL Server (primary) | `ha2-sql-dev-uksouth` |
| SQL Server (secondary) | `ha2-sql-dev-ukwest` |
| SQL Database | `ha2-db-dev` |
| SQL Failover Group | `ha2-fog-dev` |
| Key Vault | `ha2-kv-dev-{uniqueHash}` |
| Storage Account | `ha2stdev{uniqueHash}` |
| Private Endpoint (SQL primary) | `ha2-pe-sql-dev` |
| Private Endpoint (SQL secondary) | `ha2-pe-sql-secondary-dev` |
| Private Endpoint (Key Vault) | `ha2-pe-kv-dev` |
| Front Door Profile | `ha2-afd-dev` |
| WAF Policy | `ha2wafdev` |

> Storage account names cannot contain hyphens. A deterministic hash derived from the resource group ID via `uniqueString()` is appended to ensure global uniqueness. The hash stays consistent across redeployments to the same resource group.

> Key Vault names must be globally unique. A `uniqueString()` hash is appended for the same reason.

> WAF Policy names must be alphanumeric only — no hyphens permitted by Azure.

---

## IP Address Ranges

| Subnet | Dev | Prod |
|--------|-----|------|
| UK South VNet | `10.0.0.0/16` | `10.2.0.0/16` |
| UK South App Subnet | `10.0.1.0/24` | `10.2.1.0/24` |
| UK South PE Subnet | `10.0.2.0/24` | `10.2.2.0/24` |
| UK West VNet | `10.1.0.0/16` | `10.3.0.0/16` |
| UK West App Subnet | `10.1.1.0/24` | `10.3.1.0/24` |
| UK West PE Subnet | `10.1.2.0/24` | `10.3.2.0/24` |

Environments use non-overlapping ranges to allow future VNet peering or hub-and-spoke connectivity without re-addressing.

---

## Deployment

### Prerequisites

- Azure CLI installed and logged in (`az login`)
- Bicep CLI installed (`az bicep install`)
- Contributor role on the target subscription
- Subscription ID (`az account show --query id -o tsv`)

### First Deployment (Bootstrap)

The Key Vault does not exist on the first run, so the KV reference in the parameters file cannot resolve. Pass the SQL password directly via the CLI:

```bash
# Dev — first deployment
az deployment sub create \
  --location uksouth \
  --name ha2-dev-deployment \
  --template-file main.bicep \
  --parameters @dev.parameters.json \
  --parameters sqlAdminPassword="<your-secret>"

# Prod — first deployment
az deployment sub create \
  --location uksouth \
  --name ha2-prod-deployment \
  --template-file main.bicep \
  --parameters @prod.parameters.json \
  --parameters sqlAdminPassword="<your-secret>"
```

After the first run, update `<YOUR_SUBSCRIPTION_ID>` in both parameters files:

```bash
az account show --query id -o tsv
```

### Subsequent Deployments

Once the Key Vault exists, the parameters file resolves the password from it automatically:

```bash
# Dev
az deployment sub create \
  --location uksouth \
  --name ha2-dev-deployment \
  --template-file main.bicep \
  --parameters @dev.parameters.json

# Prod
az deployment sub create \
  --location uksouth \
  --name ha2-prod-deployment \
  --template-file main.bicep \
  --parameters @prod.parameters.json
```

### Validate Without Deploying

```bash
az deployment sub what-if \
  --location uksouth \
  --template-file main.bicep \
  --parameters @dev.parameters.json \
  --parameters sqlAdminPassword="<your-secret>"
```

---

## Outputs

After a successful deployment the following values are printed:

| Output | Description |
|--------|-------------|
| `primaryAppServiceUrl` | Hostname of the UK South App Service |
| `secondaryAppServiceUrl` | Hostname of the UK West App Service |
| `sqlFailoverGroupEndpoint` | SQL connection endpoint (always routes to current primary) |
| `sqlDatabaseName` | Name of the SQL database |
| `keyVaultName` | Name of the deployed Key Vault |
| `frontDoorEndpoint` | Public Front Door hostname — the URL to share with users |

---

## Security Posture

| Control | Implementation |
|---------|----------------|
| No public access to SQL | `publicNetworkAccess: 'Disabled'` on both servers |
| No public access to Key Vault | `publicNetworkAccess: 'Disabled'` |
| No stored credentials | App Services use system-assigned managed identity |
| Secrets not in parameters files | Key Vault reference replaces plaintext password post-bootstrap |
| HTTPS enforced end-to-end | Front Door redirects HTTP; App Service `httpsOnly: true`; SQL TLS 1.2 |
| FTPS disabled | `ftpsState: 'Disabled'` on both App Services |
| WAF blocking mode | OWASP DRS 2.1 + Bot Manager 1.1 in Prevention mode |
| TLS 1.2 minimum | Enforced on App Service, SQL, Storage, and Key Vault |
| No public blob access | `allowBlobPublicAccess: false` on Storage Account |
| Least-privilege KV access | `Key Vault Secrets User` (read-only) — not Owner or Contributor |
| Soft delete on Key Vault | 7 days (dev) — set to 90 days for prod |