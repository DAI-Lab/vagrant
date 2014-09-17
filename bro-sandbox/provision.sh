#!/bin/bash
# Author: Jon Schipp <jonschipp@gmail.com>
# Written for Ubuntu Saucy and Trusty, should be adaptable to other distros.

## Variables
VAGRANT=/home/vagrant
if [ -d $VAGRANT ]; then
	HOME=/home/vagrant
else
	HOME=/root
fi

# Installation notification
COWSAY=/usr/games/cowsay
IRCSAY=/usr/local/bin/ircsay
IRC_CHAN="#replace_me"
HOST=$(hostname -s)
LOGFILE=/root/bro-sandbox_install.log
EMAIL=user@company.com

# System Configuration
DOCKER_FILE="Dockerfile-2.3.1" 			# Build image from specific Dockerfile. Default builds Bro 2.3.1
CONTAINER_DESTINATION= 				# Put containers on another volume e.g. /dev/sdb1 (optional). You must mkfs.$FS first!
FS="ext4"					# Filesystem type for CONTAINER_DESTINATION, used for mounting
IMAGE="bro-2.3.1"		 		# Assign a different name to the image (optional)
USER="demo" 					# User account to create for that people will ssh into to enter container
PASS="demo" 					# Password for the account that users will ssh into
DB=/var/tmp/sandbox_db 				# Credentials database, must be readable by $USER
SCRIPTS_DIR=/usr/local/bin 			# Directory to install admin scripts
CONFIG_DIR=/etc/sandbox 			# Directory to install configuration and scripts
CONFIG="$CONFIG_DIR/sandbox.conf" 		# Global configuration file
SHELL="$CONFIG_DIR/sandbox_shell"		# $USER's shell: displays login banner then launches sandbox_login
LAUNCH_CONTAINER="$CONFIG_DIR/sandbox_login"	# User management script and container launcher
BASENAME="brolive"				# Container prefix as $BASENAME.$USERNAME, used for re-attachment.

# Container configuration (applies to each container)
DAYS=3	       # Container lifetime specified in days, removed after x days
VIRTUSER=demo  # Account used when container is entered (Must exist in container!)
CPU=1          # Number of CPU's allocated to each container
RAM=256m       # Amount of memory allocated to each container
HOSTNAME=bro   # Cosmetic: Will end up as $USER@$HOSTNAME:~$ in shell
NETWORK=none   # Disable networking by default: none; Enable networking: bridge
DNS=127.0.0.1  # Use loopback when networking is disabled to prevent error messages

# Get Ubuntu distribution information
source /etc/lsb-release

# Logging
exec > >(tee -a "$LOGFILE") 2>&1
echo -e "\n --> Logging stdout & stderr to $LOGFILE"

# Must run as root
if [ $UID -ne 0 ]; then
	echo "Script must be run as root user, exiting..."a
	exit 1
fi

cd $HOME

function die {
    if [ -f ${COWSAY:-none} ]; then
        $COWSAY -d "$*"
    else
        echo "$*"
    fi
    if [ -f $IRCSAY ]; then
        ( set +e; $IRCSAY "$IRC_CHAN" "$*" 2>/dev/null || true )
    fi
    echo "$*" | mail -s "[vagrant] Bro Sandbox install information on $HOST" $EMAIL
    exit 1
}

function hi {
    if [ -f ${COWSAY:-none} ]; then
        $COWSAY "$*"
    else
        echo "$*"
    fi
    if [ -f $IRCSAY ]; then
        ( set +e; $IRCSAY "$IRC_CHAN" "$*" 2>/dev/null || true )
    fi
    echo "$*" | mail -s "[vagrant] Bro Sandbox install information on $HOST" $EMAIL
}

function logo {
cat <<"EOF"
===========================================

		Bro
	    -----------
	  /             \
	 |  (   (0)   )  |
	 |            // |
	  \     <====// /
	    -----------

	Web: http://bro.org

===========================================

EOF
}

