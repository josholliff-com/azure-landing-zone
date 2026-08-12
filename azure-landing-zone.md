# Azure Landing Zone: Build Guide

A reference Azure landing zone built with Terraform and deployed through GitHub Actions using OIDC federation. Everything is code, everything is version controlled, and nothing is created in the portal except the two or three bootstrap resources that have to exist before Terraform can run.

This is the build guide. It maps to AZ-305 skills measured, but it is not a study guide. AZ-305 tests whether you can choose between options and justify the choice, so every phase ends with a written decision record rather than a screenshot of a green checkmark.

Resource prefix throughout is `jbo`. Environment names are `dev` and `prod`.

---

## How to use this

Nine phases. Each one has a build task, an AZ-305 mapping, a set of decisions you have to make and write down, and a cost note. Expect six to ten weeks at five to eight hours a week.

Three rules that separate this from a pile of `az` commands someone ran once:

1. **Every phase is a pull request.** Plan runs on the PR, apply runs on merge. Deploying from your workstation is a one-time act. Deploying from a pipeline is a platform.
2. **Every phase produces an ADR.** Architecture Decision Record, one markdown file, roughly a page. Context, options considered, decision, consequences. This is the single highest-signal artifact in the whole repo and it is the thing that maps to the exam.
3. **Destroy nightly.** A scheduled workflow that runs `terraform destroy` on the dev environment every night at 11pm. Rebuild takes one workflow run. This keeps the bill survivable and proves your code is actually idempotent, which is the part most people fake.

---

## Repository layout

```
azure-landing-zone/
  .github/
    workflows/
      terraform-plan.yml
      terraform-apply.yml
      nightly-destroy.yml
      policy-compliance.yml
  bootstrap/
    bootstrap.sh
    README.md
  modules/
    naming/
    networking-hub/
    networking-spoke/
    key-vault/
    log-analytics/
    app-service/
    sql-database/
    storage-account/
    private-endpoint/
    aks/
  environments/
    dev/
      main.tf
      variables.tf
      terraform.tfvars
      backend.tf
    prod/            # defined and CI-validated, not currently deployed
  policy/
    definitions/
    assignments/
  docs/
    adr/
      0001-remote-state-and-oidc.md
      0002-subscription-and-management-group-design.md
      ...
    diagrams/
    runbooks/
  README.md
```

The `prod/` folder is defined but not deployed, and the README should say so in one plain sentence: "The prod environment is defined and validated in CI but not currently deployed." That is an accurate statement about a promotion path, and it reads better than either pretending prod is live or leaving a reviewer to wonder. It demonstrates environment separation without doubling the bill, and it is a natural interview opening about how changes get promoted and why you did not copy and paste the whole environment.

---

## Phase 0: Foundation

**Build:** Remote state in Azure Storage. GitHub OIDC federation so the pipeline authenticates to Azure with no stored secrets. A naming and tagging module every other module consumes.

The bootstrap script in `bootstrap/` handles the chicken-and-egg problem. Run it once from your laptop. After that, nothing touches Azure except the pipeline.

The naming module is worth real effort. Something like:

```hcl
# modules/naming/main.tf
locals {
  # jbo-dev-eus2-net-hub-vnet
  prefix = join("-", compact([
    var.org_code,
    var.environment,
    var.location_short,
    var.workload,
  ]))
}
```

Tagging should be enforced, not suggested. You will use Azure Policy in Phase 1 to deny resource creation without `Owner`, `CostCenter`, `Environment`, and `DataClassification`. That last tag drives real decisions later in the data phase.

**AZ-305 mapping:** Governance foundations, resource organization, tagging strategy.

**Decisions to record (ADR 0001, 0002):**
- Why remote state in Azure Storage over Terraform Cloud or a state file in the repo. Address state locking and blast radius.
- One state file per environment, or per layer? Splitting networking state from application state limits blast radius but introduces cross-state data lookups. Argue your position.
- OIDC federated credentials over a service principal secret. Be able to explain what a federated credential actually validates.

**Cost:** Under $1/month. Storage account for state only.

---

## Phase 1: Governance and Identity

**Build:** A management group hierarchy. Custom RBAC role definitions. Azure Policy definitions and assignments as code. Key Vault with RBAC authorization rather than access policies. Managed identities for everything that will need them later.

Management group hierarchy modeled on Cloud Adoption Framework:

