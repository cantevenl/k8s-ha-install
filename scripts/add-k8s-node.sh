#!/usr/bin/env bash

# Copyright 2021 hybfkuf
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

function 0_add_k8s_node_script_prepare {
    # 检测是否为 root 用户，否则退出脚本
    # 检测是否为支持的 Linux 版本，否则退出脚本
    [[ $(uname) != "Linux" ]] && ERR "not support !" && exit $EXIT_FAILURE
    [[ $(id -u) -ne 0 ]] && ERR "not root !" && exit $EXIT_FAILURE
    source /etc/os-release
    K8S_NODE_OS=${ID}
    case $ID in 
    rocky | centos)  INSTALL_MANAGER="yum" ;;
    debian | ubuntu) INSTALL_MANAGER="yum" ;;
    *) ERR "not support linux: ${ID}" && EXIT $EXIT_FAILURE
    esac

    # 检查网络是否可用，否则退出脚本
    # 检查新增节点是否可达，否则退出脚本
    if ! timeout 2 ping -c 2 -i 1 114.114.114.114 &> /dev/null; then ERR "no network" && exit $EXIT_FAILURE; fi
    for NODE in "${ADD_WORKER[@]}"; do
        if ! timeout 2 ping -c 1 -i 1 ${NODE}; then
            ERR "worker node ${NODE} can't access"
            exit $EXIT_FAILURE; fi; done
}


# 当前运行的 master 节点对新的 worker 节点的 ssh 免密登录
function 1_configure_ssh_public_key_authentication {
    MSG1 "1. configure ssh public key authentication"

    # 生成新的 hosts 文件
    for HOST in "${!ADD_WORKER[@]}"; do
        local IP=${ADD_WORKER[$HOST]}
        sed -r -i "/(.*)${IP}(.*)${HOST}(.*)/d" /etc/hosts
        echo "${IP} ${HOST}" >> /etc/hosts; done

    # ssh 免密钥登录
    for NODE in "${!ADD_WORKER[@]}"; do
        local IP=${ADD_WORKER[$NODE]}
        ssh-keyscan "${NODE}" >> /root/.ssh/known_hosts
        ssh-keyscan "${IP}" >> /root/.ssh/known_hosts; done
    for NODE in "${!ADD_WORKER[@]}"; do
        sshpass -p "${K8S_ROOT_PASS}" ssh-copy-id -f -i /root/.ssh/id_rsa.pub root@"${NODE}" > /dev/null
        sshpass -p "${K8S_ROOT_PASS}" ssh-copy-id -f -i /root/.ssh/id_ecdsa.pub root@"${NODE}" > /dev/null
        sshpass -p "${K8S_ROOT_PASS}" ssh-copy-id -f -i /root/.ssh/id_ed25519.pub root@"${NODE}" > /dev/null; done
}


# 设置新节点的主机名
function 2_copy_hosts_file_to_all_k8s_node {
    MSG1 "2. copy hosts file to all k8s node"

    # 设置新添加的 worker 节点主机名
    for NODE in "${!ADD_WORKER[@]}"; do
        echo ${NODE}
        ssh ${NODE} "hostnamectl set-hostname ${NODE}"; done

    # 将新的 hosts 文件复制到所有 k8s 节点上
    for NODE in "${ALL_NODE[@]}"; do
        echo ${NODE}
        scp /etc/hosts ${NODE}:/etc/hosts; done

    # 将新的 hosts 文件复制到所有新添加的 worker 节点上
    for NODE in "${!ADD_WORKER[@]}"; do
        echo ${NODE}
        scp /etc/hosts ${NODE}:/etc/hosts; done
}


