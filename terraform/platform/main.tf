# Layer 2: everything that runs on the cluster: secrets, Postgres, and the poller.
terraform {
  required_version = ">= 1.6"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

variable "poller_image" {
  description = "Poller image to load into the cluster. Must match the image in k8s/poller-cronjob.yaml."
  type        = string
  default     = "spotify-poller:v1"
}

# ---------- Connect to the cluster built by layer 1 ----------
data "terraform_remote_state" "cluster" {
  backend = "local"
  config = {
    path = "${path.module}/../cluster/terraform.tfstate"
  }
}

locals {
  cluster = data.terraform_remote_state.cluster.outputs

  # Read the Spotify credentials from your .env file, so secrets live in one place.
  env_lines = [
    for line in split("\n", replace(file("${path.module}/../../.env"), "\r", "")) :
    trimspace(line) if trimspace(line) != "" && !startswith(trimspace(line), "#")
  ]
  env = {
    for line in local.env_lines :
    split("=", line)[0] => join("=", slice(split("=", line), 1, length(split("=", line))))
  }
}

provider "kubernetes" {
  host                   = local.cluster.endpoint
  client_certificate     = local.cluster.client_certificate
  client_key             = local.cluster.client_key
  cluster_ca_certificate = local.cluster.cluster_ca_certificate
}

provider "kubectl" {
  host                   = local.cluster.endpoint
  client_certificate     = local.cluster.client_certificate
  client_key             = local.cluster.client_key
  cluster_ca_certificate = local.cluster.cluster_ca_certificate
  load_config_file       = false
}

# ---------- The poller image ----------
# kind can't pull images from your laptop on its own, so copy it in.
resource "terraform_data" "load_image" {
  triggers_replace = [var.poller_image, local.cluster.endpoint]

  provisioner "local-exec" {
    command = "kind load docker-image ${var.poller_image} --name ${local.cluster.cluster_name}"
  }
}

# ---------- Secrets ----------
# A random database password, generated once and kept in Terraform's state.
resource "random_password" "postgres" {
  length  = 24
  special = false # keeps it safe to put inside a connection URL
}

resource "kubernetes_secret_v1" "postgres" {
  metadata {
    name = "postgres-credentials"
  }
  data = {
    POSTGRES_USER     = "spotify"
    POSTGRES_PASSWORD = random_password.postgres.result
    POSTGRES_DB       = "spotify"
    DATABASE_URL      = "postgresql://spotify:${random_password.postgres.result}@postgres:5432/spotify"
  }
}

resource "kubernetes_secret_v1" "spotify_credentials" {
  metadata {
    name = "spotify-credentials"
  }
  data = {
    SPOTIFY_CLIENT_ID     = local.env["SPOTIFY_CLIENT_ID"]
    SPOTIFY_CLIENT_SECRET = local.env["SPOTIFY_CLIENT_SECRET"]
  }
}

resource "kubernetes_secret_v1" "spotify_token" {
  metadata {
    name = "spotify-token"
  }
  data = {
    ".spotify-token" = file("${path.module}/../../.spotify-token")
  }
}

# ---------- The app: every YAML file in the k8s folder ----------
data "kubectl_path_documents" "app" {
  pattern = "${path.module}/../../k8s/*.yaml"
}

resource "kubectl_manifest" "app" {
  for_each  = data.kubectl_path_documents.app.manifests
  yaml_body = each.value

  depends_on = [
    terraform_data.load_image,
    kubernetes_secret_v1.postgres,
    kubernetes_secret_v1.spotify_credentials,
    kubernetes_secret_v1.spotify_token,
  ]
}

output "next_steps" {
  value = <<-EOT
    Platform is up. Check it with:  kubectl get pods
    Run the poller now with:        kubectl create job --from=cronjob/poller poller-test
  EOT
}
