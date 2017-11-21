#!/bin/bash
#
# $Id: install-init.sh 3.26 2017-10-21 00:45:29 rob.navarro $
#
# install init scripts, including the machine agent.
#
# Copyright 2016 AppDynamics, Inc
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
#
export PATH=/bin:/usr/bin:/sbin:/usr/sbin

cd $(dirname $0)

function usage {
	echo "$0 [-options] where:"
	echo "   -c  # use setuid c wrapper"
	echo "   -s  # use sudo"
	echo "   -p  # use pbrun wrapper"
	echo "   -x  # use user privilege wrapper"
	echo "   -a  <Machine Agent install directory>"
	exit 1
}

APPD_ROOT=`readlink -e ..`

LOGFNAME=install-init.log

PBRUN_PLACES="/usr/local/bin/pbrun /usr/bin/pbrun"
PBRUN=
for pbrun in $PBRUN_PLACES ; do
    if [ -x $pbrun ] ; then
        PBRUN=$pbrun
    fi
done

if [ `id -un` != root ] ; then
	echo install-init.sh must be run as root
	exit 1
fi

if ! [ -d $APPD_ROOT/bin ] ; then
	APPD_ROOT=/opt/AppDynamics/Controller
	echo using default path $APPD_ROOT
fi

# source function library
. $APPD_ROOT/HA/lib/log.sh
. $APPD_ROOT/HA/lib/runuser.sh
. $APPD_ROOT/HA/lib/ha.sh
. $APPD_ROOT/HA/lib/password.sh
. $APPD_ROOT/HA/lib/init.sh
. $APPD_ROOT/HA/lib/conf.sh

machine_agent_service=""
machine_agent=""
use_pbrun=0
use_cwrapper=0
use_sudo=0
use_root=0
use_xuser=0

while getopts ":csprxa:" flag; do
	case $flag in
	x)
		use_xuser=1
		;;
	c)
		use_cwrapper=1
		;;
	s)
		use_sudo=1
		;;
	p)
		if [ -x $PBRUN ] ; then
			use_pbrun=1
		else
			echo pbrun not found in $PBRUN_PLACES
			exit 1
		fi
		;;
	a)	
		machine_agent=$(readlink -e "$OPTARG")
		if ! [ -f "$machine_agent/machineagent.jar" ] ; then
			echo "$machine_agent is not a machine agent install directory"
			exit 1
		fi
		;;
	:)	
		echo "option '$OPTARG' requires a value" 1>&2
		usage
		;;
	*)
		usage
		;;
	esac
done

echo "install-init.sh command line options" "$*" > $LOGFILE
echo "runuser $RUNUSER" >> $LOGFILE
date >> $LOGFILE
chown $RUNUSER $LOGFILE

