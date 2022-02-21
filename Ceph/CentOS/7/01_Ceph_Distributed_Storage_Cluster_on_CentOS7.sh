#How to build a Ceph Distributed Storage Cluster on CentOS

# Ceph is an open source software-defined storage solution designed to address the block, file and object storage needs of modern enterprises. Its highly scalable architecture sees it being adopted as the new norm for high-growth block storage, object stores, and data lakes. Ceph provides reliable and scalable storage while keeping CAPEX and OPEX costs in line with underlying commodity hardware prices.

# Ceph makes it possible to decouple data from physical storage hardware using software abstraction layers, which provides unparalleled scaling and fault management capabilities. This makes Ceph ideal for cloud, Openstack, Kubernetes, and other microservice and container-based workloads, as it can effectively address large data volume storage needs.

# The main advantage of Ceph is that it provides interfaces for multiple storage types within a single cluster, eliminating the need for multiple storage solutions or any specialised hardware, thus reducing management overheads.

# Use cases for Ceph range from private cloud infrastructure (both hyper-converged and disaggregated) to big data analytics and rich media, or as an alternative to public cloud storage.

# In this tutorial, I will guide you to install and build a Ceph cluster on CentOS 7. A Ceph cluster requires these Ceph components:

"Ceph Components"
# A Ceph Storage Cluster consists of multiple types of daemons:
# -Ceph Monitor
# -Ceph OSD Daemon
# -Ceph Manager
# -Ceph Metadata Server	

# Ceph OSDs (ceph-osd) - Handles the data store, data replication and recovery. A Ceph cluster needs at least two Ceph OSD servers. I will use three CentOS 7 OSD servers here.
# Ceph Monitor (ceph-mon) - Monitors the cluster state, OSD map and CRUSH map. I will use one server.
# Ceph Meta Data Server (ceph-mds) - This is needed to use Ceph as a File System and stores metadata on behalf of the Ceph Filesystem
# Additionally, we can add further parts to the cluster to support different storage solutions
# Ceph rados gateway (ceph-rgw) is an HTTP server for interacting with a Ceph Storage Cluster that provides interfaces compatible with OpenStack Swift and Amazon S3.


#-----------------------------------------------------------------------
"Prerequisites"
########################################################################
# 6 server nodes, all with CentOS 7 installed.
# Root privileges on all nodes.
# The servers in this tutorial will use the following hostnames and IP addresses.

							192.168.37.10
							+-----------+-----------+
							|     [ceph-admin] 		|
							|      Manager Daemon   |
							|      Cephadm		    |
							|                       |
							+-----------------------+
        192.168.37.15					 |			192.168.37.11
        +--------------------+           |          +----------------------+
        |   [client]         |           | 			|    [mon1]            |
        |    Ceph Client     +-----------+----------+     Monitor Daemon   |
        |                    |           |          |     OSD map,CRUSH map|
        +--------------------+			 |          |     Ceph-dash	       |
										 |          +----------------------+
            +----------------------------+----------------------------+
            |                            |                            |
            |192.168.37.21               |192.168.37.22               |192.168.37.23
+-----------+-----------+    +-----------+-----------+    +-----------+-----------+
|   [osd1]              |    |   [osd2]              |    |   [osd3]              |
|     Object Storage    +----+     Object Storage    +----+     Object Storage    |
|                       |    |                       |    |                       |
|                       |    |                       |    |                       |
+-----------------------+    +-----------------------+    +-----------------------+


ceph-admin      192.168.37.10	# Ceph Cluster Deploy tool
mon1            192.168.37.11	# Monitors the cluster state, OSD map and CRUSH map
osd1            192.168.37.21
osd2            192.168.37.22
osd3            192.168.37.23
client          192.168.37.15

# All OSD nodes need two partitions, one root (/) partition and an empty partition that is used as Ceph data storage later.


#-----------------------------------------------------------------------
"Step 1 - Configure All Nodes"
########################################################################
# In this step, we will configure all 6 nodes to prepare them for the installation of the Ceph Cluster. You have to follow and run all commands below on all nodes. And make sure ssh-server is installed on all nodes.

