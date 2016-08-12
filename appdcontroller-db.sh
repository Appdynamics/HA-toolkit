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
# $Id: appdcontroller-db.sh 3.0 2016-08-04 03:09:03 cmayer $
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
PATH=/bin:/usr/bin:/sbin:/usr/sbin

NAME=$(basename $(readlink -e $0))

APPD_ROOT=/opt/AppDynamics/Controller
RUNUSER=root

# source script config
[ -f /etc/sysconfig/appdcontroller-db ] && . /etc/sysconfig/appdcontroller-db
[ -f /etc/default/appdcontroller-db ] && . /etc/default/appdcontroller-db

APPD_BIN="$APPD_ROOT/bin"
DOMAIN_XML=$APPD_ROOT/appserver/glassfish/domains/domain1/config/domain.xml
EVENTS_VMOPTIONS_FILE=$APPD_ROOT/events_service/conf/events-service.vmoptions
[[ -r $EVENTS_VMOPTIONS_FILE ]] || EVENTS_VMOPTIONS_FILE=$APPD_ROOT/events_service/analytics-processor/conf/analytics-processor.vmoptions

# For security reasons, locally embed/include function library at HA.shar build time
embed lib/password.sh
embed lib/init.sh
embed lib/conf.sh

check_sanity

DB_PID_FILE=`dbcnf_get pid-file`
DB_DATA_DIR=`dbcnf_get datadir`
DB_SKIP_SLAVE_START=`dbcnf_get skip-slave-start`

MYSQLCLIENT="$APPD_ROOT/HA/mysqlclient.sh"

if runuser [ ! -f $APPD_ROOT/db/db.cnf ] ; then
	echo appd controller not installed in $APPD_ROOT
	exit 1
fi

OPEN_FD_LIMIT=`dbcnf_get open_files_limit`
if [ "$OPEN_FD_LIMIT" -lt 65536 ]; then
	OPEN_FD_LIMIT=65536
fi

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

if [ -f $APPD_ROOT/HA/LARGE_PAGES_ENABLE ] ; then
	ENABLE_HUGE_PAGES="true"
fi

lockfile=/var/lock/subsys/$NAME
[ -d /var/lock/subsys ] || mkdir /var/lock/subsys


function enable_pam_limits {
	if [ -f /etc/pam.d/common-session ] && \
		! grep  -Eq "^[\t ]*session[\t ]+required[\t ]+pam_limits\.so" /etc/pam.d/common-session ; then
		echo "session required	pam_limits.so" >> /etc/pam.d/common-session
	elif [ -f /etc/pam.d/system-auth ] && \
		! grep  -Eq "^[\t ]*session[\t ]+required[\t ]+pam_limits\.so" /etc/pam.d/system-auth ; then
		echo "session required	pam_limits.so" >> /etc/pam.d/system-auth
	fi
}

# always make sure this gets called before any other functions that modify
# /etc/security/limits.d/appdynamics.com, i.e. reserve_memory
function set_open_fd_limits {
	if [ "$RUNUSER" == "root" ] && [[ `ulimit -S -n` -lt $OPEN_FD_LIMIT ]]
		then
		ulimit -n $OPEN_FD_LIMIT
	elif [[ `su -s /bin/bash -c "ulimit -S -n" $RUNUSER` -lt "$OPEN_FD_LIMIT" ]]
		then
		echo "$RUNUSER  soft  nofile $OPEN_FD_LIMIT" > /etc/security/limits.d/appdynamics.conf
		echo "$RUNUSER  hard  nofile $OPEN_FD_LIMIT" >> /etc/security/limits.d/appdynamics.conf
		enable_pam_limits
	fi
}

function db_running {
	if [ -z "$DB_PID_FILE" ] ; then
		DB_PID_FILE="$DB_DATA_DIR/$(hostname).pid"
	fi
	if [ -z "$DB_PID_FILE" ] ; then
		return 1
	fi
	DB_PID=`runuser cat $DB_PID_FILE 2>/dev/null`
	if [ -z "$DB_PID" ] ; then
		return 1
	fi
	if [ -d /proc/$DB_PID ] ; then
		return 0;
	fi
	return 1	
}

