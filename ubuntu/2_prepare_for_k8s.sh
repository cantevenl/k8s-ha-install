#!/usr/bin/env bash

EXIT_SUCCESS=0
EXIT_FAILURE=1
ERR(){ echo -e "\033[31m\033[01m$1\033[0m"; }
MSG1(){ echo -e "\n\n\033[32m\033[01m$1\033[0m\n"; }
MSG2(){ echo -e "\n\033[33m\033[01m$1\033[0m"; }


function 1_install_necessary_package_for_k8s {
    MSG2 "1. Install package for k8s"

    yum install -y conntrack-tools ipvsadm ipset jq iptables iptables-services bridge-utils sysstat libseccomp gcc gcc-c++ make cmake autoconf automake libxml2-devel openssl-deve curl-devel libaio-devel ncurses-devel zlib-devel ceph-common
}


function 2_disable_swap {
    MSG2 "2. Disable swap"

    sed -i -r "/(.*)swap(.*)swap(.*)/d" /etc/fstab
    swapoff -a
}


function 3_upgrade_kernel {
    MSG2 "3. Upgrade kernel"

    yum install -y kernel-lt
	grub2-set-default "$(cat /boot/grub2/grub.cfg  | grep '^menuentry' | sed -n '1,1p' | awk -F "'" '{print $2}')"
}


function 4_load_kernel_module {
    MSG2 "4. Load kernel module"

    k8s_modules=(
        "#!/usr/bin/env bash"
        "modprobe -- ip_vs"
        "modprobe -- ip_vs_rr"
        "modprobe -- ip_vs_wrr"
        "modprobe -- ip_vs_lc"
        "modprobe -- ip_vs_wlc"
        "modprobe -- ip_vs_lblc"
        "modprobe -- ip_vs_lblcr"
        "modprobe -- ip_vs_sh"
        "modprobe -- ip_vs_dh"
        "modprobe -- ip_vs_fo"
        "modprobe -- ip_vs_nq"
        "modprobe -- ip_vs_sed"
        "modprobe -- ip_vs_ftp"
        "modprobe -- br_netfilter"
        "modprobe -- nf_conntrack"
        "modprobe -- nf_conntrack_ipv4"
        "modprobe -- nf_conntrack_ipv6"
        "modprobe -- ip_tables"
        "modprobe -- ip_set"
        "modprobe -- xt_set"
        "modprobe -- ipt_set"
        "modprobe -- ipt_rpfilter"
        "modprobe -- ipt_REJECT"
        "modprobe -- ipip"
    )
    printf '%s\n' "${k8s_modules[@]}" > /etc/sysconfig/modules/k8s.modules
    chmod u+x /etc/sysconfig/modules/k8s.modules
}


function 5_configure_kernel_parameter {
    MSG2 "5. Configure kernel parameter"

    k8s_sysctl=(
        "net.ipv4.ip_forward = 1"
        "net.bridge.bridge-nf-call-iptables = 1"
        "net.bridge.bridge-nf-call-ip6tables = 1"
        "fs.may_detach_mounts = 1"
        "fs.inotify.max_user_instances = 81920"
        "fs.inotify.max_user_watches = 1048576"
        "fs.file-max = 52706963"
        "fs.nr_open = 52706963"
        "vm.swappiness = 0"
        "vm.overcommit_memory = 1"
        "vm.panic_on_oom = 0"
        "net.ipv4.tcp_tw_recycle = 0"
        "net.ipv6.conf.all.disable_ipv6 = 1"
        "net.netfilter.nf_conntrack_max = 2310720"
        "net.ipv4.tcp_keepalive_time = 600"
        "net.ipv4.tcp_keepalivve_probes = 3"
        "net.ipv4.tcp_keepalive_intvl = 15"
        "net.ipv4.tcp_max_tw_buckets = 36000"
        "net.tcp_tw_reuse = 1"
        "net.ipv4.tcp_max_orphans = 327680"
        "net.ipv4.tcp_orphan_retries = 3"
        "net.ipv4.tcp_syncookies = 1"
        "net.ipv4.tcp_max_syn_backlog = 16384"
        "net.ipv4.ip_conntrack_max = 65536"
        "net.ipv4.tcp.max_syn_backlog = 16384"
        "net.ipv4.tcp_timestamps = 0"
        "net.core.somaxconn = 16384"
    )
    printf '%s\n' "${k8s_sysctl[@]}" > /etc/sysctl.d/98-k8s.conf
    sysctl --system
}


MSG1 "*** `hostname` *** Prepare for Kubernetes"
1_install_necessary_package_for_k8s
2_disable_swap
3_upgrade_kernel
4_load_kernel_module
5_configure_kernel_parameter
