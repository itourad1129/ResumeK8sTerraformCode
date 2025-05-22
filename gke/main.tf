
# import {
#   id = "projects/pjdrc20240804/global/firewalls/allow-gameserver"
#   to = google_compute_firewall.allow_gameserver
# }

locals {
  is_unix            = substr(abspath(path.cwd), 0, 1) == "/"
  driver             = "hyperv"
  kubernetes_version = "v1.27.3"
  cluster_name       = "pjdrc-on-gke"
}

provider "kubernetes" {
  host                   = google_container_cluster.pjdrc-on-gke.endpoint
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.pjdrc-on-gke.master_auth.0.cluster_ca_certificate)
}

resource "google_container_cluster" "pjdrc-on-gke" {
  name       = "pjdrc-on-gke"
  location = "us-central1"
  project    = "pjdrc20240804"
  remove_default_node_pool = true
  initial_node_count = 1
}

resource "google_container_node_pool" "pjdrc_node_pool" {
  name       = "pjdrc-node-pool"
  cluster    = google_container_cluster.pjdrc-on-gke.name
  location   = google_container_cluster.pjdrc-on-gke.location
  project    = "pjdrc20240804"
  node_count = 1

  node_config {
    machine_type = "e2-standard-4"
    disk_size_gb = 100
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
    tags = ["gke-node"] # ← これを追加
  }

  depends_on = [google_container_cluster.pjdrc-on-gke]
}

resource "google_compute_firewall" "allow_gameserver" {
  name    = "allow-gameserver"
  network = "default"
  project = "pjdrc20240804"

  allow {
    protocol = "udp"
    ports    = ["7000-8000"]  # 必要なポート範囲を開放
  }

  source_ranges = ["0.0.0.0/0"]  # 全てのIPからの接続を許可
  target_tags   = ["gke-node"]    # GKEのノードに適用

  priority = 1000
  direction = "INGRESS"
}

locals {
  helm_values_agones = [
    ["agones.allocator.service.serviceType", "ClusterIP"],
    ["agones.ping.http.serviceType", "ClusterIP"],
    ["agones.ping.udp.serviceType", "ClusterIP"],
    ["gameserver.health.failureThreshold", "300"],       # 失敗回数の閾値 (デフォルト 6)
    ["gameserver.health.initialDelaySeconds", "60"],    # ヘルスチェック開始の遅延時間 (デフォルト 30)
    ["gameserver.health.periodSeconds", "60"],          # ヘルスチェックの間隔 (デフォルト 5)
    ["gameservers.namespaces[0]", "default"],
    ["gameservers.namespaces[1]", "agones-gameserver"],
  ]
}

provider "helm" {
  kubernetes {
    host                   = google_container_cluster.pjdrc-on-gke.endpoint
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(google_container_cluster.pjdrc-on-gke.master_auth.0.cluster_ca_certificate)
  }
}

data "google_client_config" "default" {}

resource "kubernetes_namespace" "agones_gameserver" {
  metadata {
    name = "agones-gameserver"
  }

  depends_on = [
    google_container_cluster.pjdrc-on-gke,
  ]
}

data "helm_template" "agones" {
  repository        = "https://agones.dev/chart/stable"
  name              = local.cluster_name
  chart             = "agones"
  namespace         = "agones-system"
  version           = "1.33.0"
  dependency_update = true

  dynamic "set" {
    for_each = local.helm_values_agones
    content {
      name  = set.value[0]
      value = set.value[1]
    }
  }

  depends_on = [
    google_container_cluster.pjdrc-on-gke,
    null_resource.set_gke_context,
  ]
}

resource "helm_release" "agones" {
  name              = data.helm_template.agones.name
  repository        = data.helm_template.agones.repository
  chart             = data.helm_template.agones.chart
  namespace         = data.helm_template.agones.namespace
  version           = data.helm_template.agones.version
  
  create_namespace  = true
  dependency_update = true
  wait              = true
  force_update = true
  recreate_pods = true
  

  set {
    name  = "agones.allocator.service.serviceType"
    value = "LoadBalancer"
  }

  depends_on = [
    google_container_cluster.pjdrc-on-gke
  ]
}

provider "docker" {
  #https://github.com/hashicorp/terraform-provider-docker/issues/180
  host = local.is_unix ? "unix:///var/run/docker.sock" : "npipe:////.//pipe//docker_engine"
}

resource "null_resource" "set_gke_context" {
  provisioner "local-exec" {
    command = <<EOT
      gcloud container clusters get-credentials pjdrc-on-gke --region us-central1 --project pjdrc20240804
    EOT
  }

  depends_on = [google_container_cluster.pjdrc-on-gke]
}

data "docker_image" "pjdrc_server_debug" {
  name = "itourad1129/pjdrc-server:latest"
}

data "helm_template" "pjdrc_gameserver" {
  name              = "pjdrc-gameserver"
  chart             = "./gameserver"
  namespace         = "agones-gameserver"
  dependency_update = true
  create_namespace  = true

  values = [
    file("values.yaml")
  ]

  depends_on = [
    helm_release.agones,
  ]
}

resource "helm_release" "pjdrc_gameserver" {
  name              = "pjdrc-gameserver"
  repository        = "https://agones.dev/chart/stable"
  chart             = "gameserver"
  namespace         = "agones-gameserver"
  create_namespace  = true
  dependency_update = true
  force_update      = true
  wait              = true

  values = [
    file("values.yaml")
  ]

  set {
    name  = "image.repository"
    value = "us-central1-docker.pkg.dev/pjdrc20240804/pjdrc-artifact/pjdrc-server"
  }

  depends_on = [
    helm_release.agones,
    google_container_cluster.pjdrc-on-gke
  ]
}

resource "kubernetes_service_account" "agones_sdk" {
  metadata {
    name      = "agones-sdk"
    namespace = kubernetes_namespace.agones_gameserver.metadata[0].name
  }

  depends_on = [
    kubernetes_namespace.agones_gameserver
  ]
}
resource "kubernetes_role_binding" "agones_sdk_binding" {
  metadata {
    name      = "agones-sdk-binding"
    namespace = kubernetes_namespace.agones_gameserver.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "agones-sdk"
  }

  subject {
    kind      = "ServiceAccount"
    name      = "agones-sdk"
    namespace = kubernetes_namespace.agones_gameserver.metadata[0].name
  }

  depends_on = [
    kubernetes_service_account.agones_sdk,
    helm_release.agones
  ]
}

resource "kubernetes_service" "pjdrc_gameserver_service" {
  metadata {
    name      = "pjdrc-gameserver-service"
    namespace = kubernetes_namespace.agones_gameserver.metadata[0].name
  }

  spec {
    selector = {
      "agones.dev/fleet" = "pjdrc-fleet"  # 固定の Fleet 名を使う
    }
    
    type = "LoadBalancer"

    port {
      port        = 7777       # 外部に公開するポート
      target_port = 7777       # Pod のコンテナ内のポート
      protocol    = "UDP"
    }
  }

  depends_on = [helm_release.pjdrc_gameserver]
}
