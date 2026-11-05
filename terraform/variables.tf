variable "kind_config_path" {
  description = "kind cluster config, shared with `make cluster` so both create the same cluster."
  type        = string
  default     = "../kind/kind-config.yaml"
}

variable "metrics_server_chart_version" {
  description = "metrics-server Helm chart version (same as METRICS_SERVER_CHART_VERSION in the Makefile)."
  type        = string
  default     = "3.14.0"
}

variable "kube_prometheus_stack_chart_version" {
  description = "kube-prometheus-stack Helm chart version (same as KPS_CHART_VERSION in the Makefile)."
  type        = string
  default     = "92.17.1"
}

variable "install_monitoring" {
  description = "Install kube-prometheus-stack. Set to false for a lighter cluster with only metrics-server."
  type        = bool
  default     = true
}
