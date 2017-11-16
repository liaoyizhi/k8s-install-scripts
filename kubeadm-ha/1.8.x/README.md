# 1 环境

3~6台centos 7虚机

| 虚机名称        | IP            |
| ------------- |:-------------:|
| k8s-master1   | 192.168.2.201|
| k8s-master2   | 192.168.2.202|
| k8s-master3   | 192.168.2.203|
| k8s-node1     | 192.168.2.204|
| k8s-node2     | 192.168.2.205|
| k8s-node3     | 192.168.2.206|



master.sh和node.sh脚本采用kubeadm进行安装，采用阿里镜像，安装简单快速。

# 2 master节点安装
```bash
#sh master.sh 本机IP 虚拟IP MASTER服务器主机名列表（必须包含本机，以逗号隔开） MASTER服务器IP列表（以逗号隔开，必须与主机名列表对应）
sh master.sh 192.168.2.201 192.168.2.200 k8s-master1,k8s-master2,k8s-master3 192.168.2.201,192.168.2.202,192.168.2.203
```

# 3 node节点安装
```bash
#sh node.sh 虚拟IP
sh node.sh 192.168.2.200
```
