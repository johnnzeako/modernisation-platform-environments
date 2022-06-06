#------------------------------------------------------------------------------
# Windows Jumpserver
# TODO: once we have an AMI in prod everything can be uncommented.  I've not
# uncommented the security group as its references elsewhere
#------------------------------------------------------------------------------

data "aws_subnet" "private_az_a" {
  tags = {
    Name = "${local.vpc_name}-${local.environment}-${local.subnet_set}-private-${local.region}a"
  }
}

data "aws_ami" "jumpserver_image" {
  most_recent = true
  owners      = ["801119661308"] # Microsoft

  filter {
    name   = "name"
    values = ["Windows_Server-2022-English-Full-Base-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# user-data template
data "template_file" "user_data" {
  template = file("./templates/jumpserver-user-data.yaml")
  vars = {
    # WEBOPS_PASSWORD = aws_ssm_parameter.webops.name
    S3_BUCKET = module.s3-bucket.bucket.id
  }
}

resource "aws_instance" "jumpserver_windows" {
  instance_type               = "t3.medium"
  ami                         = "ami-0e5bdd429f857895a" #data.aws_ami.jumpserver_image.id
  associate_public_ip_address = false
  iam_instance_profile        = aws_iam_instance_profile.ec2_jumpserver_profile.id
  ebs_optimized               = true
  monitoring                  = false
  vpc_security_group_ids      = [aws_security_group.jumpserver-windows.id]
  subnet_id                   = data.aws_subnet.private_az_a.id
  key_name                    = aws_key_pair.ec2-user.key_name
  user_data                   = data.template_file.user_data.rendered
  user_data_replace_on_change = false
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }
  root_block_device {
    delete_on_termination = true
    encrypted             = true
    volume_type           = "gp3"
  }

  tags = merge(
    local.tags,
    {
      Name          = "jumpserver_windows"
      os_type       = "Windows"
      os_version    = "2019"
      always_on     = "false"
      "Patch Group" = "${aws_ssm_patch_group.windows.patch_group}"
    }
  )
}

resource "aws_security_group" "jumpserver-windows" {
  description = "Configure Windows jumpserver egress"
  name        = "jumpserver-windows-${local.application_name}"
  vpc_id      = local.vpc_id

  ingress {
    description = "access from Cloud Platform Prometheus server"
    from_port   = "9182"
    to_port     = "9182"
    protocol    = "TCP"
    cidr_blocks = [local.accounts[local.environment].database_external_access_cidr.cloud_platform]
  }

  egress {
    description = "allow all"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    #tfsec:ignore:aws-vpc-no-public-egress-sgr
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "ec2_jumpserver_role" {
  name                 = "ec2-jumpserver-role"
  path                 = "/"
  max_session_duration = "3600"
  assume_role_policy = jsonencode(
    {
      "Version" : "2012-10-17",
      "Statement" : [
        {
          "Effect" : "Allow",
          "Principal" : {
            "Service" : "ec2.amazonaws.com"
          }
          "Action" : "sts:AssumeRole",
          "Condition" : {}
        }
      ]
    }
  )
  managed_policy_arns = local.ec2_common_managed_policies
  tags = merge(
    local.tags,
    {
      Name = "ec2-jumpserver-role"
    },
  )
}

resource "aws_iam_instance_profile" "ec2_jumpserver_profile" {
  name = "ec2-jumpserver-profile"
  role = aws_iam_role.ec2_jumpserver_role.name
  path = "/"
}

locals {
  jumpserver_users = [
    "rwhittlemoj",
    "julialawrence",
    "ewastempel"
  ]
}

# Create password for each user
resource "random_password" "jumpserver_users" {
  for_each = toset(local.jumpserver_users)
  length   = 32
  special  = true
}

# put in parameter store
# resource "aws_ssm_parameter" "webops" {
#   name        = "/Jumpserver/Users/WebOps"
#   description = "Jumpserver password for WebOps user"
#   type        = "SecureString"
#   value       = random_password.webops.result

#   tags = merge(
#     local.tags,
#     {
#       Name = "jumpserver-webops-password"
#     }
#   )
# }

# put in secret manager
resource "aws_secretsmanager_secret" "jumpserver_users" {
  for_each = toset(local.jumpserver_users)
  name     = "/Jumpserver/Users/${each.value}"
  # policy = data.aws_iam_policy_document.jumpserver_users[each.value].json
  tags = merge(
    local.tags,
    {
      Name = "jumpserver-user-${each.value}"
    },
  )
}

data "aws_iam_policy_document" "jumpserver_secrets" {
  for_each = toset(local.jumpserver_users)
  statement {
    effect    = "Deny"
    actions   = ["secretsmanager:*"]
    resources = ["*"]
    not_principals {
      type = "AWS"
      identifiers = [
        "arn:aws:sts::${data.aws_caller_identity.current.id}:assumed-role/${aws_iam_role.ec2_jumpserver_role.name}/${aws_instance.jumpserver_windows.id}",
        "arn:aws:sts::${data.aws_caller_identity.current.id}:assumed-role/AWSReservedSSO_modernisation-platform-developer_*/${each.value}*",
        "arn:aws:sts::${data.aws_caller_identity.current.id}:assumed-role/MemberInfrastructureAccess/*" # so terraform can wrangle it
      ]
    }
  }
}

resource "aws_secretsmanager_secret_version" "jumpserver_users" {
  for_each      = toset(local.jumpserver_users)
  secret_id     = aws_secretsmanager_secret.jumpserver_users[each.value].id
  secret_string = random_password.jumpserver_users[each.value].result
}

# permissions to retrieve it
data "aws_iam_policy_document" "jumpserver_users" {
  # statement {
  #   effect    = "Allow"
  #   actions   = ["ssm:GetParameter"]
  #   resources = ["arn:aws:ssm:${local.region}:${data.aws_caller_identity.current.id}:parameter${aws_ssm_parameter.jumpserver_users.name}"]
  # }
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:aws:secretsmanager:${local.region}:${data.aws_caller_identity.current.id}:secret:/Jumpserver/Users/*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:ListSecrets"]
    resources = ["*"]
  }
}

# Add policy to role
resource "aws_iam_role_policy" "jumpserver_users" {
  name   = "secrets-access-jumpserver-users"
  role   = aws_iam_role.ec2_jumpserver_role.id
  policy = data.aws_iam_policy_document.jumpserver_users.json
}



# Create an empty parameter for Adminstrator password recovery using
# AWSSupport-RunEC2RescueForWindowsTool Systems Manager Run Command
# https://docs.aws.amazon.com/AWSEC2/latest/WindowsGuide/ec2rw-ssm.html
# Pre-creating it so it gets deleted with the instance

# resource "aws_ssm_parameter" "jumpserver_ec2_rescue" {
#   name        = "/EC2Rescue/Passwords/${aws_instance.jumpserver_windows.id}"
#   description = "Jumpserver local admin password"
#   type        = "SecureString"
#   value       = "default"

#   tags = merge(
#     local.tags,
#     {
#       Name = "jumpserver-admin-password"
#     }
#   )
#   lifecycle {
#     # ignore changes to value and description as will get updated by Systems Manager automation
#     ignore_changes = [
#       value,
#       description
#     ]
#   }
# }

# data "aws_iam_policy_document" "jumpserver_put_parameter" {
#   statement {
#     effect = "Allow"
#     actions = [
#       "ssm:PutParameter",
#     ]
#     resources = [aws_ssm_parameter.jumpserver_ec2_rescue.arn]
#   }
# }

# resource "aws_iam_role_policy" "jumpserver_put_parameter" {
#   name   = "jumpserver-parameter-access"
#   role   = aws_iam_role.ec2_jumpserver_role.id
#   policy = data.aws_iam_policy_document.jumpserver_put_parameter.json
# }

# # Automation to recover password to parameter store on instance creation
# resource "aws_ssm_association" "jumpserver_ec2_rescue" {
#   name             = "AWSSupport-RunEC2RescueForWindowsTool"
#   association_name = "jumpserver-ec2-rescue"
#   parameters = {
#     Command = "ResetAccess"
#   }
#   targets {
#     key    = "InstanceIds"
#     values = [aws_instance.jumpserver_windows.id]
#   }
#   depends_on = [
#     aws_iam_role_policy.jumpserver_put_parameter,
#     aws_ssm_parameter.jumpserver_ec2_rescue
#   ]
# }
