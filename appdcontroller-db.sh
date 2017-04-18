#!/bin/bash
### BEGIN INIT INFO
# Provides:          appdcontroller-db
# Required-Start:    $remote_fs $syslog
# Required-Stop:     $remote_fs $syslog
# Should-Start:      zfs
# Should-Stop:       zfs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: AppDynamics Controller
# Description:       This script starts and stops the AppDynamics Controller
#                    Database, appserver, and HA components.
### END INIT INFO
#
# $Id: appdcontroller-db.sh 3.17 2017-04-18 14:48:02 cmayer $
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
# HA Aware Init file for AppDynamics Controller 
# 
# chkconfig: 2345 60 25 
# description: Controller for AppDynamics
#
# assumes that the appdynamics controller and database run as the user 
# specified in the db.cnf file
#
# edit this manually if it hasn't been automatically set by the install-init.sh
# script
#
# Setting PATH to just a few trusted directories is an **important security** requirement
export PATH=/bin:/usr/bin:/sbin:/usr/sbin

NAME=$(basename $(readlink -e $0))

APPD_ROOT=/opt/AppDynamics/Controller
RUNUSER=root

# source script config
[ -f /etc/sysconfig/appdcontroller-db ] && . /etc/sysconfig/appdcontroller-db
[ -f /etc/default/appdcontroller-db ] && . /etc/default/appdcontroller-db

if [ -f $APPD_ROOT/HA/INITDEBUG ] ; then
	logfile=/tmp/$NAME.out
	rm -f $logfile
	exec 2> $logfile
	chown $RUNUSER $logfile
	set -x
fi

EVENTS_VMOPTIONS_FILE=$APPD_ROOT/events_service/conf/events-service.vmoptions
if [ ! -f $EVENTS_VMOPTIONS_FILE ] ; then
	EVENTS_VMOPTIONS_FILE=$APPD_ROOT/events_service/analytics-processor/conf/analytics-processor.vmoptions
fi
LIMITS=/etc/security/limits.d/appdynamics.conf

# For security reasons, locally embed/include function library at HA.shar build time
embed lib/password.sh
embed lib/init.sh
embed lib/conf.sh
embed lib/status.sh

check_sanity

if runuser [ ! -f $APPD_ROOT/db/db.cnf ] ; then
	echo appd controller not installed in $APPD_ROOT
	exit 1
fi

#
# if the numa settings file exists, then disable transparent huge pages
#
function do_numa_settings {
	if [ ! -f $APPD_ROOT/HA/numa.settings ] ; then
		return
	fi

	for dir in /sys/kernel/mm/transparent_hugepage \
		/sys/kernel/mm/redhat_transparent_hugepage ; do
		if [ -f $dir/enabled ] ; then
			echo "never" > $dir/enabled
		fi
		if [ -f $dir/defrag ] ; then
			echo "never" > $dir/defrag
		fi
	done
}

#
# Create (touch) a file called LARGE_PAGES_ENABLE in $APPD_ROOT/HA
# to enable explicit huge pages support for mysqld and java.
#
# If other programs on this system are also using huge pages,
# Please add the appdynamics runtime user to the group specified by
# /proc/sys/vm/hugetlb_shm_group
#
# If AppDynamics is the only application on this host using huge pages,
# /proc/sys/vm/hugetlb_shm_group will be updated automatically.
# See https://www.kernel.org/doc/Documentation/vm/hugetlbpage.txt
# for more information.
#
ENABLE_HUGE_PAGES="false"
HUGE_PAGE_SIZE_BYTES=`awk '/Hugepagesize:/{print $2*1024}' /proc/meminfo`

if [ -f $APPD_ROOT/HA/LARGE_PAGES_ENABLE -a -n "$HUGE_PAGE_SIZE_BYTES" ] ; then
	ENABLE_HUGE_PAGES="true"
fi

lockfile=/var/lock/subsys/$NAME
[ -d /var/lock/subsys ] || mkdir /var/lock/subsys

