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

variable "region" {
  description = "Define the Region"
  type        = string
}

variable "network" {
  description = "Define the Network"
  type        = string
}

variable "subnetwork" {
  description = "Define the Sub Network"
  type        = string
}

variable "router_name" {
  description = "Define the router name"
  type        = string
}

variable "enable_arm64_dedicated_subnet" {
  description = "Create dedicated ARM64 subnet and NAT in arm64_region (not required when ARM64 uses primary sdv-subnet)."
  type        = bool
}

variable "arm64_region" {
  description = "Define the ARM64 region"
  type        = string
}

variable "arm64_subnetwork" {
  description = "Define the ARM64 Subnetwork name"
  type        = string
}

variable "pods_range" {
  type = string
}

variable "services_range" {
  type = string
}

variable "arm64_pods_range" {
  type = string
}

variable "arm64_services_range" {
  type = string
}

variable "arm64_pods_secondary_range_name" {
  description = "Secondary IP range name for pods on the ARM64 dedicated subnet (must match existing GCP names for brownfield)."
  type        = string
}

variable "arm64_services_secondary_range_name" {
  description = "Secondary IP range name for services on the ARM64 dedicated subnet (must match existing GCP names for brownfield)."
  type        = string
}


# ---------------------------------------------------------------------------
# Internal ingress
#
# Set when the platform is exposed through a regional internal Application Load
# Balancer instead of the default global external one (see sdv_gateway_internal
# in terraform/env). The resources below are the infrastructure that a
# gke-l7-rilb Gateway needs: a proxy-only subnet for the managed Envoy proxies,
# a reserved VIP, and a private DNS zone so that in-cluster clients (OIDC
# issuers, callbacks) resolve the platform domain to that VIP.
# ---------------------------------------------------------------------------

variable "gateway_internal" {
  description = "Provision the infrastructure required by an internal (gke-l7-rilb) Gateway: proxy-only subnet, reserved internal VIP and private DNS zone."
  type        = bool
  default     = false
}

variable "gateway_proxy_subnet_name" {
  description = "Name of the REGIONAL_MANAGED_PROXY subnet required by the internal Application Load Balancer."
  type        = string
  default     = "sdv-proxy-subnet"
}

variable "gateway_proxy_subnet_cidr" {
  description = "CIDR of the proxy-only subnet. Must not overlap the node, pod or service ranges."
  type        = string
  default     = "10.129.0.0/23"
}

variable "gateway_address_name" {
  description = "Name of the reserved internal address used as the Gateway VIP."
  type        = string
  default     = "sdv-gateway-internal-ip"
}

variable "gateway_dns_zone_name" {
  description = "Name of the private Cloud DNS zone resolving the platform domain to the internal Gateway VIP."
  type        = string
  default     = "horizon-sdv-private"
}

variable "gateway_dns_domain" {
  description = "DNS domain of the private zone (no trailing dot), e.g. horizon-sdv.com."
  type        = string
  default     = ""
}

variable "gateway_dns_hostnames" {
  description = "Hostnames (no trailing dot) to point at the internal Gateway VIP, e.g. [dev.horizon-sdv.com, mcp.dev.horizon-sdv.com]."
  type        = list(string)
  default     = []
}
