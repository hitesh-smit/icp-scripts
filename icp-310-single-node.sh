#!/bin/bash

: '
    Copyright (C) 2018 IBM Corporation
    Licensed under the Apache License, Version 2.0 (the “License”);
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at
    http://www.apache.org/licenses/LICENSE-2.0
    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an “AS IS” BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.

    Contributors:
        * Rafael Sene <rpsene@br.ibm.com>
 
    README: 
    
            This script executes the installation of a single node of ICP 3.1.0.
            If you want to install the Enterprise Edition, you need to set the 
            ICP_FILE_URL accordingly to ensure you can download/copy 
            the offline package from the right place. 
            
            In order to use this script, you need to set the version of ICP you
            want to install (ce, for community or ee, for enterprise only if 
            you have access to it). 
            
                Example: ./icp-310-single-node.sh ce, will install ICP CE.

            You can also set a public IP for the ICP UI, so it can be accessible
            after the installation process. This is not required, but we strongly
            recomend.

                Example: ./icp-310-single-node.sh ce 1.2.3.4 (assuming 1.2.3.4 is
                a public IP), this will install ICP ce and use 1.2.3.4 as the
                address where the ICP UI will be available.
            
            If you use only ./icp-310-single-node.sh ce, this will create
            a cluster with a internal IP assign. In this case you may need
            a ssh tunnel to access the ICP UI.

            Execute it as root :)
'

# Trap ctrl-c and call ctrl_c()
trap ctrl_c INT

function ctrl_c() {
        echo "Bye!"
}

# Get the main IP of the host
HOSTNAME_IP=$(ip route get 1 | awk '{print $NF;exit}')
HOSTNAME=$(hostname)

# Move to the root directory
cd /root || exit

# ICP Installation directory
ICP_LOCATION=/opt/ibm-cp-app-mod-3.1.0

if [ -z "$2" ]; then
    EXTERNAL_IP=$HOSTNAME_IP  
else
    EXTERNAL_IP=$2
fi

# Create SSH Key and overwrite any already created
yes y | ssh-keygen -t rsa -f /root/.ssh/id_rsa -q -P ""

# Add this ssh-key in the authorized_keys
cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys

# Updating, upgrading and installing some packages
export DEBIAN_FRONTEND=noninteractive
apt-get update -yq
apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade -yq
apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -yq vim python git socat

# Installing Docker
if [ ! -d docker_on_power ]; then
    git clone https://github.com/Unicamp-OpenPower/docker.git
fi
./docker/install_docker.sh

# Configuring ICP details (as described in the documentation)
sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf
sysctl -w net.ipv4.ip_local_port_range="10240  60999"
echo 'net.ipv4.ip_local_port_range="10240 60999"' | sudo tee -a /etc/sysctl.conf

# Check ports
if [ ! -d icp-scripts ]; then
    git clone https://github.com/rpsene/icp-scripts.git
fi
./icp-scripts/check_ports.py

# Configure network (/etc/hosts)
# This line is required for a OpenStack or PowerVC environment
sed -i -- 's/manage_etc_hosts: true/manage_etc_hosts: false/g' /etc/cloud/cloud.cfg

sed -i '/127.0.1.1/s/^/#/g' /etc/hosts
sed -i '/ip6-localhost/s/^/#/g' /etc/hosts
echo -e "$HOSTNAME_IP $HOSTNAME" | tee -a /etc/hosts

# Disable StrictHostKeyChecking ask
sed -i -- 's/#   StrictHostKeyChecking ask/StrictHostKeyChecking no/g' /etc/ssh/ssh_config

case $1 in
     ce)
            echo "Installing ICP 3.1.0 CE"
            INCEPTION=ibmcom/icp-inception:3.1.0
            docker pull $INCEPTION
            ;;
     ee)
            echo "Installing ICP 3.1.0 EE"
            # ICP Variables
            ICP_FILE=ibm-cloud-private-ppc64le-3.1.0.tar.gz
            ICP_FILE_URL=<SET_THE_URL_HERE>/$ICP_FILE
            INCEPTION=ibmcom/icp-inception-$(uname -m):3.1.0-ee
            wget $ICP_FILE_URL
            tar xf $ICP_FILE -O | docker load
            ;;
     *)
          echo "Hmm, seems you are missing the ICP version."
          exit 0
          ;;
esac

# Prepare environment for ICP installation
mkdir -p $ICP_LOCATION && cd $ICP_LOCATION || exit
docker run -v "$(pwd)":/data -e LICENSE=accept $INCEPTION cp -r cluster /data
cp /root/.ssh/id_rsa ./cluster/ssh_key

if [ "$1" == "ee" ]; then
    mkdir -p ./cluster/images
    mv /root/$ICP_FILE ./cluster/images/
fi

cd ./cluster || exit

# Remove the content of the hosts file
> ./hosts

# Add the IP of the single node in the hosts file
echo "
[master]
$HOSTNAME_IP

[worker]
$HOSTNAME_IP

[proxy]
$HOSTNAME_IP

#[management]
#4.4.4.4

#[va]
#5.5.5.5
" >> ./hosts

echo "
image-security-enforcement:
   clusterImagePolicy:
     - name: "docker.io/ibmcom/*"
       policy:
" >> ./config.yaml

# Replace the entries in the config file to remove the comments of the external IPs
sed -i -- "s/# cluster_lb_address: none/cluster_lb_address: $EXTERNAL_IP/g" ./config.yaml
sed -i -- "s/# proxy_lb_address: none/proxy_lb_address: $EXTERNAL_IP/g" ./config.yaml

# Install ICP
docker run --net=host -t -e LICENSE=accept -v "$(pwd)":/installer/cluster $INCEPTION install