no_vagrant_setup() {
local COUNT=0
local SUCCESS=0
local FILES="
https://raw.githubusercontent.com/jonschipp/vagrant/master/bro-sandbox/$DOCKER_FILE
https://raw.githubusercontent.com/jonschipp/vagrant/master/bro-sandbox/etc.default.docker
https://raw.githubusercontent.com/jonschipp/vagrant/master/bro-sandbox/sandbox.cron
https://raw.githubusercontent.com/jonschipp/vagrant/master/bro-sandbox/scripts/remove_old_containers
https://raw.githubusercontent.com/jonschipp/vagrant/master/bro-sandbox/scripts/remove_old_users
https://raw.githubusercontent.com/jonschipp/vagrant/master/bro-sandbox/scripts/disk_limit
https://raw.githubusercontent.com/jonschipp/vagrant/master/bro-sandbox/scripts/sandbox_login
https://raw.githubusercontent.com/jonschipp/vagrant/master/bro-sandbox/scripts/sandbox_shell
"

echo -e "Downloading required configuration files!\n"

for url in $FILES
do
	COUNT=$((COUNT+1))
	wget $url 2>/dev/null
	if [ $? -ne 0 ]; then
		echo "$COUNT - Download for $url failed!"
	else
		echo "$COUNT - Success! for $url"
		SUCCESS=$((SUCCESS+1))
	fi
done
echo
}

function install_docker() {
local ORDER=$1
echo -e "$ORDER Installing Docker!\n"

# Check that HTTPS transport is available to APT
if [ ! -e /usr/lib/apt/methods/https ]; then
	apt-get update
	apt-get install -y apt-transport-https
	echo
fi

# Add the repository to your APT sources
# Then import the repository key
if [ ! -e /etc/apt/sources.list.d/docker.list ]
then
	echo deb https://get.docker.io/ubuntu docker main > /etc/apt/sources.list.d/docker.list
	apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 36A1D7869245C8950F966E92D8576A8BA88D21E9
	echo
fi

# Install docker
if ! command -v docker >/dev/null 2>&1
then
	apt-get update
	apt-get install -y lxc-docker
	echo
fi
}

function user_configuration() {
local ORDER=$1
local SSH_CONFIG=/etc/ssh/sshd_config
local RESTART_SSH=0
echo -e "$ORDER Configuring the $USER user account!\n"

if [ ! -e /etc/sudoers.d/sandbox ]; then
cat > /etc/sudoers.d/sandbox <<EOF
Cmnd_Alias SANDBOX = /usr/bin/docker
$USER ALL=(root) NOPASSWD: SANDBOX
EOF
chmod 0440 /etc/sudoers.d/sandbox && chown root:root /etc/sudoers.d/sandbox
fi

# Create scripts directory if it doesn't exist
if [ ! -d $CONFIG_DIR ]; then
	mkdir -p $CONFIG_DIR
fi

if ! grep -q sandbox /etc/shells
then
	sh -c "echo $SHELL >> /etc/shells"
fi

if ! getent passwd $USER 1>/dev/null
then
	adduser --disabled-login --gecos "" --shell $SHELL $USER
	echo "$USER:$PASS" | chpasswd
fi

if ! grep -q "ClientAliveInterval 15" $SSH_CONFIG
then
	echo -e "\nClientAliveInterval 15\nClientAliveCountMax 10\n" >> $SSH_CONFIG
	RESTART_SSH=1
fi

if grep -q "PasswordAuthentication no" $SSH_CONFIG
then
	if ! grep -q "Match User $USER" $SSH_CONFIG
	then
		echo -e "\nMatch User $USER\n\tPasswordAuthentication yes\n" >> $SSH_CONFIG
		RESTART_SSH=1
	fi
fi

if ! grep -q '^#Subsystem sftp' $SSH_CONFIG
then
	sed -i '/^Subsystem sftp/s/^/#/' $SSH_CONFIG
	RESTART_SSH=1
fi

if [ $RESTART_SSH -eq 1 ]
then
	restart ssh
	echo
fi
}

