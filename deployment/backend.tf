terraform {
  backend "consul" {
    address = "hashi.fluence.dev:8501"
    scheme  = "https"
    path    = "terraform/carousel/nox"
  }

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 3.0"
    }

    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
  }
}

provider "cloudflare" {}

data "cloudflare_zone" "fluence_dev" {
  name = "fluence.dev"
}

provider "consul" {
  address    = "https://hashi.fluence.dev:8501"
  datacenter = terraform.workspace
}

provider "nomad" {
  address = "https://hashi.fluence.dev:4646"
  region  = terraform.workspace
}

provider "vault" {
  address = "https://hashi.fluence.dev:8200"
}

data "terraform_remote_state" "state" {
  backend = "consul"

  config = {
    address = "hashi.fluence.dev:8501"
    scheme  = "https"
    path    = "terraform/${terraform.workspace}"
  }
}