# 1.1	Configure Network on All hosts
echo "NM_CONTROLLED=yes" >>/etc/sysconfig/network-scripts/ifcfg-ens33
systemctl enable NetworkManager
systemctl start NetworkManager
nmcli con add type ethernet con-name ens33 ifname ens33
nmcli c modify ens33 ipv4.addresses 192.168.37.15/24
nmcli c modify ens33 ipv4.gateway 192.168.37.2
nmcli c modify ens33 ipv4.dns "8.8.8.8 4.2.2.4"
nmcli c modify ens33 +ipv4.dns-search "itstorage.net"
nmcli c modify ens33 ipv4.method manual
nmcli c modify ens33 connection.autoconnect yes
nmcli c down ens33; nmcli c up ens33 
# 1.2	Configure Hosts File
# Edit the /etc/hosts file on all node with the vim editor and add lines with the IP address and hostnames of all cluster nodes.
vi /etc/hosts
192.168.37.10	ceph-admin.itstorage.net	ceph-admin            
192.168.37.11	mon1.itstorage.net			mon1            
192.168.37.21	osd1.itstorage.net			osd1            
192.168.37.22	osd2.itstorage.net			osd2            
192.168.37.23	osd3.itstorage.net			osd3            
192.168.37.15	client.itstorage.net		client   
# 1.2.1  Set on All hosts
hostnamectl   set-hostname client
hostnamectl --static    set-hostname client
hostnamectl --transient set-hostname client
# 1.3	Update OS
yum update -y
yum install -y yum-utils.noarch
#Tips: uncomplete yum install
yum-complete-transaction -y
package-cleanup --problems
package-cleanup --dupes
rpm -Va --nofiles --nodigest

# 1.4	Install and Configure NTP on All hosts
# Install NTP to synchronize date and time on all nodes. Run the ntpdate command to set a date and time via NTP protocol, we will use the us pool NTP server. Then start and enable NTP server to run at boot time.

yum install -y ntp ntpdate ntp-doc
ntpdate 0.us.pool.ntp.org
hwclock --systohc
systemctl enable ntpd.service
systemctl start ntpd.service

# 1.5	Install Open-vm-tools
# If you are running all nodes inside VMware, you need to install this virtualization utility. Otherwise skip this step.
yum install -y open-vm-tools

# 1.6	Disable SELinux
# Disable SELinux on all nodes by editing the SELinux configuration file with the sed stream editor.
sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
# 1.7	Create a Ceph User
# Create a new user named 'cephuser' on all nodes.
useradd -d /home/cephuser -m cephuser
passwd cephuser
# 1.7.1  Configure sudo for 'cephuser'
# After creating the new user, we need to configure sudo for 'cephuser'. He must be able to run commands as root and to get root privileges without a password.
# Run the command below to create a sudoers file for the user and edit the /etc/sudoers file with sed.
echo "cephuser ALL = (root) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/cephuser
chmod 0440 /etc/sudoers.d/cephuser
sed -i s'/Defaults requiretty/#Defaults requiretty'/g /etc/sudoers

# 1.6 Changing Unique identifiers in Centos 7 after cloning a VM
https://manuelveronesi.freshdesk.com/support/solutions/articles/19000107613-changing-unique-identifiers-in-centos-7-after-cloning-a-vm

# Machine ID
# cat /etc/machine-id
daab00e07fed481d8ccf145b7affc0c5
# rm /etc/machine-id
# systemd-machine-id-setup
Initializing machine ID from random generator.
# cat /etc/machine-id
2175d9b2344a499abd87920c6f76f9a1

# Storage UUID
# Use blkid command-line utility to determine device UUID :
blkid

#Sample output :
/dev/mapper/centos_centos71-root: UUID="2bc8e0d4-64b5-4dc8-bf4a-024fc980d98a" TYPE="ext4"
/dev/mapper/centos_centos71-swap: UUID="577f9541-8d2a-4666-ac8f-ff84b584eeca" TYPE="swap"
/dev/mapper/vg_data-centos7_vol: UUID="b100ad2b-ad89-4e2d-ba8e-7eda7d703c40" TYPE="ext4"
Verify the mounted partition :
# df -lh
Filesystem                        Size  Used Avail Use% Mounted on
/dev/mapper/centos_centos71-root   24G  3.1G   19G  15% /
devtmpfs                          1.9G     0  1.9G   0% /dev
tmpfs                             1.9G     0  1.9G   0% /dev/shm
tmpfs                             1.9G   25M  1.9G   2% /run
tmpfs                             1.9G     0  1.9G   0% /sys/fs/cgroup
tmpfs                             500M     0  500M   0% /etc/nginx/cache
/dev/sda1                         477M  230M  218M  52% /boot
tmpfs                             380M     0  380M   0% /run/user/0
/dev/mapper/vg_data-centos7_vol   9.8G   37M  9.2G   1% /data
#How to change UUID for /dev/mapper/vg_data-centos7_vol which is in /data mounted partition 
# a) Generate new UUId using uuidgen utility :
uuidgen
fb5c697b-d1d6-49ab-afcd-27a22a5007c8
# b) Please take note that the UUID may only be changed when the filesystem is unmounted.
umount /data
#c) Change UUID for LVM /dev/mapper/vg_data-centos7_vol with new generated UUID :
tune2fs /dev/mapper/vg_data-centos7_vol -U fb5c697b-d1d6-49ab-afcd-27a22a5007c8
tune2fs 1.42.9 (28-Dec-2013)
# d) Mount back the /data partition :
mount /dev/mapper/vg_data-centos7_vol /data
#e) Update /etc/fstab :
# Option 1 :
UUID=fb5c697b-d1d6-49ab-afcd-27a22a5007c8 /data   ext4    defaults        1 2
# Option 2 :
/dev/mapper/vg_data-centos7_vol /data   ext4    defaults        1 2
# f) Verify new UUID for /dev/mapper/vg_data-centos7_vol
blkid
/dev/mapper/centos_centos71-root: UUID="2bc8e0d4-64b5-4dc8-bf4a-024fc980d98a" TYPE="ext4"
/dev/mapper/centos_centos71-swap: UUID="577f9541-8d2a-4666-ac8f-ff84b584eeca" TYPE="swap"
/dev/mapper/vg_data-centos7_vol: UUID="fb5c697b-d1d6-49ab-afcd-27a22a5007c8" TYPE="ext4"

