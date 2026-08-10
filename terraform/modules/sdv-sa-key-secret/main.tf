# Copyright (c) 2024-2026 Accenture, All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

data "google_project" "project" {}

resource "google_secret_manager_secret" "sa_key_secret" {
  secret_id = var.secret_id

  replication {
    user_managed {
      replicas {
        location = var.location
      }
    }
  }
}

resource "google_secret_manager_secret_version" "sa_key_secret_version" {
  secret      = google_secret_manager_secret.sa_key_secret.id
  secret_data = jsonencode({
    type         = "service_account"
    project_id   = var.project_id
    client_email = var.service_account_id
  })
}

resource "google_secret_manager_secret_iam_member" "member" {
  for_each  = { for idx, access in var.gke_access : idx => access }
  project   = google_secret_manager_secret.sa_key_secret.project
  secret_id = google_secret_manager_secret.sa_key_secret.secret_id
  role      = "roles/secretmanager.secretAccessor"
  ## ns/jenkins/jenkins-sa.
  member = "principal://iam.googleapis.com/projects/${data.google_project.project.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/${each.value.ns}/sa/${each.value.sa}"
}
