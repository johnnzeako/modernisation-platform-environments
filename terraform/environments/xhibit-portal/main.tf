data "aws_caller_identity" "current" {}

module "vm-import" {

  source = "github.com/ministryofjustice/modernisation-platform-terraform-aws-vm-import"

  bucket_prefix    = local.application_data.accounts[local.environment].bucket_prefix
  tags             = local.tags
  application_name = local.application_name
  account_number   = data.aws_caller_identity.current.account_id

}