```
Tenant Root
  jbo-platform
    jbo-platform-identity
    jbo-platform-management
    jbo-platform-connectivity
  jbo-landing-zones
    jbo-lz-corp
    jbo-lz-online
  jbo-sandbox
  jbo-decommissioned
```

You can build the full hierarchy with a single subscription sitting in one of the leaves. The hierarchy is the artifact, not the subscription count.

Policy work to actually implement, not just read about:
- Deny resource creation outside approved regions
- Deny public IP on network interfaces in the corp landing zone
- Deny storage accounts with public blob access
- Audit resources missing required tags, then move to Modify with a remediation task, then move to Deny. Doing all three in sequence teaches you why policy rollout order matters.
- Require HTTPS-only and minimum TLS 1.2 on storage

Write at least two custom policy definitions in raw JSON rather than only assigning built-ins. That is where the understanding lives.

Custom RBAC role worth building: a "Platform Operator" that can restart VMs and App Services, read everything, and modify nothing else. Getting the `Actions` and `NotActions` right, and understanding why `DataActions` is a separate axis, is directly examinable.

**AZ-305 mapping:** Design identity and governance solutions. Management groups, subscriptions, RBAC, Azure Policy, Key Vault, managed identity, Entra ID.

**Decisions to record (ADR 0003, 0004, 0005):**
- Management group depth and why. What breaks at six levels.
- Policy at management group versus subscription scope. Where exemptions live.
- Key Vault RBAC versus access policies. Why one Key Vault per application per environment rather than one shared vault.
- System-assigned versus user-assigned managed identity. You will use both in later phases, so pick a rule now and hold to it.

**Cost:** Effectively zero. Key Vault standard is per-operation and negligible.

---

## Phase 2: Networking

This is the phase with the most exam weight and the most cost risk. Read the cost note before you apply.

**Build:** Hub and spoke topology. Hub VNet with a gateway subnet, Azure Firewall subnet, and Bastion subnet. Two spokes, peered to the hub, with UDRs forcing egress through the firewall. Private DNS zones linked to the hub and resolvable from the spokes. NSGs with ASGs rather than IP ranges.

Address space design matters and is examinable. Do not use 10.0.0.0/16 for everything. Plan it:

```
10.100.0.0/16   Hub          (eastus2)
  10.100.0.0/24   GatewaySubnet
  10.100.1.0/26   AzureFirewallSubnet
  10.100.2.0/26   AzureBastionSubnet
  10.100.3.0/24   Shared services
10.110.0.0/16   Spoke: corp workload
10.120.0.0/16   Spoke: online workload
10.200.0.0/16   Reserved: second region
```

Private DNS is where most people get quietly confused, and it shows up constantly in AZ-305 scenarios. Build `privatelink.blob.core.windows.net`, `privatelink.vaultcore.azure.net`, and `privatelink.database.windows.net` zones, link them to the hub, and prove name resolution works from a spoke VM. Understanding why the zone must be linked to the VNet that hosts the resolver, and what Azure DNS Private Resolver changes about that, is worth an hour of deliberate study.

Also build once and destroy immediately, purely to understand the shape:
- Application Gateway with WAF v2 in front of a spoke workload
- Azure Front Door with a custom domain

Then write the ADR comparing Front Door, Application Gateway, Load Balancer, and Traffic Manager. Layer, scope, global versus regional, what each one actually terminates. This exact comparison appears on the exam in some form nearly every time.

**AZ-305 mapping:** Design network solutions. Hub-spoke, Private Link, DNS, load balancing, routing, network security.

**Decisions to record (ADR 0006 through 0009):**
- Hub-spoke versus Virtual WAN. At what site count and what operational maturity does VWAN win.
- Egress design. Default outbound access retired 31 March 2026, so any VM in a VNet needs an explicit path, while PaaS services do not. Compare Azure Firewall, NAT Gateway, Load Balancer outbound rules, and an NVA. Include the honest cost argument and state what you actually run under a $50 ceiling versus what you would run with a real budget. That gap, stated plainly, is a stronger answer than pretending the constraint did not exist.
- Service endpoints versus private endpoints. Explain what a service endpoint does not protect against.
- Load balancing decision tree, written as a flowchart you can redraw on a whiteboard in ninety seconds.

### Cost strategy for this phase

Rates below verified July 2026, US list, directional. Check the pricing page before you rely on them.

