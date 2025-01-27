#!/usr/bin/env bash

EXIT_SUCCESS=0
EXIT_FAILURE=1
ERR(){ echo -e "\033[31m\033[01m$1\033[0m"; }
MSG1(){ echo -e "\n\n\033[32m\033[01m$1\033[0m\n"; }
MSG2(){ echo -e "\n\033[33m\033[01m$1\033[0m"; }


declare -A CEPH_MON CEPH_MGR CEPH_OSD CEPH_MDS
CEPH_MON=(
    [ceph-node1]=10.250.19.11
    [ceph-node2]=10.250.19.12
    [ceph-node3]=10.250.19.13)
CEPH_MGR=(
    [ceph-node1]=10.250.19.11
    [ceph-node2]=10.250.19.12
    [ceph-node3]=10.250.19.13)
CEPH_OSD=( 
    [ceph-node1]=10.250.19.11
    [ceph-node2]=10.250.19.12
    [ceph-node3]=10.250.19.13
    [ceph-node4]=10.250.19.14
    [ceph-node5]=10.250.19.15)
CEPH_MDS=(
    [ceph-node1]=10.250.19.11
    [ceph-node2]=10.250.19.12
    [ceph-node3]=10.250.19.13)
CEPH_NODE=( ${!CEPH_MON[@]} ${!CEPH_MGR[@]} ${!CEPH_OSD[@]} ${!CEPH_MDS[@]} )
CEPH_NODE=($(tr ' ' '\n' <<< "${CEPH_NODE[@]}" | sort -u | tr '\n' ' '))    # shell array deduplicate
echo ${CEPH_NODE[@]}

CURRENT_NODE_IP="10.250.19.11"
CEPH_ROOT_PASS="toor"
CEPH_CLUSTER_NETWORK="10.250.0.0/16"
CEPH_PUBLIC_NETWORK="10.250.0.0/16"
CEPH_OSD_DISK="/dev/sdb"
CEPH_DASHBOARD_PASS="admin"

CEPH_DEPLOY_LOG="/root/ceph-deploy-log"
mkdir -p "${CEPH_DEPLOY_LOG}"


function _apt_wait() {
    while true; do
        if lsof /var/lib/dpkg/lock &> /dev/null; then
            sleep 1
            continue; fi
        if lsof /var/lib/dpkg/lock-frontend &> /dev/null; then
            sleep 1
            continue; fi
        if lsof /var/lib/apt/lists/lock &> /dev/null; then
            sleep 1
            continue; fi
        if lsof /var/lib/apt/daily_lock &> /dev/null; then
            sleep 1
            continue; fi
        if lsof /var/log/unattended-upgrades/unattended-upgrades.log &> /dev/null; then
            sleep 1
            continue; fi
        #echo "lock released"
        break
    done
}


