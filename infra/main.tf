terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  apis = [
    "run.googleapis.com",
    "cloudscheduler.googleapis.com",
    "firestore.googleapis.com",
    "secretmanager.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
  ]

  # Values are added out of band (gcloud secrets versions add): they never reach the Terraform state.
  secrets = ["llu-email", "llu-password", "apns-key-p8", "api-key"]

  secret_env = {
    LLU_EMAIL    = "llu-email"
    LLU_PASSWORD = "llu-password"
    APNS_KEY_P8  = "apns-key-p8"
    API_KEY      = "api-key"
  }

  plain_env = {
    APNS_KEY_ID    = var.apns_key_id
    APNS_TEAM_ID   = var.apns_team_id
    APNS_BUNDLE_ID = var.bundle_id
  }

  deploy = var.image == "" ? 0 : 1
}

resource "google_project_service" "apis" {
  for_each           = toset(local.apis)
  service            = each.value
  disable_on_destroy = false
}

resource "google_artifact_registry_repository" "images" {
  repository_id = "libreglance"
  format        = "DOCKER"
  location      = var.region
  depends_on    = [google_project_service.apis]
}

resource "google_firestore_database" "default" {
  name        = "(default)"
  type        = "FIRESTORE_NATIVE"
  location_id = var.region
  depends_on  = [google_project_service.apis]
}

resource "google_secret_manager_secret" "secrets" {
  for_each  = toset(local.secrets)
  secret_id = each.value

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

resource "google_service_account" "runtime" {
  account_id   = "libreglance-runtime"
  display_name = "LibreGlance API and poll service"
}

resource "google_project_iam_member" "runtime_firestore" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.runtime.email}"
}

resource "google_secret_manager_secret_iam_member" "runtime_secrets" {
  for_each  = google_secret_manager_secret.secrets
  secret_id = each.value.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runtime.email}"
}

resource "google_cloud_run_v2_service" "api" {
  count               = local.deploy
  name                = "libreglance-api"
  location            = var.region
  deletion_protection = false

  template {
    service_account = google_service_account.runtime.email

    scaling {
      min_instance_count = 0
      max_instance_count = 2
    }

    containers {
      image = var.image

      env {
        name = "API_KEY"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.secrets["api-key"].secret_id
            version = "latest"
          }
        }
      }
    }
  }

  depends_on = [google_secret_manager_secret_iam_member.runtime_secrets, google_firestore_database.default]
}

# The app registers its Live Activity token here; every call is checked against API_KEY.
resource "google_cloud_run_v2_service_iam_member" "api_public" {
  count    = local.deploy
  name     = google_cloud_run_v2_service.api[0].name
  location = var.region
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# Private: only the scheduler's service account may call it. Called every minute, so the
# instance stays warm (no cold start, and request-based billing stays in the free tier).
resource "google_cloud_run_v2_service" "poll" {
  count               = local.deploy
  name                = "libreglance-poll"
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  template {
    service_account                  = google_service_account.runtime.email
    timeout                          = "50s"
    max_instance_request_concurrency = 1

    scaling {
      min_instance_count = 0
      max_instance_count = 1
    }

    containers {
      image   = var.image
      command = ["uvicorn"]
      args    = ["libreglance.poll_api:app", "--host", "0.0.0.0", "--port", "8080"]

      dynamic "env" {
        for_each = local.plain_env
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = { for k, v in local.secret_env : k => v if k != "API_KEY" }
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.secrets[env.value].secret_id
              version = "latest"
            }
          }
        }
      }
    }
  }

  depends_on = [google_secret_manager_secret_iam_member.runtime_secrets, google_firestore_database.default]
}

resource "google_service_account" "scheduler" {
  account_id   = "libreglance-scheduler"
  display_name = "Calls the LibreGlance poll service"
}

resource "google_cloud_run_v2_service_iam_member" "scheduler_calls_poll" {
  count    = local.deploy
  name     = google_cloud_run_v2_service.poll[0].name
  location = var.region
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.scheduler.email}"
}

resource "google_cloud_scheduler_job" "poll" {
  count     = local.deploy
  name      = "libreglance-poll"
  region    = var.scheduler_region
  schedule  = "* * * * *"
  time_zone = "Europe/Paris"

  attempt_deadline = "50s"

  retry_config {
    retry_count = 0
  }

  http_target {
    http_method = "POST"
    uri         = "${google_cloud_run_v2_service.poll[0].uri}/poll"

    oidc_token {
      service_account_email = google_service_account.scheduler.email
      audience              = google_cloud_run_v2_service.poll[0].uri
    }
  }

  depends_on = [google_project_service.apis]
}

output "api_url" {
  value = local.deploy == 1 ? google_cloud_run_v2_service.api[0].uri : null
}

output "image_repo" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
}