function system_configuration() {
local ORDER=$1
local LIMITS=/etc/security/limits.d
echo -e "$ORDER Configuring the system for use!\n"

if [ -e $HOME/sandbox_shell ]; then
	install -o root -g root -m 755 $HOME/sandbox_shell $SHELL
fi

if [ -e $HOME/sandbox_login ]; then
	install -o root -g root -m 755 $HOME/sandbox_login $CONFIG_DIR/sandbox_login
fi

if [ -e $HOME/sandbox.cron ]; then
	install -o root -g root -m 644 $HOME/sandbox.cron /etc/cron.d/sandbox
fi

if [ ! -e $LIMITS/fsize.conf ]; then
	echo "*                hard    fsize           1000000" > $LIMITS/fsize.conf
fi

if [ ! -e $LIMITS/nproc.conf ]; then
	echo "*                hard    nproc           10000" > $LIMITS/nproc.conf
fi
}

function install_configuration_file() {
if [ ! -f $CONFIG ]; then

echo -e "Installing global configuration file to ${CONFIG}!\n"

echo "# System Configuration"		 									>> $CONFIG
echo "IMAGE=\"$IMAGE\"       # Default: launch containers from this image" 					>> $CONFIG
echo "CONFIG_DIR=\"$CONFIG_DIR\"" 	 									>> $CONFIG
echo "SHELL=\"$SHELL\"       # User's shell: displays login banner then launches sandbox_login"    		>> $CONFIG
echo "LAUNCH_CONTAINER=\"$LAUNCH_CONTAINER\"       # User management script and container launcher"		>> $CONFIG
echo "DB=\"$DB\"             # Credentials database, must be readable by \$USER"				>> $CONFIG
echo "BASENAME=\"$BASENAME\" # Container prefix as \$BASENAME.\$USERNAME, Used for re-attachment." 		>> $CONFIG
echo 														>> $CONFIG
echo "# Container Configuration"										>> $CONFIG
echo "DAYS=\"$DAYS\" 	     # Container lifetime specified in days, removed after x days" 			>> $CONFIG
echo "VIRTUSER=\"$VIRTUSER\" # Account used when container is entered (Must exist in container!)"		>> $CONFIG
echo "CPU=\"$CPU\" 	     # Number of CPU's allocated to each container"					>> $CONFIG
echo "RAM=\"$RAM\"           # Amount of memory allocated to each container"					>> $CONFIG
echo "HOSTNAME=\"$HOSTNAME\" # Cosmetic: Will end up as \$USER@\$HOSTNAME:~\$ in shell" 			>> $CONFIG
echo "NETWORK=\"$NETWORK\"   # Disable networking by default: none; Enable networking: bridge"			>> $CONFIG
echo "DNS=\"$DNS\"           # Use loopback when networking is disabled to prevent error messages"		>> $CONFIG

fi
}

function container_scripts(){
local ORDER=$1
echo -e "$ORDER Installing container maintainence scripts!\n"

for FILE in disk_limit remove_old_containers remove_old_users
do
	if [ -e $HOME/$FILE ]; then
		install -o root -g root -m 750 $HOME/$FILE $SCRIPTS_DIR/sandbox_${FILE}
	fi
done
}