function 1_configure_ssh_authentication {
    MSG1 "1. Configure SSH Authentication"

    # 生成 /etc/hosts 文件
    for HOST in "${!CEPH_MON[@]}"; do
        local IP=${CEPH_MON[$HOST]}
        sed -r -i "/(.*)${HOST}(.*)/d" /etc/hosts
        echo "${IP} ${HOST}" >> /etc/hosts
    done
    for HOST in "${!CEPH_OSD[@]}"; do
        local IP=${CEPH_OSD[$HOST]}
        sed -r -i "/(.*)${HOST}(.*)/d" /etc/hosts
        echo "${IP} ${HOST}" >> /etc/hosts
    done

    # 1.安装 sshpass 软件包
    # 2.生成 ssh 密钥对
    if ! command -v sshpass; then _apt_wait && apt-get update -y; _apt_wait && apt-get install -y sshpass; fi
    if ! command -v multitail; then _apt_wait && apt-get update -y; _apt_wait && apt-get install -y multitail; fi
    if [[ ! -d "/root/.ssh" ]]; then rm -rf /root/.ssh; mkdir /root/.ssh; chmod 0700 /root/.ssh; fi
    if [[ ! -s "/root/.ssh/id_rsa" ]]; then ssh-keygen -t rsa -N '' -f /root/.ssh/id_rsa; fi 
    if [[ ! -s "/root/.ssh/id_ecdsa" ]]; then ssh-keygen -t ecdsa -N '' -f /root/.ssh/id_ecdsa; fi
    if [[ ! -s "/root/.ssh/id_ed25519" ]]; then ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519; fi
    #if [[ ! -s "/root/.ssh/id_xmss" ]]; then ssh-keyscan -t xmss -N '' -f /root/.ssh/id_xmss; fi

    # 1.收集所有 ceph 节点的主机指纹
    # 2.将本机的 SSH 公钥拷贝到所有的 ceph 节点上
    # 3.将本机的 /etc/hosts 拷贝到其它 ceph 节点上
    # 4.设置所有节点的主机名
    for HOST in "${CEPH_NODE[@]}"; do
        ssh-keyscan "${HOST}" >> /root/.ssh/known_hosts
        sshpass -p "${CEPH_ROOT_PASS}" ssh-copy-id -f -i /root/.ssh/id_rsa.pub root@"${HOST}" > /dev/null
        sshpass -p "${CEPH_ROOT_PASS}" ssh-copy-id -f -i /root/.ssh/id_ecdsa.pub root@"${HOST}" > /dev/null
        sshpass -p "${CEPH_ROOT_PASS}" ssh-copy-id -f -i /root/.ssh/id_ed25519.pub root@"${HOST}" > /dev/null
        #sshpass -p "${CEPH_ROOT_PASS}" ssh-copy-id -f -i /root/.ssh/id_xmss.pub root@"${HOST}" > /dev/null
        ssh root@${HOST} "hostnamectl set-hostname ${HOST}"
        scp /etc/hosts root@${HOST}:/etc/
    done
}



function 2_all_ceph_upgrade {
    MSG1 "2. Ceph Node Upgrade"

    mkdir -p ${CEPH_DEPLOY_LOG}/2_ceph_node_upgrade
    for HOST in "${CEPH_NODE[@]}"; do
        ssh root@${HOST} "
            $(typeset -f _apt_wait)
            export DEBIAN_FRONTEND=noninteractive
            _apt_wait && apt-get update -y
            _apt_wait && apt-get -o Dpkg::Options::=\"--force-confold\" upgrade -q -y
            _apt_wait && apt-get -o Dpkg::Options::=\"--force-confold\" dist-upgrade -q -y
            _apt_wait && apt-get autoremove -y
            _apt_wait && apt-get autoclean -y
            _apt_wait && apt-get install -y apt-transport-https software-properties-common curl wget python3" &> ${CEPH_DEPLOY_LOG}/2_ceph_node_upgrade/${HOST}.log &
    done
    MSG2 "multitail ${CEPH_DEPLOY_LOG}/2_ceph_node_upgrade/*.log"
    wait
}