function get {
	local key=$1
	awk "/$key:/ {print \$2}"
}

function controller_mode {
	echo select value from global_configuration_local \
			where "name='appserver.mode'" | runuser $MYSQLCLIENT | get value
}

function host_crash {
	local lockfile_age=$(($(date +%s)-$(ls -l --time-style=+%s $lockfile | cut -d \  -f 6)))
	local uptime=$(printf '%.0f\n' $(cat /proc/uptime | cut -d \  -f 1))
	[ "$lockfile_age" -gt "$uptime" ]
}

function calculate_memory {
	# multiply by 1.05 and round to account for extra 2% allocation overhead +
	#  headroom
	CONTROLLER_HEAP=`domain_get_jvm_option Xmx | scale 1.04`
		
	#Parse controller JVM OPTIONS to get MaxPermSize
	CONTROLLER_MAXPERMSIZE=`domain_get_jvm_option MaxPermSize | scale`

	# multiplying by 1.1 and rounding in awk to account for the extra
	# memory MySQL allocates arround the InnoDB buffer pool.
	INNODB_BUFFER_POOL=`dbcnf_get innodb_buffer_pool_size | scale 1.1`
	INNODB_ADDITIONAL_MEM=`dbcnf_get innodb_additional_mem_pool_size | scale`
	
	# multiply by 1.05 and round to account for extra 2% allocation overhead +
	#  headroom
	EVENTS_HEAP=`runuser \
		awk -F= "'/^\s*EVENTS_HEAP_SETTINGS=/{ print \$2 }'" \
			$APPD_ROOT/bin/controller.sh | \
		sed -e 's/ /\n/g' | get_jvm_option Xmx | scale 1.05`
	
	if [ -z "$EVENTS_HEAP" ] ; then
		EVENTS_HEAP=`runuser cat $EVENTS_VMOPTIONS_FILE \
			| get_jvm_option Xmx | scale 1.05`
	fi

	if [ -z "$EVENTS_HEAP" ] ; then
		EVENTS_HEAP=0
	fi
		
	# Parse events service JVM options for MaxPermSize.  
	# Default to 64M if not set
	EVENTS_MAXPERMSIZE=`runuser cat $EVENTS_VMOPTIONS_FILE | \
		get_jvm_option MaxPermSize | scale 1.05`
		
	if [ -n "$EVENTS_MAXPERMSIZE" ] && [ "$EVENTS_MAXPERMSIZE" -lt 1 ] ; then
		# Java permsize defaults to 64MiB
		EVENTS_MAXPERMSIZE=67108864
	fi
	
	((APPD_TOTAL_RESERVED_BYTES=\
CONTROLLER_HEAP+\
CONTROLLER_MAXPERMSIZE+\
INNODB_BUFFER_POOL+\
INNODB_ADDITIONAL_MEM+\
EVENTS_HEAP+\
EVENTS_MAXPERMSIZE))
	
	((APPD_HUGE_PAGES=APPD_TOTAL_RESERVED_BYTES/HUGE_PAGE_SIZE_BYTES))
	if [ $((APPD_TOTAL_RESERVED_BYTES%HUGE_PAGE_SIZE_BYTES)) -gt 0 ]
		then
		# Round up
		((APPD_HUGE_PAGES++))
	fi
	
	PAGE_SIZE_BYTES=`getconf PAGE_SIZE`
}