function docker_configuration() {
local ORDER=$1
local DEFAULT=/etc/default/docker
local UPSTART=/etc/init/docker.conf

echo -e "$ORDER Installing the Bro Sandbox Docker image!\n"


if ! grep -q "limit fsize" $UPSTART
then
	sed -i '/limit nproc/a limit fsize 500000000 500000000' $UPSTART
fi

if ! grep -q "limit nproc 524288 524288" $UPSTART
then
	sed -i '/limit nproc/s/[0-9]\{1,8\}/524288/g' $UPSTART
fi

if [[ "$DISTRIB_CODENAME" == "saucy" || "$DISTRIB_CODENAME" == "trusty" ]]
then
	# Devicemapper allows us to limit container sizes for security
	# https://github.com/docker/docker/tree/master/daemon/graphdriver/devmapper
	if ! grep -q devicemapper $DEFAULT
	then
		echo -e " --> Using devicemapper as storage backend\n"
		install -o root -g root -m 644 $HOME/etc.default.docker $DEFAULT

		if [ -d /var/lib/docker ]; then
			rm -rf /var/lib/docker/*
		fi

		if [ ! -z $CONTAINER_DESTINATION ]; then

			if ! mount | grep -q $CONTAINER_DESTINATION ; then
				mount -o defaults,noatime,nodiratime $CONTAINER_DESTINATION /var/lib/docker
			fi

			if ! grep -q $CONTAINER_DESTINATION /etc/fstab 2>/dev/null; then
				echo -e "${CONTAINER_DESTINATION}\t/var/lib/docker\t${FS}\tdefaults,noatime,nodiratime,nobootwait\t0\t1" >> /etc/fstab
			fi
                fi

		mkdir -p /var/lib/docker/devicemapper/devicemapper
		restart docker
		sleep 5
	fi
fi

if ! docker images | grep -q $IMAGE
then
	if [ -e $HOME/$DOCKER_FILE ]; then
		docker build -t $IMAGE - < $HOME/$DOCKER_FILE
	else
		docker pull jonschipp/latest-bro-sandbox
		docker tag jonschipp/latest-bro-sandbox $IMAGE
	fi
fi
}

training_configuration() {
local COUNT=0
local SUCCESS=0
local FILES="
http://www.bro.org/downloads/archive/bro-2.2.tar.gz
http://www.bro.org/downloads/archive/bro-2.1.tar.gz
http://www.bro.org/downloads/archive/bro-2.0.tar.gz
http://www.bro.org/downloads/archive/bro-1.5.tar.gz
http://www.bro.org/downloads/archive/bro-1.4.tar.gz
http://www.bro.org/downloads/archive/bro-1.3.tar.gz
http://www.bro.org/downloads/archive/bro-1.2.tar.gz
http://www.bro.org/downloads/archive/bro-1.1.tar.gz
http://www.bro.org/downloads/archive/bro-1.0.tar.gz
http://www.bro.org/downloads/archive/bro-0.9-stable.tar.gz
"
echo -e "Applying training configuration!\n"

if [ ! -d /exercises ]
then
	mkdir /exercises
fi

if [ ! -d /versions ]
then
	mkdir /versions
	cd /versions

	for url in $FILES
	do
		COUNT=$((COUNT+1))
		wget $url 2>/dev/null
		if [ $? -ne 0 ]; then
			echo "$COUNT - Download for $url failed!"
		else
			echo "$COUNT - Success! for $url"
			SUCCESS=$((SUCCESS+1))
		fi
done

cat > /versions/README <<EOF
* Still in development: compilation fails *

This is mostly for fun, to see how Bro has changed over time.

/versions is mounted read-only.
You must copy a release tarball to your home directory and compile it there to play with it. e.g.

$ cp /versions/bro-2.0.tar.gz ~/
$ cd bro-2.0
$ ./configure
$ make
$ ./build/src/bro

EOF
fi
}

sample_exercises() {
local DIR=/exercises
echo -e "Installing sample exercises!\n"
if [ ! -d $DIR ]; then
	mkdir /exercises
fi

cd $DIR

if [ ! -d $DIR/BroCon14 ]
then
	wget http://www.bro.org/static/BroCon14/BroCon14.tar.gz 2>/dev/null
	if [ $? -ne 0 ]; then
		echo "$COUNT - Download for $url failed!"
	else
		echo "$COUNT - Success! for $url"
	fi
	tar zxf BroCon14.tar.gz
	rm -f BroCon14.tar.gz
fi
}

logo

# Run if not using Vagrant (We have to get the files another way)
if [ ! -d $VAGRANT ]; then
	no_vagrant_setup
fi

install_docker "1.)"
user_configuration "2.)"
system_configuration "3.)"
container_scripts "4.)"
docker_configuration "5.)"
install_configuration_file "6.)"
#training_configuration "6.)"
sample_exercises "7.)"

echo
if [ -d $VAGRANT ]; then
        echo "Try it out: ssh -p 2222 $USER@127.0.0.1 -o UserKnownHostsFile=/dev/null"
else
        echo "Try it out: ssh $USER@<ip> -o UserKnownHostsFile=/dev/null"
fi