function 3_optimizate_system {
    MSG1 "3. Optimizate System"

    mkdir -p "${CEPH_DEPLOY_LOG}"/3_optimizate_system
    
    # configure ssh
    local SSH_CONF_PATH="/etc/ssh/sshd_config"
    sed -i "/^UseDNS/d" ${SSH_CONF_PATH}
    sed -i "/^GSSAPIAuthentication/d" ${SSH_CONF_PATH}
    sed -i "/^PermitRootLogin/d" ${SSH_CONF_PATH}
    sed -i "/^PasswordAuthentication/d" ${SSH_CONF_PATH}
    sed -i "/^PermitEmptyPasswords/d" ${SSH_CONF_PATH}
    sed -i "/^PubkeyAuthentication/d" ${SSH_CONF_PATH}
    sed -i "/^AuthorizedKeysFile/d" ${SSH_CONF_PATH}
    #sed -i "/^ClientAliveInterval/d" ${SSH_CONF_PATH}
    sed -i "/^ClientAliveCountMax/d" ${SSH_CONF_PATH}
    sed -i "/^Protocol/d" ${SSH_CONF_PATH}

    echo "UseDNS no" >> ${SSH_CONF_PATH}
    echo "GSSAPIAuthentication no" >> ${SSH_CONF_PATH}
    echo "PermitRootLogin yes" >> ${SSH_CONF_PATH}
    echo "PasswordAuthentication yes" >> ${SSH_CONF_PATH}
    echo "PermitEmptyPasswords no" >> ${SSH_CONF_PATH}
    echo "PubkeyAuthentication yes" >> ${SSH_CONF_PATH}
    echo "AuthorizedKeysFile .ssh/authorized_keys" >> ${SSH_CONF_PATH}
    #echo "ClientAliveInterval 360" >> ${SSH_CONF_PATH}
    echo "ClientAliveCountMax 0" >> ${SSH_CONF_PATH}
    echo "Protocol 2" >> ${SSH_CONF_PATH}

    # configure ulimits
    local ULIMITS_CONF_PATH="/etc/security/limits.conf"
    sed -i -r "/^\*(.*)soft(.*)nofile(.*)/d" ${ULIMITS_CONF_PATH}
    sed -i -r "/^\*(.*)hard(.*)nofile(.*)/d" ${ULIMITS_CONF_PATH}
    sed -i -r "/^\*(.*)soft(.*)nproc(.*)/d" ${ULIMITS_CONF_PATH}
    sed -i -r "/^\*(.*)hard(.*)nproc(.*)/d" ${ULIMITS_CONF_PATH}
    sed -i -r "/^\*(.*)soft(.*)memlock(.*)/d" ${ULIMITS_CONF_PATH}
    sed -i -r "/^\*(.*)hard(.*)memlock(.*)/d" ${ULIMITS_CONF_PATH}

    echo "* soft nofile 655360" >> ${ULIMITS_CONF_PATH}
    echo "* hard nofile 131072" >> ${ULIMITS_CONF_PATH}
    echo "* soft nproc 655360" >> ${ULIMITS_CONF_PATH}
    echo "* hard nproc 655360" >> ${ULIMITS_CONF_PATH}
    echo "* soft memlock unlimited" >> ${ULIMITS_CONF_PATH}
    echo "* hard memlock unlimited" >> ${ULIMITS_CONF_PATH}

    # copy /etc/ssh/sshd.conf, /etc/security/limits.conf to all ceph node
    for HOST in "${CEPH_NODE[@]}"; do
        scp ${SSH_CONF_PATH}     root@${HOST}:/etc/ssh/
        scp ${ULIMITS_CONF_PATH} root@${HOST}:/etc/security/
        ssh root@${HOST} "
            systemctl restart sshd
            timedatectl set-timezone Asia/Shanghai
            timedatectl set-ntp true
            systemctl restart cron
            systemctl restart rsyslog" &> ${CEPH_DEPLOY_LOG}/3_optimizate_system/${HOST}.log &
    done
    wait
}


