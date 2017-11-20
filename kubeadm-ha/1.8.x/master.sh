#!/bin/bash

#sh master.sh 192.168.2.201 192.168.2.200 k8s.master1,k8s.master2,k8s.master3 192.168.2.201,192.168.2.202,192.168.2.203
#sh master.sh 本机IP 虚拟IP MASTER服务器主机名列表（必须包含本机，以逗号隔开） MASTER服务器IP列表（以逗号隔开，必须与主机名列表对应）
#只在第一台MASTER主机上运行

set -o errexit
set -o nounset
set -o pipefail

MASTER_ADDRESS=${1:-"127.0.0.1"}
CLUSTER_VIP=${2:-"127.0.0.1"}
CLUSTER_HOSTNAMES=${3:-"k8s.master1"}
CLUSTER_HOSTNAMES_ARR=(${CLUSTER_HOSTNAMES//,/ })
CLUSTER_IPS=${4:-"127.0.0.1"}
CLUSTER_IPS_ARR=(${CLUSTER_IPS//,/ })
KUBE_TOKEN=${5:-"863f67.19babbff7bfe8543"}
DOCKER_MIRRORS=${6:-"https://6jjw0pnh.mirror.aliyuncs.com"}
DOCKER_IMAGE_PREFIX="registry.cn-shenzhen.aliyuncs.com/bixin_k8s"
RPM_URL_PREFIX="http://bixin-rpm.oss-cn-shenzhen.aliyuncs.com/k8s/"
KUBE_VERSION=1.8.3
KUBE_PAUSE_VERSION=3.0
KUBE_CNI_VERSION=0.5.1
ETCD_VERSION=3.0.17
FLANNEL_VERSION=v0.8.0
CURRENT_DIR="$(pwd)"

echo '============================================================'
echo '====================Disable selinux and firewalld...========'
echo '============================================================'
#if [ $(getenforce) = "Enabled" ]; then
setenforce 0
#fi
systemctl disable firewalld
systemctl stop firewalld

sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config

echo "Disable selinux and firewalld success!"

echo '============================================================'
echo '====================Add docker yum repo...=================='
echo '============================================================'
#docker yum源
# cat >> /etc/yum.repos.d/docker.repo <<EOF
# [docker-repo]
# name=Docker Repository
# #baseurl=http://mirrors.aliyun.com/docker-engine/yum/repo/main/centos/7
# baseurl=https://yum.dockerproject.org/repo/main/centos/7
# enabled=1
# gpgcheck=0
# EOF
yum install -y yum-utils device-mapper-persistent-data lvm2
yum-config-manager --add-repo http://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
yum makecache fast
echo "Add docker yum repo success!"

echo '============================================================'
echo '====================Install docker...======================='
echo '============================================================'
#查看docker版本
#yum list docker-ce.x86_64  --showduplicates |sort -r
#安装docker
# Kubernetes 1.8已经针对Docker的1.11.2, 1.12.6, 1.13.1和17.03.2等版本做了验证。 这里在各节点安装docker的17.03.2版本。
yum install -y --setopt=obsoletes=0 docker-ce-17.03.2.ce-1.el7.centos docker-ce-selinux-17.03.2.ce-1.el7.centos

echo "Install docker success!"

echo '============================================================'
echo '====================Config docker...========================'
echo '============================================================'
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<EOF
{
  "registry-mirrors": ["${DOCKER_MIRRORS}"],
  "exec-opts": ["native.cgroupdriver=systemd"]
}
EOF
# Docker从1.13版本开始调整了默认的防火墙规则，禁用了iptables filter表中FOWARD链，这样会引起Kubernetes集群中跨Node的Pod无法通信，在各个Docker节点执行下面的命令：
iptables -P FORWARD ACCEPT
# 并在docker的systemd unit文件中以ExecStartPost加入上面的命令
sed -i '/^\ExecStart=/i\ExecStartPost=/usr/sbin/iptables -P FORWARD ACCEPT' /usr/lib/systemd/system/docker.service
echo "Config docker success!"

echo '============================================================'
echo '====Install kubernetes-cni、kubelet、kubectl、kubeadm...===='
echo '============================================================'
RPMS=(socat-1.7.3.2-2.el7.x86_64
kubernetes-cni-0.5.1-1.x86_64
kubelet-1.8.3-0.x86_64
kubectl-1.8.3-0.x86_64
kubeadm-1.8.3-0.x86_64)
# 下载rpm包
mkdir -p /tmp/k8s
for rpmName in ${RPMS[@]} ; do
  curl -o /tmp/k8s/$rpmName.rpm $RPM_URL_PREFIX$rpmName.rpm
done
# rpm安装
rpm -ivh /tmp/k8s/*.rpm
# 删除rpm包
rm -rf /tmp/k8s

echo "Install success!"

echo '============================================================'
echo '===================Config kubelet...========================'
echo '============================================================'
#sed -i 's/cgroup-driver=systemd/cgroup-driver=cgroupfs/g' /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
# Kubernetes 1.8开始要求关闭系统的Swap，如果不关闭，默认配置下kubelet将无法启动。可以通过kubelet的启动参数--fail-swap-on=false更改这个限制。这里修改启动参数
sed -i '/^\[Service\]/a\Environment="KUBELET_SWAP_ARGS=--fail-swap-on=false"' /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
sed -i 's/ExecStart=[^\n].*$/& $KUBELET_SWAP_ARGS/g' /etc/systemd/system/kubelet.service.d/10-kubeadm.conf

echo "config --pod-infra-container-image=${DOCKER_IMAGE_PREFIX}/pause-amd64:${KUBE_PAUSE_VERSION}"
cat > /etc/systemd/system/kubelet.service.d/20-pod-infra-image.conf <<EOF
[Service]
Environment="KUBELET_EXTRA_ARGS=--pod-infra-container-image=${DOCKER_IMAGE_PREFIX}/pause-amd64:${KUBE_PAUSE_VERSION}"
EOF

echo "Config kubelet success!"

echo '============================================================'
echo '==============Start docker and kubelet services...=========='
echo '============================================================'
systemctl enable docker
systemctl enable kubelet
systemctl start docker
systemctl start kubelet
echo "The docker and kubelet services started"

#创建Etcd集群
echo '============================================================'
echo '==============Create etcd-cluster with docker ...==========='
echo '============================================================'
ETCD_CLUSTER=""
ETCD_NAME="etcd"
length=${#CLUSTER_IPS_ARR[@]}
for ((i=0;i<$length;i++)) ; do
    ETCD_CLUSTER="${ETCD_CLUSTER}etcd${i}=http://${CLUSTER_IPS_ARR[$i]}:2380"
    if [ $i -lt $[$length - 1] ] ; then
    	ETCD_CLUSTER=${ETCD_CLUSTER}","
    fi
    if [ "$MASTER_ADDRESS" = "${CLUSTER_IPS_ARR[$i]}" ] ; then 
    	ETCD_NAME="etcd${i}"
    fi
done

docker run -d \
--restart always \
-v /etc/ssl/certs:/etc/ssl/certs \
-v /var/lib/etcd-cluster:/var/lib/etcd \
-p 4001:4001 \
-p 2380:2380 \
-p 2379:2379 \
--name etcd \
${DOCKER_IMAGE_PREFIX}/etcd-amd64:3.0.17 \
etcd --name=${ETCD_NAME} \
--advertise-client-urls=http://${MASTER_ADDRESS}:2379,http://${MASTER_ADDRESS}:4001 \
--listen-client-urls=http://0.0.0.0:2379,http://0.0.0.0:4001 \
--initial-advertise-peer-urls=http://${MASTER_ADDRESS}:2380 \
--listen-peer-urls=http://0.0.0.0:2380 \
--initial-cluster-token=9477af68bbee1b9ae037d6fd9e7efefd \
--initial-cluster=${ETCD_CLUSTER} \
--initial-cluster-state=new \
--auto-tls \
--peer-auto-tls \
--data-dir=/var/lib/etcd
echo "The etcd-cluster is created"

copy_sshkey_to_other_server () {
  if [ ! -f ~/.ssh/id_rsa.pub ]; then
    ssh-keygen -t rsa
  fi
  for item in ${CLUSTER_IPS_ARR[@]}; do
    if [ "$MASTER_ADDRESS" != "${item}" ] ; then
      ssh-copy-id -i ~/.ssh/id_rsa.pub root@"${item}"
    fi
  done
}

install_etct_to_other_server () {
  #yum install -y rsync
  for item in ${CLUSTER_IPS_ARR[@]}; do
    if [ "$MASTER_ADDRESS" != "${item}" ] ; then
      scp "$(basename $0)" root@"${item}":~
      ssh root@"${item}" "cd ~ && sh $(basename $0) ${item} ${CLUSTER_VIP} ${CLUSTER_HOSTNAMES} ${CLUSTER_IPS} ${KUBE_TOKEN} ${DOCKER_MIRRORS} && rm -f $(basename $0)"
      #rsync -Ravzt --progress "$CURRENT_DIR" root@"${item}":/
      #ssh root@"${item}" "cd ${CURRENT_DIR} && sh $(basename $0) ${item} ${CLUSTER_VIP} ${CLUSTER_HOSTNAMES} ${CLUSTER_IPS}"
    fi
  done
  echo "All etcd server is installed!"
}

kubeadm_init () {
  #export KUBE_REPO_PREFIX="${DOCKER_IMAGE_PREFIX}"

  API_SERVER_CERT_SANS=""
  ETCD_ENDPOINTS=""
  for item in ${CLUSTER_HOSTNAMES_ARR[@]}; do
      API_SERVER_CERT_SANS="${API_SERVER_CERT_SANS}- ${item}\n"
  done
  for item in ${CLUSTER_IPS_ARR[@]}; do
      API_SERVER_CERT_SANS="${API_SERVER_CERT_SANS}- ${item}\n"
      ETCD_ENDPOINTS="${ETCD_ENDPOINTS}  - http://${item}:2379\n"
  done
  API_SERVER_CERT_SANS="${API_SERVER_CERT_SANS}- ${CLUSTER_VIP}\n"

  cat > $(pwd)/kubeadm-init.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1alpha1
kind: MasterConfiguration
kubernetesVersion: v${KUBE_VERSION}
imageRepository: ${DOCKER_IMAGE_PREFIX}
networking:
  podSubnet: 10.244.0.0/16
apiServerCertSANs:
$(echo -e "$API_SERVER_CERT_SANS")
etcd:
  endpoints:
$(echo -e "$ETCD_ENDPOINTS")
token: ${KUBE_TOKEN}
EOF

  kubeadm init --config=$(pwd)/kubeadm-init.yaml

  #查看token的命令
  echo "You can use this order to query the token: kubeadm token list"

  #由于v1.7.x以后使用了NodeRestriction等安全检查控制，务必设置成v1.6.x推荐的admission-control配置
  sed -i 's/- --admission-control=Initializers,NamespaceLifecycle,LimitRanger,ServiceAccount,PersistentVolumeLabel,DefaultStorageClass,DefaultTolerationSeconds,NodeRestriction,ResourceQuota/- --admission-control=NamespaceLifecycle,LimitRanger,ServiceAccount,PersistentVolumeLabel,DefaultStorageClass,ResourceQuota,DefaultTolerationSeconds/g' /etc/kubernetes/manifests/kube-apiserver.yaml
  
  #config admin...
  mkdir -p $HOME/.kube
  ln -sfn /etc/kubernetes/admin.conf $HOME/.kube/config
  echo "Config admin success!"
  #重启docker kubelet服务
  systemctl restart docker kubelet
}

create_flannel_service () {
  echo '============================================================'
  echo '==============Create flannel service========================'
  echo '============================================================'

  set +o errexit
  while [ 0 -eq 0 ]
  do
    kubectl get node
    # check and retry
    if [ $? -eq 0 ]; then
        break;
    else  
        echo "Docker and kubelet service is restarting, retry in 10 seconds..."
        sleep 10s
    fi
  done
  set -o errexit

  #如果没有安装wget，则进行安装，避免接下来的操作报错
  if [ ! -f /usr/bin/wget ]; then
      yum install -y wget
  fi

  kubectl --namespace kube-system apply -f https://raw.githubusercontent.com/coreos/flannel/${FLANNEL_VERSION}/Documentation/kube-flannel-rbac.yml
  rm -rf ./kube-flannel.yml
  wget https://raw.githubusercontent.com/coreos/flannel/${FLANNEL_VERSION}/Documentation/kube-flannel.yml
  sed -i 's:quay.io/coreos/flannel:'${DOCKER_IMAGE_PREFIX}'/flannel:g' ./kube-flannel.yml
  kubectl --namespace kube-system apply -f ./kube-flannel.yml
  echo "Flannel created!"
}

install_heapster () {
  kubectl taint nodes --all node-role.kubernetes.io/master-
  kubectl create -f ../yaml/cluster-monitoring
  echo "Heapster is installed! Please wait a few minutes to check."
}

install_dashboard () {
  kubectl create -f ../yaml/dashboard/kubernetes-dashboard.yaml
  echo "Dashboard is installed! Default port is: 30000."
}

config_the_other_server () {
  K8S_CONFIG_PATH="/etc/kubernetes"
  TMP_CONFIG_PATH="/tmp/kubernetes"
  MASTER_COUNT=${#CLUSTER_IPS_ARR[@]}
  for item in ${CLUSTER_IPS_ARR[@]}; do
    if [ "$MASTER_ADDRESS" != "${item}" ] ; then
      mkdir -p TMP_CONFIG_PATH
      cp -rf $K8S_CONFIG_PATH $TMP_CONFIG_PATH
      sed -i 's/- --advertise-address='${MASTER_ADDRESS}'/- --advertise-address='${item}'/g' $TMP_CONFIG_PATH/manifests/kube-apiserver.yaml
      sed -i 's/'${MASTER_ADDRESS}'/'${item}'/g' $TMP_CONFIG_PATH/kubelet.conf
      sed -i 's/'${MASTER_ADDRESS}'/'${item}'/g' $TMP_CONFIG_PATH/admin.conf
      sed -i 's/'${MASTER_ADDRESS}'/'${item}'/g' $TMP_CONFIG_PATH/controller-manager.conf
      sed -i 's/'${MASTER_ADDRESS}'/'${item}'/g' $TMP_CONFIG_PATH/scheduler.conf
      #rsync -avzt --progress $TMP_CONFIG_PATH/* root@"${item}":$K8S_CONFIG_PATH
      scp -r $TMP_CONFIG_PATH/* root@"${item}":$K8S_CONFIG_PATH
      rm -rf $TMP_CONFIG_PATH
      ssh root@"${item}" "systemctl daemon-reload && systemctl restart docker kubelet && mkdir -p ~/.kube && ln -sfn /etc/kubernetes/admin.conf ~/.kube/config"
    fi
  done
  systemctl daemon-reload && systemctl restart docker kubelet
  #等待所有master节点ready
  set +o errexit
  for item in ${CLUSTER_HOSTNAMES_ARR[@]}; do
      while [ 0 -eq 0 ]
      do
        if [ "$(kubectl get node -o wide | grep ${item} | awk '{print $2}')" != "Ready" ]; then
            echo "Master node: '${item}' is not ready, retry in 30 seconds..."
            sleep 30s
        else  
            break;
        fi
      done
  done
  set -o errexit

  #保证所有master节点上都运行kubernetes-dashboard、kube-dns服务
  kubectl scale --replicas=$MASTER_COUNT -n kube-system deployment/kube-dns
  kubectl scale --replicas=$MASTER_COUNT -n kube-system deployment/kubernetes-dashboard
  kubectl scale --replicas=$MASTER_COUNT -n kube-system deployment/heapster
  kubectl scale --replicas=$MASTER_COUNT -n kube-system deployment/monitoring-grafana
  kubectl scale --replicas=$MASTER_COUNT -n kube-system deployment/monitoring-influxdb
  echo "All server is Configured!"
}

#高可用与负载均衡
install_keepalived_nginxlb () {
  yum install -y keepalived
  systemctl enable keepalived && systemctl restart keepalived
  mv /etc/keepalived/keepalived.conf /etc/keepalived/keepalived.conf.bak
  cat > /etc/keepalived/check_apiserver.sh <<EOF
#!/bin/bash
err=0
for k in \$( seq 1 10 )
do
    check_code=\$(ps -ef|grep kube-apiserver | wc -l)
    if [ "\$check_code" = "1" ]; then
        err=\$(expr \$err + 1)
        sleep 5
        continue
    else
        err=0
        break
    fi
done
if [ "\$err" != "0" ]; then
    echo "systemctl stop keepalived"
    /usr/bin/systemctl stop keepalived
    exit 1
else
    exit 0
fi
EOF

  chmod a+x /etc/keepalived/check_apiserver.sh

  #本机keepalived配置
  INTERFACE_NAME=$(ip a | grep -B2 "inet ${MASTER_ADDRESS}/" | awk -F ': ' '/^[0-9]/{print $2}')
  PRIORITY=100
  cat > /etc/keepalived/keepalived.conf <<EOF
! Configuration File for keepalived
global_defs {
    router_id LVS_DEVEL
}
vrrp_script chk_apiserver {
    script "/etc/keepalived/check_apiserver.sh"
    interval 2
    weight -5
    fall 3  
    rise 2
}
vrrp_instance VI_1 {
    state MASTER
    interface ${INTERFACE_NAME}
    mcast_src_ip ${MASTER_ADDRESS}
    virtual_router_id 51
    priority ${PRIORITY}
    advert_int 2
    authentication {
        auth_type PASS
        auth_pass 4be37dc3b4c90194d1600c483e10ad1d
    }
    virtual_ipaddress {
        ${CLUSTER_VIP}
    }
    track_script {
       chk_apiserver
    }
}
EOF

  #本机nginx-lb配置
  UPSTREAM_SERVER_LIST=""
  for item in ${CLUSTER_IPS_ARR[@]}; do
      UPSTREAM_SERVER_LIST="${UPSTREAM_SERVER_LIST}        server ${item}:6443 weight=5 max_fails=3 fail_timeout=30s;\n"
  done
  mkdir -p /etc/nginx
  cat > /etc/nginx/nginx-lb.conf <<EOF
events {
    use                 epoll;
    worker_connections  65535;
}
stream {
    upstream apiserver {
$(echo -e "$UPSTREAM_SERVER_LIST")
    }

    server {
        listen 8443;
        proxy_connect_timeout 1s;
        proxy_timeout 3s;
        proxy_pass apiserver;
    }
}
EOF
  docker run -d -p 8443:8443 --name nginx-lb --restart always -v /etc/nginx/nginx-lb.conf:/etc/nginx/nginx.conf nginx

  #其它master配置
  OTHER_PRIORITY=$[$PRIORITY+1]
  for item in ${CLUSTER_IPS_ARR[@]}; do
    #排除本机
    if [ "$MASTER_ADDRESS" != "${item}" ] ; then
      ssh root@"${item}" "yum install -y keepalived && systemctl enable keepalived && systemctl restart keepalived && mv /etc/keepalived/keepalived.conf /etc/keepalived/keepalived.conf.bak && mkdir -p /etc/nginx"
      scp /etc/keepalived/check_apiserver.sh root@"${item}":/etc/keepalived/check_apiserver.sh
      scp /etc/keepalived/keepalived.conf root@"${item}":/etc/keepalived/keepalived.conf
      scp /etc/nginx/nginx-lb.conf root@"${item}":/etc/nginx/nginx-lb.conf
      ssh root@"${item}" "chmod a+x /etc/keepalived/check_apiserver.sh \
      && OTHER_INTERFACE_NAME=\$(ip a | grep -B2 \"inet ${item}/\" | awk -F ': ' '/^[0-9]/{print \$2}') \
      && sed -i 's/state MASTER/state BACKUP/g' /etc/keepalived/keepalived.conf \
      && sed -i 's/'${MASTER_ADDRESS}'/'${item}'/g' /etc/keepalived/keepalived.conf \
      && sed -i 's/priority ${PRIORITY}/priority ${OTHER_PRIORITY}/g' /etc/keepalived/keepalived.conf \
      && sed -i 's/interface ${INTERFACE_NAME}/interface '\${OTHER_INTERFACE_NAME}'/g' /etc/keepalived/keepalived.conf \
      && systemctl restart keepalived \
      && docker run -d -p 8443:8443 --name nginx-lb --restart always -v /etc/nginx/nginx-lb.conf:/etc/nginx/nginx.conf nginx"
      ((OTHER_PRIORITY++))
    fi
  done

  #systemctl restart keepalived

  #设置kube-proxy
  kubectl get -n kube-system configmap/kube-proxy -o yaml > /tmp/kube-proxy-configmap.yaml
  sed -i 's/'${MASTER_ADDRESS}:6443'/'${CLUSTER_VIP}:8443'/g' /tmp/kube-proxy-configmap.yaml
  kubectl replace -f /tmp/kube-proxy-configmap.yaml
  rm -f /tmp/kube-proxy-configmap.yaml
  #设置cluster-info
  kubectl get -n kube-public configmap/cluster-info -o yaml > /tmp/cluster-info-configmap.yaml
  sed -i 's/'${MASTER_ADDRESS}:6443'/'${CLUSTER_VIP}:8443'/g' /tmp/cluster-info-configmap.yaml
  kubectl replace -f /tmp/cluster-info-configmap.yaml
  rm -f /tmp/cluster-info-configmap.yaml
  #重启容器
  kubectl delete po $(kubectl get pods --all-namespaces -o wide | grep -E 'kube-proxy|kubernetes-dashboard' | awk '{print $2}') -n kube-system
  systemctl restart docker kubelet keepalived
}

set_all_master_to_unschedulable () {
  for item in ${CLUSTER_HOSTNAMES_ARR[@]}; do
      kubectl patch node ${item} -p '{"spec":{"unschedulable":true}}'
  done
  echo 'All master server is unschedulable.'
}


#仅需在第一台master安装的模块
if [ "$MASTER_ADDRESS" = "${CLUSTER_IPS_ARR[0]}" ] ; then
  echo '============================================================'
  echo '====Generate ssh-key and copy to other server ?(yes/no)====='
  echo '============================================================'
  while :; do echo
    read -p 'Input "yes" or "no" to continue: ' answer
    case "$answer" in
      "yes" )
        copy_sshkey_to_other_server
        break
        ;;
      "no" )
        #echo "bye!"
        break
        ;;
      * )
        echo 'Input error! Please only input "yes" or "no"...'
        ;;
    esac
  done

  echo '============================================================'
  echo '==============Install etcd to other server ?(yes/no)========'
  echo '============================================================'
  while :; do echo
    read -p 'Input "yes" or "no" to continue: ' answer
    case "$answer" in
      "yes" )
        install_etct_to_other_server
        break
        ;;
      "no" )
        #echo "bye!"
        break
        ;;
      * )
        echo 'Input error! Please only input "yes" or "no"...'
        ;;
    esac
  done

  echo '============================================================'
  echo '==============Start kubeadm init ?(yes/no)=================='
  echo '============================================================'
  while :; do echo
    read -p 'Input "yes" or "no" to continue: ' answer
    case "$answer" in
      "yes" )
        kubeadm_init
        create_flannel_service
        break
        ;;
      "no" )
        #echo "bye!"
        break
        ;;
      * )
        echo 'Input error! Please only input "yes" or "no"...'
        ;;
    esac
  done

  echo '============================================================'
  echo '==============Install dashboard ?(yes/no)==================='
  echo '============================================================'
  while :; do echo
    read -p 'Input "yes" or "no" to continue: ' answer
    case "$answer" in
      "yes" )
        install_heapster
        install_dashboard
        break
        ;;
      "no" )
        #echo "bye!"
        break
        ;;
      * )
        echo 'Input error! Please only input "yes" or "no"...'
        ;;
    esac
  done

  echo '============================================================'
  echo '==============Config the other server ?(yes/no)============='
  echo '============================================================'
  while :; do echo
    read -p 'Input "yes" or "no" to continue: ' answer
    case "$answer" in
      "yes" )
        config_the_other_server
        break
        ;;
      "no" )
        #echo "bye!"
        break
        ;;
      * )
        echo 'Input error! Please only input "yes" or "no"...'
        ;;
    esac
  done

  echo '============================================================'
  echo '==========Install keepalived and nginx-lb ?(yes/no)========='
  echo '============================================================'
  while :; do echo
    read -p 'Input "yes" or "no" to continue: ' answer
    case "$answer" in
      "yes" )
        install_keepalived_nginxlb
        break
        ;;
      "no" )
        #echo "bye!"
        break
        ;;
      * )
        echo 'Input error! Please only input "yes" or "no"...'
        ;;
    esac
  done

  echo '============================================================'
  echo '======Set all master server to unschedulable ?(yes/no)======'
  echo '============================================================'
  while :; do echo
    read -p 'Input "yes" or "no" to continue: ' answer
    case "$answer" in
      "yes" )
        set_all_master_to_unschedulable
        break
        ;;
      "no" )
        #echo "bye!"
        break
        ;;
      * )
        echo 'Input error! Please only input "yes" or "no"...'
        ;;
    esac
  done

  kubectl get pods --all-namespaces -o wide
  echo 'All Done!'
fi