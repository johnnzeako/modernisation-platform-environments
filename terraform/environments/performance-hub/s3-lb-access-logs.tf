module "lb-access-logs-enabled" {
  source = "/Users/zuri/gitWork/mod-platform/modernisation-platform-terraform-loadbalancer"

  vpc_all                             = "${local.vpc_name}-${local.environment}"
  application_name                    = local.application_name
  public_subnets                      = [data.aws_subnet.public_az_a.id,data.aws_subnet.public_az_b.id,data.aws_subnet.public_az_c.id]
  loadbalancer_ingress_rules          = local.loadbalancer_ingress_rules
  tags                                = local.tags
  account_number                      = local.environment_management.account_ids[terraform.workspace]
  region                              = local.app_data.accounts[local.environment].region
}
