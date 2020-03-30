terraform {
  required_version = "~> 0.12"
}

provider "google" {
  project     = var.project_id
  region      = var.region
  credentials = file("${path.module}/key.json")
}

locals {
  api_services = [
    "cloudbilling.googleapis.com",
    "compute.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "oslogin.googleapis.com",
    "serviceusage.googleapis.com"
  ]
}

data "google_project" "main" {
  project_id = var.project_id
}

resource "google_compute_project_metadata_item" "os_login" {
  project = data.google_project.main.project_id
  key     = "enable-oslogin"
  value   = "TRUE"
}

resource "google_compute_network" "vpc_network" {
  name                    = "vpc-network"
  auto_create_subnetworks = true
}

resource "google_project_service" "enabled" {
  for_each           = toset(local.api_services)
  service            = each.key
  disable_on_destroy = false
}

resource "google_compute_firewall" "ssh" {
  name    = "enable-ssh"
  network = google_compute_network.vpc_network.id

  allow {
    protocol = "tcp"
    ports    = [22]
  }

  target_tags = ["frontend", "redis"]
}

data "google_compute_default_service_account" "default" {}

module "php_instance_template" {
  service_account = {
    email  = data.google_compute_default_service_account.default.email
    scopes = ["compute-ro", "storage-ro"]
  }
  source               = "terraform-google-modules/vm/google//modules/instance_template"
  version              = "2.1.0"
  machine_type         = var.machine_type
  source_image_project = "ubuntu-os-cloud"
  source_image_family  = "ubuntu-1804-lts"
  name_prefix          = "php"
  tags                 = ["frontend"]
  network              = google_compute_network.vpc_network.id
  //  startup_script =<<EOT
  //#!/bin/bash
  //apt update -y
  //apt install -y ansible
  //gsutil cp -r ${google_storage_bucket.ansible.url}/ansible /opt
  //ansible-playbook /opt/ansible/playbook.yml -t nginx,php
  //EOT
  metadata = {
    enable-oslogin = "TRUE"
    user-data      = <<EOT
#cloud-config
packages: ["ansible"]
write_files:
- path: /etc/ansible/ansible.cfg
  content: |
      [defaults]
      remote_tmp     = /tmp
      local_tmp      = /tmp
runcmd:
- gsutil cp -r ${google_storage_bucket.ansible.url}/ansible /opt
- ansible-playbook /opt/ansible/playbook.yml -t web
EOT
  }
  access_config = [{
    nat_ip       = null
    network_tier = null
  }]
}

module "redis_instance_template" {
  service_account = {
    email  = data.google_compute_default_service_account.default.email
    scopes = ["compute-ro", "storage-ro"]
  }
  source               = "terraform-google-modules/vm/google//modules/instance_template"
  version              = "2.1.0"
  machine_type         = var.machine_type
  source_image_project = "ubuntu-os-cloud"
  source_image_family  = "ubuntu-1804-lts"
  name_prefix          = "redis"
  tags                 = ["redis"]
  network              = google_compute_network.vpc_network.id
  //  startup_script =<<EOT
  //#!/bin/bash
  //apt update -y
  //apt install -y ansible
  //gsutil cp -r ${google_storage_bucket.ansible.url}/ansible /opt
  //ansible-playbook /opt/ansible/playbook.yml -t redis
  //EOT
  metadata = {
    enable-oslogin = "TRUE"
    user-data      = <<EOT
#cloud-config
packages: ["ansible"]
write_files:
- path: /etc/ansible/ansible.cfg
  content: |
      [defaults]
      remote_tmp     = /tmp
      local_tmp      = /tmp
runcmd:
- gsutil cp -r ${google_storage_bucket.ansible.url}/ansible /opt
- ansible-playbook /opt/ansible/playbook.yml -t redis
EOT
  }
  access_config = [{
    nat_ip       = null
    network_tier = null
  }]
}

module "php_mig" {
  source              = "terraform-google-modules/vm/google//modules/mig"
  version             = "2.1.0"
  instance_template   = module.php_instance_template.self_link
  region              = var.region
  autoscaling_enabled = false
  target_size         = 1
  project_id          = data.google_project.main.project_id
  hostname            = "php"
}

module "redis_mig" {
  source              = "terraform-google-modules/vm/google//modules/mig"
  version             = "2.1.0"
  instance_template   = module.redis_instance_template.self_link
  region              = var.region
  autoscaling_enabled = false
  target_size         = 1
  project_id          = data.google_project.main.project_id
  hostname            = "redis"
}

module "gce-lb-http" {
  source  = "GoogleCloudPlatform/lb-http/google"
  version = "~> 3.1"

  name              = "http-lb"
  project           = data.google_project.main.project_id
  target_tags       = ["frontend"]
  firewall_networks = [google_compute_network.vpc_network.name]
  backends = {
    default = {
      description                     = null
      protocol                        = "HTTP"
      port                            = 80
      port_name                       = "http"
      timeout_sec                     = 10
      connection_draining_timeout_sec = null
      enable_cdn                      = false

      health_check = {
        check_interval_sec  = null
        timeout_sec         = null
        healthy_threshold   = null
        unhealthy_threshold = null
        request_path        = "/"
        port                = 80
        host                = null
      }

      log_config = {
        enable      = true
        sample_rate = 1.0
      }

      groups = [
        {
          group                        = module.php_mig.instance_group
          balancing_mode               = null
          capacity_scaler              = null
          description                  = null
          max_connections              = null
          max_connections_per_instance = null
          max_connections_per_endpoint = null
          max_rate                     = null
          max_rate_per_instance        = null
          max_rate_per_endpoint        = null
          max_utilization              = null
        },
      ]
    }
  }
}