#
# search for a machine agent in a few likely places
#
if [ -z "$machine_agent" ] ; then
	machine_agent=(`find_machine_agent`)
	if [ ${#machine_agent[@]} -gt 1 ] ; then
		echo too many machine agents: ${machine_agent[@]}
		echo select one, and specify it using -a
		usage
		exit 1
	fi
fi
if [ -n "$machine_agent" ] ; then
	machine_agent_service=appdynamics-machine-agent
	echo "found machine agent in $machine_agent"
fi

if [ `id -u` != 0 ] ; then
	echo $0 must be run as root
	exit 1
fi

# list of AppDynamics services in start order
APPDYNAMICS_SERVICE_LIST=( appdcontroller-db appdcontroller $machine_agent_service)

VENDOR=`lsb_release -i 2>/dev/null | awk '{print $3}'`

if echo $VENDOR | grep -iq ubuntu ; then
	#
	# Define explicit start and stop order lists for Ubuntu and other distros
	# were update-rc.d ignores the LSB dependency headers
	#
	APPDYNAMICS_SERVICE_START=( 90 91 92 )
	APPDYNAMICS_SERVICE_STOP=( 90 89 08 )
fi

APPDSERVICE=/sbin/appdservice

ROOTOWNER=`ls -ld $APPD_ROOT | awk '{print $3}'`
if [[ `id -u $RUNUSER` != "0" ]] ; then
	if [ `expr $use_cwrapper + $use_sudo + $use_pbrun + $use_xuser` == 0 ] ; then
		echo non-root MySQL usage requires at least one privilege escalation method
		usage
	fi
	if [ `expr $use_cwrapper + $use_pbrun + $use_xuser` -gt 1 ] ; then
		echo cwrapper, xuser and pbrun are mutually exclusive
		usage
	fi
else
	use_root=1
fi

CHKCONFIG=`which chkconfig 2>/dev/null`
UPDATE_RC_D=`which update-rc.d 2>/dev/null`
SERVICE=`which service 2>/dev/null`

function require {
	# args: executable "redhat package" "debian package" [ force|advise ] ["<reason package is required>"]
	local errors=0
	if ! [[  -x `which $1 2>/dev/null` ]] || [ "$4" == "force" ] ; then
		if [[ -x `which apt-get 2>/dev/null` ]] ; then
			if [ "$4" == "advise" ] ; then
				echo "Package $3 not installed."
				echo "$3 is required $5"
				return 1
			else
				if ! apt-get -qq -y install $3 && [ "$4" == "force" ] ; then
					errors=1
				fi
			fi
		elif [[ -x `which yum 2>/dev/null` ]] ; then
			if [ "$4" == "advise" ] ; then
				echo "Package $2 not installed."
				echo "$2 is required $5"
				return 1
			else
				if ! yum --quiet -y install $2 >/dev/null && [ "$4" == "force" ] ; then
					errors=1
				fi
			fi
		fi
		if ! [[  -x `which $1 2>/dev/null` ]] || [ "$errors" -gt 0 ] ; then
			echo "Unable to install package containing $1"
			return 1
		fi
	fi
}

#
# install the init function and ancillary config files for service $1
# with start priority $2 and stop priority $3
#
function install_init {
	local service=$1
	local start_pri=$2
	local stop_pri=$3

	echo "installing /etc/init.d/$service"
	rm -f /etc/init.d/$service			# remove potential sym links
	cp ./$service.sh /etc/init.d/$service
	chmod 0755 /etc/init.d/$service

	if [ -x "$CHKCONFIG" ] ; then
		chkconfig --add $service
		SYS_CONFIG_DIR=/etc/sysconfig
	elif [ -x "$UPDATE_RC_D" ] ; then
		update-rc.d -f $service remove 
		update-rc.d $service defaults $start_pri $stop_pri
		SYS_CONFIG_DIR=/etc/default
	else
		echo "unsupported linux distribution: chkconfig or update-rc.d required"
		exit 1
	fi

	echo "installing $SYS_CONFIG_DIR/$1"
	sysconfig_file=$service.sysconfig
	if [ ! -f $sysconfig_file ] ; then
		sysconfig_file=$service.sysconfig.template
	else
		echo using customized $service configuration file
	fi

	sed < $sysconfig_file > $SYS_CONFIG_DIR/$1 \
		-e "/^RUNUSER=/s,=.*,=$RUNUSER," \
		-e "/^APPD_ROOT=/s,=.*,=$APPD_ROOT," \
		-e "/^MACHINE_AGENT_HOME=/s,=.*,=$machine_agent,"
	chmod 644 $SYS_CONFIG_DIR/$service
}

#
# make sure we have xmllint, bc, and the right version of ping installed
#
missing_dependencies=0
require xmllint libxml2 libxml2-utils || ((missing_dependencies++))
require bc bc bc || ((missing_dependecies++))
require ex vim-minimal vim-tiny || ((missing_dependecies++))
require curl curl curl || ((missing_dependencies++))
if ! ping -q -W 1 -c 1 localhost >/dev/null ; then
	require ping iputils iputils-ping force || ((missing_dependencies++))
fi
if [ "$missing_dependencies" -gt 0 ] ; then
	exit 1
fi

#
# check that HA Toolkit has access to MySQL clients via password in any of:
#   MYSQL_ROOT_PASSWD - env variable
#   $APPD_ROOT/db/.rootpw
#   $APPD_ROOT/db/.rootpw.obf
#
get_mysql_passwd > /dev/null

#
# since our RUNUSER isn't root, we want to make it so that sudo works
# for our selected commands.   
# this is not a security hole, it is a controlled privilege escalation, really.
#
if [[ `id -u $RUNUSER` != "0" ]] ; then

	if [ $use_sudo == 1 ] ; then
		# Clean up C / pbrun wrappers if they were previously installed
		rm -f $APPDSERVICE 2>/dev/null
		require sudo sudo sudo || exit 1
		[ -d /etc/sudoers.d ] || mkdir /etc/sudoers.d && chmod 0750 /etc/sudoers.d
		grep -Eq "^#includedir[\t ]+/etc/sudoers.d[\t ]*$" /etc/sudoers || \
		grep -Eq "^#include[\t ]+/etc/sudoers.d/appdynamics[\t ]*$" /etc/sudoers || \
		echo "#include /etc/sudoers.d/appdynamics" >> /etc/sudoers
		if [ -x "$CHKCONFIG" ] ; then
			COMMA=
			for s in ${APPDYNAMICS_SERVICE_LIST[@]} ; do
				CMND_ALIAS_LIST="$CMND_ALIAS_LIST $COMMA \\
				$SERVICE $s *"
				COMMA=","
			done
		elif [ -x "$UPDATE_RC_D" ] ; then
			COMMA=
			for s in ${APPDYNAMICS_SERVICE_LIST[@]} ; do
				CMND_ALIAS_LIST="$CMND_ALIAS_LIST$COMMA \\
				$SERVICE $s *"
				COMMA=","
			done
		fi
		cat > /etc/sudoers.d/appdynamics <<- SUDOERS
		# allow appdynamics user to:
		#    start, stop, and query status of appdynamics via init scripts
		#    to enable and disable those init scripts
		Defaults:$RUNUSER !requiretty
		Cmnd_Alias APPD = $CMND_ALIAS_LIST
			$RUNUSER ALL=(root) NOPASSWD: APPD
		SUDOERS
		chmod 0440 /etc/sudoers.d/appdynamics
		echo "installed /etc/sudoers.d/appdynamics"
	fi

	if [ $use_cwrapper == 1 ] ; then
		if require cc gcc gcc advise "to build $APPDSERVICE privilege escalation wrapper" ; then
			# Clean up sudo privilege escalation if it was previously installed
			rm -f /etc/sudoers.d/appdynamics 2>/dev/null
			# catch case where previous $APPDSERVICE cannot be overwritten by compiler
			rm -f $APPDSERVICE 2> /dev/null
			if [[ -f "$APPDSERVICE" ]]; then
			   echo "Unable to remove previous $APPDSERVICE. Please remove manually and re-run."
			   exit 1
			fi
			# compile wrapper, chown and chmod with setuid
			cc -D_GNU_SOURCE -DAPPDUSER=`id -u $RUNUSER` -o $APPDSERVICE appdservice.c
			if [ -x $APPDSERVICE ] ; then
				chown root:root $APPDSERVICE
				chmod 4755 $APPDSERVICE
				echo "installed setuid root wrapper as $APPDSERVICE"
			else
				echo "installation of $APPDSERVICE failed"
			fi
		else
			echo "Exiting..."
			exit 1
		fi
	fi

	if [ $use_pbrun == 1 ] ; then
		# Clean up sudo privilege escalation if it was previously installed
		rm -f /etc/sudoers.d/appdynamics 2>/dev/null
		# Install the pbrun privilege escalation wrapper
		cp appdservice-pbrun.sh $APPDSERVICE
		chmod 755 $APPDSERVICE
		echo "installed pbrun wrapper as $APPDSERVICE"
	fi

	if [ $use_xuser == 1 ] ; then
		# Clean up sudo privilege escalation if it was previously installed
		rm -f /etc/sudoers.d/appdynamics 2>/dev/null
		# Install the xuser privilege escalation wrapper
		cp appdservice-xuser.sh $APPDSERVICE
		chmod 755 $APPDSERVICE
		echo "installed xuser wrapper as $APPDSERVICE"
	fi

	if [ $use_root == 1 ] ; then
		# Clean up sudo privilege escalation if it was previously installed
		rm -f /etc/sudoers.d/appdynamics 2>/dev/null
		cp appdservice-root.sh $APPDSERVICE
		chmod 755 $APPDSERVICE
		echo "installed root wrapper as $APPDSERVICE"
	fi

	if use_privileged_ports && ! require setcap libcap libcap2-bin; then
		echo "\
ERROR: AppDynamics is configured to bind to at least one port < 1024 as an
unprivileged user, but the setcap utility is not available on this host.
AppDynamics will not run in the configuration."
		exit 1
	fi
fi

#
# install all
#
i=0
for s in ${APPDYNAMICS_SERVICE_LIST[@]} ; do
	install_init $s ${APPDYNAMICS_SERVICE_START[$i]} ${APPDYNAMICS_SERVICE_STOP[$i]}
	((i++))
done

#
# ensure the machine agent directory is owned by RUNUSER
#
if [ -d "$machine_agent" ] ; then
	chown -R $RUNUSER "$machine_agent"
fi

#
# common use case - start with NOROOT, then root user deploys install-init.sh
#
if [ -f $APPD_ROOT/HA/NOROOT ] ; then
	echo "removing $APPD_ROOT/HA/NOROOT" | tee $LOGFILE
	rm -f $APPD_ROOT/HA/NOROOT
fi
