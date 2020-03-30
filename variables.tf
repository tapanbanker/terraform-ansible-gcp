//variable "billing_account_id" {}

variable "project_id" {
  description = "The name of the new GCP project"
}

variable "machine_type" {
  description = "The machine type for compute instances use"
  default     = "f1-micro"
}

variable "region" {
  description = "GCP region"
  default     = "us-east1"
}