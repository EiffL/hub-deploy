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
      # The nfs server (like the hub, grafana and prometheus) is pinned to
      # the hyperdisk-capable core nodes (persistentNodeSelector in
      # charts/hub and charts/support), which cannot attach pd-* disks.
      name = "hub-nfs-lightcone"
      type = "hyperdisk-balanced"
      size = 50
    }
  }
}

# Cloud Build image builds + Workload Identity grants for lightcone-cli.
# The names it creates are wired into hubs/lightcone/config.yaml
# (LIGHTCONE_REGISTRY, LIGHTCONE_BUILD_BUCKET, LIGHTCONE_BUILD_SERVICE_ACCOUNT,
# singleuser.serviceAccountName).
module "lightcone" {
  source               = "../../modules/lightcone"
  name                 = local.name
  user_service_account = "${local.name}-hub-user"
  reader_service_accounts = [
    module.gke_cluster.service_accounts["gke-node"],
  ]
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
    # See tf/modules/gke_cluster: required with Workload Identity.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

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

# Dedicated node pools for dask-gateway scheduler/worker pods
# (nodeSelector hub.jupyter.org/node-purpose: dask in hubs/_common/config.yaml).
resource "google_container_node_pool" "user-lc-n2" {
  name     = "user-dask-n2-202609"
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
      "hub.jupyter.org/node-purpose" = "dask"
    }

    service_account = module.gke_cluster.service_accounts["gke-node"]
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}

resource "google_container_node_pool" "user-lc-n4d" {
  name     = "user-dask-n4d-202609"
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
      "hub.jupyter.org/node-purpose" = "dask"
    }

    service_account = module.gke_cluster.service_accounts["gke-node"]
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}
