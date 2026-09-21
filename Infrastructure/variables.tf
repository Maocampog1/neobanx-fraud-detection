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

variable "generator_salt" {
  type      = string
  sensitive = true
}

variable "dataset_url" {
  type    = string
  default = "https://storage.googleapis.com/neobanx-fraud-detection-datasets/fraudTrain.csv"
}