#!/bin/bash
# Install Zabbix server
# ---------------------------------------------------
SCRIPT_PATH=$(cd `dirname "${BASH_SOURCE[0]}"` && pwd)
DBpass="Passw0rd" #using one pass forall
#-----add showing------
Info() {
        printf "\033[1;32m$@\033[0m\n"
}

Error()
{
        printf "\033[1;31m$@\033[0m\n"
}

#--------------------Su checking function----------------------
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
#----------------Installed server checking function--------------------------
checkzabbix() {
	if [ -f "/etc/zabbix/zabbix_server.conf" ]; then
                echo "Zabbix Server already installed"
                exit 1
        fi
}
#-----------------Vars------------------------------
SERVER_IP=$(hostname -I | awk '{print $2;}') # choose second adapter
isRoot

#NEW -------- Install Httpd---------

yum -y install httpd && systemctl enable httpd && systemctl start httpd


#-------------------ADDING ZABBIX REPOSITORY--------------------

# wget --no-check-certificate  https://repo.zabbix.com/zabbix/4.4/rhel/7/x86_64/zabbix-release-4.4-1.el7.noarch.rpm
# rpm -Uvh zabbix-release-4.4-1.el7.noarch.rpm

 rpm -Uvh https://repo.zabbix.com/zabbix/4.4/rhel/7/x86_64/zabbix-release-4.4-1.el7.noarch.rpm

#-------- Need to enable repository of optional rpms in the system you will run Zabbix frontend on----

yum-config-manager --enable rhel-7-server-optional-rpms

#-----------Install and configure Maria sql
# ---------------------------------------------------

yum -y install mariadb mariadb-server

# my.cnf additional settings for InnoDB log rotate

touch /etc/my.cnf.d/innolog.conf
cat >> /etc/my.cnf.d/innolog.conf <<_EOF_
# Innodb
innodb_file_per_table
#
innodb_log_group_home_dir = /var/lib/mysql/
ninnodb_buffer_pool_size = 4G
innodb_additional_mem_pool_size = 16M
#
innodb_log_files_in_group = 2
innodb_log_file_size=512M
innodb_log_buffer_size = 8M
innodb_lock_wait_timeout = 120
#
innodb_thread_concurrency = 4
innodb_flush_log_at_trx_commit = 2
innodb_flush_method = O_DIRECT
#
#wsrep_provider_options="gcache.size=128M"
_EOF_

# Enable and start MariaDB

systemctl enable mariadb && systemctl start mariadb

# mysql_secure_installation, dont need, but could be useful in big deals
mysql --user=root <<_EOF_
  UPDATE mysql.user SET Password=PASSWORD('${DBpass}') WHERE User='root';
  DELETE FROM mysql.user WHERE User='';
  DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
  DROP DATABASE IF EXISTS test;
  DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
  FLUSH PRIVILEGES;
_EOF_
#create zabbix DB and user
cat <<EOF | mysql -uroot -p$DBpass
create database zabbix character set utf8 collate utf8_bin;
grant all privileges on zabbix.* to zabbix@localhost identified by '${DBpass}';
flush privileges;
EOF

#SERVER/FRONTEND INSTALLATION with MySQL/Apache support

yum -y install zabbix-server-mysql zabbix-web-mysql httpd -y

# import initial schema and data for the server with MySQL:

zcat /usr/share/doc/zabbix-server-mysql*/create.sql.gz | mysql -uroot -p$DBpass zabbix

#CONFIGURE DATABASE FOR ZABBIX SERVER, edit zabbix_server.conf to use their respective databases

sed -i 's/# DBHost=.*/DBHost=localhost/' /etc/zabbix/zabbix_server.conf
sed -i 's/# DBName=.*/DBName=zabbix/' /etc/zabbix/zabbix_server.conf
sed -i 's/# DBUser=.*/DBUser=zabbix/' /etc/zabbix/zabbix_server.conf
sed -i "s/# DBPassword=.*/DBPassword="$DBpass"/" /etc/zabbix/zabbix_server.conf
#ZABBIX FRONTEND CONFIGURATION, RHEL 7 it's necessary to uncomment and set the right date.timezone setting for you.