function install_docker {
    apt-get remove -y docker docker-engine docker.io containerd runc
    apt-get update -y
    apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release software-properties-common

    docker_url="https://mirrors.ustc.edu.cn/docker-ce"
    #docker_url="https://mirrors.aliyun.com/docker-ce"
    #docker_url="https://download.docker.com"

    while true; do
        if curl -fsSL ${docker_url}/linux/ubuntu/gpg | sudo gpg --yes --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg; then
            break; fi
        sleep 1
    done
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] ${docker_url}/linux/ubuntu $(lsb_release -cs) stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -y
    # local docker_version="5:19.03.15~3-0~ubuntu-$(lsb_release -sc)"
    # apt-mark unhold docker-ce docker-ce-cli
    # apt-get install -y --allow-downgrades docker-ce=${docker_version} docker-ce-cli=${docker_version} containerd.io
    # apt-mark hold docker-ce docker-ce-cli
    apt-get install -y docker-ce docker-ce-cli containerd.io
    systemctl enable --now docker
}
function 4_install_docker {
    mkdir -p ${CEPH_DEPLOY_LOG}/4_install_docker
    MSG1 "4. Install docker"

    docker_url="https://mirrors.ustc.edu.cn/docker-ce"
    #docker_url="https://mirrors.aliyun.com/docker-ce"
    #docker_url="https://download.docker.com"
    while true; do
        if curl -fsSL ${docker_url}/linux/ubuntu/gpg | sudo gpg --yes --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg; then
            break; fi
        sleep 1
    done
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] ${docker_url}/linux/ubuntu $(lsb_release -cs) stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    for HOST in "${CEPH_NODE[@]}"; do
        scp /usr/share/keyrings/docker-archive-keyring.gpg root@${HOST}:/usr/share/keyrings/
        scp /etc/apt/sources.list.d/docker.list root@${HOST}:/etc/apt/sources.list.d/
    done

    for HOST in "${CEPH_NODE[@]}"; do
        ssh root@${HOST} "
            $(typeset -f _apt_wait)
            _apt_wait && apt-get remove -y docker docker-engine docker.io containerd runc
            _apt_wait && apt-get update -y
            _apt_wait && apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release software-properties-common
            _apt_wait && apt-get update -y
            _apt_wait && apt-get install -y docker-ce docker-ce-cli containerd.io
            systemctl enable --now docker" &> ${CEPH_DEPLOY_LOG}/4_install_docker/${HOST}.log &
    done
    MSG2 "multitail ${CEPH_DEPLOY_LOG}/4_install_docker/*.log"
    wait
}


function 5_install_cephadm {
    MSG1 "5. Install Cephadm"
    #curl --silent https://download.ceph.com/keys/release.asc | sudo apt-key add -
    #add-apt-repository -y https://download.ceph.com/debian-pacific
    #apt-get install -y cephadm
    mkdir -p "${CEPH_DEPLOY_LOG}"/5_install_cephadm
    for HOST in "${!CEPH_MON[@]}"; do
        # MSG2 "${HOST} install cephadm"
        ssh root@${HOST} "
            $(typeset -f _apt_wait)
            export DEBIAN_FRONTEND=noninteractive
            curl --silent https://download.ceph.com/keys/release.asc | sudo apt-key add -
            add-apt-repository -y https://download.ceph.com/debian-pacific
            _apt_wait && apt-get update -y
            _apt_wait && apt-get install -y cephadm" &> ${CEPH_DEPLOY_LOG}/5_install_cephadm/${HOST}.log &
    done
    MSG2 "multitail ${CEPH_DEPLOY_LOG}/5_install_cephadm/*.log"
    wait
}