# How to generate UUID for network interface
# UUIDs (Universal Unique Identifier) for network interface card can be generated using the following command :
uuidgen <DEVICE>
#Example :
uuidgen eth0
#Then you can add it to your NIC config file (assuming your interface is eth0) :
# NIC configuration fileShell
/etc/sysconfig/network-scripts/ifcfg-eth0
# Add/modify the following :
UUID=<uuid>


#-----------------------------------------------------------------------
"Step 2 - Configure the SSH Server"
########################################################################
# In this step, I will configure the ceph-admin node. The admin node is used for configuring the monitor node and the osd nodes. Login to the ceph-admin node and become the 'cephuser'.
su - cephuser
ssh-keygen
# leave passphrase blank/empty.

# Next, create the configuration file for the ssh configuration.
# 2.1  Next, create the configuration file for the ssh configuration.
vim ~/.ssh/config
# Paste configuration below:
Host ceph-admin
        Hostname ceph-admin
        User cephuser
 
Host mon1
        Hostname mon1
        User cephuser
 
Host osd1
        Hostname osd1
        User cephuser
 
Host osd2
        Hostname osd2
        User cephuser
 
Host osd3
        Hostname osd3
        User cephuser
 
Host client
        Hostname client
        User cephuser
#	Save the file.
#	Change the permission of the config file.
chmod 644 ~/.ssh/config
#	Now add the SSH key to all nodes with the ssh-copy-id command.
ssh-keyscan osd1 osd2 osd3 mon1 client >> ~/.ssh/known_hosts
ssh-copy-id osd1
ssh-copy-id osd2
ssh-copy-id osd3
ssh-copy-id mon1
ssh-copy-id client

# Type in your 'cephuser' password when requested.
#-----------------------------------------------------------------------
"Step 3 - Configure Firewalld"
########################################################################
# We will use Firewalld to protect the system. In this step, we will enable firewald on all nodes, then open the ports needed by ceph-admon, ceph-mon and ceph-osd.
# Login to the ceph-admin node and start firewalld.
ssh root@ceph-admin
systemctl start firewalld
systemctl enable firewalld
# Open port 80, 2003 and 4505-4506, and then reload the firewall.
sudo firewall-cmd --zone=public --add-port=80/tcp --permanent
sudo firewall-cmd --zone=public --add-port=2003/tcp --permanent
sudo firewall-cmd --zone=public --add-port=4505-4506/tcp --permanent
sudo firewall-cmd --reload
# From the ceph-admin node, login to the monitor node 'mon1' and start firewalld.
ssh root@mon1
sudo systemctl start firewalld
sudo systemctl enable firewalld
# Open new port on the Ceph monitor node and reload the firewall.
sudo firewall-cmd --zone=public --add-port=6789/tcp --permanent
sudo firewall-cmd --reload
# Finally, open port 6800-7300 on each of the osd nodes - osd1, osd2 and os3.
# Login to each osd node from the ceph-admin node.
ssh root@osd1
sudo systemctl start firewalld
sudo systemctl enable firewalld
# Open the ports and reload the firewall.
sudo firewall-cmd --zone=public --add-port=6800-7300/tcp --permanent
sudo firewall-cmd --reload
ssh root@osd2
sudo systemctl start firewalld
sudo systemctl enable firewalld
# Open the ports and reload the firewall.
sudo firewall-cmd --zone=public --add-port=6800-7300/tcp --permanent
sudo firewall-cmd --reload
ssh root@osd3
sudo systemctl start firewalld
sudo systemctl enable firewalld
# Open the ports and reload the firewall.
sudo firewall-cmd --zone=public --add-port=6800-7300/tcp --permanent
sudo firewall-cmd --reload

