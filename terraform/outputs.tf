output "kubectl_context" {
  description = "kubectl context for the cluster (the Makefile uses the same one)."
  value       = kind_cluster.this.context_name
}

output "urls" {
  description = "Local URLs, reachable through the kind port mappings."
  value = {
    api        = "http://localhost:8080/items"
    grafana    = "http://localhost:3000/d/slo-demo-api"
    prometheus = "http://localhost:9090"
  }
}

output "grafana_admin_password" {
  description = "Grafana admin password (anonymous read-only access works without it)."
  value       = try(random_password.grafana_admin[0].result, null)
  sensitive   = true
}
