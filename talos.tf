locals {
  controller_nodes = [
    for i in range(var.controller_count) : {
      name    = "c${i}"
      address = cidrhost(var.cluster_node_network, var.cluster_node_network_first_controller_hostnum + i)
    }
  ]
  worker_nodes = [
    for i in range(var.worker_count) : {
      name    = "w${i}"
      address = cidrhost(var.cluster_node_network, var.cluster_node_network_first_worker_hostnum + i)
    }
  ]
  common_machine_config = {
    machine = {
      time = {
        servers = [
          "time.cloudflare.com",
	  "time.google.com"
	]
      }
      kubelet = {
	# NB https://www.talos.dev/v1.8/kubernetes-guides/configuration/deploy-metrics-server/
	extraArgs = {
	  rotate-server-certificates = true
	}
	extraMounts = [
	  {
	    destination = "/var/localstore"
	    type = "bind"
	    source = "/var/localstore"
	    options = [
	      "bind",
	      "rshared",
	      "rw"
	    ]
	  }
	]
	# NB: Required for rootless dev containers.
	#     https://www.talos.dev/v1.9/kubernetes-guides/configuration/usernamespace/
	extraConfig = {	  
	  featureGates = {
            UserNamespacesSupport = true
            UserNamespacesPodSecurityStandards = true
	  }
	}
      }
      # NB the install section changes are only applied after a talos upgrade
      #    (which we do not do). instead, its preferred to create a custom
      #    talos image, which is created in the installed state.
      #install = {}
      features = {
        # see https://www.talos.dev/v1.9/kubernetes-guides/configuration/kubeprism/
        # see talosctl -n $c0 read /etc/kubernetes/kubeconfig-kubelet | yq .clusters[].cluster.server
        # NB if you use a non-default CNI, you must configure it to use the
        #    https://localhost:7445 kube-apiserver endpoint.
        kubePrism = {
          enabled = true
          port    = 7445
        }
        # see https://www.talos.dev/v1.9/talos-guides/network/host-dns/
        hostDNS = {
          enabled              = true
          forwardKubeDNSToHost = true
        }
      }
      kernel = {
        modules = [
          // piraeus dependencies.
          {
            name = "drbd"
            parameters = [
              "usermode_helper=disabled",
            ]
          },
          {
            name = "drbd_transport_tcp"
          },
        ]
      }
      network = {
        extraHostEntries = [
	  {
            ip = var.cluster_node_gateway
            aliases = [
	      "k8sdash",
	      "k8sdash.${var.ingress_domain}",
	      "grafana",
	      "grafana.${var.ingress_domain}",
	      "prometheus",
	      "prometheus.${var.ingress_domain}",
	      "hubble",
	      "hubble.${var.ingress_domain}",
	      "graph",
	      "graph.${var.ingress_domain}",
	      "argocd",
	      "argocd.${var.ingress_domain}",
	      "minio",
	      "minio.${var.ingress_domain}",
	      "gitea",
	      "gitea.${var.ingress_domain}",
	      "regui",
	      "regui.${var.ingress_domain}",
	      "oci",
	      "oci.${var.ingress_domain}",
	      "cloud",
              var.cluster_node_host
            ]
          },
          {
            ip = var.cluster_node_gateway
            aliases = [
              var.cluster_node_host,
            ]
          }
        ]
      }
      registries = {
        config = {
	  "oci.${var.ingress_domain}" = {
            tls = {
              insecureSkipVerify = true
	    }
	  },
	  "${var.cluster_node_gateway}" = {
            tls = {
              insecureSkipVerify = true
	    }
	  }
        }
        mirrors = {
#	  "oci.${var.ingress_domain}" = {
#	    endpoints = [
#	      "https://${var.cluster_node_gateway}",
#	    ]
#	    skipFallback = false
#	  },
	  "docker.io" = {
	    endpoints = [
	      "http://${var.cluster_node_gateway}:5001",
	    ]
#	    skipFallback = false
	  }, 
	  "k8s.io" = {
	    endpoints = [
	      "http://${var.cluster_node_gateway}:5002",
	    ]
#	    skipFallback = false
	  }, 
	  "gcr.io" = {
	    endpoints = [
	      "http://${var.cluster_node_gateway}:5003",
	    ]
#	    skipFallback = false
	  }, 
	  "ghcr.io" = {
	    endpoints = [
	      "http://${var.cluster_node_gateway}:5004",
	    ]
#	    skipFallback = false
	  }
        }
      }
    }
    cluster = {
      # see https://www.talos.dev/v1.9/talos-guides/discovery/
      # see https://www.talos.dev/v1.9/reference/configuration/#clusterdiscoveryconfig
      discovery = {
        enabled = true
        registries = {
          kubernetes = {
            disabled = false
          }
          service = {
            disabled = true
          }
        }
      }
      network = {
        cni = {
          name = "none"
        }
      }
      proxy = {
        disabled = true
      }
      # Metrics Server : https://www.talos.dev/v1.8/kubernetes-guides/configuration/deploy-metrics-server/
      extraManifests = [
	"https://raw.githubusercontent.com/alex1989hu/kubelet-serving-cert-approver/main/deploy/standalone-install.yaml",
	"https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"
      ]
    }
  }
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.7.0/docs/resources/machine_secrets
resource "talos_machine_secrets" "talos" {
  talos_version = "v${var.talos_version}"
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.7.0/docs/data-sources/machine_configuration
data "talos_machine_configuration" "controller" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = var.cluster_endpoint
  machine_secrets    = talos_machine_secrets.talos.machine_secrets
  machine_type       = "controlplane"
  talos_version      = "v${var.talos_version}"
  kubernetes_version = var.kubernetes_version
  examples           = false
  docs               = false
  config_patches = [
    yamlencode(local.common_machine_config),
    yamlencode({
      machine = {
        network = {
          interfaces = [
            # see https://www.talos.dev/v1.9/talos-guides/network/vip/
            {
              interface = "eth0"
              dhcp      = true
              vip = {
                ip = var.cluster_vip
              }
            }
          ]
        }
      }
    }),
    yamlencode({
      cluster = {
#	certSANs = [
#	  "10.17.4.80"
#	]
	apiServer = {
	  resources = {
	    requests = {
	      cpu = 0.5
	      memory =  "750Mi"
	    }
	    limits = {
	      cpu = 2
	      memory = "4Gi"
	    }
	  }
	  # NB: Required for rootless dev containers.
	  #     https://www.talos.dev/v1.9/kubernetes-guides/configuration/usernamespace/
	  # NB: AuthorizedNodeWithSelectors: https://github.com/siderolabs/talos/issues/9980
	  extraArgs = {
	    feature-gates = "UserNamespacesSupport=true,UserNamespacesPodSecurityStandards=true,AuthorizeNodeWithSelectors=false"
	  }
	}
        inlineManifests = [
          {
            name     = "spin"
            contents = <<-EOF
            apiVersion: node.k8s.io/v1
            kind: RuntimeClass
            metadata:
              name: wasmtime-spin-v2
            handler: spin
            EOF
          },
          {
            name = "cilium"
            contents = join("---\n", [
              data.helm_template.cilium.manifest,
              "# Source cilium.tf\n${local.cilium_external_lb_manifest}",
            ])
          },
          {
            name = "cert-manager"
            contents = join("---\n", [
              yamlencode({
                apiVersion = "v1"
                kind       = "Namespace"
                metadata = {
                  name = "cert-manager"
                }
              }),
              data.helm_template.cert_manager.manifest,
              "# Source cert-manager.tf\n${local.cert_manager_ingress_ca_manifest}",
            ])
          },
          {
            name     = "trust-manager"
            contents = data.helm_template.trust_manager.manifest
          },
          {
            name     = "reloader"
            contents = data.helm_template.reloader.manifest
          },
        ],
      },
    }),
  ]
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.7.0/docs/data-sources/machine_configuration
data "talos_machine_configuration" "worker" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = var.cluster_endpoint
  machine_secrets    = talos_machine_secrets.talos.machine_secrets
  machine_type       = "worker"
  talos_version      = "v${var.talos_version}"
  kubernetes_version = var.kubernetes_version
  examples           = false
  docs               = false
  config_patches = [
    yamlencode(local.common_machine_config),
  ]
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.7.0/docs/data-sources/client_configuration
data "talos_client_configuration" "talos" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.talos.client_configuration
  endpoints            = [for node in local.controller_nodes : node.address]
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.7.0/docs/resources/cluster_kubeconfig
resource "talos_cluster_kubeconfig" "talos" {
  client_configuration = talos_machine_secrets.talos.client_configuration
  endpoint             = local.controller_nodes[0].address
  node                 = local.controller_nodes[0].address
  depends_on = [
    talos_machine_bootstrap.talos,
  ]
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.7.0/docs/resources/machine_configuration_apply
resource "talos_machine_configuration_apply" "controller" {
  count                       = var.controller_count
  client_configuration        = talos_machine_secrets.talos.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controller.machine_configuration
  endpoint                    = local.controller_nodes[count.index].address
  node                        = local.controller_nodes[count.index].address
  config_patches = [
    yamlencode({
      machine = {
        network = {
          hostname = local.controller_nodes[count.index].name
        }
      }
    }),
  ]
  depends_on = [
    libvirt_domain.controller,
  ]
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.7.0/docs/resources/machine_configuration_apply
resource "talos_machine_configuration_apply" "worker" {
  count                       = var.worker_count
  client_configuration        = talos_machine_secrets.talos.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker.machine_configuration
  endpoint                    = local.worker_nodes[count.index].address
  node                        = local.worker_nodes[count.index].address
  config_patches = [
    yamlencode({
      machine = {
	disks = [{
	  device = "/dev/disk/by-id/wwn-0x000000000000ab00"  # 000000000000ab00
	  # local.worker_nodes[count.index].wwn
          partitions = [{
	    mountpoint = "/var/localstore"
	  }]
	}]
        network = {
          hostname = local.worker_nodes[count.index].name
        }
      }
    }),
  ]
  depends_on = [
    libvirt_domain.worker,
  ]
}

// see https://registry.terraform.io/providers/siderolabs/talos/0.7.0/docs/resources/machine_bootstrap
resource "talos_machine_bootstrap" "talos" {
  client_configuration = talos_machine_secrets.talos.client_configuration
  endpoint             = local.controller_nodes[0].address
  node                 = local.controller_nodes[0].address
  depends_on = [
    talos_machine_configuration_apply.controller,
  ]
  timeouts = {
    create = "10m"
  }
}

#resource "time_sleep" "wait_for_cluster" {
#  depends_on = [
#    talos_machine_configuration_apply.controller,
#    talos_machine_configuration_apply.worker,
#    talos_machine_bootstrap.talos
#  ]
#  create_duration = "10m"
#}