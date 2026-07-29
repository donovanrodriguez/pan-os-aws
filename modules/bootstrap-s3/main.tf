terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
    random = {
      source = "hashicorp/random"
    }
  }
}

variable "prefix" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}
variable "management_mode" {
  type    = string
  default = "panorama"
}
variable "panorama_ip" { type = string }
variable "panorama_auth_key" {
  type      = string
  sensitive = true
  default   = null
}
variable "panorama_device_group" { type = string }
variable "panorama_template_stack" { type = string }
variable "scm_folder" {
  type    = string
  default = null
}
variable "scm_pin_id" {
  type      = string
  sensitive = true
  default   = null
}
variable "scm_pin_value" {
  type      = string
  sensitive = true
  default   = null
}
variable "auth_codes" {
  type      = list(string)
  default   = []
  sensitive = true
}
variable "fw_configs" {
  type = map(object({
    hostname = string
  }))
}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "aws_s3_bucket" "bootstrap" {
  bucket        = "${var.prefix}-fw-bootstrap-${random_string.suffix.result}"
  force_destroy = true
  tags          = var.tags
}

resource "aws_s3_bucket_public_access_block" "bootstrap" {
  bucket                  = aws_s3_bucket.bootstrap.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "bootstrap" {
  bucket = aws_s3_bucket.bootstrap.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# One PAN-OS bootstrap package per firewall under <fw-key>/. The firewall's
# user_data points at "bucket/<fw-key>" and the instance role grants read.
resource "aws_s3_object" "init_cfg" {
  for_each     = var.fw_configs
  bucket       = aws_s3_bucket.bootstrap.id
  key          = "${each.key}/config/init-cfg.txt"
  content_type = "text/plain"

  content = var.management_mode == "scm" ? templatefile("${path.module}/templates/init-cfg-scm.txt.tmpl", {
    hostname   = each.value.hostname
    scm_folder = coalesce(var.scm_folder, "unset")
    pin_id     = coalesce(var.scm_pin_id, "unset")
    pin_value  = coalesce(var.scm_pin_value, "unset")
    }) : templatefile("${path.module}/templates/init-cfg.txt.tmpl", {
    hostname              = each.value.hostname
    panorama_ip           = var.panorama_ip
    panorama_auth_key     = coalesce(var.panorama_auth_key, "unset")
    panorama_device_group = var.panorama_device_group
    panorama_template     = var.panorama_template_stack
  })

  lifecycle {
    precondition {
      condition = var.management_mode == "scm" ? alltrue([
        var.scm_folder != null,
        var.scm_pin_id != null,
        var.scm_pin_value != null,
      ]) : var.panorama_auth_key != null
      error_message = "management_mode=scm requires scm_folder + scm_pin_id + scm_pin_value; management_mode=panorama requires panorama_auth_key."
    }
  }
}

resource "aws_s3_object" "authcodes" {
  for_each     = toset(keys(var.fw_configs))
  bucket       = aws_s3_bucket.bootstrap.id
  key          = "${each.value}/license/authcodes"
  content      = join("\n", var.auth_codes)
  content_type = "text/plain"
}

resource "aws_s3_object" "empty_software" {
  for_each     = toset(keys(var.fw_configs))
  bucket       = aws_s3_bucket.bootstrap.id
  key          = "${each.value}/software/.keep"
  content      = ""
  content_type = "text/plain"
}

resource "aws_s3_object" "empty_content" {
  for_each     = toset(keys(var.fw_configs))
  bucket       = aws_s3_bucket.bootstrap.id
  key          = "${each.value}/content/.keep"
  content      = ""
  content_type = "text/plain"
}

output "bucket_name" { value = aws_s3_bucket.bootstrap.bucket }
output "bucket_arn" { value = aws_s3_bucket.bootstrap.arn }
