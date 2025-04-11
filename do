#!/bin/bash
set -euo pipefail
#set -x

export KUBECONFIG=${ENV}/kubeconfig.yml
export TALOSCONFIG=${ENV}/talosconfig.yml
export SSL_CERT_FILE="${ROOT}/kubernetes-ingress-ca-crt.pem"

plan=tfplan

# the talos image builder.
# NB this can be one of:
#   imager: build locally using the ghcr.io/siderolabs/imager container image.
#   image_factory: build remotely using the image factory service at https://factory.talos.dev.
# NB this is automatically set to imager when running on linux 6.1+; otherwise,
#    it is set to image_factory.
talos_image_builder="$(perl -e 'print ((`uname -r` =~ /^(\d+\.\d+)/ && $1 >= 6.1) ? "imager" : "image_factory")')"

# see https://github.com/siderolabs/talos/releases
# renovate: datasource=github-releases depName=siderolabs/talos
talos_version="1.9.1"

# see https://github.com/siderolabs/extensions/pkgs/container/qemu-guest-agent
# see https://github.com/siderolabs/extensions/tree/main/guest-agents/qemu-guest-agent
talos_qemu_guest_agent_extension_tag="9.1.2@sha256:d601efce65544bd3f8617d0e4b355e1131563e120dd63225037526254ce3196f"

# see https://github.com/siderolabs/extensions/pkgs/container/drbd
# see https://github.com/siderolabs/extensions/tree/main/storage/drbd
# see https://github.com/LINBIT/drbd
talos_drbd_extension_tag="9.2.12-v1.9.1@sha256:54968d9481ed6f7af353ea233d035898e4dfff378206d04948546c76452707c7"

# see https://github.com/siderolabs/extensions/pkgs/container/spin
# see https://github.com/siderolabs/extensions/tree/main/container-runtime/spin
talos_spin_extension_tag="v0.17.0@sha256:90dc7ea8260caadbdf17513d87a6a834869ec4021bc9d190d4f5f21911ce8dd7"

# see https://github.com/piraeusdatastore/piraeus-operator/releases
# renovate: datasource=github-releases depName=piraeusdatastore/piraeus-operator
piraeus_operator_version="2.7.1"

export CHECKPOINT_DISABLE='1'
export TF_LOG='DEBUG' # TRACE, DEBUG, INFO, WARN or ERROR.
export TF_LOG_PATH='terraform.log'

export TALOSCONFIG=${ENV}/talosconfig.yml
export KUBECONFIG=${ENV}/kubeconfig.yml

function step {
    echo "🥑 $*  "
}

function update-talos-extension {
  # see https://github.com/siderolabs/extensions?tab=readme-ov-file#installing-extensions
  local variable_name="$1"
  local image_name="$2"
  local images="$3"
  local image="$(grep -F "$image_name:" <<<"$images")"
  local tag="${image#*:}"
  echo "updating the talos extension to $image..."
  variable_name="$variable_name" tag="$tag" perl -i -pe '
    BEGIN {
      $var = $ENV{variable_name};
      $val = $ENV{tag};
    }
    s/^(\Q$var\E=).*/$1"$val"/;
  ' do
}

function update-talos-extensions {
  step "updating the talos extensions"
  local images="$(crane export "ghcr.io/siderolabs/extensions:v$talos_version" | tar x -O image-digests)"
  update-talos-extension talos_qemu_guest_agent_extension_tag ghcr.io/siderolabs/qemu-guest-agent "$images"
  update-talos-extension talos_drbd_extension_tag ghcr.io/siderolabs/drbd "$images"
  update-talos-extension talos_spin_extension_tag ghcr.io/siderolabs/spin "$images"
}