# Firewalld configuration is done.
########################################################################
#-----------------------------------------------------------------------
"Step 4 - Configure the Ceph OSD Nodes"
#In this tutorial, we have 3 OSD nodes and each node has two partitions.
# /dev/sda for the root partition.
# /dev/sdb is an empty partition - 30GB in my case.
# We will use /dev/sdb for the Ceph disk. From the ceph-admin node, login to all OSD nodes and format the /dev/sdb partition with XFS.
ssh osd1
ssh osd2
ssh osd3
#Check the partition with the fdisk command.
sudo fdisk -l /dev/sdb
#Format the /dev/sdb partition with XFS filesystem and with a GPT partition table by using the parted command.
sudo parted -s /dev/sdb mklabel gpt mkpart primary xfs 0% 100%
sudo mkfs.xfs /dev/sdb -f
#Now check the partition, and you will get xfs /dev/sdb partition.
sudo blkid -o value -s TYPE /dev/sdb
########################################################################
#-----------------------------------------------------------------------
"Step 5 - Build the Ceph Cluster"
########################################################################
# In this step, we will install Ceph on all nodes from the ceph-admin node.
# Login to the ceph-admin node.
ssh root@ceph-admin
su - cephuser
#5.1	Install ceph-deploy on the ceph-admin node
sudo rpm -Uhv http://download.ceph.com/rpm-jewel/el7/noarch/ceph-release-1-1.el7.noarch.rpm
sudo yum update -y && sudo yum install ceph-deploy -y
# Make sure all nodes are updated.
# After the ceph-deploy tool has been installed, create a new directory for the ceph cluster configuration.

#5.2	Create New Cluster Config
mkdir cluster
cd cluster/
# Next, create a new cluster configuration with the 'ceph-deploy' command, define the monitor node to be 'mon1'.
ceph-deploy new mon1
# The command will generate the Ceph cluster configuration file 'ceph.conf' in the cluster directory.

# Edit the ceph.conf file with vim.
vim ceph.conf
# Your network address
public network = 192.168.37.0/24
osd pool default size = 2
#5.3	Install Ceph on All Nodes
# Now install Ceph on all other nodes from the ceph-admin node. This can be done with a single command.
ceph-deploy install ceph-admin mon1 osd1 osd2 osd3
# The command will automatically install Ceph on all nodes: mon1, osd1-3 and ceph-admin - The installation will take some time.

# Now deploy the ceph-mon on mon1 node.
ceph-deploy mon create-initial
# The command will create the monitor key, check and get the keys with with the 'ceph' command.
ceph-deploy gatherkeys mon1

#5.4	Adding OSDS to the Cluster
# When Ceph has been installed on all nodes, then we can add the OSD daemons to the cluster. OSD Daemons will create their data and journal partition on the disk /dev/sdb.

# Check that the /dev/sdb partition is available on all OSD nodes.
ceph-deploy disk list osd1 osd2 osd3
# You will see the /dev/sdb disk with XFS format.

# Next, delete the /dev/sdb partition tables on all nodes with the zap option.
ceph-deploy disk zap osd1:/dev/sdb osd2:/dev/sdb osd3:/dev/sdb
# The command will delete all data on /dev/sdb on the Ceph OSD nodes.

#Now prepare all OSDS nodes. Make sure there are no errors in the results.
ceph-deploy osd prepare osd1:/dev/sdb osd2:/dev/sdb osd3:/dev/sdb
# If you see the osd1-3 is ready for OSD use result, then the deployment was successful.

# Activate the OSDs with the command below:
ceph-deploy osd activate osd1:/dev/sdb1 osd2:/dev/sdb1 osd3:/dev/sdb1
# Check the output for errors before you proceed. Now you can check the sdb disk on OSD nodes with the list command.
ceph-deploy disk list osd1 osd2 osd3

# The results is that /dev/sdb has now two partitions:
#	/dev/sdb1 - Ceph Data
#	/dev/sdb2 - Ceph Journal
# Or you can check that directly on the OSD node with fdisk.
ssh osd1
sudo fdisk -l /dev/sdb

# Next, deploy the management-key to all associated nodes.
ceph-deploy admin ceph-admin mon1 osd1 osd2 osd3
# Change the permission of the key file by running the command below on all nodes.
sudo chmod 644 /etc/ceph/ceph.client.admin.keyring
# The Ceph Cluster on CentOS 7 has been created.

#-----------------------------------------------------------------------
"Step 6 - Testing the Ceph setup"
########################################################################
# In step 4, we've installed and created our new Ceph cluster, then we added OSDS nodes to the cluster. Now we can test the cluster and make sure there are no errors in the cluster setup.

# From the ceph-admin node, log in to the ceph monitor server 'mon1'.