| Component | Rate | If left running |
|---|---|---|
| Azure Firewall Standard | $1.25/hr + $0.016/GB | ~$912/mo |
| Azure Firewall Premium | $1.75/hr + $0.016/GB | ~$1,278/mo |
| Azure Firewall Basic | $0.395/hr + $0.065/GB | ~$288/mo |
| Application Gateway WAF v2 | ~$0.36/hr + capacity units | ~$250 to $350/mo |
| NAT Gateway | ~$0.045/hr + $0.045/GB | ~$32/mo |
| Bastion Developer | free | $0 |
| VPN Gateway VpnGw1 | ~$0.19/hr | ~$140/mo |

The important detail: Azure Firewall bills per deployment hour, and a partial hour is billed as a full hour. Six hours on a Saturday is $7.50 on Standard. The month-long number only applies if you forget it exists, which is exactly what the feature flag below prevents.

**Strategy 1: feature-flag every metered component.** Default off. The code proves you can build it, the default costs nothing, and conditional resource creation is itself a Terraform skill worth demonstrating.

Egress has three tiers, and the locals block picks whichever is enabled. Note that the retirement of default outbound access applies to VMs in a VNet. App Service, Container Apps, and Functions manage their own egress, so most of this build needs no explicit path at all. Turn on NAT Gateway only for the sessions where you have VMs running.

```hcl
variable "enable_azure_firewall" {
  description = "Deploy Azure Firewall in the hub. Billed per deployment hour, see ADR 0007."
  type        = bool
  default     = false
}

variable "enable_nat_gateway" {
  description = "Deploy NAT Gateway for spoke egress. Only needed when VMs are running."
  type        = bool
  default     = false
}

resource "azurerm_firewall" "main" {
  count = var.enable_azure_firewall ? 1 : 0

  name                = module.naming.firewall
  resource_group_name = azurerm_resource_group.hub.name
  location            = var.location
  sku_name            = "AZFW_VNet"
  sku_tier            = var.firewall_sku_tier
  firewall_policy_id  = azurerm_firewall_policy.main[0].id

  ip_configuration {
    name                 = "primary"
    subnet_id            = azurerm_subnet.firewall[0].id
    public_ip_address_id = azurerm_public_ip.firewall[0].id
  }
}

resource "azurerm_nat_gateway" "main" {
  count = var.enable_nat_gateway ? 1 : 0

  name                = module.naming.nat_gateway
  resource_group_name = azurerm_resource_group.hub.name
  location            = var.location
  sku_name            = "Standard"
}

# Egress path resolves to whichever tier is enabled. Firewall wins if both are
# on, since routing through the firewall makes the NAT Gateway redundant.
# Default outbound access was retired 31 March 2026, but that applies to VMs in
# a VNet. PaaS services manage their own egress and need neither of these.
locals {
  egress = var.enable_azure_firewall ? {
    next_hop_type = "VirtualAppliance"
    next_hop_ip   = azurerm_firewall.main[0].ip_configuration[0].private_ip_address
  } : {
    next_hop_type = "Internet"
    next_hop_ip   = null
  }
}

# Guard against paying for both at once.
resource "terraform_data" "egress_sanity_check" {
  lifecycle {
    precondition {
      condition     = !(var.enable_azure_firewall && var.enable_nat_gateway)
      error_message = "Firewall and NAT Gateway both enabled. Routing through the firewall makes NAT Gateway redundant and you would be paying for both."
    }
  }
}

resource "azurerm_route" "spoke_default" {
  name                   = "default-egress"
  route_table_name       = azurerm_route_table.spoke.name
  resource_group_name    = azurerm_resource_group.hub.name
  address_prefix         = "0.0.0.0/0"
  next_hop_type          = local.egress.next_hop_type
  next_hop_in_ip_address = local.egress.next_hop_ip
}
```

Flip the flag on, open a PR, merge, capture what you need, revert the flag, merge again. The git history showing the firewall going in and coming back out is itself evidence of cost-aware change management.

**Strategy 2: NAT Gateway only when VMs are running.** At roughly $32/month it would consume two thirds of a $50 ceiling, and most of this build does not need it. Default outbound access retirement applies to VMs in a VNet; App Service, Container Apps, Functions, and every private endpoint here handle egress themselves. Flag it on for the Bastion and VM sessions in this phase and Phase 6, where you actually need deterministic outbound IPs and SNAT port scaling, then flag it off. Six hours costs about thirty cents.