#
# Explicitly reserve memory for major controller components
#
function reserve_memory {
	# set swappiness to 1 after (CORE-68175):
	# https://www.percona.com/blog/2014/04/28/oom-relation-vm-swappiness0-new-kernel/
	# and
	# https://access.redhat.com/documentation/en-US/Red_Hat_Enterprise_Linux/6/html/Performance_Tuning_Guide/s-memory-tunables.html
	echo 1 > /proc/sys/vm/swappiness
	
	calculate_memory

	#
	# If zfs is running on this host
	# Carve room for controller heap, innodb_buffer_pool_size and
	# innodb_additional_mem_pool_size.  Leave 20% system RAM uncommitted.
	#

	TOTAL_RESERVABLE_MEM=`free -b | awk '/Mem:/{RESERVABLE_MEM=$2*0.8; printf("%.0f\n", RESERVABLE_MEM)}'`
	(( REQ_ZFS_ARC_MAX=TOTAL_RESERVABLE_MEM-APPD_TOTAL_RESERVED_BYTES ))
	# warn if heap plus innodb_buffer_pool_size is greater than available RAM
	if [ "$REQ_ZFS_ARC_MAX" -lt "0" ] ; then
		echo "\
$NAME: Warning!  Controller Heap + innodb_buffer_pool_size
+ innodb_additional_mem_pool_size, ($APPD_TOTAL_RESERVED_BYTES bytes), greater
than reservable system RAM, ($TOTAL_RESERVABLE_MEM bytes)."
	else
		if zpool list >/dev/null 2>&1 ; then 
			ZFS_ARC_MAX=`cat /sys/module/zfs/parameters/zfs_arc_max`
			if ([ "$ZFS_ARC_MAX" -eq "0" ] || [ "$ZFS_ARC_MAX" -gt "$REQ_ZFS_ARC_MAX" ]) ; then
				echo $REQ_ZFS_ARC_MAX > /sys/module/zfs/parameters/zfs_arc_max
			fi
		fi
	fi
	
	# If huge pages are supported and enabled.
	if [ -n "$HUGE_PAGE_SIZE_BYTES" ] && [ "$ENABLE_HUGE_PAGES" == "true" ]
		then
		local SHMMAX_MAX
		local SHMALL_MAX
		if [[ `uname -m` == "x86_64" ]]
			then
			SHMMAX_MAX=`echo "2^64 - 16777217" | bc`
		else
			SHMMAX_MAX=`echo "2^32 - 16777217" | bc`
		fi
		SHMALL_MAX=$SHMMAX_MAX
		
	  	# Explicitly allocate and enable huge pages for the controller's
		# java and mysql processes
		
		echo $(($(cat /proc/sys/vm/nr_hugepages)+APPD_HUGE_PAGES)) > /proc/sys/vm/nr_hugepages

		# Allow the AppDynamics user to access the huge pages we're allocating.
		if ! id -G $RUNUSER | grep -wq `cat /proc/sys/vm/hugetlb_shm_group`
			then
			echo $(id -g $RUNUSER) > /proc/sys/vm/hugetlb_shm_group
		fi
		
		#check/set shmmax
		#use bc to handle unsigned 64-bit unsigned integers
		((APPD_SHMMAX=APPD_HUGE_PAGES*HUGE_PAGE_SIZE_BYTES))
		local PROC_SHMMAX=$(cat /proc/sys/kernel/shmmax)
		[[ $(echo "$PROC_SHMMAX < $SHMMAX_MAX"|bc) == "1" ]] \
			&& echo "shmmax = $PROC_SHMMAX+$APPD_SHMMAX; \
			if (shmmax > $SHMMAX_MAX) shmmax=$SHMMAX_MAX; print shmmax;"\
				| bc > /proc/sys/kernel/shmmax

		#check/set shmmall
		#use bc to handle unsigned 64-bit unsigned integers
		((APPD_SHMALL=APPD_SHMMAX/PAGE_SIZE_BYTES))
		local PROC_SHMALL=$(cat /proc/sys/kernel/shmall)
		[[ $(echo "$PROC_SHMALL < $SHMALL_MAX"|bc) == "1" ]] \
			&& echo "shmall = $PROC_SHMALL+$APPD_SHMALL; \
			if(shmall > $SHMALL_MAX) shmall=$SHMALL_MAX; print shmall;" \
				| bc > /proc/sys/kernel/shmall
	
		# check/set unlimited memlock limit for $RUNUSER
		if [[ $RUNUSER == "root" ]]
			then
			ulimit -l unlimited
		else
			if [[ $(su -s /bin/bash -c "ulimit -l" $RUNUSER) != "unlimited" ]]
				then
				echo "$RUNUSER  soft  memlock  unlimited" >> /etc/security/limits.d/appdynamics.conf
				echo "$RUNUSER  hard  memlock  unlimited" >> /etc/security/limits.d/appdynamics.conf
			fi
		fi
		
		dbcnf_set large_pages ""
		
		# check/tweak domain.xml

		domain_set_jvm_option +UseLargePages
		domain_set_jvm_option LargePageSizeInBytes $HUGE_PAGE_SIZE_BYTES
		
		# XXX
		# check / tweak events service settings
		if ! runuser cat $EVENTS_VMOPTIONS_FILE | \
			grep -q "\-XX:+UseLargePages" ; then
			runuser ex -s $EVENTS_VMOPTIONS_FILE <<- EVENTS_LARGE_PAGES
				a
				-XX:+UseLargePages 
				-XX:LargePageSizeInBytes=$HUGE_PAGE_SIZE_BYTES
				.
				wq
			EVENTS_LARGE_PAGES
		# simplify the awk-fu below...
		elif [[ `( runuser cat $EVENTS_VMOPTIONS_FILE ) \
			| awk -F= '/^[\t ]*-XX:LargePageSizeInBytes=/{
				if(sub(/[k,K]$/,"",$2)==1){ 
					BYTES=$2*1024 
				}
				else if(sub(/[m,M]$/,"",$2)==1){ 
					BYTES=$2*1048576 
				}
				else if(sub(/[g,G]$/,"",$2)==1){ 
					BYTES=$2*1073741824 
				} else { 
					gsub(/[^0-9]/,"",$2) 
					BYTES=$2
				} 
				print BYTES; 
				exit;
			}'` != "$HUGE_PAGE_SIZE_BYTES" ]] ; then
			#update large page size
			runuser ex -s $EVENTS_VMOPTIONS_FILE <<- ADJUST_EVENT_LARGE_PAGE_SIZE
				%s/-XX:LargePageSizeInBytes=[1-9][0-9]*[k,K,m,M,g,G]\?/-XX:LargePageSizeInBytes=$HUGE_PAGE_SIZE_BYTES/g
				wq
			ADJUST_EVENT_LARGE_PAGE_SIZE
		fi
	else
		# disable controller MySQL and Java huge page support
		dbcnf_unset large-pages
		domain_unset_jvm_option +UseLargePages
		domain_unset_jvm_option LargePageSizeInBytes

		# remove events service large pages config from controller.sh
		if ( runuser cat $EVENTS_VMOPTIONS_FILE ) \
			 | grep -q "^[\t ]*\-XX:+UseLargePages[\t ]*" ; then
			runuser ex -s $EVENTS_VMOPTIONS_FILE <<- DELETE_EVENTS_LARGE_PAGES
				%s/^[\t ]*-XX:+UseLargePages[\t ]*\n//g
				%s/^[\t ]*-XX:LargePageSizeInBytes=.*\n//g
				wq
			DELETE_EVENTS_LARGE_PAGES
		fi
	fi
	# XXX
}

