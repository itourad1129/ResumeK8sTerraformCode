terraform {
  backend "local" {}
  required_providers {
    kubernetes = {
      source  = "registry.terraform.io/hashicorp/kubernetes"
      version = "~> 2.23.0"
    }
    helm = {
      source  = "registry.terraform.io/hashicorp/helm"
      version = "~> 2.11.0"
    }
    minikube = {
      source  = "scott-the-programmer/minikube"
      version = "~> 0.3.3"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0.2"
    }
    github = {
      source  = "integrations/github"
      version = "~> 5.18.3"
    }
  }
  required_version = "~> 1.5.0"
}
