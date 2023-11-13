variable "replicas" {
  description = "replicas to run"
  type        = string
}

variable "nox" {
  description = "nox docker image"
  type        = string
}

variable "faucet" {
  description = "faucet docker image"
  type        = string
}

resource "consul_keys" "configs" {
  # nox config
  key {
    path   = "configs/fluence/nox/Config.toml"
    value  = file("Config.toml")
    delete = true
  }

  # promtail config
  key {
    path   = "configs/fluence/nox/promtail.yml"
    value  = file("promtail.yml")
    delete = true
  }
}

resource "vault_policy" "nox" {
  name   = "${terraform.workspace}/nox"
  policy = <<-EOT
    path "kv/nox/${terraform.workspace}/*"
    {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_policy" "faucet" {
  name   = "${terraform.workspace}/nox/faucet"
  policy = <<-EOT
    path "kv/nox/${terraform.workspace}/faucet/*"
    {
      capabilities = ["read"]
    }
    path "kv/nox/${terraform.workspace}/chain"
    {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_policy" "promtail" {
  name   = "${terraform.workspace}/nox/promtail"
  policy = <<-EOT
    path "kv/loki/basicauth/promtail"
    {
      capabilities = ["read"]
    }
  EOT
}

resource "nomad_csi_volume" "nox" {
  count = var.replicas

  namespace    = "fluence"
  plugin_id    = "do-csi"
  volume_id    = "nox[${count.index}]"
  name         = "${terraform.workspace}-nox-${count.index}"
  capacity_min = "50GiB"
  capacity_max = "50GiB"

  capability {
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
  }

  mount_options {
    fs_type     = "ext4"
    mount_flags = ["noatime"]
  }
}

resource "nomad_csi_volume" "ipfs" {
  namespace    = "fluence"
  plugin_id    = "do-csi"
  volume_id    = "ipfs"
  name         = "${terraform.workspace}-ipfs"
  capacity_min = "10GiB"
  capacity_max = "10GiB"

  capability {
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
  }

  mount_options {
    fs_type     = "ext4"
    mount_flags = ["noatime"]
  }
}

resource "nomad_job" "nox" {
  depends_on = [
    nomad_csi_volume.nox,
    nomad_csi_volume.ipfs,
    vault_policy.nox,
    vault_policy.faucet,
    vault_policy.promtail,
    consul_keys.configs,
  ]

  jobspec          = file("${path.module}/job.nomad.hcl")
  detach           = false
  purge_on_destroy = true

  timeouts {
    create = "15m"
    update = "15m"
  }

  hcl2 {
    allow_fs = true
    vars = {
      env             = terraform.workspace
      replicas        = var.replicas
      nox-image       = var.nox
      nox-policy      = "${terraform.workspace}/nox"
      faucet-image    = var.faucet
      faucet-policy   = "${terraform.workspace}/nox/faucet"
      promtail-policy = "${terraform.workspace}/nox/promtail"
    }
  }
}

resource "cloudflare_record" "nox" {
  count = var.replicas

  zone_id = data.cloudflare_zone.fluence_dev.zone_id
  name    = "${count.index}-${terraform.workspace}"
  value   = data.terraform_remote_state.state.outputs.ingress_ip4
  type    = "A"
}

resource "cloudflare_record" "ipfs" {
  zone_id = data.cloudflare_zone.fluence_dev.zone_id
  name    = "${terraform.workspace}-ipfs"
  value   = data.terraform_remote_state.state.outputs.ingress_ip4
  type    = "A"
}

resource "cloudflare_record" "faucet" {
  zone_id = data.cloudflare_zone.fluence_dev.zone_id
  name    = "faucet-${terraform.workspace}"
  value   = data.terraform_remote_state.state.outputs.ingress_ip4
  type    = "A"
}

data "vault_generic_secret" "keys" {
  count = var.replicas
  path  = "kv/nox/${terraform.workspace}/nodes/${count.index}"
}

output "peer_ids" {
  value = [
    for i in range(var.replicas) :
    "/dns4/${i}-${terraform.workspace}.fluence.dev/tcp/9000/wss/p2p/${data.vault_generic_secret.keys.*.data[i].peer_id}"
  ]
  sensitive = true
}