**Strategy 3: deallocate instead of destroy, manually only.** Azure Firewall has an SDK-level stop that the portal does not expose. Deallocating stops billing and preserves the rule configuration:

```powershell
$fw = Get-AzFirewall -Name $fwName -ResourceGroupName $rgName
$fw.Deallocate()
Set-AzFirewall -AzureFirewall $fw

# Restart
$vnet = Get-AzVirtualNetwork -ResourceGroupName $rgName -Name $vnetName
$pip  = Get-AzPublicIpAddress -ResourceGroupName $rgName -Name $pipName
$fw.Allocate($vnet, @($pip))
Set-AzFirewall -AzureFirewall $fw
```

Two caveats that matter more than the technique. The private IP can change on reallocation, which silently breaks any UDR pointing at the old address. And Terraform has no model of allocation state, so a deallocated firewall will show as drift and the next apply will fight you. Use this for a manual afternoon of study, never inside the pipeline. The feature flag is the pipeline-safe version of the same idea.

**Strategy 4: Application Gateway and VPN Gateway are build-once-and-destroy.** Deploy in the morning, capture the behavior, destroy before dinner. Neither has a deallocate path worth the trouble.

Set the budget alert at $25 now rather than waiting for Phase 8, and set actual-plus-forecast alerts, not actual alone. This is the phase where a forgotten resource gets expensive.

---

## Phase 3: Compute and Application Architecture

**Build:** The same trivial application deployed three ways, so the comparison is empirical rather than theoretical.

1. **App Service** on a Linux plan, VNet integrated, private endpoint on the inbound side, pulling secrets from Key Vault via managed identity. Deployment slots with a swap.
2. **Container Apps** running the same container, with a Dapr or plain HTTP scale rule and scale-to-zero configured.
3. **AKS**, a two-node system pool plus a user pool, with workload identity federation, Azure CNI Overlay, and the AKS-managed ingress or an ingress controller. Destroy it the same day.

Then add the messaging tier, because integration patterns carry real exam weight:
- Service Bus queue with a dead letter queue and a consumer that deliberately fails so you can watch messages land in the DLQ
- Event Grid topic with a subscription and a filter
- Storage queue, for the contrast

**AZ-305 mapping:** Design compute solutions, design application architecture solutions. Messaging, events, API Management, caching.

**Decisions to record (ADR 0010 through 0012):**
- App Service versus Container Apps versus AKS versus Functions. Write it as a decision tree with actual thresholds, not "it depends."
- Service Bus versus Event Grid versus Event Hubs. Message versus event. Pull versus push. Ordering and delivery guarantees.
- Where you put API Management, or why you did not.

**Cost:** App Service B1 is roughly $13/month. Container Apps scales to zero and costs cents. AKS control plane is free on the Free tier, nodes are not. Two B2s nodes are roughly $60/month if left up. Destroy AKS daily.

---

## Phase 4: Data

**Build:** Azure SQL Database with a private endpoint, Entra-only authentication, and TDE with a customer-managed key from your Key Vault. That CMK chain, Key Vault to managed identity to SQL, is a common exam scenario and a genuinely fiddly build.

Storage account exercising every design axis:
- Hot, cool, cold, and archive tiers with a lifecycle management policy that moves blobs on age
- Versioning, soft delete, and a legal hold on one container
- LRS versus ZRS versus GRS versus RA-GZRS, deployed and compared on cost
- Private endpoint plus a firewall rule set that denies public network access

Cosmos DB, serverless tier so it stays cheap. Create the same container with different partition keys and observe RU consumption on a cross-partition query versus a point read. Then walk the five consistency levels and write down what each one costs you in latency and availability.

**AZ-305 mapping:** Design data storage solutions. Relational, non-relational, integration, encryption, tiering.

**Decisions to record (ADR 0013 through 0016):**
- SQL Database versus Managed Instance versus SQL on a VM. Anchor it to a real scenario, ideally a workload from your current job.
- Cosmos partition key selection and why a bad one is unfixable without a migration.
- Redundancy tier per data classification. This is where the `DataClassification` tag from Phase 0 pays off.
- Where encryption keys live and who can rotate them.