function unreserve_memory {
	# If huge pages are supported and enabled.
	if [ -n "$HUGE_PAGE_SIZE_BYTES" ] && [ "$ENABLE_HUGE_PAGES" == "true" ]
		then
		calculate_memory
		local SHMMAX_MAX
		local SHMALL_MAX
		if [[ `uname -m` == "x86_64" ]]
			then
			SHMMAX_MAX=`echo "2^64 - 16777217" | bc`
		else
			SHMMAX_MAX=`echo "2^32 - 16777217" | bc`
		fi
		SHMALL_MAX=$SHMMAX_MAX
		
	  	# Explicitly allocate and enable huge pages for the controller's
		# java and mysql processes
		
		echo $(($(cat /proc/sys/vm/nr_hugepages)-APPD_HUGE_PAGES)) > /proc/sys/vm/nr_hugepages
		
		#check/set shmmax
		#use bc to handle unsigned 64-bit unsigned integers
		((APPD_SHMMAX=APPD_HUGE_PAGES*HUGE_PAGE_SIZE_BYTES))
		local PROC_SHMMAX=$(cat /proc/sys/kernel/shmmax)
		[[ $(echo "$PROC_SHMMAX < $SHMMAX_MAX"|bc) == "1" ]] \
			&& echo "shmmax = $PROC_SHMMAX-$APPD_SHMMAX; \
			if (shmmax > $SHMMAX_MAX) shmmax=$SHMMAX_MAX; print shmmax;"\
				| bc > /proc/sys/kernel/shmmax

		#check/set shmmall
		#use bc to handle unsigned 64-bit unsigned integers
		((APPD_SHMALL=APPD_SHMMAX/PAGE_SIZE_BYTES))
		local PROC_SHMALL=$(cat /proc/sys/kernel/shmall)
		[[ $(echo "$PROC_SHMALL < $SHMALL_MAX"|bc) == "1" ]] \
			&& echo "shmall = $PROC_SHMALL-$APPD_SHMALL; \
			if(shmall > $SHMALL_MAX) shmall=$SHMALL_MAX; print shmall;" \
				| bc > /proc/sys/kernel/shmall
	fi
}