function build_talos_image__imager {
    # see https://www.talos.dev/v1.9/talos-guides/install/boot-assets/
    # see https://www.talos.dev/v1.9/advanced/metal-network-configuration/
    # see Profile type at https://github.com/siderolabs/talos/blob/v1.9.1/pkg/imager/profile/profile.go#L24-L47

    if [[ -f $PWD/tmp/talos-1.9.1.qcow2 ]]; then
	return
    fi
    local talos_version_tag="v$talos_version"
    rm -rf tmp/talos
    mkdir -p tmp/talos
    cat >"tmp/talos/talos-$talos_version.yml" <<EOF
arch: amd64
platform: nocloud
secureboot: false
version: $talos_version_tag
customization:
  extraKernelArgs:
    - net.ifnames=0
input:
  kernel:
    path: /usr/install/amd64/vmlinuz
  initramfs:
    path: /usr/install/amd64/initramfs.xz
  baseInstaller:
    imageRef: ghcr.io/siderolabs/installer:$talos_version_tag
  systemExtensions:
    - imageRef: ghcr.io/siderolabs/qemu-guest-agent:$talos_qemu_guest_agent_extension_tag
    - imageRef: ghcr.io/siderolabs/drbd:$talos_drbd_extension_tag
    - imageRef: ghcr.io/siderolabs/spin:$talos_spin_extension_tag
output:
  kind: image
  imageOptions:
    diskSize: $((2*1024*1024*1024))
    diskFormat: raw
  outFormat: raw
EOF
  echo "creating image..."
  docker run --rm -i \
    -v $PWD/tmp/talos:/secureboot:ro \
    -v $PWD/tmp/talos:/out \
    -v /dev:/dev \
    --privileged \
    "ghcr.io/siderolabs/imager:$talos_version_tag" \
    - < "tmp/talos/talos-$talos_version.yml"
}

function build_talos_image__image_factory {
    # see https://www.talos.dev/v1.9/learn-more/image-factory/
    # see https://github.com/siderolabs/image-factory?tab=readme-ov-file#http-frontend-api
  local talos_version_tag="v$talos_version"
  rm -rf tmp/talos
  mkdir -p tmp/talos
  echo "creating image factory schematic..."
  cat >"tmp/talos/talos-$talos_version.yml" <<EOF
customization:
  extraKernelArgs:
    - net.ifnames=0
  systemExtensions:
    officialExtensions:
      - siderolabs/qemu-guest-agent
      - siderolabs/drbd
      - siderolabs/spin
EOF
  local schematic_response="$(curl \
    -X POST \
    --silent \
    --data-binary @"tmp/talos/talos-$talos_version.yml" \
    https://factory.talos.dev/schematics)"
  local schematic_id="$(jq -r .id <<<"$schematic_response")"
  if [ -z "$schematic_id" ]; then
    echo "ERROR: Failed to create the image schematic."
    exit 1
  fi
  local image_url="https://factory.talos.dev/image/$schematic_id/$talos_version_tag/nocloud-amd64.raw.zst"
  echo "downloading image from $image_url..."
  rm -f tmp/talos/nocloud-amd64.raw.zst
  curl \
    --silent \
    --output tmp/talos/nocloud-amd64.raw.zst \
    "$image_url"
  echo "extracting image..."
  unzstd tmp/talos/nocloud-amd64.raw.zst
}

function build_talos_image {
  case "$talos_image_builder" in
    imager)
      build_talos_image__imager
      ;;
    image_factory)
      build_talos_image__image_factory
      ;;
    *)
      echo $"unknown talos_image_builder $talos_image_builder"
      exit 1
      ;;
  esac
  local pool=default #tanzen
  local qemu="-c qemu:///system"
  echo "converting image to the qcow2 format..."
  local talos_libvirt_base_volume_name="talos-$talos_version.qcow2"
  qemu-img convert -O qcow2 tmp/talos/nocloud-amd64.raw tmp/talos/$talos_libvirt_base_volume_name
  qemu-img info tmp/talos/$talos_libvirt_base_volume_name
  if [ -n "$(virsh $qemu vol-list ${pool} | grep $talos_libvirt_base_volume_name)" ]; then
      #    virsh vol-delete --pool default $talos_libvirt_base_volume_name
      virsh $qemu vol-delete --pool ${pool} $talos_libvirt_base_volume_name
  fi
  echo "uploading image to libvirt..."
  virsh $qemu vol-create-as ${pool} $talos_libvirt_base_volume_name 10M
  #  virsh vol-upload --pool default $talos_libvirt_base_volume_name tmp/talos/$talos_libvirt_base_volume_name
  virsh $qemu vol-upload --pool ${pool} $talos_libvirt_base_volume_name tmp/talos/$talos_libvirt_base_volume_name
  cat >terraform.tfvars <<EOF
talos_version                  = "$talos_version"
talos_libvirt_base_volume_name = "$talos_libvirt_base_volume_name"
EOF
}

