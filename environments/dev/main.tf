module "naming" {
  source = "../../modules/naming"

  org_code       = "jbo"
  environment    = "dev"
  location_short = "eus2"
  workload       = "platform"
}

resource "azurerm_resource_group" "main" {
  name     = module.naming.resource_group
  location = "eastus2"

  tags = {
    Owner              = "platform"
    CostCenter         = "platform"
    Environment        = "dev"
    DataClassification = "internal"
  }
}

data "azurerm_client_config" "current" {}

module "management_groups" {
  source = "../../modules/management-groups"

  org_code        = "jbo"
  root_parent_id  = "/providers/Microsoft.Management/managementGroups/${data.azurerm_client_config.current.tenant_id}"
  subscription_id = data.azurerm_client_config.current.subscription_id
}
module "policy" {
  source = "../../modules/policy"

  org_code            = "jbo"
  definition_scope_id = "/providers/Microsoft.Management/managementGroups/${data.azurerm_client_config.current.tenant_id}"
  landing_zones_id    = module.management_groups.landing_zones_id
  lz_corp_id          = module.management_groups.lz_corp_id
  location            = "eastus2"

  enable_assignments = true
  tag_effect         = "Modify"
}
