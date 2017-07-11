#!/bin/bash
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
set -ex
: ${WORK_DIR:="$(pwd)"}
source ${WORK_DIR}/tools/gate/funcs/helm.sh
source ${WORK_DIR}/tools/gate/funcs/kube.sh

helm_build

helm search

# NOTE(portdirect): Temp workaround until module loading is supported by
# OpenStack-Helm in Fedora
if [ "x$HOST_OS" == "xfedora" ]; then
  sudo modprobe openvswitch
  sudo modprobe gre
  sudo modprobe vxlan
  sudo modprobe ip6_tables
fi

if [ "x$PVC_BACKEND" == "xceph" ]; then
  kubectl label nodes ceph-storage=enabled --all
  CONTROLLER_MANAGER_POD=$(kubectl get -n kube-system pods -l component=kube-controller-manager --no-headers -o name | head -1 | awk -F '/' '{ print $NF }')
  kubectl exec -n kube-system ${CONTROLLER_MANAGER_POD} -- sh -c "cat > /etc/resolv.conf <<EOF
nameserver 10.96.0.10
nameserver 8.8.8.8
search cluster.local svc.cluster.local
EOF"

  export osd_cluster_network=192.168.0.0/16
  export osd_public_network=192.168.0.0/16

  helm install --namespace=ceph ${WORK_DIR}/ceph --name=ceph \
    --set manifests_enabled.client_secrets=false \
    --set network.public=$osd_public_network \
    --set network.cluster=$osd_cluster_network

  kube_wait_for_pods ceph 600

  kubectl exec -n ceph ceph-mon-0 -- ceph -s

  helm install --namespace=openstack ${WORK_DIR}/ceph --name=ceph-openstack-config \
    --set manifests_enabled.storage_secrets=false \
    --set manifests_enabled.deployment=false \
    --set ceph.namespace=ceph \
    --set network.public=$osd_public_network \
    --set network.cluster=$osd_cluster_network

  kube_wait_for_pods openstack 420

  kubectl exec -n ceph ceph-mon-0 -- ceph osd pool create volumes 8
  kubectl exec -n ceph ceph-mon-0 -- ceph osd pool create images 8
  kubectl exec -n ceph ceph-mon-0 -- ceph osd pool create vms 8
fi

helm install --namespace=openstack ${WORK_DIR}/ingress --name=ingress
helm install --namespace=openstack ${WORK_DIR}/mariadb --name=mariadb
helm install --namespace=openstack ${WORK_DIR}/memcached --name=memcached
helm install --namespace=openstack ${WORK_DIR}/etcd --name=etcd-rabbitmq
helm install --namespace=openstack ${WORK_DIR}/rabbitmq --name=rabbitmq
kube_wait_for_pods openstack 600
helm install --namespace=openstack ${WORK_DIR}/keystone --name=keystone
if [ "x$PVC_BACKEND" == "xceph" ]; then
  helm install --namespace=openstack ${WORK_DIR}/glance --name=glance
else
  helm install --namespace=openstack ${WORK_DIR}/glance --name=glance \
      --values=${WORK_DIR}/tools/overrides/mvp/glance.yaml
fi
kube_wait_for_pods openstack 420
helm install --namespace=openstack ${WORK_DIR}/nova --name=nova \
    --values=${WORK_DIR}/tools/overrides/mvp/nova.yaml \
    --set=conf.nova.libvirt.nova.conf.virt_type=qemu
helm install --namespace=openstack ${WORK_DIR}/neutron --name=neutron \
    --values=${WORK_DIR}/tools/overrides/mvp/neutron.yaml
kube_wait_for_pods openstack 420

if [ "x$INTEGRATION" == "xaio" ]; then
 bash ${WORK_DIR}/tools/gate/openstack_aio_launch.sh
fi

if [ "x$INTEGRATION" == "xmulti" ]; then
  if [ "x$PVC_BACKEND" == "xceph" ]; then
    helm install --namespace=openstack ${WORK_DIR}/cinder --name=cinder
  else
    helm install --namespace=openstack ${WORK_DIR}/cinder --name=cinder \
        --values=${WORK_DIR}/tools/overrides/mvp/cinder.yaml
  fi
  helm install --namespace=openstack ${WORK_DIR}/heat --name=heat
  helm install --namespace=openstack ${WORK_DIR}/horizon --name=horizon
  kube_wait_for_pods openstack 420

  helm install --namespace=openstack ${WORK_DIR}/barbican --name=barbican
  helm install --namespace=openstack ${WORK_DIR}/magnum --name=magnum
  kube_wait_for_pods openstack 420

  helm install --namespace=openstack ${WORK_DIR}/mistral --name=mistral
  helm install --namespace=openstack ${WORK_DIR}/senlin --name=senlin
  kube_wait_for_pods openstack 600

  helm_test_deployment keystone 600
  helm_test_deployment glance 600
  helm_test_deployment cinder 600
  helm_test_deployment neutron 600
  helm_test_deployment nova 600
fi