#
# set appropriate limits for the appd user
#
function set_limits {

	FD_LIMIT=`dbcnf_get open_files_limit`
	if [ "$FD_LIMIT" -lt 65536 ]; then
		FD_LIMIT=65536
	fi

	if [ "$RUNUSER" == "root" ] ; then
		if [ `ulimit -S -n` -lt $FD_LIMIT ] ; then
			ulimit -n $FD_LIMIT
		fi
		if $ENABLE_HUGE_PAGES ; then
			ulimit -l unlimited
		fi
		return
	fi

	if [ `runuser ulimit -S -n` -lt "$FD_LIMIT" ] ; then
		echo "$RUNUSER  soft  nofile $FD_LIMIT" > $LIMITS
		echo "$RUNUSER  hard  nofile $FD_LIMIT" >> $LIMITS
	fi

	if $ENABLE_HUGE_PAGES && [ `runuser ulimit -l` != "unlimited" ] ; then
		echo "$RUNUSER  soft  memlock  unlimited" >> $LIMITS
		echo "$RUNUSER  hard  memlock  unlimited" >> $LIMITS
	fi

	for pam in /etc/pam.d/common-session /etc/pam.d/system-auth ; do
		if [ ! -f $pam ] ; then 
			continue
		fi
		if grep -Eq "^\s*session\s+required\s+pam_limits\.so" $pam ; then
			echo "session required	pam_limits.so" >> $pam
			break
		fi
	done
}

#
# if the lockfile is older than uptime, we crashed
#
function host_crash {
	local lockfile_age=$(($(date +%s)-$(ls -l --time-style=+%s $lockfile | cut -d \  -f 6)))
	local uptime=$(printf '%.0f\n' $(cat /proc/uptime | cut -d \  -f 1))
	[ "$lockfile_age" -gt "$uptime" ]
}

#
# calculate a bunch of memory footprints and set global variables accordingly
# 
function calculate_memory {
	# multiply by 1.05 and round to account for extra 2% headroom
	CONTROLLER_HEAP=`domain_get_jvm_option Xmx | scale 1.04`
		
	# Parse controller JVM OPTIONS to get MaxPermSize
	CONTROLLER_MAXPERMSIZE=`domain_get_jvm_option MaxPermSize | scale`

	# multiplying by 1.1 and rounding in awk to account for the extra
	# memory MySQL allocates arround the InnoDB buffer pool.
	INNODB_BUFFER_POOL=`dbcnf_get innodb_buffer_pool_size | scale 1.1`
	INNODB_ADDITIONAL_MEM=`dbcnf_get innodb_additional_mem_pool_size | scale`
	
	# multiply by 1.05 and round to account for extra 2% headroom
	EVENTS_HEAP=`runuser cat $APPD_ROOT/bin/controller.sh | \
		awk -F= '/^\s*EVENTS_HEAP_SETTINGS=/ { print \$2 }' | \
		sed -e 's/ /\n/g' | get_jvm_option Xmx | scale 1.05`
	
	if [ -z "$EVENTS_HEAP" -a -f $EVENTS_VMOPTIONS_FILE ] ; then
		EVENTS_HEAP=`runuser cat $EVENTS_VMOPTIONS_FILE \
			| get_jvm_option Xmx | scale 1.05`
	fi
	if [ -z "$EVENTS_HEAP" ] ; then
		EVENTS_HEAP=0
	fi
		
	# Parse events service JVM options for MaxPermSize.  
	# Default to 64M if not set
	if [ -f $EVENTS_VMOPTIONS_FILE ] ; then
		EVENTS_MAXPERMSIZE=`runuser cat $EVENTS_VMOPTIONS_FILE | \
			get_jvm_option MaxPermSize | scale 1.05`
	fi
	
	if [ -z "$EVENTS_MAXPERMSIZE" ] || [ "$EVENTS_MAXPERMSIZE" -lt 1 ] ; then
		# Java permsize defaults to 64MiB
		EVENTS_MAXPERMSIZE=67108864
	fi
	
	(( APPD_TOTAL_RESERVED_BYTES = \
		CONTROLLER_HEAP + \
		CONTROLLER_MAXPERMSIZE + \
		INNODB_BUFFER_POOL + \
		INNODB_ADDITIONAL_MEM + \
		EVENTS_HEAP + \
		EVENTS_MAXPERMSIZE ))
	
	(( APPD_HUGE_PAGES = APPD_TOTAL_RESERVED_BYTES / HUGE_PAGE_SIZE_BYTES ))
	# Round up
	if [ $(( APPD_TOTAL_RESERVED_BYTES % HUGE_PAGE_SIZE_BYTES )) -gt 0 ] ; then
		(( APPD_HUGE_PAGES++ ))
	fi
	
	PAGE_SIZE_BYTES=`getconf PAGE_SIZE`

	#
	# If zfs is running on this host
	# Carve room for controller heap, innodb_buffer_pool_size and
	# innodb_additional_mem_pool_size.  Leave 20% system RAM uncommitted.
	#
	TOTAL_RESERVABLE_MEM=`free -b | awk '/Mem:/ { printf("%.0f\n", $2 * 0.8)}'`

	(( REQ_ZFS_ARC_MAX = TOTAL_RESERVABLE_MEM - APPD_TOTAL_RESERVED_BYTES ))
}

