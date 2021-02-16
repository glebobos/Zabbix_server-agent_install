#!/bin/bash
# Install zabbix agent \ client and server

# Additions
# ---------------------------------------------------\
Info() {
	printf "\033[1;32m$@\033[0m\n"
}

Error()
{
	printf "\033[1;31m$@\033[0m\n"
}

isRoot() {
	if [ $(id -u) -ne 0 ]; then
		Error "You must be root user to continue"
		exit 1
	fi
	RID=$(id -u root 2>/dev/null)
	if [ $? -ne 0 ]; then
		Error "User root no found. You should create it to continue"
		exit 1
	fi
	if [ $RID -ne 0 ]; then
		Error "User root UID not equals 0. User root must have UID 0"
		exit 1
	fi
}

isRoot

# Vars
# ---------------------------------------------------
SERVER_IP=$1
HOST_IP=$(hostname -I | awk '{print $2;}')
HOST_NAME=$(hostname)
# NEW Check installed agent and server
#-----------------------------------------------------
if [[ -f /etc/zabbix/zabbix_server.conf ]]; then
	echo "Add zabbix agent to $HOST_IP"
else
	if [ -z "$1" ]; then
    Error "\nPlease call '$0 <Zabbix Server IP>' to run this command!\n"
    exit 1
	fi
fi

# Installation
# ---------------------------------------------------\

yum install epel-release -y

rpm -Uvh https://repo.zabbix.com/zabbix/4.4/rhel/7/x86_64/zabbix-release-4.4-1.el7.noarch.rpm

yum install zabbix-agent -y

# Configure local zabbix agent for server and host. check /etc/zabbix/zabbix_server.conf
#------------------------------------------------------
if [[ -f /etc/zabbix/zabbix_server.conf ]]; then
sed -i "s/^\(Server=\).*/\1"127.0.0.1,localhost,$SERVER_IP"/" /etc/zabbix/zabbix_agentd.conf
else 
sed -i "s/^\(Server=\).*/\1"$SERVER_IP"/" /etc/zabbix/zabbix_agentd.conf
fi
sed -i "s/^\(ServerActive\).*/\1="$SERVER_IP"/" /etc/zabbix/zabbix_agentd.conf
sed -i "s/^\(Hostname\).*/\1="$HOST_NAME"/" /etc/zabbix/zabbix_agentd.conf

# Configure firewalld
# ---------------------------------------------------\
firewall-cmd --permanent  --add-port=10050/tcp
firewall-cmd --reload

# Enable and start agent
# ---------------------------------------------------\
systemctl enable zabbix-agent && systemctl start zabbix-agent

# ---------------------------------------------------\
echo -e ""
Info "Done!"
if [[ -f /etc/zabbix/zabbix_server.conf ]]; then
Info "Enjoy!"
else
Info "Now, you must add this host to your Zabbix server in the Configuration > Hosts area"
Info "This host ip - $HOST_IP"
fi