function 6_deploy_ceph_cluster {
    MSG1 "6. Deploy Ceph Cluster"
    # cephadm bootstrap will:
    #     1. Create a monitor and manager daemon for the new cluster on the local host.
    #     2. Generate a new SSH key for the Ceph cluster and add it to the root user’s /root/.ssh/authorized_keys file.
    #     3. Write a copy of the public key to /etc/ceph/ceph.pub.
    #     4. Write a minimal configuration file to /etc/ceph/ceph.conf. This file is needed to communicate with the new cluster.
    #     5. Write a copy of the client.admin administrative (privileged!) secret key to /etc/ceph/ceph.client.admin.keyring.
    #     6. Add the _admin label to the bootstrap host. By default, any host with this label will (also) 
    #        get a copy of /etc/ceph/ceph.conf and /etc/ceph/ceph.client.admin.keyring.
    # cephadm bootstrap options
    #     --output-dir OUTPUT_DIR               directory to write config, keyring, and pub key files
    #     --output-config OUTPUT_CONFIG         location to write conf file to connect to new cluster
    #     --output-pub-ssh-key PUB_SSH_KEY      location to write the cluster's public SSH key
    #     --initial-dashboard-user USER         Initial user for the dashboard (default admin)
    #     --initial-dashboard-password PASSWD   Initial password for the initial dashboard user
    #     --ssl-dashboard-port PORT             Port number used to connect with dashboard using SSL
    #     --skip-dashboard                      do not enable the Ceph Dashboard
    #     --skip-mon-network                    set mon public_network based on bootstrap mon ip
    #     --dashboard-password-noupdate         stop forced dashboard password change
    #     --skip-pull                           do not pull the latest image before bootstrapping
    #     --skip-firewalld                      Do not configure firewalld
    #     --allow-overwrite                     allow overwrite of existing --output-* config/keyring/ssh files
    #     --registry-url REGISTRY_URL           url for custom registry
    #     --registry-username USERNAME          username for custom registry
    #     --registry-password PASSWORD          password for custom registry
    #     --registry-json REGISTRY_JSON         json file with custom registry login info (URL, Username, Password)
    #     --cluster-network CLUSTER_NETWORK     subnet to use for cluster replication, recovery and heartbeats (in CIDR notation network/mask)
    #     --single-host-defaults                adjust configuration defaults to suit a single-host cluster
    MSG2 "6.1 Bootstrap a new cluster"
    cephadm bootstrap \
        --mon-ip ${CURRENT_NODE_IP} \
        --cluster-network ${CEPH_CLUSTER_NETWORK} \
        --initial-dashboard-password ${CEPH_DASHBOARD_PASS}
    
    # Enable ceph cli
    #   You can install the ceph-common package, which contains all of the ceph commands, 
    #   including ceph, rbd, mount.ceph (for mounting CephFS file systems), etc.:
    MSG2 "6.2 Enable ceph cli"
    for HOST in "${!CEPH_MON[@]}"; do
        ssh root@${HOST} "
            cephadm add-repo --release pacific
            cephadm install  ceph-common"
    done


    # Adding Hosts
    #   By default, a ceph.conf file and a copy of the client.admin keyring are maintained 
    #   in /etc/ceph on all hosts with the _admin label, which is initially applied only 
    #   to the bootstrap host. We usually recommend that one or more other hosts be given 
    #   the _admin label so that the Ceph CLI (e.g., via cephadm shell) is easily accessible 
    #   on multiple hosts. To add the _admin label to additional host(s):
    MSG2 "6.3 Adding host"
    for HOST in "${CEPH_NODE[@]}"; do
        ssh-copy-id -f -i /etc/ceph/ceph.pub root@${HOST}   # Install the cluster’s public SSH key in the new host’s root user’s authorized_keys file
    done

    for HOST in "${!CEPH_MON[@]}"; do
        local IP=${CEPH_MON[$HOST]}
        ceph orch host add ${HOST} ${IP} --labels _admin
        ceph orch host label add ${HOST} mon; done
    ceph orch host ls

    for HOST in "${!CEPH_MGR[@]}"; do
        local IP=${CEPH_MGR[$HOST]}
        if [[ ${!CEPH_MON[*]} =~ ${HOST} ]]; then :
        else
            ceph orch host add ${HOST} ${IP}; fi
        ceph orch host label add ${HOST} mgr; done
    ceph orch host ls

    for HOST in "${!CEPH_OSD[@]}"; do
        local IP=${CEPH_OSD[$HOST]}
        if [[ ${!CEPH_MON[*]} =~ ${HOST} ]]; then :
        else
            ceph orch host add ${HOST} ${IP}; fi
        ceph orch host label add ${HOST} osd; done
    ceph orch host ls

    for HOST in "${!CEPH_MDS[@]}"; do
        local IP=${CEPH_MDS[$HOST]}
        if [[ ${!CEPH_MON[*]} =~ ${HOST} ]]; then :
        else
            ceph orch host add ${HOST} ${IP}; fi
        ceph orch host label add ${HOST} mds; done
    ceph orch host ls
}