ssh mon1
# Run the command below to check the cluster health.
sudo ceph health
# Now check the cluster status.
sudo ceph -s

# Make sure Ceph health is OK and there is a monitor node 'mon1' with IP address '192.168.37.11'. There should be 3 OSD servers and all should be up and running, and there should be an available disk of about 24GB - 3x8GB Ceph Data partition.

# Congratulation, you've build a new Ceph Cluster successfully.

#-----------------------------------------------------------------------
"Step 7 - Configure Ceph Client Node"
########################################################################
ssh root@192.168.37.15
useradd -d /home/cephuser -m cephuser
passwd cephuser
echo "cephuser ALL = (root) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/cephuser
sed -i s'/Defaults requiretty/#Defaults requiretty'/g /etc/sudoers
chmod 0440 /etc/sudoers.d/cephuser
sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
yum install -y open-vm-tools
yum install -y ntp ntpdate ntp-doc
ntpdate 0.us.pool.ntp.org
hwclock --systohc
systemctl enable ntpd.service
systemctl start ntpd.service
vim /etc/hosts
192.168.37.10	ceph-admin.itstorage.net	ceph-admin            
192.168.37.11	mon1.itstorage.net			mon1            
192.168.37.21	osd1.itstorage.net			osd1            
192.168.37.22	osd2.itstorage.net			osd2            
192.168.37.23	osd3.itstorage.net			osd3            
192.168.37.15	client.itstorage.net		client 
#-----------------------------------------------------------------------
"Step 8 - Configure the Ceph Admin-node"
########################################################################
#Login to the ceph-admin node.
ssh root@ceph-admin
su - cephuser
#Edit the ssh configuration file with vim.
vim ~/.ssh/config

#Add the new client node configuration at the end of the file.

Host client
        Hostname client
        User cephuser
#Save the config file and exit vim.
#Next, edit the /etc/hosts file on the ceph-admin node.
sudo vim /etc/hosts
#And add the client hostname and IP address.
10.0.15.15      client
#Save /etc/hosts and exit the editor.

#Now we can add the ceph-admin SSH key to the client node.
ssh-keyscan client >> ~/.ssh/known_hosts
ssh-copy-id client
#Type in your "cephuser" password when requested.
#Try to connect to the client node server with the command below to test the connection.
ssh client
#-----------------------------------------------------------------------
"Step 9 - Install Ceph on Client Node"
########################################################################
#In this step, we will install Ceph on the client node (the node that acts as client node) from the ceph-admin node.
#Login to the ceph-admin node as root by ssh and become "cephuser" with su.
ssh root@ceph-admin
su - cephuser
#Go to the Ceph cluster directory, in our first Ceph tutorial, we used the 'cluster' directory.
cd cluster/
#Install Ceph on the client node with ceph-deploy and then push the configuration and the admin key to the client node.
ceph-deploy install client
ceph-deploy admin client
#The Ceph installation will take some time (depends on the server and network speed). When the task finished, connect to the client node and change the permission of the admin key.
ssh client
sudo chmod 644 /etc/ceph/ceph.client.admin.keyring
#Ceph has been installed on the client node.
#-----------------------------------------------------------------------
"Step 10 - Configure and Mount Ceph as Block Device"
########################################################################
#Ceph allows users to use the Ceph cluster as a thin-provisioned block device. We can mount the Ceph storage like a normal hard drive on our system. Ceph Block Storage or Ceph RADOS Block Storage (RBD) stores block device images as an object, it automatically stripes and replicates our data across the Ceph cluster. Ceph RBD has been integrated with KVM, so we can also use it as block storage on various virtualization platforms such as OpenStack, Apache CLoudstack, Proxmox VE etc.

#Before creating a new block device on the client node, we must check the cluster status. Login to the Ceph monitor node and check the cluster state.

