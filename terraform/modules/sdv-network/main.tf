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

module "vpc" {
  source  = "terraform-google-modules/network/google"
  version = "~> 15.1"

  project_id   = data.google_project.project.project_id
  network_name = var.network
  routing_mode = "GLOBAL"

  subnets = concat(
    [
      {
        subnet_name               = var.subnetwork
        subnet_region             = var.region
        subnet_ip                 = "10.1.0.0/24"
        enable_ula_internal_ipv6  = true
        private_ip_google_access  = true
        subnet_flow_logs          = "true"
        subnet_flow_logs_interval = "INTERVAL_5_MIN"
        subnet_flow_logs_sampling = "0.5"
        subnet_flow_logs_metadata = "INCLUDE_ALL_METADATA"
        subnet_flow_logs_filter   = "true"
      }
    ],
    var.enable_arm64_dedicated_subnet ? [
      {
        subnet_name               = var.arm64_subnetwork
        subnet_region             = var.arm64_region
        subnet_ip                 = "10.2.0.0/24"
        enable_ula_internal_ipv6  = true
        private_ip_google_access  = true
        subnet_flow_logs          = "true"
        subnet_flow_logs_interval = "INTERVAL_5_MIN"
        subnet_flow_logs_sampling = "0.5"
        subnet_flow_logs_metadata = "INCLUDE_ALL_METADATA"
        subnet_flow_logs_filter   = "true"
      }
    ] : []
  )

  secondary_ranges = merge(
    {
      "${var.subnetwork}" = [
        {
          range_name    = "pods-range"
          ip_cidr_range = var.pods_range
        },
        {
          range_name    = "services-range"
          ip_cidr_range = var.services_range
        },
      ]
    },
    var.enable_arm64_dedicated_subnet ? {
      "${var.arm64_subnetwork}" = [
        {
          range_name    = var.arm64_pods_secondary_range_name
          ip_cidr_range = var.arm64_pods_range
        },
        {
          range_name    = var.arm64_services_secondary_range_name
          ip_cidr_range = var.arm64_services_range
        }
      ]
    } : {}
  )

  routes = [
    {
      name                     = var.router_name
      description              = "route through IGW to access internet"
      destination_range        = "0.0.0.0/0"
      tags                     = "egress-inet"
      next_hop_internet        = "true"
      private_ip_google_access = true
    }
  ]
}

# ---------------------------------------------------------------------------
# Internal ingress infrastructure (gateway_internal = true)
#
# Created only when the platform is served by a regional internal Application
# Load Balancer, i.e. in projects where organization policy forbids external
# load balancers (constraints/compute.restrictLoadBalancerCreationForTypes).
# ---------------------------------------------------------------------------

# Managed Envoy proxies of the regional internal ALB are allocated from this
# subnet. Without it the Gateway is created but never programmed.
resource "google_compute_subnetwork" "gateway_proxy_only" {
  count = var.gateway_internal ? 1 : 0

  name          = var.gateway_proxy_subnet_name
  project       = data.google_project.project.project_id
  region        = var.region
  network       = module.vpc.network_id
  ip_cidr_range = var.gateway_proxy_subnet_cidr
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"
}

# Reserving the VIP keeps the address stable across Gateway recreation, so the
# DNS records below never go stale.
resource "google_compute_address" "gateway_internal" {
  count = var.gateway_internal ? 1 : 0

  name         = var.gateway_address_name
  project      = data.google_project.project.project_id
  region       = var.region
  subnetwork   = module.vpc.subnets["${var.region}/${var.subnetwork}"].self_link
  address_type = "INTERNAL"
  purpose      = "SHARED_LOADBALANCER_VIP"
}

# Private zone: the platform domain is not publicly delegated in this mode, but
# in-cluster clients must still resolve it (Keycloak issuer, OAuth callbacks).
resource "google_dns_managed_zone" "gateway_internal" {
  count = var.gateway_internal ? 1 : 0

  name        = var.gateway_dns_zone_name
  dns_name    = "${var.gateway_dns_domain}."
  description = "Resolves the Horizon SDV domain to the internal Gateway VIP inside the VPC."
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = module.vpc.network_id
    }
  }
}

resource "google_dns_record_set" "gateway_internal" {
  for_each = var.gateway_internal ? toset(var.gateway_dns_hostnames) : toset([])

  project      = data.google_project.project.project_id
  managed_zone = google_dns_managed_zone.gateway_internal[0].name
  name         = "${each.value}."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_address.gateway_internal[0].address]
}