#
# change a memory allocation
#
function increment {
	local resourcefile=$1
	local amount=$2
	echo `cat $resourcefile` + $APPD_HUGE_PAGES | bc > $resourcefile
}

#
# Explicitly reserve memory for major controller components
#
function reserve_memory {
	echo 1 > /proc/sys/vm/swappiness
	
	calculate_memory

	# warn if heap plus innodb_buffer_pool_size is greater than available RAM
	if [ "$REQ_ZFS_ARC_MAX" -lt "0" ] ; then
		echo "$NAME: Warning!  controller memory $APPD_TOTAL_RESERVED_BYTES \
			exceeds available memory $TOTAL_RESERVABLE_MEM"
	else
		if zpool list >/dev/null 2>&1 ; then 
			ZFS_ARC_MAX=`cat /sys/module/zfs/parameters/zfs_arc_max`
			if [ "$ZFS_ARC_MAX" -eq "0" -o "$ZFS_ARC_MAX" -gt "$REQ_ZFS_ARC_MAX" ] ; then
				echo $REQ_ZFS_ARC_MAX > /sys/module/zfs/parameters/zfs_arc_max
			fi
		fi
	fi
	
	#
	# unconditionally disable controller MySQL and Java huge page support
	# we re-enable it below.   much cleaner code
	#
	dbcnf_unset large-pages
	domain_unset_jvm_option +UseLargePages
	domain_unset_jvm_option LargePageSizeInBytes

	# remove events service large pages config from controller.sh
	if [ -f $EVENTS_VMOPTIONS_FILE ] ; then
		runuser ex -s $EVENTS_VMOPTIONS_FILE <<- DELETE_EVENTS_LARGE_PAGES
			%s/^[\t ]*-XX:+UseLargePages[\t ]*\n//g
			%s/^[\t ]*-XX:LargePageSizeInBytes=.*\n//g
			wq
		DELETE_EVENTS_LARGE_PAGES
	fi

	#
	# If huge pages are supported and enabled,
	# Explicitly allocate and enable huge pages 
	# for the controller's java and mysql processes
	#
	if ! $ENABLE_HUGE_PAGES ; then
		return
	fi
	
	increment /proc/sys/vm/nr_hugepages $APPD_HUGE_PAGES

	# Allow the AppDynamics user to access the huge pages we're allocating.
	if ! id -G $RUNUSER | grep -wq /proc/sys/vm/hugetlb_shm_group ; then
		echo $(id -g $RUNUSER) > /proc/sys/vm/hugetlb_shm_group
	fi
		
	# this code will break if we try to allocate 2 ^ 64 memory. let it.
	(( APPD_SHMMAX = APPD_HUGE_PAGES * HUGE_PAGE_SIZE_BYTES))

	increment /proc/sys/kernel/shmmax $APPD_SHMMAX
	increment /proc/sys/kernel/shmall $APPD_SHMMAX

	dbcnf_set large_pages ""
		
	domain_set_jvm_option +UseLargePages
	domain_set_jvm_option LargePageSizeInBytes $HUGE_PAGE_SIZE_BYTES
		
	if [ -f $EVENTS_VMOPTIONS_FILE ] ; then
		runuser ex -s $EVENTS_VMOPTIONS_FILE <<- EVENTS_LARGE_PAGES
			a
			-XX:+UseLargePages 
			-XX:LargePageSizeInBytes=$HUGE_PAGE_SIZE_BYTES
			.
			wq
		EVENTS_LARGE_PAGES
	fi
}