ssh mon1
sudo ceph -s
#Make sure cluster health is 'HEALTH_OK' and pgmap is 'active & clean'.
#In this step, we will use Ceph as a block device or block storage on a client server with CentOS 7 as the client node operating system. From the ceph-admin node, connect to the client node with ssh. There is no password required as we configured passwordless logins for that node in the furst chapters.
ssh client
#Ceph provides the rbd command for managing rados block device images. We can create a new image, resize, create a snapshot, and export our block devices with the rbd command.
#Create a new rbd image with size 5GB, and then check 'disk01' is available on the rbd list.
rbd create disk01 --size 5120
rbd ls -l
#Next, activate the rbd kernel module.
sudo modprobe rbd
sudo rbd feature disable disk01 exclusive-lock object-map fast-diff deep-flatten
#Now, map the disk01 image to a block device via rbd kernel module, and make sure the disk01 in the list of mapped devices then.
sudo rbd map disk01
rbd showmapped
#We can see that the disk01 image has been mapped as '/dev/rbd0' device. Before using it to store data, we have to format that disk01 image with the mkfs command. I will use the XFS file system.
sudo mkfs.xfs /dev/rbd0
#Mount '/dev/rbd0' to the mnt directory. I will use the 'mydisk' subdirectory for this purpose.
sudo mkdir -p /mnt/mydisk
sudo mount /dev/rbd0 /mnt/mydisk
#The Ceph RBD or RADOS Block Device has been configured and mounted on the system. Check that the device has been mounted correctly with the df command.
df -hT
#Using Ceph as Block Device on CentOS 7 has been successful.
#-----------------------------------------------------------------------
"Step 11 - Setup RBD at Boot time"
########################################################################
#Using Ceph as a Block Device on the CentOS 7 Client node has been successful. Now we will configure to automount the Ceph Block Device to the system. at boot time We need to create a services file for 'RBD Auto Mount'.

#Create a new file in the /usr/local/bin directory for mounting and unmounting of the RBD disk01.
cd /usr/local/bin/
sudo vim rbd-mount
#Paste the script below:

#!/bin/bash
# Script Author: http://bryanapperson.com/
# Change with your pools name
export poolname=rbd
 
# CHange with your disk image name
export rbdimage=disk01
 
# Mount Directory
export mountpoint=/mnt/mydisk
 
# Image mount/unmount and pool are passed from the systems service as arguments
# Determine if we are mounting or unmounting
if [ "$1" == "m" ]; then
   modprobe rbd
   rbd feature disable $rbdimage exclusive-lock object-map fast-diff deep-flatten
   rbd map $rbdimage --id admin --keyring /etc/ceph/ceph.client.admin.keyring
   mkdir -p $mountpoint
   mount /dev/rbd/$poolname/$rbdimage $mountpoint
fi
if [ "$1" == "u" ]; then
   umount $mountpoint
   rbd unmap /dev/rbd/$poolname/$rbdimage
fi

#Save the file and exit vim, then make it executable with chmod.
sudo chmod +x rbd-mount
#Next, go to the systemd directory and create the service file.
cd /etc/systemd/system/
sudo vim rbd-mount.service
#Paste service configuration below:
[Unit]
Description="RADOS block device mapping for $rbdimage in pool $poolname"
Conflicts=shutdown.target
Wants=network-online.target
After=NetworkManager-wait-online.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/rbd-mount m
ExecStop=/usr/local/bin/rbd-mount u
[Install]
WantedBy=multi-user.target

#Save the file and exit vim.
#Reload the systemd files and enable the rbd-mount service to start at boot time.
sudo systemctl daemon-reload
sudo systemctl enable rbd-mount.service
sudo systemctl status rbd-mount.service
#If you reboot the client node now, rbd 'disk01' will automatically be mounted to the '/mnt/mydisk' directory.
# test
[root@client mydisk]# cd /mnt/mydisk
[root@client mydisk]# fallocate -l 1G test.img
# or
[root@client mydisk]# dd if=/dev/zero of=test3.iso bs=4096 count=100000 seek=$[1024*10]

[cephuser@ceph-admin cluster]$  ceph df
GLOBAL:
    SIZE       AVAIL      RAW USED     %RAW USED 
    76759M     73657M        3101M          4.04 
POOLS:
    NAME     ID     USED     %USED     MAX AVAIL     OBJECTS 
    rbd      0      834M      2.34        34877M         223 
[cephuser@ceph-admin cluster]$ 

#-----------------------------------------------------------------------
"11 COMMANDS EVERY CEPH ADMINISTRATOR SHOULD KNOW"
########################################################################
#If you have just started working with Ceph, you already know there is a lot going on under the hood. To help you in your journey to becoming a Ceph master, here's a list of 10 commands every Ceph cluster administrator should know. Print it out, stick it to your wall and let it feed your Ceph mojo!

1. Check or watch cluster health: ceph status || ceph -w
#If you want to quickly verify that your cluster is operating normally, use ceph status to get a birds-eye view of cluster status (hint: typically, you want your cluster to be active + clean). You can also watch cluster activity in real-time with ceph -w; you'll typically use this when you add or remove OSDs and want to see the placement groups adjust.

2. Check cluster usage stats: ceph df
#To check a cluster’s data usage and data distribution among pools, use ceph df. This provides information on available and used storage space, plus a list of pools and how much storage each pool consumes. Use this often to check that your cluster is not running out of space.

3. Check placement group stats: ceph pg dump
#When you need statistics for the placement groups in your cluster, use ceph pg dump. You can get the data in JSON as well in case you want to use it for automatic report generation.

