variable "env" {
  type = string
}

variable "replicas" {
  type = string
}

variable "decider-period" {
  type = string
}

variable "nox-image" {
  type = string
}

variable "nox-policy" {
  type = string
}

variable "faucet-image" {
  type = string
}

variable "faucet-policy" {
  type = string
}

variable "promtail-policy" {
  type = string
}

job "nox" {
  region = var.env
  datacenters = [
    "fra1"
  ]
  namespace = "fluence"

  group "nox" {
    count = var.replicas

    update {
      max_parallel      = 6
      healthy_deadline  = "10m"
      progress_deadline = "15m"
    }

    network {
      port "tcp" {
        host_network = "public"
      }
      port "ws" {
        host_network = "public"
      }
      port "metrics" {}

      port "promtail" {}
    }

    service {
      name = "nox"
      port = "metrics"

      meta {
        replica = "nox-${NOMAD_ALLOC_INDEX}"
      }

      check {
        type     = "http"
        path     = "/health"
        port     = "metrics"
        interval = "10s"
        timeout  = "1s"
      }
    }

    service {
      name = "nox-${NOMAD_ALLOC_INDEX}"
      port = "ws"

      meta {
        alloc_id = NOMAD_ALLOC_ID
        replica  = "nox-${NOMAD_ALLOC_INDEX}"
      }

      tags = [
        "traefik.enable=true",
        "traefik.http.routers.nox-${NOMAD_ALLOC_INDEX}.entrypoints=nox",
        "traefik.http.routers.nox-${NOMAD_ALLOC_INDEX}.rule=Host(`${NOMAD_ALLOC_INDEX}-${NOMAD_REGION}.fluence.dev`)",
      ]
    }

    service {
      name = "nox-legacy-${NOMAD_ALLOC_INDEX}"
      port = "ws"

      meta {
        alloc_id = NOMAD_ALLOC_ID
        replica  = "nox-${NOMAD_ALLOC_INDEX}"
      }

      tags = [
        "traefik.enable=true",
        "traefik.http.routers.nox-legacy-${NOMAD_ALLOC_INDEX}.entrypoints=nox-legacy-${NOMAD_ALLOC_INDEX}",
        "traefik.http.routers.nox-legacy-${NOMAD_ALLOC_INDEX}.rule=Host(`${NOMAD_REGION}.fluence.dev`)",
      ]
    }

    service {
      name = "promtail"
      port = "promtail"

      meta {
        sidecar_to = "nox"
        instance   = "nox-${NOMAD_ALLOC_INDEX}"
      }

      check {
        type     = "http"
        path     = "/ready"
        port     = "promtail"
        interval = "10s"
        timeout  = "1s"
      }
    }

    volume "nox" {
      type            = "csi"
      source          = "nox"
      attachment_mode = "file-system"
      access_mode     = "single-node-writer"
      per_alloc       = true
    }

    task "nox" {
      driver = "docker"

      kill_signal  = "SIGINT"
      kill_timeout = "30s"

      vault {
        policies = [
          var.nox-policy,
        ]
      }

      volume_mount {
        volume      = "nox"
        destination = "/.fluence"
      }

      resources {
        cpu        = 1000
        memory     = 1000
        memory_max = 2500
      }

      env {
        FLUENCE_ENV_AQUA_IPFS_EXTERNAL_API_MULTIADDR = "/dns4/${var.env}-ipfs.fluence.dev/tcp/5020"
        FLUENCE_ENV_AQUA_IPFS_LOCAL_API_MULTIADDR    = "/dns4/${var.env}-ipfs.fluence.dev/tcp/5020"

        FLUENCE_SYSTEM_SERVICES__ENABLE                      = "aqua-ipfs,decider,registry"
        FLUENCE_SYSTEM_SERVICES__DECIDER__DECIDER_PERIOD_SEC = var.decider-period
        FLUENCE_MAX_SPELL_PARTICLE_TTL                       = format("%ds", convert(var.decider-period, number) - 1)

        FLUENCE_CONFIG      = "/local/Config.toml"
        FLUENCE_LOG__FORMAT = "logfmt"

        RUST_LOG = "info,ipfs_effector=off,ipfs_pure=off,chain_connector=debug,run-console=debug"

        FLUENCE_HTTP_PORT = NOMAD_PORT_metrics
      }

      config {
        image          = var.nox-image
        auth_soft_fail = true

        labels {
          replica = "nox-${NOMAD_ALLOC_INDEX}"
        }

        entrypoint = ["/local/entrypoint.sh"]
        args = [
          "--allow-private-ips",
          "${BOOTSTRAP}",
          "-x=${attr.unique.network.ip-address}",
          "--external-maddrs",
          "/dns4/${NOMAD_ALLOC_INDEX}-${NOMAD_REGION}.fluence.dev/tcp/9000/wss",

          "-k=${KEY}",
          "-f=ed25519",
          "--management-key=${MANAGEMENT_KEY}",

          /* "--aqua-pool-size=${attr.cpu.numcores}", */
          "--aqua-pool-size=2",

          "--tcp-port=${NOMAD_PORT_tcp}",
          "--ws-port=${NOMAD_PORT_ws}",
          # "--metrics-port=${NOMAD_PORT_metrics}",
        ]

        ports = [
          "tcp",
          "ws",
          "metrics",
        ]
      }

      template {
        data        = file("entrypoint.sh")
        destination = "local/entrypoint.sh"
        perms       = 777
      }

      template {
        data        = <<-EOH
        {{ if eq (env "NOMAD_ALLOC_INDEX") "0" }}
        BOOTSTRAP='--local'
        {{ else }}
        BOOTSTRAP="--bootstraps=/dns4/0-{{ env "NOMAD_REGION" }}.fluence.dev/tcp/9000/wss"
        {{ end }}
        EOH
        destination = "local/bootstrap"
        env         = true
      }

      template {
        data        = <<-EOH
        {{ key "configs/fluence/nox/Config.toml" }}
        EOH
        destination = "local/Config.toml"
      }

      template {
        data        = <<-EOH
        {{- with secret "kv/nox/${var.env}/management" -}}
        MANAGEMENT_KEY='{{ .Data.peer_id }}'
        {{- end -}}
        EOH
        destination = "secrets/secrets.env"
        env         = true
      }

      template {
        data        = <<-EOH
        {{- with secret (env "NOMAD_ALLOC_INDEX" | printf "kv/nox/${var.env}/nodes/%s") -}}
        # nox PeerID private key
        KEY={{ .Data.private }}
        # private key of the Provider (Signing) Wallet
        FLUENCE_ENV_CONNECTOR_WALLET_KEY={{ .Data.wallet_key }}
        {{- end }}

        {{ with secret "kv/nox/${var.env}/connector" -}}
        # block number from which to start scanning the chain for Deals
        # should be set to the block number at the time of last environment cleanup
        FLUENCE_ENV_CONNECTOR_FROM_BLOCK={{ .Data.from_block }}
        # Matcher contract address
        FLUENCE_ENV_CONNECTOR_CONTRACT_ADDRESS={{ .Data.contract_address }}
        {{- end }}

        {{ with secret "kv/nox/${var.env}/chain" -}}
        # blockchain node RPC URL
        FLUENCE_ENV_CONNECTOR_API_ENDPOINT='{{ .Data.api_endpoint }}'
        # network id of the blockchain network, must correspond to RPC URI
        FLUENCE_SYSTEM_SERVICES__DECIDER__NETWORK_ID = "{{ .Data.chain_id }}"
        {{- end -}}
        EOH
        destination = "secrets/node-secrets.env"
        env         = true
      }
    }

    task "promtail" {
      driver = "docker"
      user   = "nobody"

      lifecycle {
        hook    = "poststart"
        sidecar = true
      }

      vault {
        policies = [
          var.promtail-policy,
        ]
      }

      resources {
        cpu        = 50
        memory     = 64
        memory_max = 128
      }

      env {
        INSTANCE = "nox-${NOMAD_ALLOC_INDEX}"
      }

      config {
        image = "grafana/promtail:2.6.1"

        args = [
          "-config.file=local/promtail.yml",
          "-config.expand-env=true",
        ]

        ports = [
          "promtail",
        ]
      }

      template {
        data        = <<-EOH
        {{ key "configs/fluence/nox/promtail.yml" }}
        EOH
        destination = "local/promtail.yml"
      }

      template {
        data = <<-EOH
        {{- with secret "kv/loki/basicauth/promtail" -}}
        {{ .Data.password }}{{ end }}
        EOH

        destination = "secrets/auth"
      }
    }
  }

  group "ipfs" {
    network {
      port "api" {
        to     = 5020
        static = 5020
      }

      port "gateway" {}

      port "swarm" {
        host_network = "public"
      }

      port "swarm-ws" {
        host_network = "public"
      }
    }

    service {
      name = "${var.env}-ipfs"
      port = "api"

      tags = [
        "traefik.enable=true",
        "traefik.tcp.routers.ipfs-api.entrypoints=ipfs-api",
        "traefik.tcp.routers.ipfs-api.rule=HostSNI(`*`)",
      ]
    }

    volume "ipfs" {
      type            = "csi"
      source          = "ipfs"
      attachment_mode = "file-system"
      access_mode     = "single-node-writer"
    }

    task "ipfs" {
      driver = "docker"

      volume_mount {
        volume      = "ipfs"
        destination = "/data/ipfs"
      }

      env {
        IPFS_PATH    = "/data/ipfs"
        IPFS_PROFILE = "server"
      }

      config {
        image = "ipfs/kubo:v0.24.0"

        ports = [
          "api",
          "gateway",
          "swarm",
          "swarm-ws",
        ]

        volumes = [
          "local/ipfs/:/container-init.d/",
        ]
      }

      dynamic "template" {
        for_each = fileset(".", "ipfs/*.sh")

        content {
          data        = file(template.value)
          destination = "local/${template.value}"
          change_mode = "noop"
        }
      }

      resources {
        cpu        = 500
        memory     = 256
        memory_max = 1024
      }
    }
  }

  group "faucet" {
    ephemeral_disk {
      migrate = true
      size    = 500
    }

    network {
      port "http" {
        to = 3000
      }
    }

    service {
      name = "faucet"
      port = "http"

      tags = [
        "traefik.enable=true",
        "traefik.http.routers.faucet.entrypoints=https",
        "traefik.http.routers.faucet.rule=Host(`faucet-${var.env}.fluence.dev`)",
      ]
    }

    task "faucet" {
      driver = "docker"

      kill_timeout = "10s"

      vault {
        policies = [
          var.faucet-policy
        ]
      }

      env {
        FAUCET_TIMEOUT   = "30"
        FAUCET_USD_VALUE = "10"
        FAUCET_FLT_VALUE = "0.01"
        FAUCET_DATA_DIR  = "/alloc/data"

        NEXT_PUBLIC_CHAIN_NAME      = "Fluence ${var.env} Network"
        NEXT_PUBLIC_BLOCK_EXPLORER  = "https://blockscout-${var.env}.fluence.dev"
        NEXT_PUBLIC_NATIVE_CURRENCY = "tFLT"
      }

      config {
        image = var.faucet-image

        ports = [
          "http",
        ]
      }

      template {
        data        = <<-EOH
        {{ with secret "kv/nox/${var.env}/faucet/auth0" -}}
        AUTH0_SECRET='{{ .Data.secret }}'
        AUTH0_BASE_URL='https://faucet-${var.env}.fluence.dev'
        AUTH0_ISSUER_BASE_URL='{{ .Data.issuer_base_url }}'
        AUTH0_CLIENT_ID='{{ .Data.client_id }}'
        AUTH0_CLIENT_SECRET='{{ .Data.client_secret }}'
        {{- end }}
        EOH
        destination = "secrets/auth0.env"
        env         = true
      }

      template {
        data        = <<-EOH
        {{ with secret "kv/nox/${var.env}/faucet/secret" -}}
        # private key for the faucet wallet, which make transaction to faucet contract
        FAUCET_PRIVATE_KEY='{{ .Data.private_key }}'
        # address of the faucet contract
        NEXT_PUBLIC_FAUCET_ADDRESS='{{ .Data.address }}'
        NEXT_PUBLIC_CHAIN_ID='{{ .Data.chain_id }}'
        {{- end }}

        {{ with secret "kv/nox/${var.env}/chain" -}}
        # blockchain node RPC URL
        FAUCET_CHAIN_RPC_URL='{{ .Data.api_endpoint }}'
        {{- end -}}
        EOH
        destination = "secrets/chain.env"
        env         = true
      }

      resources {
        cpu        = 100
        memory     = 128
        memory_max = 256
      }
    }
  }
}
