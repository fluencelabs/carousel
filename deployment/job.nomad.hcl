variable "env" {
  type = string
}

variable "replicas" {
  type = string
}

variable "nox-image" {
  type = string
}

variable "nox-policy" {
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
      max_parallel = 4
    }

    network {
      dns {
        servers = [
          "1.1.1.1",
        ]
      }

      port "tcp" {
        host_network = "public"
      }
      port "ws" {
        host_network = "public"
      }
      port "metrics" {}

      port "ipfs_swarm" {
        host_network = "public"
      }
      port "ipfs_api" {
        host_network = "public"
      }
      port "ipfs_gateway" {
        host_network = "public"
      }

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
        memory     = 2000
        memory_max = 3000
      }

      env {
        IPFS_ADDRESSES_SWARM    = "/ip4/0.0.0.0/tcp/${NOMAD_PORT_ipfs_swarm},/ip4/0.0.0.0/tcp/${NOMAD_PORT_ipfs_swarm}/ws"
        IPFS_ADDRESSES_API      = "/ip4/0.0.0.0/tcp/${NOMAD_PORT_ipfs_api}"
        IPFS_ADDRESSES_GATEWAY  = "/ip4/0.0.0.0/tcp/${NOMAD_PORT_ipfs_gateway}"
        IPFS_ADDRESSES_ANNOUNCE = "/ip4/${NOMAD_HOST_IP_ipfs_swarm}/tcp/${NOMAD_PORT_ipfs_swarm},/ip4/${NOMAD_HOST_IP_ipfs_swarm}/tcp/${NOMAD_PORT_ipfs_swarm}/ws"
        IPFS_PATH               = "/.fluence/ipfs"

        FLUENCE_ENV_AQUA_IPFS_EXTERNAL_API_MULTIADDR = "/ip4/${NOMAD_HOST_IP_ipfs_api}/tcp/${NOMAD_PORT_ipfs_api}"
        FLUENCE_ENV_AQUA_IPFS_LOCAL_API_MULTIADDR    = "/ip4/127.0.0.1/tcp/${NOMAD_PORT_ipfs_api}"

        FLUENCE_SYSTEM_SERVICES__ENABLE                      = "aqua-ipfs,decider"
        FLUENCE_SYSTEM_SERVICES__DECIDER__DECIDER_PERIOD_SEC = "10"
        FLUENCE_MAX_SPELL_PARTICLE_TTL                       = "9s"
        FLUENCE_SYSTEM_SERVICES__DECIDER__NETWORK_ID         = "80001"

        FLUENCE_CONFIG      = "/local/Config.toml"
        FLUENCE_LOG__FORMAT = "logfmt"

        CERAMIC_HOST = "https://ceramic-${NOMAD_REGION}.fluence.dev"
        RUST_LOG     = "info,ipfs_effector=off,ipfs_pure=off,run-console=info"

        FLUENCE_HTTP_PORT = NOMAD_PORT_metrics
      }

      config {
        image          = var.nox-image
        auth_soft_fail = true

        labels {
          replica = "nox-${NOMAD_ALLOC_INDEX}"
        }

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
          "ipfs_swarm",
          "ipfs_api",
          "ipfs_gateway",
        ]
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
        KEY={{ .Data.private }}
        FLUENCE_ENV_CONNECTOR_WALLET_KEY={{ .Data.wallet_key }}
        {{- end }}

        {{ with secret "kv/nox/${var.env}/connector" -}}
        FLUENCE_ENV_CONNECTOR_API_ENDPOINT={{ .Data.api_endpoint }}
        FLUENCE_ENV_CONNECTOR_FROM_BLOCK={{ .Data.from_block }}
        FLUENCE_ENV_CONNECTOR_CONTRACT_ADDRESS={{ .Data.contract_address }}
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
}