function init {
    if [[ "$( virsh vol-list default | \
                grep -c talos-1.9.1.qcow2)" -gt 0 ]]; then
	echo using cached talos image.
	return
    fi

    step 'build talos image'
    build_talos_image || true
    step 'initialize talos kubernetes terraform model'
    time terraform init -lockfile=readonly
}

function plan {
  step "planning kubernetes cluster. output in ${INFRA}/plan.log"
  time terraform plan -out=$plan > plan.log
}

function apply {
    time terraform apply $plan
    rm -rf ${ENV}/kubeconfig.yml
    rm -rf ${ENV}/talosconfig.yml
    terraform output -raw talosconfig > ${ENV}/talosconfig.yml
    terraform output -raw kubeconfig > ${ENV}/kubeconfig.yml
    chmod go-r ${ENV}/kubeconfig.yml
    chmod go-r ${ENV}/talosconfig.yml
    health
#    kubectl taint nodes c0 node-role.kubernetes.io/control-plane:NoSchedule-
#    piraeus-install
    export-kubernetes-ingress-ca-crt
    info
}

function plan-apply {
    plan
    apply
}

function health {
    step health check
    
    local controllers="$(terraform output -raw controllers)"
    local c0="$(echo $controllers | cut -d , -f 1)"
    step "boostrapping talos control plane: $c0"
    talosctl bootstrap -n $c0 || true
  
    step cluster health
    set +Eeuo pipefail
    
    local pause=10
    local cycles_per_min=$(( 60 / pause ))
    local minutes=30
    local retries=$(( cycles_per_min * minutes ))
    local cycle=0
    local ready=0
    local live=0

    step waiting for control plane to be reachable
    while [[ true ]]; do
	kubectl get --raw='/readyz?verbose' > /dev/null 2>&1
	if [[ $? -eq 0 ]]; then
	    break
	fi
	sleep 3
	printf "."
    done
    while [[ true ]]; do
	# NB: https://stackoverflow.com/questions/73407661/componentstatus-is-deprecated-what-to-use-then
	# get cluster service statuses, count the number of status lines that end in "ok".
	# if all services report ok, proceed. Otherwise show non-ok statuses and keep waiting.
	# first for ready status
	if [[ $( kubectl get --raw='/readyz?verbose' | grep + | egrep -vc  "ok$" ) -gt 0 ]]; then
	    echo
	    echo some control plane components are not ready:
	    kubectl get --raw='/readyz?verbose' | grep -v " ok"
	    ready=0
	else
	    echo all control plane components reporting ready status
	    ready=1
	fi
	# then for live status.
	if [[ $( kubectl get --raw='/livez?verbose' | grep + | egrep -vc  "ok$" ) -gt 0 ]]; then
	    echo
	    echo some control plane components are not live:
	    kubectl get --raw='/livez?verbose' | grep -v " ok"
	    live=0
	else
	    echo all control plane components reporting live status
	    live=1
	fi
	if [[ ( $ready -eq 1 && $live -eq 1 ) || ( $cycle -ge $retries ) ]]; then
	    echo cluster health check succeeded.
	    break
	fi
	cycle=$(( cycle + 1 ))
	print "."
	sleep $pause
    done
    set -Eeuo pipefail
    echo
}

