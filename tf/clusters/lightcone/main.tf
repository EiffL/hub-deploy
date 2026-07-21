terraform {
  required_version = ">=1.8"
  backend "gcs" {
    bucket = "tf-state-lightconehub"
    prefix = "tf/state"
  }
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.7.0"
    }
  }
}

provider "google" {
  project = "lightconehub"
  region  = "europe-west1"
  zone    = "europe-west1-b"
}

locals {
  name = "lightcone"
}

data "google_client_config" "provider" {}

module "gke_cluster" {
  source = "../../modules/gke_cluster"
  name   = local.name
  hub_nfs_disks = {
    lightcone = {
      name = "hub-nfs-lightcone"
      type = "pd-balanced"
      size = 50
    }
  }
}

resource "google_container_node_pool" "user" {
  name     = "user-202510"
  cluster  = module.gke_cluster.cluster.id
  location = module.gke_cluster.cluster.location
  # node_locations lets us specify a single-zone regional cluster:
  node_locations = [data.google_client_config.provider.zone]

  lifecycle {
    ignore_changes = [node_count]
  }

  autoscaling {
    min_node_count = 0
    max_node_count = 4
  }

  node_config {
    machine_type = "e2-highmem-8"
    disk_size_gb = 100
    disk_type    = "pd-balanced"

    labels = {
      "hub.jupyter.org/node-purpose" = "user"
    }

    service_account = module.gke_cluster.service_accounts["gke-node"]
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}
