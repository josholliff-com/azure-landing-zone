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