function health0 {
    # This times out unpredictably with the error below.
    # But the cluster is up.
    # Switching approaches until developing a reliable alternative.
    c() {
	[STDERR] [STDOUT] 🥑 talosctl health  
[STDERR] [STDOUT] waiting for cluster to be healthy.
[STDERR] [STDERR] discovered nodes: ["10.17.4.80" "10.17.4.90"]
[STDERR] [STDERR] waiting for etcd to be healthy: ...
[STDERR] [STDERR] waiting for etcd to be healthy: 1 error occurred:
[STDERR] [STDERR] 	* 10.17.4.80: service "etcd" not in expected state "Running": current state [Preparing] Running pre state
[STDERR] [STDERR] waiting for etcd to be healthy: 1 error occurred:
[STDERR] [STDERR] 	* 10.17.4.80: service is not healthy: etcd
[STDERR] [STDERR] waiting for etcd to be healthy: OK
[STDERR] [STDERR] waiting for etcd members to be consistent across nodes: ...
[STDERR] [STDERR] waiting for etcd members to be consistent across nodes: OK
[STDERR] [STDERR] waiting for etcd members to be control plane nodes: ...
[STDERR] [STDERR] waiting for etcd members to be control plane nodes: OK
[STDERR] [STDERR] waiting for apid to be ready: ...
[STDERR] [STDERR] waiting for apid to be ready: 1 error occurred:
[STDERR] [STDERR] 	* 10.17.4.90: rpc error: code = Unavailable desc = connection error: desc = "transport: authentication handshake failed: tls: failed to verify certificate
: x509: certificate signed by unknown authority"
[STDERR] [STDERR] healthcheck error: rpc error: code = DeadlineExceeded desc = context deadline exceeded

    }
    
  step 'talosctl health'
  local controllers="$(terraform output -raw controllers)"
  local workers="$(terraform output -raw workers)"
  local c0="$(echo $controllers | cut -d , -f 1)"
  local timeout=10m0s
  
  step "boostrapping talos control plane: $c0"
  talosctl bootstrap -n $c0 || true
  
  echo "waiting for cluster to be healthy."
  talosctl -e $c0 -n $c0 --wait-timeout $timeout \
    health \
    --control-plane-nodes $controllers \
    --worker-nodes $workers
}

