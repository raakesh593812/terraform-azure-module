terraform {
  required_version = ">= 0.12.0"
}

module "resource_group" {
source		= "./modules/ResourceGroup"
name     = "${var.application}-${var.environment}-RG"
locations = "${var.location}"
tags     = "${(var.default_tags)}"
}

module "application-vnet" {
  source              = "./modules/vnet"
  resource_group_name = "${module.resource_group.resource_group_name}"
  location            = "${var.location}"
  tags     = "${(var.default_tags)}"
  vnet_name           = "${var.application}-${var.environment}-vnet"
  address_space       = "${var.address_space}"
}
resource "azurerm_subnet" "subnet1" {
   count                = "${var.clientnetworks != "" ? length(var.clientnetworks) : 0}"
    name                = "${var.application}-${var.environment}-${element(var.clientnetworks[*].name,count.index)}" 
    address_prefixes    = [element(var.clientnetworks[*].value,count.index)]
    resource_group_name  = "${module.resource_group.resource_group_name}"
    virtual_network_name = "${module.application-vnet.vnet_name}"
    enforce_private_link_service_network_policies = element(var.clientnetworks[*].private_link_service,count.index)
    enforce_private_link_endpoint_network_policies  = element(var.clientnetworks[*].private_endpoint,count.index) 
}



resource "azurerm_network_security_group" "nsg" {
  name                = "${var.application}-${var.environment}-NSG"
  resource_group_name = "${module.resource_group.resource_group_name}"
  location            = "${var.location}"

  tags     = "${(var.default_tags)}"
}

resource "azurerm_subnet_network_security_group_association" "nsg_associate" {
  count                     = 2
  subnet_id                 = "${element(azurerm_subnet.subnet1.*.id, count.index)}"
  network_security_group_id = "${azurerm_network_security_group.nsg.id}"
}

resource "azurerm_lb" "azlb" {
    name                = "${var.application}-${var.environment}-lb"
    resource_group_name = "${module.resource_group.resource_group_name}"
    location            = "${var.location}"
    sku                 = "standard"
    tags                = "${(var.default_tags)}"
  
    frontend_ip_configuration {
      name                          = "${var.application}-${var.environment}-lb-feip"
      availability_zone             = 1
      subnet_id                     = "${azurerm_subnet.subnet1.0.id}"
      private_ip_address_allocation = "Dynamic"
    }
  }

  resource "azurerm_lb_backend_address_pool" "azlb" {
  name                = "BackEndAddressPool"
  loadbalancer_id     = "${azurerm_lb.azlb.id}"
}

resource "azurerm_lb_probe" "azlb" {

  resource_group_name = "${module.resource_group.resource_group_name}"
  loadbalancer_id     = "${azurerm_lb.azlb.id}"
  name                = "ssh-running-probe"
  port                = 22

}

resource "azurerm_lb_rule" "azlb" {
  name                           = "LB_rule"
  resource_group_name = "${module.resource_group.resource_group_name}"
  loadbalancer_id     = "${azurerm_lb.azlb.id}"
  protocol                       = "TCP"
  frontend_port                  = 22
  backend_port                   = 22
  frontend_ip_configuration_name = "${var.application}-${var.environment}-lb-feip"
  enable_floating_ip             = false
  backend_address_pool_id        = "${azurerm_lb_backend_address_pool.azlb.id}"
  idle_timeout_in_minutes        = 5
  probe_id                       = "${azurerm_lb_probe.azlb.id}"
}

resource "azurerm_private_link_service" "az_private_link" {
  name                = "${var.application}-${var.environment}-pls"
  location            = "${var.location}"
  resource_group_name = "${module.resource_group.resource_group_name}"

  load_balancer_frontend_ip_configuration_ids = [azurerm_lb.azlb.frontend_ip_configuration.0.id]
    nat_ip_configuration {
    name                       = "primary"
    private_ip_address         = "10.134.2.17"
    private_ip_address_version = "IPv4"
    subnet_id                  = "${azurerm_subnet.subnet1.1.id}"
    primary                    = true
  }

}


resource "azurerm_private_endpoint" "pep" {
  name                =  "${var.application}-${var.environment}-ple"
  location            = "${var.location}"
  resource_group_name = "${module.resource_group.resource_group_name}"
  subnet_id           = "${azurerm_subnet.subnet1.1.id}"

  private_service_connection {
    name                           = "example-privateserviceconnection"
    private_connection_resource_id = "${azurerm_private_link_service.az_private_link.id}"
    is_manual_connection           = false
  }
}

