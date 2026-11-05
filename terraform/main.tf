locals {
  # Read the same YAML that `make cluster` passes to `kind create cluster`,
  # so the node image and port mappings are defined in one place.
  kind_config = yamldecode(file("${path.module}/${var.kind_config_path}"))
}

resource "kind_cluster" "this" {
  name           = local.kind_config.name
  wait_for_ready = true

  kind_config {
    kind        = local.kind_config.kind
    api_version = local.kind_config.apiVersion

    dynamic "node" {
      for_each = local.kind_config.nodes
      content {
        role  = node.value.role
        image = node.value.image

        dynamic "extra_port_mappings" {
          for_each = try(node.value.extraPortMappings, [])
          content {
            container_port = extra_port_mappings.value.containerPort
            host_port      = extra_port_mappings.value.hostPort
            listen_address = extra_port_mappings.value.listenAddress
            protocol       = extra_port_mappings.value.protocol
          }
        }
      }
    }
  }
}

# The providers connect with the credentials kind generated for this cluster.
provider "kubernetes" {
  host                   = kind_cluster.this.endpoint
  client_certificate     = kind_cluster.this.client_certificate
  client_key             = kind_cluster.this.client_key
  cluster_ca_certificate = kind_cluster.this.cluster_ca_certificate
}

provider "helm" {
  kubernetes = {
    host                   = kind_cluster.this.endpoint
    client_certificate     = kind_cluster.this.client_certificate
    client_key             = kind_cluster.this.client_key
    cluster_ca_certificate = kind_cluster.this.cluster_ca_certificate
  }
}

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = var.metrics_server_chart_version
  namespace  = "kube-system"
  values     = [file("${path.module}/../monitoring/metrics-server-values.yaml")]
  wait       = true
}