function piraeus-install {
  # see https://github.com/piraeusdatastore/piraeus-operator
  # see https://github.com/piraeusdatastore/piraeus-operator/blob/v2.7.1/docs/how-to/talos.md
  # see https://github.com/piraeusdatastore/piraeus-operator/blob/v2.7.1/docs/tutorial/get-started.md
  # see https://github.com/piraeusdatastore/piraeus-operator/blob/v2.7.1/docs/tutorial/replicated-volumes.md
  # see https://github.com/piraeusdatastore/piraeus-operator/blob/v2.7.1/docs/explanation/components.md
  # see https://github.com/piraeusdatastore/piraeus-operator/blob/v2.7.1/docs/reference/linstorsatelliteconfiguration.md
  # see https://github.com/piraeusdatastore/piraeus-operator/blob/v2.7.1/docs/reference/linstorcluster.md
  # see https://linbit.com/drbd-user-guide/linstor-guide-1_0-en/
  # see https://linbit.com/drbd-user-guide/linstor-guide-1_0-en/#ch-kubernetes
  # see 5.7.1. Available Parameters in a Storage Class at https://linbit.com/drbd-user-guide/linstor-guide-1_0-en/#s-kubernetes-sc-parameters
  # see https://linbit.com/drbd-user-guide/drbd-guide-9_0-en/
  # see https://www.talos.dev/v1.9/kubernetes-guides/configuration/storage/#piraeus--linstor
  step 'piraeus install'
  kubectl apply --server-side -k "https://github.com/piraeusdatastore/piraeus-operator//config/default?ref=v$piraeus_operator_version"
  step 'piraeus wait'
  kubectl wait pod --timeout=15m --for=condition=Ready -n piraeus-datastore -l app.kubernetes.io/component=piraeus-operator
  step 'piraeus configure'
  kubectl apply -n piraeus-datastore -f - <<'EOF'
apiVersion: piraeus.io/v1
kind: LinstorSatelliteConfiguration
metadata:
  name: talos-loader-override
spec:
  podTemplate:
    spec:
      initContainers:
        - name: drbd-shutdown-guard
          $patch: delete
        - name: drbd-module-loader
          $patch: delete
      volumes:
        - name: run-systemd-system
          $patch: delete
        - name: run-drbd-shutdown-guard
          $patch: delete
        - name: systemd-bus-socket
          $patch: delete
        - name: lib-modules
          $patch: delete
        - name: usr-src
          $patch: delete
        - name: etc-lvm-backup
          hostPath:
            path: /var/etc/lvm/backup
            type: DirectoryOrCreate
        - name: etc-lvm-archive
          hostPath:
            path: /var/etc/lvm/archive
            type: DirectoryOrCreate
EOF
  kubectl apply -f - <<EOF
apiVersion: piraeus.io/v1
kind: LinstorCluster
metadata:
  name: linstor
EOF
  kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
provisioner: linstor.csi.linbit.com
metadata:
  name: linstor-lvm-r1
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
parameters:
  csi.storage.k8s.io/fstype: xfs
  linstor.csi.linbit.com/autoPlace: "1"
  linstor.csi.linbit.com/storagePool: lvm
EOF
  step 'piraeus configure wait'
  kubectl wait pod --timeout=15m --for=condition=Ready -n piraeus-datastore -l app.kubernetes.io/name=piraeus-datastore
  kubectl wait LinstorCluster/linstor --timeout=15m --for=condition=Available
  create_device_pool
}
function create_device_pool {
    step 'piraeus create-device-pool'
    workers=( $( terraform output -raw workers | tr ',' ' ' ) )    
    step "wait for worker storage"
    for ((n=0; n<${#workers[@]}; ++n)); do
	local node="w$((n))"
	wait_node $node $n "000000000000ab%02x"
    done
}
function wait_node {
    node=$1
    n=$2
    wwn_format=$3
    local wwn="$(printf "${wwn_format}" $n)"
    step "piraeus wait node $node"
    while ! kubectl linstor storage-pool list --node "$node" >/dev/null 2>&1; do sleep 3; done
    step "piraeus create-device-pool $node"
    if ! kubectl linstor storage-pool list --node "$node" --storage-pool lvm | grep -q lvm; then
      kubectl linstor physical-storage create-device-pool \
        --pool-name lvm \
        --storage-pool lvm \
        lvm \
        "$node" \
        "/dev/disk/by-id/wwn-0x$wwn"
    fi
}

function piraeus-info {
  step 'piraeus node list'
  kubectl linstor node list
  step 'piraeus storage-pool list'
  kubectl linstor storage-pool list
  step 'piraeus volume list'
  kubectl linstor volume list
}
function controllers {
    terraform output -raw controllers
}
function workers {
    terraform output -raw workers
}
function info {
    local controllers="$(terraform output -raw controllers)"
    local workers="$(terraform output -raw workers)"
    local nodes=($(echo "$controllers,$workers" | tr ',' ' '))
    step 'talos node installer image'
    for n in "${nodes[@]}"; do
	# NB there can be multiple machineconfigs in a machine. we only want to see
	#    the ones with an id that looks like a version tag.
	talosctl -n $n get machineconfigs -o json \
	    | jq -r 'select(.metadata.id | test("v\\d+")) | .spec' \
	    | yq -r '.machine.install.image' \
	    | sed -E "s,(.+),$n: \1,g"
    done
    step 'talos node os-release'
    for n in "${nodes[@]}"; do
	talosctl -n $n read /etc/os-release \
	    | sed -E "s,(.+),$n: \1,g"
    done
    step 'kubernetes nodes and cluster info'
    kubectl get nodes -o wide
    kubectl cluster-info

    step 'cilium info'
    cilium status --wait
    kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose

#    piraeus-info
}

function dash {
    controllers="$(terraform output -raw controllers)"
    workers="$(terraform output -raw workers)"
    all="$controllers,$workers"
    talosctl -n $all version
    talosctl -n $all dashboard
}

function export-kubernetes-ingress-ca-crt {
    secret=ingress-tls
    printf "Waiting for secret: $secret."
    while ! kubectl get secret $secret 2>> /dev/null --namespace cert-manager; do
	printf "-"
	sleep 3
    done
    echo
    kubectl get -n cert-manager secret/$secret -o jsonpath='{.data.tls\.crt}' \
	| base64 -d \
		 > kubernetes-ingress-ca-crt.pem
}

function upgrade {
  step 'talosctl upgrade'
  local controllers=($(terraform output -raw controllers | tr ',' ' '))
  local workers=($(terraform output -raw workers | tr ',' ' '))
  for n in "${controllers[@]}" "${workers[@]}"; do
    talosctl -e $n -n $n upgrade --preserve --wait
  done
  health
}

function destroy {
  time terraform destroy -auto-approve
}

case $1 in
  update-talos-extensions)
    update-talos-extensions
    ;;
  init)
    init
    ;;
  plan)
    plan
    ;;
  apply)
    apply
    ;;
  plan-apply)
    plan
    apply
    ;;
  health)
    health
    ;;
  info)
    info
    ;;
  destroy)
    destroy
    ;;
  *)
    echo $"Usage: $0 {init|plan|apply|plan-apply|health|info}"
    exit 1
    ;;
esac
