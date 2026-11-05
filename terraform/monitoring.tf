# kube-prometheus-stack with the same trimmed values as `make monitoring`.
# The ServiceMonitor, SLO rules, and dashboard stay in Kustomize
# (`make monitoring-manifests`): they need the chart's CRDs, which do not exist
# yet when Terraform plans a brand-new cluster.

resource "kubernetes_namespace_v1" "monitoring" {
  count = var.install_monitoring ? 1 : 0

  metadata {
    name = "monitoring"
  }
}

# Random Grafana admin password. It is stored in the local, git-ignored
# Terraform state; read it with `terraform output -raw grafana_admin_password`.
resource "random_password" "grafana_admin" {
  count = var.install_monitoring ? 1 : 0

  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "grafana_admin" {
  count = var.install_monitoring ? 1 : 0

  metadata {
    name      = "grafana-admin"
    namespace = kubernetes_namespace_v1.monitoring[0].metadata[0].name
  }

  data = {
    admin-user     = "admin"
    admin-password = random_password.grafana_admin[0].result
  }
}

resource "helm_release" "kube_prometheus_stack" {
  count = var.install_monitoring ? 1 : 0

  name       = "kps"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.kube_prometheus_stack_chart_version
  namespace  = kubernetes_namespace_v1.monitoring[0].metadata[0].name
  values     = [file("${path.module}/../monitoring/kube-prometheus-stack-values.yaml")]
  wait       = true
  timeout    = 600

  depends_on = [
    kubernetes_secret_v1.grafana_admin,
    helm_release.metrics_server,
  ]
}