4. View the CRUSH map: ceph osd tree
#Need to troubleshoot a cluster by identifying the physical data center, room, row and rack of a failed OSD faster? Use ceph osd tree, which produces an ASCII art CRUSH tree map with a host, its OSDs, whether they are up and their weight.

5. Create or remove OSDs: ceph osd create || ceph osd rm
#Use ceph osd create to add a new OSD to the cluster. If no UUID is given, it will be set automatically when the OSD starts up. When you need to remove an OSD from the CRUSH map, use ceph osd rm with the UUID.

6. Create or delete a storage pool: ceph osd pool create || ceph osd pool delete
#Create a new storage pool with a name and number of placement groups with ceph osd pool create. Remove it (and wave bye-bye to all the data in it) with ceph osd pool delete.

7. Repair an OSD: ceph osd repair
#Ceph is a self-repairing cluster. Tell Ceph to attempt repair of an OSD by calling ceph osd repair with the OSD identifier.

8. Benchmark an OSD: ceph tell osd.* bench
#Added an awesome new storage device to your cluster? Use ceph tell to see how well it performs by running a simple throughput benchmark. By default, the test writes 1 GB in total in 4-MB increments.

9. Adjust an OSD’s crush weight: ceph osd crush reweight
#Ideally, you want all your OSDs to be the same in terms of thoroughput and capacity...but this isn't always possible. When your OSDs differ in their key attributes, use ceph osd crush reweight to modify their weights in the CRUSH map so that the cluster is properly balanced and OSDs of different types receive an appropriately-adjusted number of I/O requests and data.

10. List cluster keys: ceph auth list
#Ceph uses keyrings to store one or more Ceph authentication keys and capability specifications. The ceph auth list command provides an easy way to to keep track of keys and capabilities
#-----------------------------------------------------------------------
"12 How to do a Ceph cluster maintenance/shutdown"
########################################################################
#Below steps are taken from redhat documentation:

#Follow the below procedure for Shutting down the Ceph Cluster:
# 1.    Stop the clients from using the RBD images/Rados Gateway on this cluster or any other clients.
# 2.    The cluster must be in healthy state before proceeding.
ssh mon1
sudo ceph health
# 3.    Set the noout, norecover, norebalance, nobackfill, nodown and pause flags
ceph osd set noout
ceph osd set norecover
ceph osd set norebalance
ceph osd set nobackfill
ceph osd set nodown
ceph osd set pause
#4.    Shutdown osd nodes one by one
#5.    Shutdown monitor nodes one by one
#6.    Shutdown admin node

# For Bringing up follow the below order:
# 1.    Power on the admin node
# 2.    Power on the monitor nodes
# 3.    Power on the osd nodes
# 4.    Wait for all the nodes to come up , Verify all the services are
# up and the connectivity is fine between the nodes.
ssh mon1
sudo ceph health
HEALTH_WARN pauserd,pausewr,nodown,noout,nobackfill,norebalance,norecover flag(s) set

sudo ceph -s
    cluster 19fcabe2-06c9-4213-9b5c-8f058a23394f
     health HEALTH_WARN
            pauserd,pausewr,nodown,noout,nobackfill,norebalance,norecover flag(s) set
     monmap e1: 1 mons at {mon1=192.168.37.11:6789/0}
            election epoch 4, quorum 0 mon1
     osdmap e28: 3 osds: 3 up, 3 in
            flags pauserd,pausewr,nodown,noout,nobackfill,norebalance,norecover,sortbitwise,require_jewel_osds
      pgmap v147: 64 pgs, 1 pools, 0 bytes data, 0 objects
            323 MB used, 76436 MB / 76759 MB avail
                  64 active+clean

# 5.    Unset all the noout,norecover,noreblance, nobackfill, nodown and pause flags.
ceph osd unset noout
ceph osd unset norecover
ceph osd unset norebalance
ceph osd unset nobackfill
ceph osd unset nodown
ceph osd unset pause
# 6.	Power on All clients
# 7.    Check and verify the cluster is in healthy state, Verify all the
# clients are able to access the cluster.

https://openattic.org/posts/how-to-do-a-ceph-cluster-maintenanceshutdown/
#-----------------------------------------------------------------------
"Steps to stop/restart entire ceph cluster"
########################################################################
> We’re trying to stop and then restart our ceph cluster. Our steps are as following:
>
> stop cluster:
>         stop mds -> stop osd -> stop mon
>
> restart cluster:
>         start mon -> start osd -> start mds

https://documentation.suse.com/ses/6/html/ses-all/ceph-operating-services.html
#-----------------------------------------------------------------------


# Monitoring of a Ceph Cluster with Ceph-dash on CentOS

