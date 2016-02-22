#!/bin/bash

# This script is only tested on CentOS 6.5 and Ubuntu 12.04 LTS with Percona XtraDB Cluster 5.6.
# You can customize variables such as MOUNTPOINT, RAIDCHUNKSIZE and so on to your needs.
# You can also customize it to work with other Linux flavours and versions.
# If you customize it, copy it to either Azure blob storage or Github so that Azure
# custom script Linux VM extension can access it, and specify its location in the 
# parameters of DeployPXC powershell script or runbook or Azure Resource Manager CRP template.   

NODEID=${1}
NODEADDRESS=${2}
MYCNFTEMPLATE=${3}
RPLPWD=${4}
ROOTPWD=${5}
PROBEPWD=${6}
MASTERIP=${7}
MOUNTPOINT="/datadrive"
RAIDCHUNKSIZE=512
SITENAME=${8}

RAIDDISK="/dev/md127"
RAIDPARTITION="/dev/md127p1"
# An set of disks to ignore from partitioning and formatting
BLACKLIST="/dev/sda|/dev/sdb"

check_os() {
    grep ubuntu /proc/version > /dev/null 2>&1
    isubuntu=${?}
    grep centos /proc/version > /dev/null 2>&1
    iscentos=${?}
}

scan_for_new_disks() {
    # Looks for unpartitioned disks
    declare -a RET
    DEVS=($(ls -1 /dev/sd*|egrep -v "${BLACKLIST}"|egrep -v "[0-9]$"))
    for DEV in "${DEVS[@]}";
    do
        # Check each device if there is a "1" partition.  If not,
        # "assume" it is not partitioned.
        if [ ! -b ${DEV}1 ];
        then
            RET+="${DEV} "
        fi
    done
    echo "${RET}"
}

get_disk_count() {
    DISKCOUNT=0
    for DISK in "${DISKS[@]}";
    do 
        DISKCOUNT+=1
    done;
    echo "$DISKCOUNT"
}

create_raid0_ubuntu() {
    dpkg -s mdadm 
    if [ ${?} -eq 1 ];
    then 
        echo "installing mdadm"
        wget --no-cache http://mirrors.cat.pdx.edu/ubuntu/pool/main/m/mdadm/mdadm_3.2.5-5ubuntu4_amd64.deb
        dpkg -i mdadm_3.2.5-5ubuntu4_amd64.deb
    fi
    echo "Creating raid0"
    udevadm control --stop-exec-queue
    echo "yes" | mdadm --create "$RAIDDISK" --name=data --level=0 --chunk="$RAIDCHUNKSIZE" --raid-devices="$DISKCOUNT" "${DISKS[@]}"
    udevadm control --start-exec-queue
    mdadm --detail --verbose --scan > /etc/mdadm.conf
}

create_raid0_centos() {
    echo "Creating raid0"
    yes | mdadm --create "$RAIDDISK" --name=data --level=0 --chunk="$RAIDCHUNKSIZE" --raid-devices="$DISKCOUNT" "${DISKS[@]}"
    mdadm --detail --verbose --scan > /etc/mdadm.conf
}

do_partition() {
# This function creates one (1) primary partition on the
# disk, using all available space
    DISK=${1}
    echo "Partitioning disk $DISK"
    echo "n
p
1


w
" | fdisk "${DISK}" 
#> /dev/null 2>&1

#
# Use the bash-specific $PIPESTATUS to ensure we get the correct exit code
# from fdisk and not from echo
if [ ${PIPESTATUS[1]} -ne 0 ];
then
    echo "An error occurred partitioning ${DISK}" >&2
    echo "I cannot continue" >&2
    exit 2
fi
}

add_to_fstab() {
    UUID=${1}
    MOUNTPOINT=${2}
    grep "${UUID}" /etc/fstab >/dev/null 2>&1
    if [ ${?} -eq 0 ];
    then
        echo "Not adding ${UUID} to fstab again (it's already there!)"
    else
        LINE="UUID=${UUID} ${MOUNTPOINT} ext4 defaults,noatime 0 0"
        echo -e "${LINE}" >> /etc/fstab
    fi
}

