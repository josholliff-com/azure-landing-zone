variable "org_code" {
  type = string
}

variable "environment" {
  type = string
}

variable "location_short" {
  type = string
}

variable "workload" {
  type = string
}

locals {
  prefix = join("-", [var.org_code, var.environment, var.location_short, var.workload])
}

output "resource_group" {
  value = "${local.prefix}-rg"
}

output "virtual_network" {
  value = "${local.prefix}-vnet"
}

output "prefix" {
  value = local.prefix
}