#-----------------------------------------------------------------------
"Monitoring of a Ceph Cluster with Ceph-dash on CentOS"
########################################################################
#Enable Dashboard module on [Monitor Daemon/ mon1] Node.
#Furthermore, Dashboard requires SSL/TLS. Create a self-signed certificate on this example.
ssh mon1
sudo ceph health
sudo dnf install ceph-mgr-dashboard
ceph mgr module enable dashboard
ceph mgr module ls | grep -A 5 enabled_modules
# create self-signed certificate
ceph dashboard create-self-signed-cert
# create a user for Dashboard
# [ceph dashboard ac-user-create (username) (password) administrator]
ceph dashboard ac-user-create admin password1 administrator
# confirm Dashboard URL
ceph mgr services

#On Dashboard Host (mon1), Firewalld is running, allow service ports.
firewall-cmd --add-port=8443/tcp --permanent
firewall-cmd --reload

#Access to the Dashboard URL from a Client Computer with Web Browser, then Ceph Dashboard Login form is shown. Login as a user you just added. After login, it's possible to see various status of Ceph Cluster.

#-----------------------------------------------------------------------
# Reference
https://blog.risingstack.com/ceph-storage-deployment-vm/
https://ubuntu.com/ceph/what-is-ceph
https://www.howtoforge.com/tutorial/how-to-build-a-ceph-cluster-on-centos-7/
http://docs.ceph.com/docs/jewel/
https://access.redhat.com/documentation/en/red-hat-ceph-storage/
http://docs.ceph.com/docs/jewel/rbd/rbd/
http://blog.programster.org/ceph-deploy-and-mount-a-block-device/
http://bryanapperson.com/blog/mounting-rbd-at-boot-under-centos-7/
https://tracker.ceph.com/projects/ceph/wiki/10_Commands_Every_Ceph_Administrator_Should_Know
# Setup Three Node Ceph Storage Cluster on Ubuntu 18.04
https://kifarunix.com/setup-three-node-ceph-storage-cluster-on-ubuntu-18-04/
# Ceph Octopus running on Debian Buster
https://ralph.blog.imixs.com/2020/04/14/ceph-octopus-running-on-debian-buster/
# Kubernetes – Storage Volumes with Ceph
https://ralph.blog.imixs.com/2020/02/21/kubernetes-storage-volumes-with-ceph/
# Rook Best Practices for Running Ceph on Kubernetes
https://documentation.suse.com/sbp/all/html/SBP-rook-ceph-kubernetes/index.html

# Ceph Storage
https://www.virtualtothecore.com/adventures-ceph-storage-part-1-introduction/

# Ceph Pacific running on Debian 11 (Bullseye)
https://ralph.blog.imixs.com/2021/10/03/ceph-pacific-running-on-debian-11-bullseye/

# Ceph Octopus running on Debian Buster
https://ralph.blog.imixs.com/2020/04/14/ceph-octopus-running-on-debian-buster/

# Kubernetes – Storage Volumes with Ceph
https://ralph.blog.imixs.com/2020/02/21/kubernetes-storage-volumes-with-ceph/

# https://documentation.suse.com/sbp/all/html/SBP-rook-ceph-kubernetes/index.html
https://documentation.suse.com/sbp/all/html/SBP-rook-ceph-kubernetes/index.html

# Monitoring of a Ceph Cluster with Ceph-dash on CentOS 7
https://www.howtoforge.com/tutorial/monitoring-of-a-ceph-cluster-with-ceph-dash/
https://www.server-world.info/en/note?os=CentOS_8&p=ceph15&f=6
https://docs.ceph.com/en/mimic/mgr/dashboard/

# Installing Ceph the Easy-Peasy Way
https://ceph.io/en/news/blog/2019/red-hat-ceph-4-easy-peasy-installation/

# 5 Ceph storage questions answered and explained
https://www.techtarget.com/searchstorage/feature/5-Ceph-storage-questions-answered-and-explained

# Ceph - Add Disk To Cluster
https://blog.programster.org/ceph-add-disk-to-cluster

# How many OSD are down, Ceph will lost the data
# That depends which OSDs are down. If ceph has enough time and space to recover a failed OSD then your cluster could survive two failed OSDs of an acting set. But then again, it also depends on your actual configuration (ceph osd tree) and rulesets. Also keep in mind that in order to rebalance after an OSD failed your cluster can fill up quicker since it lost a whole OSD. The recovery starts when an OSD has been down for 10 minutes, then it is marked as "out" and the remapping begins.
#-----------------------------------------------------------------------

# Other Reference
https://www.howtoforge.com/tutorial/monitoring-of-a-ceph-cluster-with-ceph-dash/
https://www.server-world.info/en/note?os=CentOS_8&p=ceph15&f=6
https://docs.ceph.com/en/mimic/mgr/dashboard/
