# Customer-managed CMK (with associated alias and key policy) used for encryption of EBS volumes and snapshots backing AMIs generated from image builder
resource "aws_kms_key" "sprinkler_ebs_encryption_cmk" {
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.sprinkler_ebs_encryption_policy_doc.json
}

resource "aws_kms_alias" "sprinkler_ebs_encryption_cmk_alias" {
  name          = "alias/sprinkler_ebs-encryption-key"
  target_key_id = aws_kms_key.sprinkler_ebs_encryption_cmk.id
}

data "aws_iam_policy_document" "sprinkler_ebs_encryption_policy_doc" {

  # checkov:skip=CKV_AWS_109: "Key policy requires asterisk resource"
  # checkov:skip=CKV_AWS_111: "Key policy requires asterisk resource"

  # Allow root users full management access to key
  statement {
    effect = "Allow"
    actions = [
      "kms:*"
    ]

    resources = ["*"] # Represents the key to which this policy is attached

    # AWS should add the AWS account by default but adding here for visibility
    # See https://docs.aws.amazon.com/kms/latest/developerguide/key-policies.html#key-policy-default-allow-root-enable-iam
    principals {
      type        = "AWS"
      identifiers = [data.aws_caller_identity.current.account_id] #
    }
  }

  # Allow all mod platform account to use this key so that they can launch ec2 instances based on AMIs backed by encrypted snapshots
  # Actions based on https://aws.amazon.com/blogs/security/how-to-share-encrypted-amis-across-accounts-to-launch-encrypted-ec2-instances/
  # Conditions for principals is based on approach taken for S3 example in https://aws.amazon.com/blogs/security/iam-share-aws-resources-groups-aws-accounts-aws-organizations/
  # Conditions for key grants is based on https://docs.aws.amazon.com/kms/latest/developerguide/key-policies.html#key-policy-service-integration
  statement {
    effect = "Allow"
    actions = [
      "kms:DescribeKey",
      "kms:ReEncrypt*",
      "kms:CreateGrant",
      "kms:Decrypt"
    ]

    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "ForAnyValue:StringLike"
      variable = "aws:PrincipalOrgPaths"
      values = [
        "${data.aws_organizations_organization.root_account.id}/*/${local.environment_management.modernisation_platform_organisation_unit_id}/*"
      ]
    }

  }

  # Allow all core-shared-services-production to use this key so that it can create encrypted volumes with EC2 Image Builder
  statement {
    effect = "Allow"
    actions = [
      "kms:CreateGrant",
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]

    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.environment_management.account_ids["core-shared-services-production"]}:root"]
    }
  }
}