sed -i "s/^\;date.timezone.*/date.timezone = \'"Europe"\/"Minsk"\'/" /etc/php.ini #varible could be use, but

# Create zabbix.conf.php without manual job
# ---------------------------------------------------
touch /etc/zabbix/web/zabbix.conf.php
cat >> /etc/zabbix/web/zabbix.conf.php <<_EOF_
<?php
// Zabbix GUI configuration file.
global \$DB;

\$DB['TYPE']     = 'MYSQL';
\$DB['SERVER']   = 'localhost';
\$DB['PORT']     = '0';
\$DB['DATABASE'] = 'zabbix';
\$DB['USER']     = 'zabbix';
\$DB['PASSWORD'] = '${DBpass}';

// Schema name. Used for IBM DB2 and PostgreSQL.
\$DB['SCHEMA'] = '';

\$ZBX_SERVER      = 'localhost';
\$ZBX_SERVER_PORT = '10051';
\$ZBX_SERVER_NAME = '';

\$IMAGE_FORMAT_DEFAULT = IMAGE_FORMAT_PNG;
_EOF_

# Firewall adaptation
# ---------------------------------------------------
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-port=10051/tcp
firewall-cmd --permanent --add-port=10050/tcp
firewall-cmd --reload

# SElinux adaptation
# ---------------------------------------------------
setsebool -P zabbix_can_network on
setsebool -P httpd_can_network_connect 1
setsebool -P httpd_can_connect_zabbix 1



# Enable and start zabbix, restart httpd services
systemctl restart httpd
systemctl enable zabbix-server && systemctl start zabbix-server

# ---------------------------------------------------
#-------0015719: SELinux is preventing /usr/sbin/zabbix_server_mysql from 'create' accesses on the sock_file /var/run/zabbix/zabbix_server_pre...
#----/var/run/zabbix/zabbix_server_preprocessing.sock permission denied------
#-NEW-----create a new SELinux policy module file----
touch zabbix_server_add.te
cat >> zabbix_server_add.te <<EOF
module zabbix_server_add 1.1;

require {
        type zabbix_var_run_t;
        type tmp_t;
        type zabbix_t;
        class sock_file { create unlink write };
        class unix_stream_socket connectto;
        class process setrlimit;
        class capability dac_override;
}

#============= zabbix_t ==============

#!!!! This avc is allowed in the current policy
allow zabbix_t self:process setrlimit;

#!!!! This avc is allowed in the current policy
allow zabbix_t self:unix_stream_socket connectto;

#!!!! This avc is allowed in the current policy
allow zabbix_t tmp_t:sock_file { create unlink write };

#!!!! This avc is allowed in the current policy
allow zabbix_t zabbix_var_run_t:sock_file { create unlink write };

#!!!! This avc is allowed in the current policy
allow zabbix_t self:capability dac_override;
EOF

# ====convert the 'zabbix_server_add.te' into the policy module using the checkmodule

checkmodule -M -m -o zabbix_server_add.mod zabbix_server_add.te

#=========compile the policy module 'zabbix_server_add.mod' using the semodule_package

semodule_package -m zabbix_server_add.mod -o zabbix_server_add.pp

#=========load the compiled policy module 'zabbix_server_add.pp' to the system

semodule -i zabbix_server_add.pp

#Small trick with my git
# wget https://github.com/glebobos/FinalExam/raw/main/mi-zabbixserver.pp
# semodule -i mi-zabbixserver.pp

# until [ $(systemctl is-active zabbix-server) == "active" ]
# do
#  echo "Waiting server..." 
# sleep 1
# done

# Fin.
#---------------------------------------------------\
echo -e "\nNow you can use Zabbix!\n\nLink to Zabbix server - http://$SERVER_IP/zabbix\nDB Password - $DBpass\nDefault login - Admin\nDefault password - zabbix\n"
echo -e "\nMariaDB root password - $DBpass\n"
echo -e "Zabbix:\nDBUser: zabbix\nDBPass: $DBpass\nLink to Zabbix server - http://$SERVER_IP/zabbix\n\nMariaDB\nROOTPass: $DBpass" > $SCRIPT_PATH/zabbix-creds.txt
echo -e "\nCredential data saved to - $SCRIPT_PATH/zabbix-creds.txt"


