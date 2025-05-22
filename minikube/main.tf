
locals {
  is_unix            = substr(abspath(path.cwd), 0, 1) == "/"
  driver             = "hyperv"
  kubernetes_version = "v1.27.3"
  cluster_name       = "pjdrc-on-minikube-agones"
}

provider "minikube" {
  kubernetes_version = local.kubernetes_version
}

resource "minikube_cluster" "pjdrc_on_minikube_agones" {
  cluster_name       = local.cluster_name
  kubernetes_version = local.kubernetes_version
  driver             = local.driver
  memory             = "8192mb"
  cpus               = 8
  disk_size          = "60000m"
  vm                 = true
  preload            = true

  network_plugin    = "cni"
  cni               = "bridge"
  container_runtime = "containerd"
  network           = ""

  mount = false
  addons = [
    "default-storageclass",
    "storage-provisioner",
    "metrics-server",
  ]

  ports = [
    "32774:8443",
    "7000-8000:7000-8000/udp",
  ]
  
  extra_config = ["kubelet.resolv-conf=/run/systemd/resolve/resolv.conf"]
}

resource "terraform_data" "switch_profile" {
  triggers_replace = [
    minikube_cluster.pjdrc_on_minikube_agones.id,
  ]

  provisioner "local-exec" {
    command = "minikube profile ${local.cluster_name}"
  }
}

locals {
  helm_values_agones = [
    ["agones.allocator.service.serviceType", "ClusterIP"],
    ["agones.ping.http.serviceType", "ClusterIP"],
    ["agones.ping.udp.serviceType", "ClusterIP"],
    ["gameserver.health.failureThreshold", "10"],       # 失敗回数の閾値 (デフォルト 6)
    ["gameserver.health.initialDelaySeconds", "60"],    # ヘルスチェック開始の遅延時間 (デフォルト 30)
    ["gameserver.health.periodSeconds", "10"],          # ヘルスチェックの間隔 (デフォルト 5)
    ["gameservers.namespaces[0]", "default"],
    ["gameservers.namespaces[1]", "agones-gameserver"],
  ]
}

resource "null_resource" "helm_repo_update" {
  provisioner "local-exec" {
    command = <<EOT
      helm repo add agones https://agones.dev/chart/stable
      helm repo add open-match https://open-match.dev/chart/stable
      helm repo update
    EOT
  }

  triggers = {
    always_run = timestamp()
  }
}

provider "helm" {
  kubernetes {
    config_path    = "~/.kube/config"
    config_context = local.cluster_name
    host           = minikube_cluster.pjdrc_on_minikube_agones.host
  }
}

provider "kubernetes" {
  config_path = "~/.kube/config"
  host        = minikube_cluster.pjdrc_on_minikube_agones.host
}

resource "kubernetes_namespace" "agones_gameserver" {
  metadata {
    name = "agones-gameserver"
  }

  depends_on = [
    terraform_data.switch_profile,
    minikube_cluster.pjdrc_on_minikube_agones,
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
    terraform_data.switch_profile,
    minikube_cluster.pjdrc_on_minikube_agones
  ]
}

resource "helm_release" "agones" {
  name              = data.helm_template.agones.name
  repository        = data.helm_template.agones.repository
  chart             = data.helm_template.agones.chart
  namespace         = data.helm_template.agones.namespace
  #version           = data.helm_template.agones.version
  version           = "1.42.0"  # Agonesのバージョンを明示的に指定
  create_namespace  = true
  dependency_update = true
  timeout           = 600
  wait              = true

  dynamic "set" {
    for_each = local.helm_values_agones
    content {
      name  = set.value[0]
      value = set.value[1]
    }
  }

  depends_on = [
    terraform_data.switch_profile,
    minikube_cluster.pjdrc_on_minikube_agones,
    kubernetes_namespace.agones_gameserver,
    null_resource.helm_repo_update
  ]
}

provider "docker" {
  #https://github.com/hashicorp/terraform-provider-docker/issues/180
  host = local.is_unix ? "unix:///var/run/docker.sock" : "npipe:////.//pipe//docker_engine"
}

data "docker_image" "pjdrc_server_debug" {
  name = "itourad1129/pjdrc-server:latest"
}

resource "terraform_data" "load_image" {
  triggers_replace = [
    data.docker_image.pjdrc_server_debug.id,
  ]

  provisioner "local-exec" {
    command = "minikube image load ${data.docker_image.pjdrc_server_debug.name} --profile ${local.cluster_name}"
  }

  depends_on = [
    minikube_cluster.pjdrc_on_minikube_agones,
    terraform_data.switch_profile,
  ]
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
    terraform_data.load_image
  ]
}

resource "helm_release" "pjdrc_gameserver" {
  name              = data.helm_template.pjdrc_gameserver.name
  repository        = data.helm_template.pjdrc_gameserver.repository
  chart             = data.helm_template.pjdrc_gameserver.chart
  namespace         = data.helm_template.pjdrc_gameserver.namespace
  version           = data.helm_template.pjdrc_gameserver.version
  create_namespace  = true
  dependency_update = true
  force_update      = true
  wait              = true

  values = data.helm_template.agones.values

  depends_on = [
    kubernetes_namespace.agones_gameserver,
    minikube_cluster.pjdrc_on_minikube_agones,
    terraform_data.load_image,
    helm_release.agones
  ]
}

resource "helm_release" "open_match" {
  name              = "open-match"
  repository        = "https://open-match.dev/chart/stable"
  chart             = "open-match"
  namespace         = "open-match"
  version           = "1.8.0" # 適宜最新に調整
  create_namespace  = true
  dependency_update = true
  wait              = true

  set {
    name  = "open-match-override.enabled"
    value = "true"
  }

  set {
    name  = "backend.portType"
    value = "NodePort"
  }

  # Backend
  set {
    name  = "open-match.override.components.backend.service.nodePort"
    value = 30054
  }
  set {
    name  = "open-match.override.components.backend.httpService.nodePort"
    value = 30396
  }

  set {
    name  = "frontend.portType"
    value = "NodePort"
  }

  # Frontend
  set {
    name  = "open-match.override.components.frontend.service.nodePort"
    value = 30939
  }
  set {
    name  = "open-match.override.components.frontend.httpService.nodePort"
    value = 30604
  }

  set {
    name  = "query.portType"
    value = "NodePort"
  }

  # Query
  set {
    name  = "open-match.override.components.query.service.nodePort"
    value = 32667
  }
  set {
    name  = "open-match.override.components.query.httpService.nodePort"
    value = 31909
  }

  # 必要に応じて他のパラメータをセット
  # set {
  #   name  = "global.logLevel"
  #   value = "debug"
  # }

  depends_on = [
    minikube_cluster.pjdrc_on_minikube_agones,
    terraform_data.switch_profile,
    null_resource.helm_repo_update
  ]
}

resource "kubernetes_namespace" "open_match_system" {
  metadata {
    name = "open-match-system"
  }

  depends_on = [
    terraform_data.switch_profile,
    minikube_cluster.pjdrc_on_minikube_agones,
  ]
}

