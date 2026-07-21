terraform {
  required_version = ">=1.8"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.7.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0.2"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38.0"
    }
  }
}

data "google_client_config" "provider" {}

locals {
  service_accounts = {
    deployer = {
      display_name = "Deployment account for ${var.name}",
      role         = "roles/container.admin",
    },
    gke-node = {
      display_name = "GKE Node SA for ${var.name}",
      role         = "roles/container.defaultNodeServiceAccount",
    },
  }
  location = var.gke_location != null ? var.gke_location : data.google_client_config.provider.region
  zone     = var.gke_zone != null ? var.gke_zone : data.google_client_config.provider.zone
}

resource "google_artifact_registry_repository" "repo" {
  location      = var.registry_location != null ? var.registry_location : data.google_client_config.provider.region
  repository_id = var.name
  description   = "${var.name} container registry"
  format        = "DOCKER"
}

resource "google_compute_network" "vpc" {
  name                    = "${var.name}-vpc"
  auto_create_subnetworks = "true"
}

resource "google_container_cluster" "cluster" {
  # Workload Identity: lets pods obtain namespace-scoped GCP identities
  # from the metadata server (used for keyless Cloud Build submission
  # and registry probing by lightcone-cli). Direct IAM grants target
  # principalSet://…/namespace/<ns> principals — no per-KSA GSAs.
  workload_identity_config {
    workload_pool = "${data.google_client_config.provider.project}.svc.id.goog"
  }

  name     = var.name
  location = local.location
  release_channel {
    channel = "REGULAR"
  }

  network = google_compute_network.vpc.name

  # terraform recommends removing the default node pool
  remove_default_node_pool = true
  initial_node_count       = 1

  maintenance_policy {
    # times are UTC
    # allow maintenance only on weekends,
    # from late Western Friday night (10pm Honolulu UTC-10)
    # to early Eastern Monday AM (4am Sydney UTC+11)
    recurring_window {
      start_time = "2021-01-02T08:00:00Z"
      end_time   = "2021-01-03T17:00:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=SA"
    }
  }
  timeouts {
    create = "20m"
    update = "30m"
  }
}

# define node pools here, too hard to encode with variables
resource "google_container_node_pool" "core" {
  name     = "core-2025-10"
  cluster  = google_container_cluster.cluster.name
  location = local.location # location of *cluster*
  # node_locations lets us specify a single-zone regional cluster:
  node_locations = [local.zone]

  lifecycle {
    ignore_changes = [node_count]
  }

  autoscaling {
    min_node_count = 1
    max_node_count = 3
  }
  node_count = 1

  node_config {
    machine_type = "e2-highmem-2"
    disk_size_gb = 50
    disk_type    = "pd-balanced"

    # Required with Workload Identity: the GKE metadata server hands
    # pods their namespace identity instead of the node SA.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    labels = {
      "hub.jupyter.org/node-purpose" = "core"
    }
    # Google recommends custom service accounts that have cloud-platform scope and permissions granted via IAM Roles.
    service_account = google_service_account.sa["gke-node"].email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}


output "cluster" {
  value = {
    name     = google_container_cluster.cluster.name,
    id       = google_container_cluster.cluster.id,
    location = google_container_cluster.cluster.location,
  }
}

# create mapping of service accounts
resource "google_service_account" "sa" {
  for_each     = local.service_accounts
  account_id   = "${var.name}-${each.key}"
  display_name = each.value.display_name
}

resource "google_project_iam_member" "iam" {
  project  = data.google_client_config.provider.project
  for_each = local.service_accounts
  role     = each.value.role
  member   = "serviceAccount:${google_service_account.sa[each.key].email}"
}

resource "google_project_iam_member" "deploy-pusher" {
  project = data.google_client_config.provider.project
  # deployer also gets storage admin
  role   = "roles/storage.admin"
  member = "serviceAccount:${google_service_account.sa["deployer"].email}"
}

# create keys for each service account
resource "google_service_account_key" "keys" {
  for_each           = local.service_accounts
  service_account_id = google_service_account.sa[each.key].account_id
}

output "private_keys" {
  value = {
    for sa_name in keys(local.service_accounts) :
    sa_name => base64decode(google_service_account_key.keys[sa_name].private_key)
  }
  sensitive = true
}

output "service_accounts" {
  value = {
    for sa_name in keys(local.service_accounts) :
    sa_name => google_service_account.sa[sa_name].email
  }
  sensitive = true
}

resource "google_compute_disk" "nfs" {
  for_each = var.hub_nfs_disks
  name     = each.value.name
  type     = each.value.type
  zone     = data.google_client_config.provider.zone
  size     = each.value.size
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_compute_address" "ingress" {
  name        = "${var.name}-ingress"
  description = "static ip for ${var.name} cluster ingress controller"
  region      = data.google_client_config.provider.region
}

provider "kubernetes" {
  host  = "https://${google_container_cluster.cluster.endpoint}"
  token = data.google_client_config.provider.access_token
  cluster_ca_certificate = base64decode(
    google_container_cluster.cluster.master_auth[0].cluster_ca_certificate,
  )
}

provider "helm" {
  kubernetes = {
    host  = "https://${google_container_cluster.cluster.endpoint}"
    token = data.google_client_config.provider.access_token
    cluster_ca_certificate = base64decode(
      google_container_cluster.cluster.master_auth[0].cluster_ca_certificate,
    )
  }
}

resource "kubernetes_namespace" "cert-manager" {
  metadata {
    name = "cert-manager"
  }
}

resource "kubernetes_namespace" "support" {
  metadata {
    name = "support"
  }
}

resource "helm_release" "cert-manager" {
  name       = "cert-manager"
  namespace  = kubernetes_namespace.cert-manager.metadata[0].name
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = "v1.19.1"
  set = [
    {
      name  = "crds.enabled"
      value = "true"
    },
    {
      name  = "config.apiVersion"
      value = "controller.config.cert-manager.io/v1alpha1"
    },
    {
      name  = "config.kind"
      value = "ControllerConfiguration"
    },
    {
      name  = "config.enableGatewayAPI"
      value = "true"
    },
    {
      name  = "ingressShim.defaultIssuerKind"
      value = "ClusterIssuer"
    }
  ]
}
