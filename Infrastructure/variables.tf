variable "project_id" {
  type    = string
  default = "neobanx-fraud-detection"
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "db_password" {
  type      = string
  sensitive = true
}