**Cost:** SQL Serverless with auto-pause is roughly $5 to $15/month if you actually let it pause. Cosmos serverless is a few dollars. Storage is pennies at this volume.

---

## Phase 5: Monitoring and Observability

**Build:** Log Analytics workspace, single workspace in the management subscription, with data collection rules targeting VMs. Application Insights connected to the App Service. Diagnostic settings on every resource, deployed by policy rather than by hand, which is the whole point.

Then write actual queries. Ten KQL queries saved in the repo covering failed sign-ins, policy non-compliance, App Service 5xx rates, SQL DTU pressure, and cost anomalies. A workbook that renders them. Alert rules defined in Terraform with action groups.

Set one SLO with an error budget, then build the alert that fires when the budget burns too fast. Most people never do this and it is a strong differentiator.

**AZ-305 mapping:** Design solutions for logging and monitoring.

**Decisions to record (ADR 0017, 0018):**
- Centralized versus workspace-per-team. Cover data sovereignty, RBAC, and cross-workspace query cost.
- Retention and archive tiering against your actual compliance driver.

**Cost:** First 5 GB per month of ingestion is free. Ingestion at this scale stays inside that if you are not ingesting VM performance counters at a five-second interval. Watch this one, ingestion is the sneakiest line item in Azure.

---

## Phase 6: Business Continuity

**Build:** Recovery Services vault with a backup policy applied to a VM, plus a Backup vault for blob and disk backup. Enable soft delete and immutability on the vault. Then actually perform a restore, because a backup you have not restored is a hypothesis.

Zone-redundant deployment of one workload. Then deliberately break it: stop the instance in one zone and watch the load balancer behavior.

Azure Site Recovery configured for one VM to a secondary region. Run a test failover. Do not skip the test failover, it is the entire lesson.

Write RPO and RTO targets before you build, then measure what you actually achieved and record the gap. That gap analysis is the most credible thing you can put in front of an interviewer.

**AZ-305 mapping:** Design business continuity solutions. Backup and recovery, high availability, disaster recovery.

**Decisions to record (ADR 0019 through 0021):**
- Availability zones versus paired regions versus both. Cost per nine.
- Backup retention against a stated compliance requirement.
- Active-active versus active-passive versus backup-and-restore, tied to RPO and RTO numbers.

**Cost:** ASR is roughly $25/month per protected instance plus storage, billed monthly rather than hourly. This is the one phase that does not fit the session model, so give it a dedicated month. See the operating plan.

---

## Phase 7: Migration Design

Paper phase, no deployment. This is deliberate. AZ-305 asks migration questions and the answer is always a design, never a click.

Take a real workload from your current environment. A file server, a line-of-business SQL app, a print infrastructure, whatever you actually run. Then produce:

- Current state diagram with dependencies
- Azure Migrate assessment approach, and what data you would need to collect first
- Target state architecture, using the modules you built in Phases 2 through 5
- Migration method per component: rehost, replatform, refactor, retire
- Cutover runbook with rollback steps
- Cost comparison, current run rate versus projected Azure run rate, including the parts people forget: egress, backup storage, support plan, and reserved instance commitments

**AZ-305 mapping:** Design migration solutions. Azure Migrate, Data Box, Database Migration Service.

**Decisions to record:** The whole phase is one large decision document. Call it `docs/migration-assessment.md` and treat it as a writing sample.

**Cost:** Zero.

---

## Phase 8: Cost, Security Posture, and Operations

**Build:** Budget with action group alerts, deployed by Terraform. Cost analysis views by tag. A policy that denies VM SKUs above a size threshold in the sandbox management group.

Defender for Cloud enabled, secure score captured as a baseline. Then remediate ten findings and capture the delta. That before-and-after screenshot pair is worth more than a paragraph of description.

A GitHub Actions workflow that runs `checkov` or `tfsec` on every PR and fails the build on high severity findings. Another that runs `terraform fmt -check` and `terraform validate`. A third that queries policy compliance state and posts a summary comment on the PR.

**AZ-305 mapping:** Governance, cost management, security posture. Also the part of platform engineering that the exam does not test but every hiring manager asks about.

---

## What to do with this once it is built

The repo is the deliverable, but the repo alone does not get read. Three things convert it:

**A README with an architecture diagram at the top.** Draw it properly. Mermaid renders natively in GitHub, so the diagram lives in version control with everything else. First screen should answer what this is, what it demonstrates, and what it cost to run.

