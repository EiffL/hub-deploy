terraform {
  required_version = ">=1.8"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.7.0"
    }
  }
}

# Image building for lightcone-cli via GCP Cloud Build: user server pods
# (through a dedicated Workload Identity principal) submit builds of a
# staged-context tarball; a dedicated build SA with registry-writer-only
# rights runs them. No credentials are stored anywhere — everything is IAM.

resource "google_project_service" "cloudbuild" {
  service            = "cloudbuild.googleapis.com"
  disable_on_destroy = false
}

data "google_project" "current" {}
data "google_client_config" "provider" {}

locals {
  # Direct Workload Identity principal for the dedicated singleuser
  # Kubernetes SA (created by charts/hub, selected via
  # jupyterhub.singleuser.serviceAccountName). Scoping to this one KSA —
  # rather than the whole namespace (principalSet .../namespace/<ns>) —
  # keeps these GCP grants off the hub control plane and, crucially, off
  # the dask scheduler/worker pods, which run user-built images on the
  # namespace `default` SA. Requires WI on the cluster + node pools (see
  # tf/modules/gke_cluster).
  user_principal = "principal://iam.googleapis.com/projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${data.google_client_config.provider.project}.svc.id.goog/subject/ns/${var.name}/sa/${var.user_service_account}"
  location       = var.location != null ? var.location : data.google_client_config.provider.region
}

# ---- registry for built project images ------------------------------------

resource "google_artifact_registry_repository" "images" {
  location      = local.location
  repository_id = "${var.name}-cloudbuild-images"
  format        = "DOCKER"
  description   = "lightcone-cli project images built by Cloud Build"
}

# Nodes pull the built images for dask worker pods; the hardened node SA
# (roles/container.defaultNodeServiceAccount) has no registry read.
resource "google_artifact_registry_repository_iam_member" "nodes_read_images" {
  for_each   = toset(var.reader_service_accounts)
  repository = google_artifact_registry_repository.images.name
  location   = google_artifact_registry_repository.images.location
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${each.key}"
}

# User server pods probe image existence (content-addressed freshness check).
resource "google_artifact_registry_repository_iam_member" "user_read_images" {
  repository = google_artifact_registry_repository.images.name
  location   = google_artifact_registry_repository.images.location
  role       = "roles/artifactregistry.reader"
  member     = local.user_principal
}

# ---- build sources + logs bucket ------------------------------------------

resource "google_storage_bucket" "lc_build" {
  name                        = "${data.google_client_config.provider.project}-${var.name}-lc-build"
  location                    = local.location
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

# User server pods upload build sources and read failure logs. Split into
# create + view (NOT objectAdmin): one user cannot overwrite or delete
# another's uploaded build context. Cross-user *read* of these short-lived,
# content-addressed objects remains possible under bucket-wide viewer; if
# that matters, move to per-user object prefixes with IAM conditions.
resource "google_storage_bucket_iam_member" "user_bucket_create" {
  bucket = google_storage_bucket.lc_build.name
  role   = "roles/storage.objectCreator"
  member = local.user_principal
}

resource "google_storage_bucket_iam_member" "user_bucket_view" {
  bucket = google_storage_bucket.lc_build.name
  role   = "roles/storage.objectViewer"
  member = local.user_principal
}

# ---- dedicated build service account (least privilege) --------------------

resource "google_service_account" "lc_build" {
  account_id   = "${var.name}-lc-build"
  display_name = "Cloud Build runner for lightcone image builds (${var.name})"
}

resource "google_artifact_registry_repository_iam_member" "build_sa_write" {
  repository = google_artifact_registry_repository.images.name
  location   = google_artifact_registry_repository.images.location
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.lc_build.email}"
}

resource "google_storage_bucket_iam_member" "build_sa_bucket" {
  bucket = google_storage_bucket.lc_build.name
  role   = "roles/storage.objectAdmin" # read sources, write logs, clean up
  member = "serviceAccount:${google_service_account.lc_build.email}"
}

# Cloud Build validates access to a user-specified source/logs bucket at
# submission time with a bucket-level storage.buckets.get, which
# objectAdmin (object-level only) lacks — without this the build is
# rejected with "service account ... does not have access to the bucket".
# legacyBucketReader adds buckets.get (+ object list) and nothing else.
resource "google_storage_bucket_iam_member" "build_sa_bucket_get" {
  bucket = google_storage_bucket.lc_build.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.lc_build.email}"
}

# ---- what user server pods may do -----------------------------------------

# Submit builds…
resource "google_project_iam_member" "user_builds_editor" {
  project = data.google_client_config.provider.project
  role    = "roles/cloudbuild.builds.editor"
  member  = local.user_principal
}

# …that run as the dedicated build SA.
resource "google_service_account_iam_member" "user_use_build_sa" {
  service_account_id = google_service_account.lc_build.name
  role               = "roles/iam.serviceAccountUser"
  member             = local.user_principal
}
