variable "org_code" {
  type = string
}

variable "root_parent_id" {
  description = "Tenant root management group resource ID."
  type        = string
}

variable "subscription_id" {
  description = "The single subscription, placed in the corp landing zone leaf."
  type        = string
}

# Cloud Adoption Framework shape, three levels deep. See ADR 0002 for why not four.
#
#   Tenant Root
#     jbo-platform
#       jbo-platform-identity
#       jbo-platform-management
#       jbo-platform-connectivity
#     jbo-landing-zones
#       jbo-lz-corp          <- the subscription lives here
#       jbo-lz-online
#     jbo-sandbox
#     jbo-decommissioned

resource "azurerm_management_group" "platform" {
  name                       = "${var.org_code}-platform"
  display_name               = "Platform"
  parent_management_group_id = var.root_parent_id
}

resource "azurerm_management_group" "platform_children" {
  for_each = toset(["identity", "management", "connectivity"])

  name                       = "${var.org_code}-platform-${each.key}"
  display_name               = title(each.key)
  parent_management_group_id = azurerm_management_group.platform.id
}

resource "azurerm_management_group" "landing_zones" {
  name                       = "${var.org_code}-landing-zones"
  display_name               = "Landing Zones"
  parent_management_group_id = var.root_parent_id
}

resource "azurerm_management_group" "lz_corp" {
  name                       = "${var.org_code}-lz-corp"
  display_name               = "Corp"
  parent_management_group_id = azurerm_management_group.landing_zones.id

  # Subscription association lives here rather than in a separate
  # azurerm_management_group_subscription_association resource. Using both
  # forms against the same management group causes them to fight on every plan.
  subscription_ids = [var.subscription_id]
}

resource "azurerm_management_group" "lz_online" {
  name                       = "${var.org_code}-lz-online"
  display_name               = "Online"
  parent_management_group_id = azurerm_management_group.landing_zones.id
}

resource "azurerm_management_group" "sandbox" {
  name                       = "${var.org_code}-sandbox"
  display_name               = "Sandbox"
  parent_management_group_id = var.root_parent_id
}

resource "azurerm_management_group" "decommissioned" {
  name                       = "${var.org_code}-decommissioned"
  display_name               = "Decommissioned"
  parent_management_group_id = var.root_parent_id
}

output "platform_id" {
  value = azurerm_management_group.platform.id
}

output "landing_zones_id" {
  value = azurerm_management_group.landing_zones.id
}

output "lz_corp_id" {
  value = azurerm_management_group.lz_corp.id
}

output "lz_online_id" {
  value = azurerm_management_group.lz_online.id
}

output "sandbox_id" {
  value = azurerm_management_group.sandbox.id
}