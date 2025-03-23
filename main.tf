######################################
# Terraform & Provider Configuration
######################################
terraform {
  cloud {
    organization = "mark_kharitonov"

    workspaces {
      name = "opp_site_checker"
    }
  }
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0" # or a more recent version
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
  required_version = ">= 1.0"
}

provider "azurerm" {
  features {}
  # Subscription & credentials taken from env vars:
  # ARM_CLIENT_ID, ARM_CLIENT_SECRET, ARM_TENANT_ID, ARM_SUBSCRIPTION_ID
}

######################################
# Variables
######################################
variable "location" {
  type    = string
  default = "canadacentral"
}

# These map to TFC workspace env vars: TF_VAR_twilio_from, TF_VAR_twilio_sid, TF_VAR_twilio_token
variable "twilio_from" {
  type      = string
  sensitive = true
}

variable "twilio_sid" {
  type      = string
  sensitive = true
}

variable "twilio_token" {
  type      = string
  sensitive = true
}

######################################
# Data Sources
######################################
data "azurerm_client_config" "current" {}

######################################
# Resource Group
######################################
resource "azurerm_resource_group" "opp_site_checker" {
  name     = "rg-opp-site-checker"
  location = var.location
}

######################################
# Random Suffix for Uniqueness
######################################
resource "random_string" "suffix" {
  length  = 4
  special = false
  upper   = false
}

######################################
# Storage Account
######################################
resource "azurerm_storage_account" "opp_site_checker" {
  name                     = "stoppsitechecker${random_string.suffix.result}"
  resource_group_name      = azurerm_resource_group.opp_site_checker.name
  location                 = azurerm_resource_group.opp_site_checker.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
}

######################################
# Key Vault (RBAC-Enabled)
######################################
resource "azurerm_key_vault" "opp_site_checker" {
  name                      = "kv-opp-site-checker${random_string.suffix.result}"
  location                  = azurerm_resource_group.opp_site_checker.location
  resource_group_name       = azurerm_resource_group.opp_site_checker.name
  tenant_id                 = data.azurerm_client_config.current.tenant_id
  sku_name                  = "standard"
  enable_rbac_authorization = true
}

######################################
# Key Vault Secrets
######################################
locals {
  secrets = {
    twilio-from  = var.twilio_from
    twilio-sid   = var.twilio_sid
    twilio-token = var.twilio_token
  }
}

resource "azurerm_key_vault_secret" "secrets" {
  for_each     = local.secrets
  name         = each.key
  value        = each.value
  key_vault_id = azurerm_key_vault.opp_site_checker.id
}

######################################
# App Service Plan (Consumption)
######################################
resource "azurerm_app_service_plan" "opp_site_checker" {
  name                = "asp-opp-site-checker"
  location            = azurerm_resource_group.opp_site_checker.location
  resource_group_name = azurerm_resource_group.opp_site_checker.name
  kind                = "FunctionApp"
  reserved            = true

  sku {
    tier = "Dynamic"
    size = "Y1"
  }
}

######################################
# Package Function Code (Zip)
######################################
data "archive_file" "function_zip" {
  type        = "zip"
  source_dir  = "${path.module}/function_app"
  output_path = "${path.module}/function_app.zip"
}

######################################
# Azure Linux Function App
######################################
resource "azurerm_linux_function_app" "opp_site_checker" {
  name                       = "fn-opp-site-checker${random_string.suffix.result}"
  location                   = azurerm_resource_group.opp_site_checker.location
  resource_group_name        = azurerm_resource_group.opp_site_checker.name
  service_plan_id            = azurerm_app_service_plan.opp_site_checker.id
  storage_account_name       = azurerm_storage_account.opp_site_checker.name
  storage_account_access_key = azurerm_storage_account.opp_site_checker.primary_access_key

  # Which Functions runtime to use
  functions_extension_version = "~4"

  # Optionally set a Python version. Example:
  site_config {
    application_stack {
      python_version = "3.9"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  # Use Key Vault references in app settings
  app_settings = {
    "FUNCTIONS_WORKER_RUNTIME" = "python"
    "WEBSITE_RUN_FROM_PACKAGE" = "1"

    # Key Vault references for Twilio
    "TWILIO_FROM"  = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.secrets["twilio-from"].id})"
    "TWILIO_SID"   = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.secrets["twilio-sid"].id})"
    "TWILIO_TOKEN" = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.secrets["twilio-token"].id})"
  }

  # Deploy the code from the zip
  zip_deploy_file = data.archive_file.function_zip.output_path
}

######################################
# Grant Function App RBAC Permissions to Key Vault
######################################
resource "azurerm_role_assignment" "function_kv_reader" {
  scope                = azurerm_key_vault.opp_site_checker.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_function_app.opp_site_checker.identity.principal_id
}

######################################
# Outputs
######################################
output "function_app_name" {
  description = "Name of the deployed Function App"
  value       = azurerm_linux_function_app.opp_site_checker.name
}

output "function_app_url" {
  description = "Primary endpoint for the Function App"
  value       = azurerm_linux_function_app.opp_site_checker.default_hostname
}
