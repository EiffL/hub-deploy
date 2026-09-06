terraform {
  required_version = ">=1.8"
  backend "gcs" {
    bucket = "tf-state-bids-hub-demo"
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
  project = "bids-jupyterhub"
  region  = "us-central1"
  zone    = "us-central1-a"
}

locals {
  name = "demo"
}

data "google_client_config" "provider" {}

module "gke_cluster" {
  source = "../../modules/gke_cluster"
  name   = local.name
  hub_nfs_disks = {
    hd = {
      name = "hub-nfs-demo-hyperdisk"
      type = "hyperdisk-balanced"
      size = 50
    }
  }
}

module "lightcone" {
  source               = "../../modules/lightcone"
  name                 = local.name
  user_service_account = "${local.name}-hub-user"
  reader_service_accounts = [
    module.gke_cluster.service_accounts["gke-node"],
  ]
}


resource "google_container_node_pool" "user-2607" {
  name     = "user-202607"
  cluster  = module.gke_cluster.cluster.id
  location = module.gke_cluster.cluster.location
  # node_locations lets us specify a single-zone regional cluster:
  node_locations = [data.google_client_config.provider.zone]

  lifecycle {
    ignore_changes = [node_count]
  }

  autoscaling {
    min_node_count = 0
    max_node_count = 5
  }

  node_config {
    # See tf/modules/gke_cluster: required with Workload Identity.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    machine_type = "n2-highmem-8"
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

resource "google_container_node_pool" "user-lc-n2" {
  name     = "user-dask-n2-202607"
  cluster  = module.gke_cluster.cluster.id
  location = module.gke_cluster.cluster.location
  # node_locations lets us specify a single-zone regional cluster:
  node_locations = [data.google_client_config.provider.zone]

  lifecycle {
    ignore_changes = [node_count]
  }

  autoscaling {
    min_node_count = 0
    max_node_count = 2
  }

  node_config {
    # See tf/modules/gke_cluster: required with Workload Identity.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    machine_type = "n2-standard-8"
    disk_size_gb = 100
    disk_type    = "pd-balanced"

    labels = {
      # should these be user nodes, or dedicated to dask?
      "hub.jupyter.org/node-purpose" = "dask"
    }

    service_account = module.gke_cluster.service_accounts["gke-node"]
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}

resource "google_container_node_pool" "user-lc-n4d" {
  name     = "user-dask-n4d-202607"
  cluster  = module.gke_cluster.cluster.id
  location = module.gke_cluster.cluster.location
  # node_locations lets us specify a single-zone regional cluster:
  node_locations = [data.google_client_config.provider.zone]

  lifecycle {
    ignore_changes = [node_count]
  }

  autoscaling {
    min_node_count = 0
    max_node_count = 2
  }

  node_config {
    # See tf/modules/gke_cluster: required with Workload Identity.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    machine_type = "n4d-standard-8"
    disk_size_gb = 100
    disk_type    = "hyperdisk-balanced"

    labels = {
      # should these be user nodes, or dedicated to dask?
      "hub.jupyter.org/node-purpose" = "dask"
    }

    service_account = module.gke_cluster.service_accounts["gke-node"]
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}
