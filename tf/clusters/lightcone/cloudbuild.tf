# Image building for lightcone-cli via GCP Cloud Build: user pods (through
# the namespace's Workload Identity principal) submit builds of a
# staged-context tarball; a dedicated build SA with registry-writer-only
# rights runs them. No credentials are stored anywhere — everything is IAM.

resource "google_project_service" "cloudbuild" {
  service            = "cloudbuild.googleapis.com"
  disable_on_destroy = false
}

data "google_project" "current" {}

locals {
  # Direct Workload Identity principal covering every pod in the hub
  # namespace (requires WI enabled on the cluster + node pools, see
  # tf/modules/gke_cluster). Same pattern as granting a namespace
  # registry read — no per-KSA Google service account needed.
  hub_principal = "principalSet://iam.googleapis.com/projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${data.google_client_config.provider.project}.svc.id.goog/namespace/${local.name}"
}

# ---- registry for built project images ------------------------------------

resource "google_artifact_registry_repository" "binder" {
  repository_id = "binder"
  location      = "europe-west1"
  format        = "DOCKER"
  description   = "lightcone project images built by Cloud Build"
}

# Nodes pull the built images for dask worker pods; the hardened node SA
# (roles/container.defaultNodeServiceAccount) has no registry read.
resource "google_artifact_registry_repository_iam_member" "nodes_read_binder" {
  repository = google_artifact_registry_repository.binder.name
  location   = google_artifact_registry_repository.binder.location
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${module.gke_cluster.service_accounts["gke-node"]}"
}

# Hub pods probe image existence (content-addressed freshness check).
resource "google_artifact_registry_repository_iam_member" "hub_read_binder" {
  repository = google_artifact_registry_repository.binder.name
  location   = google_artifact_registry_repository.binder.location
  role       = "roles/artifactregistry.reader"
  member     = local.hub_principal
}

# ---- build sources + logs bucket ------------------------------------------

resource "google_storage_bucket" "lc_build" {
  name                        = "${data.google_client_config.provider.project}-${local.name}-lc-build"
  location                    = "EUROPE-WEST1"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  lifecycle_rule {
    condition {
      age = 7 # sources are content-addressed re-uploads; logs are ephemeral
    }
    action {
      type = "Delete"
    }
  }
}

# Hub pods upload sources and read failure logs.
resource "google_storage_bucket_iam_member" "hub_bucket_admin" {
  bucket = google_storage_bucket.lc_build.name
  role   = "roles/storage.objectAdmin"
  member = local.hub_principal
}

# ---- dedicated build service account (least privilege) --------------------

resource "google_service_account" "lc_build" {
  account_id   = "${local.name}-lc-build"
  display_name = "Cloud Build runner for lightcone image builds (${local.name})"
}

resource "google_artifact_registry_repository_iam_member" "build_sa_write" {
  repository = google_artifact_registry_repository.binder.name
  location   = google_artifact_registry_repository.binder.location
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.lc_build.email}"
}

resource "google_storage_bucket_iam_member" "build_sa_bucket" {
  bucket = google_storage_bucket.lc_build.name
  role   = "roles/storage.objectAdmin" # read sources, write logs
  member = "serviceAccount:${google_service_account.lc_build.email}"
}

# ---- what user pods may do ------------------------------------------------

# Submit builds…
resource "google_project_iam_member" "hub_builds_editor" {
  project = data.google_client_config.provider.project
  role    = "roles/cloudbuild.builds.editor"
  member  = local.hub_principal
}

# …that run as the dedicated build SA.
resource "google_service_account_iam_member" "hub_use_build_sa" {
  service_account_id = google_service_account.lc_build.name
  role               = "roles/iam.serviceAccountUser"
  member             = local.hub_principal
}