# 检查节点是否已经存在集群中，如果存在集群中，则去除该节点
function 3_deduplicate_add_worker {
    MSG1 "3. deduplicate add worker"
    ADD_WORKER_HOST=( ${!ADD_WORKER[@]} )
    ADD_WORKER_IP=( ${ADD_WORKER[@]} )
    echo "${ADD_WORKER_HOST[@]}"
    echo "${ADD_WORKER_IP[@]}"
    echo 
    for NODE in "${!ADD_WORKER[@]}"; do
        IP=${ADD_WORKER[$NODE]}
        if kubectl get node ${NODE} &> /dev/null; then
            ADD_WORKER_HOST=( ${ADD_WORKER_HOST[@]/${NODE}} )
            ADD_WORKER_IP=( ${ADD_WORKER_IP[@]/${IP}} )
        fi
    done
    echo "${ADD_WORKER_HOST[@]}"
    echo "${ADD_WORKER_IP[@]}"
    echo
    unset ADD_WORKER
    ADD_WORKER=( ${ADD_WORKER_HOST[@]} )
    echo "${ADD_WORKER[@]}"
    echo "${ADD_WORKER_IP[@]}"
    echo
    if [[ -z ${ADD_WORKER_HOST} ]]; then
        echo "Nothing need to do !!!"
        exit 0
    fi
    if [[ -z ${ADD_WORKER_IP} ]]; then
        echo "Nothing need to do !!!"
        exit 0
    fi
}


# stage one
function 4_run_stage_one {
    MSG1 "4. run stage one"

    source /etc/os-release
    mkdir -p "${K8S_DEPLOY_LOG_PATH}/logs_add-worker/stage-one"
    case ${ID} in
    centos|rhel)
        # Linux: centos/rhel
        source centos/1_prepare_for_server.sh
        for NODE in "${ADD_WORKER[@]}"; do
            MSG2 "*** ${NODE} *** is Preparing for Linux Server"
            ssh root@${NODE} \
                "export TIMEZONE=${TIMEZONE}
                 $(typeset -f 1_import_repo)
                 $(typeset -f 2_install_necessary_package)
                 $(typeset -f 3_upgrade_system)
                 $(typeset -f 4_disable_firewald_and_selinux)
                 $(typeset -f 5_set_timezone_and_ntp_client)
                 $(typeset -f 6_configure_sshd)
                 $(typeset -f 7_configure_ulimit)
                 1_import_repo
                 2_install_necessary_package
                 3_upgrade_system
                 4_disable_firewald_and_selinux
                 5_set_timezone_and_ntp_client
                 6_configure_sshd
                 7_configure_ulimit" \
                 &> ${K8S_DEPLOY_LOG_PATH}/logs_add-worker/stage-one/${NODE}.log &
        done
        MSG2 "Please Waiting... (multitail -s 2 -f ${K8S_DEPLOY_LOG_PATH}/logs_add-worker/stage-one/*.log)"
        wait
        ;;
    rocky)
        # Linux: rocky
        source rocky/1_prepare_for_server.sh
        for NODE in "${ADD_WORKER[@]}"; do
            MSG2 "*** ${NODE} *** is Preparing for Linux Server"
            ssh root@${NODE} \
                "export TIMEZONE=${TIMEZONE}
                 $(typeset -f 1_import_repo)
                 $(typeset -f 2_install_necessary_package)
                 $(typeset -f 3_upgrade_system)
                 $(typeset -f 4_disable_firewald_and_selinux)
                 $(typeset -f 5_set_timezone_and_ntp_client)
                 $(typeset -f 6_configure_sshd)
                 $(typeset -f 7_configure_ulimit)
                 1_import_repo
                 2_install_necessary_package
                 3_upgrade_system
                 4_disable_firewald_and_selinux
                 5_set_timezone_and_ntp_client
                 6_configure_sshd
                 7_configure_ulimit" \
                 &> ${K8S_DEPLOY_LOG_PATH}/logs_add-worker/stage-one/${NODE}.log &
        done
        MSG2 "Please Waiting... (multitail -s 2 -f ${K8S_DEPLOY_LOG_PATH}/logs_add-worker/stage-one/*.log)"
        wait
        ;;
    ubuntu)
        # Linux: ubuntu
        source ubuntu/1_prepare_for_server.sh
        for NODE in "${ADD_WORKER[@]}"; do
            MSG2 "*** ${NODE} *** is Preparing for Linux Server"
            ssh root@${NODE} \
                "export TIMEZONE=${TIMEZONE}
                 $(typeset -f _apt_wait)
                 $(typeset -f 1_upgrade_system)
                 $(typeset -f 2_install_necessary_package)
                 $(typeset -f 3_disable_firewald_and_selinux)
                 $(typeset -f 4_set_timezone_and_ntp_client)
                 $(typeset -f 5_configure_sshd)
                 $(typeset -f 6_configure_ulimit)
                 _apt_wait
                 1_upgrade_system
                 2_install_necessary_package
                 3_disable_firewald_and_selinux
                 4_set_timezone_and_ntp_client
                 5_configure_sshd
                 6_configure_ulimit" \
                 &> ${K8S_DEPLOY_LOG_PATH}/logs_add-worker/stage-one/${NODE}.log &
        done
        MSG2 "Please Waiting... (multitail -s 2 -f ${K8S_DEPLOY_LOG_PATH}/logs_add-worker/stage-one/*.log)"
        wait
        ;;
    debian)
        # Linux: debian
        source debian/1_prepare_for_server.sh
        for NODE in "${ADD_WORKER[@]}"; do
            MSG2 "*** ${NODE} *** is Preparing for Linux Server"
            ssh root@${NODE} \
                "export TIMEZONE=${TIMEZONE}
                 $(typeset -f _apt_wait)
                 $(typeset -f 1_upgrade_system)
                 $(typeset -f 2_install_necessary_package)
                 $(typeset -f 3_disable_firewald_and_selinux)
                 $(typeset -f 4_set_timezone_and_ntp_client)
                 $(typeset -f 5_configure_sshd)
                 $(typeset -f 6_configure_ulimit)
                 _apt_wait
                 1_upgrade_system
                 2_install_necessary_package
                 3_disable_firewald_and_selinux
                 4_set_timezone_and_ntp_client
                 5_configure_sshd
                 6_configure_ulimit" \
                 &> ${K8S_DEPLOY_LOG_PATH}/logs_add-worker/stage-one/${NODE}.log &
        done
        MSG2 "Please Waiting... (multitail -s 2 -f ${K8S_DEPLOY_LOG_PATH}/logs_add-worker/stage-one/*.log)"
        wait
        ;;
    *)
        ERR "Not Support Linux !" && exit $EXIT_FAILURE ;;
    esac
}


