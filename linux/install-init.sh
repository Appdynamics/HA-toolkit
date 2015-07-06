#!/bin/bash
#
# $Id: install-init.sh 2.10 2015-06-30 14:56:01 cmayer $
#
# install init script
#
SCRIPTNAME=$(basename $(readlink -e $0))

export PATH=/sbin:/usr/sbin:$PATH

# list of AppDynamics services in start order
APPDYNAMICS_SERVICE_LIST=( appdcontroller-db appdcontroller )

VENDOR=`lsb_release -i 2>/dev/null | awk '{print $3}'`

if echo $VENDOR | grep -iq ubuntu ; then
	#
	# Define explicit start and stop order lists for Ubuntu and other distros
	# were update-rc.d ignores the LSB dependency headers
	#
	APPDYNAMICS_SERVICE_START=( 90 91 )
	APPDYNAMICS_SERVICE_STOP=( 90 89 )
fi

use_sudo=true
use_appdservice=true
APPDSERVICE=/sbin/appdservice

cd $(dirname $0)
APPD_ROOT=`cd .. ; pwd`
if ! [ -d $APPD_ROOT/bin ] ; then
	APPD_ROOT=/opt/AppDynamics/Controller
	echo using default path $APPD_ROOT
fi
DOMAIN_XML=$APPD_ROOT/appserver/glassfish/domains/domain1/config/domain.xml

ROOTOWNER=`ls -ld $APPD_ROOT | awk '{print $3}'`
RUNUSER=`su -s /bin/bash -c "awk -F= '/^[\t ]*user=/ {print \\$2}' $APPD_ROOT/db/db.cnf" $ROOTOWNER`

CHKCONFIG=`which chkconfig 2>/dev/null`
UPDATE_RC_D=`which update-rc.d 2>/dev/null`
SERVICE=`which service 2>/dev/null`

function require() {
	# args: executable "redhat package" "debian package" [ force ]
	local errors=0
	if ! [[  -x `which $1 2>/dev/null` ]] || [ "$4" == "force" ] ; then
		if [[ -x `which apt-get 2>/dev/null` ]] ; then
			if ! apt-get -qq -y install $3 && [ "$4" == "force" ] ; then
				errors=1
			fi
		elif [[ -x `which yum 2>/dev/null` ]] ; then
			if ! yum --quiet -y install $2 >/dev/null && [ "$4" == "force" ] ; then
				errors=1
			fi
		fi
		if ! [[  -x `which $1 2>/dev/null` ]] || [ "$errors" -gt 0 ] ; then
			echo "Unable to install package containing $1"
			return 1
		fi
	fi
}

function install_init() {
	echo "installing /etc/init.d/$1"
	sed <./$1.sh >/etc/init.d/$1 \
		-e "/^APPD_ROOT=/s,=.*,=$APPD_ROOT," \
		-e "/^RUNUSER=/s,=.*,=$RUNUSER,"

	chmod 0744 /etc/init.d/$1

	if [ -x "$CHKCONFIG" ] ; then
		chkconfig --add $1
	elif [ -x "$UPDATE_RC_D" ] ; then
		update-rc.d -f $1 remove 
		update-rc.d $1 defaults $2 $3
	else
		echo "unsupported linux distribution: chkconfig or update-rc.d required"
		exit 1
	fi
}

#
# make sure we have xmllint, bc, and the right version of ping installed
#
missing_dependencies=0
require xmllint libxml2 libxml2-utils || ((missing_dependencies++))
require bc bc bc || ((missing_dependecies++))
require ex vim-minimal vim-tiny || ((missing_dependecies++))
if ! ping -q -W 1 -c 1 localhost >/dev/null ; then
	require ping iputils iputils-ping force || ((missing_dependencies++))
fi
if [ "$missing_dependencies" -gt 0 ] ; then
	exit 1
fi

#
# since our RUNUSER isn't root, we want to make it so that sudo works
# for our selected commands.   
# this is not a security hole, it is a controlled privilege escalation, really.
#
if [[ `id -u $RUNUSER` != "0" ]] ; then

	if [ $use_sudo == true ] ; then
	require sudo sudo sudo || exit 1
	[ -d /etc/sudoers.d ] || mkdir /etc/sudoers.d && chmod 0750 /etc/sudoers.d
	grep -Eq "^#includedir[\t ]+/etc/sudoers.d[\t ]*$" /etc/sudoers || \
	grep -Eq "^#include[\t ]+/etc/sudoers.d/appdynamics[\t ]*$" /etc/sudoers || \
	echo "#include /etc/sudoers.d/appdynamics" >> /etc/sudoers
	if [ -x "$CHKCONFIG" ] ; then
		COMMA=
		for s in ${APPDYNAMICS_SERVICE_LIST[@]} ; do
			CMND_ALIAS_LIST="$CMND_ALIAS_LIST $COMMA \\
			$SERVICE $s *, \\
			$CHKCONFIG $s on, \\
			$CHKCONFIG $s off"
			COMMA=","
		done
	elif [ -x "$UPDATE_RC_D" ] ; then
		COMMA=
		for s in ${APPDYNAMICS_SERVICE_LIST[@]} ; do
			CMND_ALIAS_LIST="$CMND_ALIAS_LIST$COMMA \\
			$SERVICE $s *, \\
			$UPDATE_RC_D $s enable, \\
			$UPDATE_RC_D $s disable"
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

	if [ $use_appdservice == true ] ; then
		# compile wrapper, chown and chmod with setuid
		cc -DAPPDUSER=`id -u $RUNUSER` -o $APPDSERVICE appdservice.c
		if [ -x $APPDSERVICE ] ; then
			chown root:root $APPDSERVICE
			chmod 4755 $APPDSERVICE
			echo "installed $APPDSERVICE"
		else
			echo "installation of $APPDSERVICE failed"
		fi
	fi

	if ! require setcap libcap libcap2-bin && \
		[[ `echo "cat //*[@port<1024]" | xmllint --shell $DOMAIN_XML | wc -l` -gt 1 ]] ; then
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
