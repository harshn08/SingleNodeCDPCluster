#! /bin/bash
echo "-- Configure and optimize the OS"
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag
echo "echo never > /sys/kernel/mm/transparent_hugepage/enabled" >> /etc/rc.d/rc.local
echo "echo never > /sys/kernel/mm/transparent_hugepage/defrag" >> /etc/rc.d/rc.local
# add tuned optimization https://www.cloudera.com/documentation/enterprise/6/6.2/topics/cdh_admin_performance.html
echo  "vm.swappiness = 1" >> /etc/sysctl.conf
sysctl vm.swappiness=1
timedatectl set-timezone UTC

echo "-- Install Java OpenJDK8 and other tools"
yum install -y java-1.8.0-openjdk-devel vim wget curl git bind-utils rng-tools
yum install -y epel-release
yum install -y python-pip

cp /usr/lib/systemd/system/rngd.service /etc/systemd/system/
systemctl daemon-reload
systemctl start rngd
systemctl enable rngd

echo "-- Configure networking"
PUBLIC_IP=`curl https://api.ipify.org/`
hostnamectl set-hostname `hostname -f`
#echo "`hostname -I` `hostname`" >> /etc/hosts
sed -i "s/HOSTNAME=.*/HOSTNAME=`hostname`/" /etc/sysconfig/network
systemctl disable firewalld
systemctl stop firewalld
setenforce 0
sed -i 's/SELINUX=.*/SELINUX=disabled/' /etc/selinux/config

echo "-- Install CM and MariaDB"

## CM 7
wget https://${username}:${password}@archive.cloudera.com/p/cm7/7.3.1/redhat7/yum/cloudera-manager.repo -P /etc/yum.repos.d/
sed -i "s/username=changeme/username=${username}/" /etc/yum.repos.d/cloudera-manager.repo
sed -i "s/password=changeme/password=${password}/" /etc/yum.repos.d/cloudera-manager.repo

## MariaDB 10.1
cat - >/etc/yum.repos.d/MariaDB.repo <<EOF
[mariadb]
name = MariaDB
baseurl = http://yum.mariadb.org/10.1/centos7-amd64
gpgkey=https://yum.mariadb.org/RPM-GPG-KEY-MariaDB
gpgcheck=1
EOF

yum clean all
rm -rf /var/cache/yum/
yum repolist

## CM
yum install -y cloudera-manager-agent cloudera-manager-daemons cloudera-manager-server

## MariaDB
yum install -y MariaDB-server MariaDB-client
cat conf/mariadb.config > /etc/my.cnf

echo "--Enable and start MariaDB"
systemctl enable mariadb
systemctl start mariadb

echo "-- Install JDBC connector"
wget https://dev.mysql.com/get/Downloads/Connector-J/mysql-connector-java-5.1.46.tar.gz -P ~
tar zxf ~/mysql-connector-java-5.1.46.tar.gz -C ~
mkdir -p /usr/share/java/
cp ~/mysql-connector-java-5.1.46/mysql-connector-java-5.1.46-bin.jar /usr/share/java/mysql-connector-java.jar
rm -rf ~/mysql-connector-java-5.1.46*

echo "-- Create DBs required by CM"
mysql -u root < scripts/create_db.sql

echo "-- Secure MariaDB"
mysql -u root < scripts/secure_mariadb.sql

echo "-- Prepare CM database 'scm'"
/opt/cloudera/cm/schema/scm_prepare_database.sh mysql scm scm cloudera

## PostgreSQL
#yum install -y postgresql-server python-pip
#pip install psycopg2==2.7.5 --ignore-installed
#echo 'LC_ALL="en_US.UTF-8"' >> /etc/locale.conf
#sudo su -l postgres -c "postgresql-setup initdb"
#cat conf/pg_hba.conf > /var/lib/pgsql/data/pg_hba.conf
#cat conf/postgresql.conf > /var/lib/pgsql/data/postgresql.conf
#echo "--Enable and start pgsql"
#systemctl enable postgresql
#systemctl restart postgresql


## PostgreSQL see: https://www.postgresql.org/download/linux/redhat/
yum install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-7-x86_64/pgdg-redhat-repo-latest.noarch.rpm
yum install -y postgresql96
yum install -y postgresql96-server
pip install psycopg2==2.7.5 --ignore-installed

echo 'LC_ALL="en_US.UTF-8"' >> /etc/locale.conf
/usr/pgsql-9.6/bin/postgresql96-setup initdb

cat conf/pg_hba.conf > /var/lib/pgsql/9.6/data/pg_hba.conf
cat conf/postgresql.conf > /var/lib/pgsql/9.6/data/postgresql.conf

echo "--Enable and start pgsql"
systemctl enable postgresql-9.6
systemctl start postgresql-9.6

echo "-- Create DBs required by CM"
sudo -u postgres psql <<EOF
CREATE DATABASE ranger;
CREATE USER ranger WITH PASSWORD 'cloudera';
GRANT ALL PRIVILEGES ON DATABASE ranger TO ranger;
CREATE DATABASE das;
CREATE USER das WITH PASSWORD 'cloudera';
GRANT ALL PRIVILEGES ON DATABASE das TO das;
EOF

# install local CSDs
mv ~/*.jar /opt/cloudera/csd/
mv /home/centos/*.jar /opt/cloudera/csd/
chown cloudera-scm:cloudera-scm /opt/cloudera/csd/*
chmod 644 /opt/cloudera/csd/*

echo "-- Install local parcels"
mv ~/*.parcel ~/*.parcel.sha /opt/cloudera/parcel-repo/
mv /home/centos/*.parcel /home/centos/*.parcel.sha /opt/cloudera/parcel-repo/
chown cloudera-scm:cloudera-scm /opt/cloudera/parcel-repo/*

echo "-- Enable passwordless root login via rsa key"
ssh-keygen -f ~/myRSAkey -t rsa -N ""
mkdir ~/.ssh
cat ~/myRSAkey.pub >> ~/.ssh/authorized_keys
chmod 400 ~/.ssh/authorized_keys
ssh-keyscan -H `hostname` >> ~/.ssh/known_hosts
sed -i 's/.*PermitRootLogin.*/PermitRootLogin without-password/' /etc/ssh/sshd_config
systemctl restart sshd

echo "-- Start CM, it takes about 2 minutes to be ready"
systemctl start cloudera-scm-server