# stage two
function 5_run_stage_two {
    MSG1 "5. run stage two"

    source /etc/os-release
    mkdir -p "${K8S_DEPLOY_LOG_PATH}/logs_add-worker/stage-two"
    case ${ID} in
    centos|rhel)
        # Linux centos/rhel
        source centos/2_prepare_for_k8s.sh
        for NODE in "${ADD_WORKER[@]}"; do
            MSG2 "*** ${NODE} *** is Preparing for Kubernetes"
            ssh root@${NODE} \
                "$(typeset -f 1_install_necessary_package_for_k8s)
                 $(typeset -f 2_disable_swap)
                 $(typeset -f 3_upgrade_kernel)
                 $(typeset -f 4_load_kernel_module)
                 $(typeset -f 5_configure_kernel_parameter)
                 1_install_necessary_package_for_k8s
                 2_disable_swap
                 3_upgrade_kernel
                 4_load_kernel_module
                 5_configure_kernel_parameter" \
                 &> ${K8S_DEPLOY_LOG_PATH}/logs_add-worker/stage-two/${NODE}.log &
        done
        MSG2 "Please Waiting... (multitail -s 2 -f ${K8S_DEPLOY_LOG_PATH}/logs_add-worker/stage-two/*.log)"
        wait
        ;;
    rocky)
        # Linux: rocky
        source rocky/2_prepare_for_k8s.sh
        for NODE in "${ADD_WORKER[@]}"; do
            MSG2 "*** ${NODE} *** is Preparing for Linux Server"
            MSG2 "*** ${NODE} *** is Preparing for Kubernetes"
            ssh root@${NODE} \
                "$(typeset -f 1_install_necessary_package_for_k8s)
                 $(typeset -f 2_disable_swap)
                 $(typeset -f 3_upgrade_kernel)
                 $(typeset -f 4_load_kernel_module)
                 $(typeset -f 5_configure_kernel_parameter)
                 1_install_necessary_package_for_k8s
                 2_disable_swap
                 4_load_kernel_module
                 5_configure_kernel_parameter" \
                 &> ${K8S_DEPLOY_LOG_PATH}/logs_add-worker/stage-two/${NODE}.log &
        done
        MSG2 "Please Waiting... (multitail -s 2 -f ${K8S_DEPLOY_LOG_PATH}/logs_add-worker/stage-two/*.log)"
        wait
        ;;
    ubuntu)
        # Linux: ubuntu
        source ubuntu/2_prepare_for_k8s.sh
        for NODE in "${ADD_WORKER[@]}"; do
            MSG2 "*** ${NODE} *** is Preparing for Kubernetes"
            ssh root@${NODE} \
                "$(typeset -f _apt_wait)
                 $(typeset -f 1_disable_swap)
                 $(typeset -f 2_load_kernel_module)
                 $(typeset -f 3_configure_kernel_parameter)
                 _apt_wait
                 1_disable_swap
                 2_load_kernel_module
                 3_configure_kernel_parameter" \
                 &> ${K8S_DEPLOY_LOG_PATH}/logs_add-worker/stage-two/${NODE}.log &
        done
        MSG2 "Please Waiting... (multitail -s 2 -f ${K8S_DEPLOY_LOG_PATH}/logs_add-worker/stage-two/*.log)"
        wait
        ;;
    debian)
        # Linux: debian
        source debian/2_prepare_for_k8s.sh
        for NODE in "${ADD_WORKER[@]}"; do
            MSG2 "*** ${NODE} *** is Preparing for Kubernetes"
            ssh root@${NODE} \
                "$(typeset -f _apt_wait)
                 $(typeset -f 1_disable_swap)
                 $(typeset -f 2_load_kernel_module)
                 $(typeset -f 3_configure_kernel_parameter)
                 _apt_wait
                 1_disable_swap
                 2_load_kernel_module
                 3_configure_kernel_parameter" \
                 &> ${K8S_DEPLOY_LOG_PATH}/logs_add-worker/stage-two/${NODE}.log &
        done
        MSG2 "Please Waiting... (multitail -s 2 -f ${K8S_DEPLOY_LOG_PATH}/logs_add-worker/stage-two/*.log)"
        wait
        ;;
    *)
        ERR "Not Support Linux !" && exit $EXIT_FAILURE ;;
    esac
}