#  resource "azurerm_network_interface" "test" {
#    count               = 2
#    name                = "${var.application}-${var.environment}-ple-${count.index}"
#   location            = "${var.location}"
#   resource_group_name = "${module.resource_group.resource_group_name}"

#    ip_configuration {
#      name                          = "testConfiguration"
#      subnet_id                     = "${azurerm_subnet.subnet1.0.id}"
#      private_ip_address_allocation = "dynamic"
#    }
#  }

#  resource "azurerm_network_interface_backend_address_pool_association" "azlb_nicasso" {
#   count                   = 2 
#   network_interface_id    = "${element(azurerm_network_interface.test.*.id, count.index)}"
#   ip_configuration_name   = "testConfiguration"
#   backend_address_pool_id = "${azurerm_lb_backend_address_pool.azlb.id}"
# }

# resource "azurerm_linux_virtual_machine" "azvm" {
#   count               = 2
#   name                  = "acctvm${count.index}"
#   location            = "${var.location}"
#   resource_group_name = "${module.resource_group.resource_group_name}"
#   size                = "Standard_DS1_v2"
#   admin_username      = "adminuser"
#   admin_password      = "Password1234!"
#   network_interface_ids =["${element(azurerm_network_interface.test.*.id, count.index)}"]
#   disable_password_authentication = false

#   os_disk {
#     caching              = "ReadWrite"
#     storage_account_type = "Standard_LRS"
#   }

#   source_image_reference {
#     publisher = "Canonical"
#     offer     = "UbuntuServer"
#     sku       = "16.04-LTS"
#     version   = "latest"
#   }
# }
data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "keyvault" {
  name                = "${var.keyvault}"
  location            = "${var.location}"
  resource_group_name = "${module.resource_group.resource_group_name}"
  tenant_id           = "${data.azurerm_client_config.current.tenant_id}"
  sku_name            = "premium"

}

resource "azurerm_key_vault_access_policy" "kv_access_policy" {
  key_vault_id = "${azurerm_key_vault.keyvault.id}"
  tenant_id    = "${data.azurerm_client_config.current.tenant_id}"
  object_id    = "06f10a49-0f83-415d-a9c1-7f39399b1950"

  key_permissions = [
    "Get",
  ]

  secret_permissions = [
    "Get",
  ]
}

resource "azurerm_private_endpoint" "pep_kv" {
  name                =  "${var.application}-${var.environment}-ple-kv"
  location            = "${var.location}"
  resource_group_name = "${module.resource_group.resource_group_name}"
  subnet_id           = "${azurerm_subnet.subnet1.1.id}"

  private_service_connection {
    name                           = "example-privateserviceconnection"
    private_connection_resource_id = "${azurerm_key_vault.keyvault.id}"
    is_manual_connection           = false
    subresource_names              = ["Vault"]
  }
}

resource "azurerm_storage_account" "azstoacc" {
  name                      = "xklzzccxsa01"
  location            = "${var.location}"
  resource_group_name = "${module.resource_group.resource_group_name}"
  account_tier              = "Standard"
  account_kind              = "StorageV2"
  account_replication_type  = "LRS"
  allow_blob_public_access  = "false"
  is_hns_enabled            = "true"

  network_rules {
    default_action             = "Deny"
    #ip_rules                   = ["149.206.8.223"]
    #virtual_network_subnet_ids = ["${azurerm_subnet.subnet1.0.id}"]
  }
}
resource "azurerm_storage_container" "az_sto_container" {
  count                 = "${length(var.storage_container_name)}"
  name                  = "${element(var.storage_container_name, count.index)}"
  storage_account_name  = "${azurerm_storage_account.azstoacc.name}"
  container_access_type = "private"
}
data "azurerm_subscription" "primary" {
}

resource "azurerm_role_assignment" "azroleassign1" {
  scope                = "${data.azurerm_subscription.primary.id}"
  role_definition_name = "Reader"
  principal_id         = "${data.azurerm_client_config.current.object_id}"
}

resource "azurerm_private_endpoint" "pep_sa" {
  name                =  "${var.application}-${var.environment}-ple-sa"
  location            = "${var.location}"
  resource_group_name = "${module.resource_group.resource_group_name}"
  subnet_id           = "${azurerm_subnet.subnet1.1.id}"

  private_service_connection {
    name                           = "example-privateserviceconnection-sa"
    private_connection_resource_id = "${azurerm_storage_account.azstoacc.id}"
    is_manual_connection           = false
    subresource_names              = ["blob"]
  }
}