**The ADR folder linked prominently.** When someone asks in an interview why you chose hub-spoke over Virtual WAN, you have already written the answer and you will deliver it cleanly because you wrote it once already. This is the actual value of the ADR discipline. It is rehearsal disguised as documentation.

**Two or three writeups published somewhere public.** Not the whole build. Specific problems: the CMK chain from Key Vault to SQL, the private DNS resolution path across peered VNets, what the nightly destroy workflow taught you about idempotency. Short, technical, and specific. These are what people actually find and read.

---

## Operating plan: $50/month ceiling

This is a hard ceiling, not a target. Everything below is built around it.

### Standing floor: $10 to $13/month

What runs continuously, survives the nightly destroy, or cannot be switched off.

| Item | Monthly | Notes |
|---|---|---|
| State storage, ZRS, versioned | ~$1 | Survives destroy by design |
| Key Vault standard | ~$0.30 | Per-operation, negligible at this volume |
| Log Analytics | $0 | Free under 5 GB/month ingestion |
| Container Apps | $0 to $3 | Scales to zero, near-free when idle |
| Cosmos DB serverless | $1 to $3 | RU-billed, no floor |
| Azure SQL serverless | $5 to $8 | Only if auto-pause actually fires |
| Standard public IPs | $3.65 each | The quiet killer, see below |

Two of these drift if you are not watching.

**SQL auto-pause.** Serverless only stays cheap if it actually pauses. Set `auto_pause_delay_in_minutes = 60` and verify in the portal after week one that it has genuinely paused rather than being held awake by a monitoring query or a connection pool.

**Orphaned public IPs.** Every static Standard public IP is $3.65/month whether or not it is attached to anything. Destroy a firewall carelessly and its IP can survive. Six forgotten IPs is $22/month of nothing. This is exactly what the orphan report in the nightly destroy workflow catches, so read it rather than letting it scroll past.

### Session budget: about $37/month

Everything expensive is hourly, so a working session is cheap. Six hours:

| Component | 6-hour session |
|---|---|
| Azure Firewall Standard | $7.50 |
| Application Gateway WAF v2 | ~$2.40 |
| VPN Gateway VpnGw1 | ~$1.15 |
| AKS, 2x B2s nodes, Free control plane | ~$0.50 |
| NAT Gateway | ~$0.30 |
| Bastion Developer | free |

A Saturday running all of it at once is roughly $12. Three such sessions per month still lands under the ceiling. That is more Phase 2 and Phase 3 time than you will actually want.

### Session protocol

1. Open a PR flipping the relevant `enable_*` flag to true
2. Merge, let apply run, note the start time
3. Do the work. Capture screenshots, KQL output, `terraform plan` diffs, whatever the ADR needs
4. Open a PR flipping the flag back to false
5. Merge before you close the laptop

Steps 4 and 5 are the whole discipline. Everything else is optional.

### The one phase that breaks the pattern

Phase 6 Site Recovery bills per protected instance per month, roughly $25, not hourly. Give it a dedicated month: run the test failover, capture the results, disable it, and skip the firewall sessions that month. Everything else in the plan is hourly and composes freely.

### Guardrails

**A budget alert is not a kill switch.** Azure budgets notify, they do not stop deployment, and notification can lag actual spend by several hours. Set the alert at $25 so it fires with room to react rather than at $50 where it fires after the fact.

The real protection is structural:
- Every metered component behind a flag defaulting to false
- Nightly scheduled destroy of the dev environment
- Orphan report reviewed, not skimmed
- Cost analysis blade checked every Monday, as a calendar item
- Policy in the sandbox management group denying VM SKUs above a threshold, from Phase 8

### A note on funding

Do not run this on employer MSDN or Visual Studio credit. This repository is deliberately separated from your employer in its naming, and funding it from a work benefit undoes that separation and creates an awkward conversation on the way out the door. Fifty dollars a month of your own money makes it unambiguously yours, which is the entire point of building it.

---

## Sequencing note

Phases 0 through 2 are the ones that matter most and the ones most people skip past to get to the fun compute stuff. The OIDC pipeline, the policy-as-code, and the network topology are what separate a platform engineer from someone who has used Azure. Spend disproportionate time there.

If you only get through Phase 5, you still have a repository that demonstrably outclasses what most candidates bring to a cloud engineer interview.