# stage three
function 6_run_stage_three {
    MSG1 "6. run stage three"

    source /etc/os-release
    mkdir -p "${K8S_DEPLOY_LOG_PATH}/logs_add-worker/stage-three"
    case ${ID} in
    centos|rhel)
        # Linux: centos/rhel
        source centos/3_install_docker.sh
        for NODE in "${ADD_WORKER[@]}"; do
            MSG2 "*** ${NODE} *** is Installing Docker"
            ssh root@${NODE} \
                "export TIMEZONE=${TIMEZONE}
                 $(typeset -f 1_install_docker)
                 $(typeset -f 2_configure_docker)
                 1_install_docker
                 2_configure_docker" \
                 &> ${K8S_DEPLOY_LOG_PATH}/logs_add-worker/stage-three/${NODE}.log &
        done
        MSG2 "Please Waiting... (multitail -s 2 -f ${K8S_DEPLOY_LOG_PATH}/logs_add-worker/stage-three/*.log)"
        wait
        ;;
    rocky)
        # Linux: rocky
        source rocky/3_install_docker.sh
        for NODE in "${ADD_WORKER[@]}"; do
            MSG2 "*** ${NODE} *** is Installing Docker"
            ssh root@${NODE} \
                "export TIMEZONE=${TIMEZONE}
                 $(typeset -f 1_install_docker)
                 $(typeset -f 2_configure_docker)
                 1_install_docker
                 2_configure_docker" \
                 &> ${K8S_DEPLOY_LOG_PATH}/logs_add-worker/stage-three/${NODE}.log &
        done
        MSG2 "Please Waiting... (multitail -s 2 -f ${K8S_DEPLOY_LOG_PATH}/logs_add-worker/stage-three/*.log)"
        wait
        ;;
    ubuntu)
        # Linux: ubuntu
        source ubuntu/3_install_docker.sh
        for NODE in "${ADD_WORKER[@]}"; do
            MSG2 "*** ${NODE} *** is Installing Docker"
            ssh root@${NODE} \
                "export TIMEZONE=${TIMEZONE}
                 $(typeset -f _apt_wait)
                 $(typeset -f 1_install_docker)
                 $(typeset -f 2_configure_docker)
                 $(typeset -f 3_audit_for_docker)
                 _apt_wait
                 1_install_docker
                 2_configure_docker
                 3_audit_for_docker" \
                 &> ${K8S_DEPLOY_LOG_PATH}/logs_add-worker/stage-three/${NODE}.log &
        done
        MSG2 "Please Waiting... (multitail -s 2 -f ${K8S_DEPLOY_LOG_PATH}/logs_add-worker/stage-three/*.log)"
        wait
        ;;
    debian)
        # Linux: debian
        source debian/3_install_docker.sh
        for NODE in "${ADD_WORKER[@]}"; do
            MSG2 "*** ${NODE} *** is Installing Docker"
            ssh root@${NODE} \
                "export TIMEZONE=${TIMEZONE}
                 $(typeset -f _apt_wait)
                 $(typeset -f 1_install_docker)
                 $(typeset -f 2_configure_docker)
                 $(typeset -f 3_audit_for_docker)
                 _apt_wait
                 1_install_docker
                 2_configure_docker
                 3_audit_for_docker" \
                 &> ${K8S_DEPLOY_LOG_PATH}/logs_add-worker/stage-three/${NODE}.log &
        done
        MSG2 "Please Waiting... (multitail -s 2 -f ${K8S_DEPLOY_LOG_PATH}/logs_add-worker/stage-three/*.log)"
        wait
        ;;
    *)
        ERR "Not Support Linux !" && exit $EXIT_FAILURE ;;
    esac
}


