# Terraform for the k8s-slo-pipeline-demo learning project: creates the local
# kind cluster and installs the Helm releases. No cloud provider and no remote
# backend; state stays in this directory and is git-ignored.

terraform {
  required_version = ">= 1.14.0"

  required_providers {
    kind = {
      source  = "tehcyx/kind"
      version = "0.13.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "3.3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.9.1"
    }
  }
}