function unreserve_memory {
	if ! $ENABLE_HUGE_PAGES ; then
		return
	fi
	calculate_memory
	increment /proc/sys/vm/nr_hugepages -$APPD_HUGE_PAGES
	increment /proc/sys/kernel/shmmax -$APPD_SHMMAX
	increment /proc/sys/kernel/shmall -$APPD_SHMMAX
}

case "$1" in  
start)  
	require_root

	do_numa_settings
	set_limits

	#
	# we only run reserve_memory
	# if no lockfile or stale lockfile precedes last startup (crash?)
	# we do not reserve memory if
	# a) mysql crashed or shut down outside of init: 
	# b) stale lockfile that is younger than last boot
	# c) mysql already running
	#
	if ! db_running ; then
		if ! [ -f $lockfile ] || host_crash ; then
			reserve_memory
		fi
		runuser $CONTROLLER_SH start-db
	fi
	rm -f $lockfile	
	touch $lockfile	
;;  
  
stop)
	require_root
	service appdcontroller stop
	# The default controller shutdown timeout is 45 minutes 
	# That is a long time to be stuck with a hung appserver on the way down.
	# Thankfully, we can set an environment variable to override that:
	export AD_SHUTDOWN_TIMEOUT_IN_MIN=10
	# call separately because if _stopControllerAppServer can "exit 1"
	# which will leave the database still running
	runuser $CONTROLLER_SH stop-db
	unreserve_memory
	rm -f $lockfile
;;  

restart)  
	$0 stop  
	$0 start  
;;  
  
status)  
	if db_running ; then
controllerversion=`echo "select value from global_configuration_cluster where name='schema.version'" | run_mysql | get value`
	if [ ! -z "$controllerversion" ] ; then
		echo version: $controllerversion
	fi
		echo -n "db running as $RUNUSER - "
		if [ "`controller_mode`" == "active" ] ; then
			echo "active"
		else
			echo "passive"
			if replication_disabled ; then
				echo replication disabled
			fi
		fi
		case `echo "select value from global_configuration_local where name='ha.controller.type'" | run_mysql | get value` in
		primary) 
			echo primary
			;;
		secondary)
			echo secondary
			;;
		notapplicable)
			echo HA not installed
			;;
		*)
			echo unknown HA type
			;;
		esac
		
		echo "SHOW SLAVE STATUS" | \
			( run_mysql ) | awk \
			'/Slave_IO_State/ {print}
			/Seconds_Behind_Master/ {print} 
			/Master_Server_Id/ {print}
			/Master_Host/ {print}'
		echo "SHOW SLAVE STATUS" | ( run_mysql ) | awk '
			/Master_SSL_Allowed/ { if ($2 == "Yes") {print "Using SSL Replication" }}'
	else
		echo "db not running"
	fi
	if replication_disabled ; then
		echo "replication persistently broken"
	fi
;;

*)  
        echo "Usage: $0 {start|stop|restart|status}"  
        exit 1  
esac
exit 0 