# 复制二进制文件 kubelet kube-proxy kubectl
function 7_copy_bnary_file_to_new_worker_node {
    MSG1 "7. copy binary file to new worker node"

    # 1. 解压二进制文件
    mkdir -p ${K8S_DEPLOY_LOG_PATH}/bin
    tar -xvf bin/${K8S_VERSION}/kube-proxy.tar.xz   -C ${K8S_DEPLOY_LOG_PATH}/bin/
    tar -xvf bin/${K8S_VERSION}/kubelet.tar.xz      -C ${K8S_DEPLOY_LOG_PATH}/bin/
    tar -xvf bin/${K8S_VERSION}/kubectl.tar.xz      -C ${K8S_DEPLOY_LOG_PATH}/bin/

    # 2. 将 k8s 二进制文件拷贝到新添加的 worker 节点上
    for NODE in "${ADD_WORKER[@]}"; do
        for PKG in \
            ${K8S_DEPLOY_LOG_PATH}/bin/kube-proxy \
            ${K8S_DEPLOY_LOG_PATH}/bin/kubelet \
            ${K8S_DEPLOY_LOG_PATH}/bin/kubectl; do
            scp ${PKG} ${NODE}:/usr/local/bin/
        done
    done
}


# 从第一个 worker 节点上把相关的：
#   1、k8s 证书文件
#   2、kubelet 和 kube-proxy 自启动文件
#   3、kublet 和 kube-proxy 配置文件
# 拷贝到新的 worker 节点上
function 8_copy_certs_config_binary_to_new_worker_node {
    MSG1 "8. copy certs config and binary to new worker node"
    
    local WORKER_IP
    local ADD_NODE_PATH="${K8S_DEPLOY_LOG_PATH}/add-worker"
    mkdir -p ${ADD_NODE_PATH}

    # 获取任何一个 worker 节点的 ip 地址
    WORKER_HOST=$(kubectl get node -o wide -l '!node-role.kubernetes.io/master' | grep -i Ready | sed -n '1,1p' | awk '{print $1}')
    WORKER_IP=$(kubectl get node -o wide -l '!node-role.kubernetes.io/master' | grep -i Ready | sed -n '1,1p' | awk '{print $6}')
    MSG2 "copy from ${WORKER_HOST}(${WORKER_IP})"

    # 将 worker 节点的 k8s 证书和配置文件先拷贝到当前主机上
    # master 节点还需要拷贝 /etc/etcd/ 目录
    scp -r root@${WORKER_IP}:/etc/kubernetes/                       ${ADD_NODE_PATH}
    scp -r root@${WORKER_IP}:/etc/systemd/system/kubelet.service.d/ ${ADD_NODE_PATH}
    scp root@${WORKER_IP}:/lib/systemd/system/kubelet.service       ${ADD_NODE_PATH}
    scp root@${WORKER_IP}:/lib/systemd/system/kube-proxy.service    ${ADD_NODE_PATH}
    # 将 worker 节点的二进制文件拷贝到当前主机上
    scp -r root@${WORKER_IP}:/usr/local/bin/kubelet                 ${ADD_NODE_PATH}
    scp -r root@${WORKER_IP}:/usr/local/bin/kube-proxy              ${ADD_NODE_PATH}

    for NODE in "${ADD_WORKER[@]}"; do
        # 将复制过来的 k8s 证书和配置文件拷贝到新添加的 worker 节点上
        scp -r ${ADD_NODE_PATH}/kubernetes          root@${NODE}:/etc/
        scp -r ${ADD_NODE_PATH}/kubelet.service.d   root@${NODE}:/etc/systemd/system/
        scp ${ADD_NODE_PATH}/kubelet.service        root@${NODE}:/lib/systemd/system/
        scp ${ADD_NODE_PATH}/kube-proxy.service     root@${NODE}:/lib/systemd/system/
        # 将复制过来的 kubectl kube-proxy 二进制文件拷贝到新添加的 worker 节点上
        scp ${ADD_NODE_PATH}/kubelet                root@${NODE}:/usr/local/bin/
        scp ${ADD_NODE_PATH}/kube-proxy             root@${NODE}:/usr/local/bin/
        # 给 kubectl kube-proxy 添加可执行权限
        ssh root@${NODE} "chmod u+x /usr/local/bin/kubelet /usr/local/bin/kube-proxy"

        #ssh root@${NODE} "mkdir -p /etc/cni/bin /var/lib/kubelet /var/log/kubernetes"
        # 为新添加的 worker 节点创建所需目录
        #for DIR_PATH in \
            #"/var/lib/kubelet" \
            #"/var/lib/kube-proxy" \
            #"/var/log/kubernetes"; do
            #ssh ${NODE} "mkdir -p ${DIR_PATH}"
    done
}


# enabled kublet, kube-proxy service
function 9_enable_kube_service {
    MSG1 "9. Enbled kubelet kube-proxy service"

    for NODE in "${ADD_WORKER[@]}"; do
        ssh root@${NODE} "
            systemctl enable docker kubelet kube-proxy
            systemctl restart docker kubelet kube-proxy"
    done
}


function add_k8s_node {
    MSG1 "Adding k8s worker node ..."
    0_add_k8s_node_script_prepare
    1_configure_ssh_public_key_authentication
    2_copy_hosts_file_to_all_k8s_node
    3_deduplicate_add_worker
    4_run_stage_one
    5_run_stage_two
    6_run_stage_three
    #7_copy_bnary_file_to_new_worker_node
    8_copy_certs_config_binary_to_new_worker_node
    9_enable_kube_service
    exit ${EXIT_SUCCES}
}
