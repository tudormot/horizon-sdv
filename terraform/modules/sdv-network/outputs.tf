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

output "vpc_nat_router_name" {
  description = "The name of the created router for NAT."
  value       = google_compute_router.vpc_nat_router.name
}

output "vpc_nat_name" {
  description = "The name of the created NAT."
  value       = google_compute_router_nat.vpc_nat.name
}

output "vpc_nat_ip_name" {
  description = "The name of the created NAT ip address"
  value       = google_compute_address.vpc_nat_ip.name
}

output "gateway_internal_address" {
  description = "Reserved internal Gateway VIP (empty unless gateway_internal is set)."
  value       = var.gateway_internal ? google_compute_address.gateway_internal[0].address : ""
}

output "gateway_internal_address_name" {
  description = "Name of the reserved internal Gateway address; the GKE Gateway resolves the VIP by name (empty unless gateway_internal is set)."
  value       = var.gateway_internal ? google_compute_address.gateway_internal[0].name : ""
}
