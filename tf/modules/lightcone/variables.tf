variable "name" {
  type        = string
  description = "Name of the deployment"
}

variable "user_service_account" {
  type        = string
  description = "The service account name for users"
}

variable "reader_service_accounts" {
  type        = list(string)
  default     = []
  description = "List of service account names to grant pull access to artifact registry"
}

variable "location" {
  type        = string
  description = "GCP location for cluster if different from provider zone, e.g. us-central1 for regional cluster"
  default     = null
}