function 7_placement_mons {
    # Adding Additional Mons
    #   A typical Ceph cluster has three or five monitor daemons spread across different 
    #   hosts. We recommend deploying five monitors if there are five or more nodes in your cluster.

    #MSG1 "7 Adding additional mons"
    #ceph config set mon public_network ${CEPH_PUBLIC_NETWORK}   # designating a particular subnet for monitors
    #ceph orch apply mon --unmanaged                             # disable automated monitor deployment
    #for HOST in "${!CEPH_MON[@]}"; do
        #local IP=${CEPH_MON[$HOST]}
        #ceph orch daemon add mon ${HOST}:${IP}
    #done

    MSG1 "7. Placement mons"
    local ceph_mons
    for mon in "${!CEPH_MON[@]}"; do
        ceph_mons="${ceph_mons}","${mon}"
    done
    ceph_mons="${ceph_mons[@]/,}"
    echo ${ceph_mons}
    ceph orch apply mon --placement="${ceph_mons}"
}
    


function 8_placement_mgrs {
    ## Addding additional 
    #MSG1 "8 Adding additional mgrs"
    #for HOST in "${!CEPH_MGR[@]}"; do
        #local IP=${CEPH_MGR[$HOST]}
        #ceph orch daemon add mgr ${HOST}:${IP}
    #done

    MSG1 "8. Placement mgrs"
    local ceph_mgrs
    for mgr in "${!CEPH_MGR[@]}"; do
        ceph_mgrs="${ceph_mgrs}","${mgr}"
    done
    ceph_mgrs=${ceph_mgrs[@]/,}
    echo ${ceph_mgrs}
    ceph orch apply mgr --placement="${ceph_mgrs}"
}


function 9_placement_osd {
    # Adding Storage
    #   ceph orch device ls [--hostname=...] [--wide] [--refresh]       # To print a list of devices discovered by cephadm, run this command:
    # A storage device is considered available if all of the following conditions are met: 
    #   The device must have no partitions.
    #   The device must not have any LVM state.
    #   The device must not be mounted.
    #   The device must not contain a file system.
    #   The device must not contain a Ceph BlueStore OSD.
    #   The device must be larger than 5 GB.
    # Ceph will not provision an OSD on a device that is not available.
    # Tell Ceph to consume any available and unused storage device
    #   ceph orch apply osd --all-available-devices
    #   ceph orch apply osd --all-available-devices --dry-run
    # Create an OSD from a specific device on a specific host:
    #   ceph orch daemon add osd host1:/dev/sdb
    MSG1 "9. Placement osd"
    for HOST in "${!CEPH_OSD[@]}"; do
        ceph orch daemon add osd ${HOST}:${CEPH_OSD_DISK}
    done

    #MSG1 "9. Placement osd"
    #ceph orch apply osd --all-available-devices --unmanaged=true    # use all device, but not auto add osd
    #ceph orch apply osd --all-available-devices                     # use all device, and auto add osd

}


function 10_placement_mds {
    #MSG1 "10. Adding mds"
    #local count=0
    #local MDS_HOSTS
    #for HOST in "${!CEPH_MDS[@]}"; do
        #MDS_HOSTS="${MDS_HOSTS}"" ${HOST}"
        #(( count++ ))
    #done
    #ceph orch apply mds fs-cluster --placement="${count} ${MDS_HOSTS}"

    MSG1 "10. Placement mds"
    local ceph_mds
    for mds in "${!CEPH_MDS[@]}"; do
        ceph_mds="${ceph_mds}","${mds}"
    done
    ceph_mds=${ceph_mds[@]/,}
    echo ${ceph_mds}
    ceph orch apply mds cephfs --placement="${ceph_mds}"
}



1_configure_ssh_authentication
2_all_ceph_upgrade
3_optimizate_system
4_install_docker
5_install_cephadm
6_deploy_ceph_cluster
7_placement_mons
8_placement_mgrs
9_placement_osd
10_placement_mds