case "$1" in  
start)  
	require_root
	# conditionally run reserve_memory
	# if no lockfile or host crash (stale lockfile precedes last startup): reserve memory
	# mysql crashed or shut down outside of intit: stale lockfile that is younger than last boot: noop
	# mysql already running: noop
	if ! db_running ; then
		set_open_fd_limits
		# if numa settings, then we need to disable transparent huge pages
		if [ -f $APPD_ROOT/HA/numa.settings ] ; then
			for dir in /sys/kernel/mm/transparent_hugepage \
				/sys/kernel/mm/redhat_transparent_hugepage ; do
				if [ -f $dir/enabled ] ; then
					echo "never" > $dir/enabled
				fi
				if [ -f $dir/defrag ] ; then
					echo "never" > $dir/defrag
				fi
			done
		fi
		if ! [ -f $lockfile ] || host_crash ; then
			reserve_memory
		fi
		runuser $APPD_BIN/controller.sh start-db
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
	runuser $APPD_BIN/controller.sh stop-db
	unreserve_memory
	rm -f $lockfile
;;  

restart)  
	$0 stop  
	$0 start  
;;  
  
status)  
	if db_running ; then
controllerversion=`echo "select value from global_configuration_cluster where name='schema.version'" | runuser $MYSQLCLIENT | get value`
	if [ ! -z "$controllerversion" ] ; then
		echo version: $controllerversion
	fi
		echo -n "db running as $RUNUSER - "
		if [ "`controller_mode`" == "active" ] ; then
			echo "active"
		else
			echo "passive"
			if [ -n "$DB_SKIP_SLAVE_START" ] ; then
				echo replication disabled
			fi
		fi
		case `echo "select value from global_configuration_local where name='ha.controller.type'" | runuser $MYSQLCLIENT | get value` in
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
			( runuser $MYSQLCLIENT ) | awk \
			'/Slave_IO_State/ {print}
			/Seconds_Behind_Master/ {print} 
			/Master_Server_Id/ {print}
			/Master_Host/ {print}'
		echo "SHOW SLAVE STATUS" | ( runuser $MYSQLCLIENT ) | awk '
			/Master_SSL_Allowed/ { if ($2 == "Yes") {print "Using SSL Replication" }}'
	else
		echo "db not running"
	fi
	if [ -n "`dbcnf_get skip-slave-start`" ] ; then
		echo "replication persistently broken"
	fi
;;

*)  
        echo "Usage: $0 {start|stop|restart|status}"  
        exit 1  
esac
exit 0 
