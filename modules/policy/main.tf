variable "org_code" {
  type = string
}

# Definitions are created at the TENANT ROOT, not at jbo-platform.
#
# A definition can only be assigned at or below the scope where it is defined.
# jbo-platform and jbo-landing-zones are siblings, so a definition living in
# the former cannot be assigned in the latter. Defining at root is what real
# landing zones do, for exactly this reason. See ADR 0003.
variable "definition_scope_id" {
  description = "Tenant root management group ID. Must be at or above every assignment scope."
  type        = string
}

variable "landing_zones_id" {
  type = string
}

variable "lz_corp_id" {
  type = string
}

variable "location" {
  type = string
}

variable "allowed_locations" {
  type    = list(string)
  default = ["eastus2", "centralus"]
}

# Definitions ship first and get verified before anything enforces.
variable "enable_assignments" {
  type    = bool
  default = false
}

# Effects are variables so the Audit -> Modify -> Deny rollout is three PRs
# against the same code rather than three rewrites. See ADR 0003.
variable "tag_effect" {
  type    = string
  default = "Audit"
}

variable "nic_public_ip_effect" {
  type    = string
  default = "Audit"
}

variable "required_tags" {
  type = map(string)
  default = {
    CostCenter         = "unassigned"
    Owner              = "unassigned"
    DataClassification = "internal"
  }
}

locals {
  nic_policy = jsondecode(file("${path.module}/definitions/deny-nic-public-ip.json"))
  tag_policy = jsondecode(file("${path.module}/definitions/require-tag-modify.json"))
}

# ---------------------------------------------------------------------------
# Custom definitions
# ---------------------------------------------------------------------------

resource "azurerm_policy_definition" "deny_nic_public_ip" {
  name                = "${var.org_code}-deny-nic-public-ip"
  policy_type         = "Custom"
  mode                = local.nic_policy.mode
  display_name        = "Network interfaces must not have a public IP"
  description         = "Workloads reach the internet through the hub egress path, not through instance-attached public IPs."
  management_group_id = var.definition_scope_id

  policy_rule = jsonencode(local.nic_policy.policyRule)
  parameters  = jsonencode(local.nic_policy.parameters)

  metadata = jsonencode({
    category = "Network"
    version  = "1.0.0"
  })
}

resource "azurerm_policy_definition" "require_tag" {
  name                = "${var.org_code}-require-tag"
  policy_type         = "Custom"
  mode                = local.tag_policy.mode
  display_name        = "Require a tag, with Modify remediation"
  description         = "Adds the tag with a default value when absent. Deployed at Audit first."
  management_group_id = var.definition_scope_id

  policy_rule = jsonencode(local.tag_policy.policyRule)
  parameters  = jsonencode(local.tag_policy.parameters)

  metadata = jsonencode({
    category = "Tags"
    version  = "1.0.0"
  })
}

# ---------------------------------------------------------------------------
# Built-in lookups
# ---------------------------------------------------------------------------

data "azurerm_policy_definition_built_in" "allowed_locations" {
  display_name = "Allowed locations"
}

data "azurerm_policy_definition_built_in" "deny_public_blob" {
  display_name = "Storage account public access should be disallowed"
}

data "azurerm_policy_definition_built_in" "storage_https" {
  display_name = "Secure transfer to storage accounts should be enabled"
}

# ---------------------------------------------------------------------------
# Assignments
# ---------------------------------------------------------------------------

resource "azurerm_management_group_policy_assignment" "allowed_locations" {
  count = var.enable_assignments ? 1 : 0

  name                 = "${var.org_code}-allowed-locations"
  display_name         = "Allowed locations"
  management_group_id  = var.landing_zones_id
  policy_definition_id = data.azurerm_policy_definition_built_in.allowed_locations.id

  parameters = jsonencode({
    listOfAllowedLocations = { value = var.allowed_locations }
  })

  non_compliance_message {
    content = "Deploy to an approved region. See ADR 0003."
  }
}

resource "azurerm_management_group_policy_assignment" "deny_public_blob" {
  count = var.enable_assignments ? 1 : 0

  name                 = "${var.org_code}-deny-public-blob"
  display_name         = "Storage public blob access disallowed"
  management_group_id  = var.landing_zones_id
  policy_definition_id = data.azurerm_policy_definition_built_in.deny_public_blob.id

  parameters = jsonencode({
    effect = { value = "Deny" }
  })
}

resource "azurerm_management_group_policy_assignment" "storage_https" {
  count = var.enable_assignments ? 1 : 0

  name                 = "${var.org_code}-storage-https"
  display_name         = "Secure transfer to storage accounts"
  management_group_id  = var.landing_zones_id
  policy_definition_id = data.azurerm_policy_definition_built_in.storage_https.id

  parameters = jsonencode({
    effect = { value = "Deny" }
  })
}

resource "azurerm_management_group_policy_assignment" "deny_nic_public_ip" {
  count = var.enable_assignments ? 1 : 0

  name                 = "${var.org_code}-deny-nic-pip"
  display_name         = "No public IPs on network interfaces"
  management_group_id  = var.lz_corp_id
  policy_definition_id = azurerm_policy_definition.deny_nic_public_ip.id

  parameters = jsonencode({
    effect = { value = var.nic_public_ip_effect }
  })
}

# The identity requirement is driven by the DEFINITION content, not by the
# runtime effect value. This definition carries then.details with
# roleDefinitionIds and operations, so Azure requires an identity on EVERY
# assignment of it, including at Audit where those details never execute.
#
# Discovered as a ResourceIdentityRequired 400 during the Audit rollout, on
# three of seven resources, after four had already succeeded. Microsoft avoids
# this in their built-ins by shipping "Require a tag on resources" and
# "Add a tag to resources" as two separate definitions. See ADR 0003.
resource "azurerm_management_group_policy_assignment" "require_tag" {
  for_each = var.enable_assignments ? var.required_tags : {}

  # Policy assignment names cap at 24 characters at management group scope,
  # which is why DataClassification truncates to jbo-tag-dataclassificati.
  name                 = substr("${var.org_code}-tag-${lower(each.key)}", 0, 24)
  display_name         = "Require tag: ${each.key}"
  management_group_id  = var.landing_zones_id
  policy_definition_id = azurerm_policy_definition.require_tag.id

  location = var.location

  identity {
    type = "SystemAssigned"
  }

  parameters = jsonencode({
    tagName  = { value = each.key }
    tagValue = { value = each.value }
    effect   = { value = var.tag_effect }
  })
}

# Policy does NOT grant its own identity the role named in roleDefinitionIds.
# Granted at every stage so propagation has settled before the effect flips.
resource "azurerm_role_assignment" "tag_remediation" {
  for_each = var.enable_assignments ? var.required_tags : {}

  scope                = var.landing_zones_id
  role_definition_name = "Tag Contributor"
  principal_id         = azurerm_management_group_policy_assignment.require_tag[each.key].identity[0].principal_id
}

output "definition_ids" {
  value = {
    deny_nic_public_ip = azurerm_policy_definition.deny_nic_public_ip.id
    require_tag        = azurerm_policy_definition.require_tag.id
  }
}

output "tag_assignment_ids" {
  value = { for k, v in azurerm_management_group_policy_assignment.require_tag : k => v.id }
}