configure_disks() {
	ls "${MOUNTPOINT}"
	if [ ${?} -eq 0 ]
	then 
		return
	fi
    DISKS=($(scan_for_new_disks))
    echo "Disks are ${DISKS[@]}"
    declare -i DISKCOUNT
    DISKCOUNT=$(get_disk_count) 
    echo "Disk count is $DISKCOUNT"
    if [ $DISKCOUNT -gt 1 ];
    then
    	if [ $iscentos -eq 0 ];
    	then
       	    create_raid0_centos
    	elif [ $isubuntu -eq 0 ];
    	then
            create_raid0_ubuntu
    	fi
        do_partition ${RAIDDISK}
        PARTITION="${RAIDPARTITION}"
    else
        DISK="${DISKS[0]}"
        do_partition ${DISK}
        PARTITION=$(fdisk -l ${DISK}|grep -A 1 Device|tail -n 1|awk '{print $1}')
    fi

    echo "Creating filesystem on ${PARTITION}."
    mkfs -t ext4 -E lazy_itable_init=1 ${PARTITION}
    mkdir "${MOUNTPOINT}"
    read UUID FS_TYPE < <(blkid -u filesystem ${PARTITION}|awk -F "[= ]" '{print $3" "$5}'|tr -d "\"")
    add_to_fstab "${UUID}" "${MOUNTPOINT}"
    echo "Mounting disk ${PARTITION} on ${MOUNTPOINT}"
    mount "${MOUNTPOINT}"
}

open_ports() {
    iptables -A INPUT -p tcp -m tcp --dport 80 -j ACCEPT
    iptables -A INPUT -p tcp -m tcp --dport 6082 -j ACCEPT
    iptables-save
}

disable_apparmor_ubuntu() {
    /etc/init.d/apparmor teardown
    update-rc.d -f apparmor remove
}

disable_selinux_centos() {
    sed -i 's/^SELINUX=.*/SELINUX=disabled/I' /etc/selinux/config
    setenforce 0
}

configure_network() {
    open_ports
    if [ $iscentos -eq 0 ];
    then
        disable_selinux_centos
    elif [ $isubuntu -eq 0 ];
    then
        disable_apparmor_ubuntu
    fi
}

create_vcl() {
  cat <<EOF >/etc/varnish/default.vcl
vcl 4.0;
backend default {

      .host = "${SITENAME}.azurewebsites.net";
      .port = "80";
      .connect_timeout = 600s;
      .first_byte_timeout = 600s;
      .between_bytes_timeout = 600s;
}
sub vcl_recv {
     set req.http.host = "my-azure-webapp.azurewebsites.net";
     set req.backend = default;
     return (lookup);
}

EOF

PORTVARNISH=80
sed -i "s/^DAEMON_OPTS=.*/DAEMON_OPTS=\"-a : ${PORTVARNISH} \ " /etc/default/varnish

}

install_varnish_ubuntu() {    
   
    echo "installing varnish"
    apt-get update
    export DEBIAN_FRONTEND=noninteractive
    
    wget http://repo.varnish-cache.org/debian/GPG-key.txt 
    apt-key add GPG-key.txt 
    echo "deb http://repo.varnish-cache.org/ubuntu/ precise varnish-3.0" |  tee -a /etc/apt/sources.list
    apt-get update
    apt-get install varnish

}

install_varnish_centos() {
    
    rpm --nosignature -i varnish-release-3.0-1.noarch.rpm
    if [ ${?} -eq 0 ];
    then
        return
    fi
    echo "installing varnish"
    wget http://repo.varnish-cache.org/redhat/varnish-3.0/el5/noarch/varnish-release-3.0-1.noarch.rpm
    yum install varnish
}


configure_varnish() {
    
 

    mkdir "${MOUNTPOINT}/varnish"
    ln -s "${MOUNTPOINT}/varnish" /var/lib/varnish
    chmod o+x /var/lib/varnish
    groupadd varnish
    useradd -r -g varnish varnish
    chmod o+x "${MOUNTPOINT}/varnish"
    chown -R varnish:varnish "${MOUNTPOINT}/varnish"

    if [ $iscentos -eq 0 ];
    then
        install_varnish_centos
    elif [ $isubuntu -eq 0 ];
    then
        install_varnish_ubuntu
    fi

    create_vcl
    service varnish start
    
}

check_os
if [ $iscentos -ne 0 ] && [ $isubuntu -ne 0 ];
then
    echo "unsupported operating system"
    exit 1 
else
    configure_network
    configure_disks
    configure_varnish
	yum -y erase hypervkvpd.x86_64
	yum -y install microsoft-hyper-v
#	echo "/sbin/reboot" | /usr/bin/at now + 3 min >/dev/null 2>&1
fi

