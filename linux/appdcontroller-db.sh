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
# $Id: appdcontroller-db.sh 1.6 2015-06-12 12:22:17 cmayer $
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
NAME=$(basename $(readlink -e $0))

APPD_ROOT=/opt/AppDynamics/Controller
DOMAIN_XML=$APPD_ROOT/appserver/glassfish/domains/domain1/config/domain.xml
EVENTS_SERVICE_VMOPTIONS_FILE=$APPD_ROOT/events_service/analytics-processor/conf/analytics-processor.vmoptions
RUNUSER=root

if [ `id -un` == $RUNUSER ] ; then
        function runuser {
                $*
        }
else
        function runuser {
                su -c "$*" $RUNUSER
        }
fi

if runuser [ ! -f $APPD_ROOT/db/db.cnf ] ; then
	echo appd controller not installed in $APPD_ROOT
	exit 1
fi

DB_CNF=/tmp/db.cnf.$$
function cleanup() {
	rm -f $DB_CNF
}
trap cleanup EXIT

cleanup
runuser cat $APPD_ROOT/db/db.cnf > $DB_CNF

OPEN_FD_LIMIT=`awk -F= '/^[\t ]*open_files_limit=/{print $2; exit}' $DB_CNF`
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

APPD_BIN="$APPD_ROOT/bin"
lockfile=/var/lock/subsys/$NAME
[ -d /var/lock/subsys ] || mkdir /var/lock/subsys

function require_root {
	if [ `id -un` != "root" ] ; then
		echo "service changes must be run as root"
		exit 1
	fi
}

#
# trivial sanity check
#
if runuser [ ! -x $APPD_BIN/controller.sh ] ; then
	echo controller disabled on this host
	exit 1
fi



function enable_pam_limits() {
	if [ -f /etc/pam.d/common-session ] && \
		! grep  -Eq "^[\t ]*session[\t ]+required[\t ]+pam_limits\.so" /etc/pam.d/common-session ; then
		echo "session required	pam_limits.so" >> /etc/pam.d/common-session
	elif [ -f /etc/pam.d/system-auth ] && \
		! grep  -Eq "^[\t ]*session[\t ]+required[\t ]+pam_limits\.so" /etc/pam.d/system-auth ; then
		echo "session required	pam_limits.so" >> /etc/pam.d/system-auth
	fi
}

# always make sure this gets called before any other functions that modify
# /etc/security/limits.d/appdynamics.com, i.e. reserve_memory()
function set_open_fd_limits() {
	if [ "$RUNUSER" == "root" ] && [[ `ulimit -S -n` -lt $OPEN_FD_LIMIT ]]
		then
		ulimit -n $OPEN_FD_LIMIT
	elif [[ `su -c "ulimit -S -n" $RUNUSER` -lt "$OPEN_FD_LIMIT" ]]
		then
		echo "$RUNUSER  soft  nofile $OPEN_FD_LIMIT" > /etc/security/limits.d/appdynamics.conf
		echo "$RUNUSER  hard  nofile $OPEN_FD_LIMIT" >> /etc/security/limits.d/appdynamics.conf
		enable_pam_limits
	fi
}

function db_running() {
	DB_PID_FILE=`cat $DB_CNF | grep "^[\t ]*pid-file" | cut -d = -f 2`
	DB_DATA_DIR=`cat $DB_CNF | grep "^[\t ]*datadir" | cut -d = -f 2`
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

function replication_disabled() {
	if cat $DB_CNF | grep -q "^[\t ]*skip-slave-start=true" ; then
		return 0
	else
		return 1
	fi
}

function active() {
	if echo select value from global_configuration_local \
			where "name='appserver.mode'" | \
		runuser $APPD_BIN/controller.sh login-db | \
		tail -1 | grep -q "active" ; then
		return 0
	else
		return 1
	fi
}

function host_crash(){
	local lockfile_age=$(($(date +%s)-$(ls -l --time-style=+%s $lockfile | cut -d \  -f 6)))
	local uptime=$(printf '%.0f\n' $(cat /proc/uptime | cut -d \  -f 1))
	[ "$lockfile_age" -gt "$uptime" ]
}

function calculate_memory(){
	JVM_OPTIONS=`echo "cat /domain/configs/config[@name='server-config']/java-config/jvm-options" | runuser xmllint --shell $DOMAIN_XML`
	
	# multiply by 1.05 and round to account for extra 2% allocation overhead +
	#  headroom
	CONTROLLER_HEAP=`echo "$JVM_OPTIONS" | awk '/-Xmx/{
		gsub(/<\/?jvm-options>(-Xmx)?/,"")
			if(sub(/[k,K]$/,"")==1){ 
				BYTES=$0*1024 
			}
			else if(sub(/[m,M]$/,"")==1){ 
				BYTES=$0*1048576 
			}
			else if(sub(/[g,G]$/,"")==1){ 
				BYTES=$0*1073741824 
			} else { 
				gsub(/[^0-9]/,"") 
				BYTES=$0 
			} 
		}
		END{
			BYTES=BYTES*1.05
			printf("%.0f\n", BYTES)
		}'`
		
	#Parse controller JVM OPTIONS to get MaxPermSize
	CONTROLLER_MAXPERMSIZE=`echo "$JVM_OPTIONS" | awk '/-XX:MaxPermSize=/{
		gsub(/<\/?jvm-options>(-XX:MaxPermSize=)?/,"")
			if(sub(/[k,K]$/,"")==1){ 
				BYTES=$0*1024 
			}
			else if(sub(/[m,M]$/,"")==1){ 
				BYTES=$0*1048576 
			}
			else if(sub(/[g,G]$/,"")==1){ 
				BYTES=$0*1073741824 
			} else { 
				gsub(/[^0-9]/,"") 
				BYTES=$0 
			} 
		}
		END{print BYTES}'`

	# multiplying by 1.1 and rounding in awk to account for the extra
	# memory MySQL allocates arround the InnoDB buffer pool.
	INNODB_BUFFER_POOL=`cat $DB_CNF | \
		awk -F= '/^[\t ]*innodb_buffer_pool_size/{ 
		if(sub(/[K][\t ]*$/,"",$2)==1){
			BYTES=$2*1024
		}
		else if(sub(/[M][\t ]*$/,"",$2)==1){
			BYTES=$2*1048576
		}
		else if(sub(/[G][\t ]*$/,"",$2)==1){
			BYTES=$2*1073741824 
		} else {
			gsub(/[^0-9]/,"",$2) 
			BYTES=$2
		}
		BYTES=BYTES*1.1
		printf("%.0f\n", BYTES)
		exit; 
	}'`
	
	INNODB_ADDITIONAL_MEM=`cat $DB_CNF | \
		awk -F= '/^[\t ]*innodb_additional_mem_pool_size=/{ 
		if(sub(/[K][\t ]*$/,"",$2)==1){
			BYTES=$2*1024
		}
		else if(sub(/[M][\t ]*$/,"",$2)==1){
			BYTES=$2*1048576
		}
		else if(sub(/[G][\t ]*$/,"",$2)==1){
			BYTES=$2*1073741824
		} else {
			gsub(/[^0-9]/,"",$2)
			BYTES=$2
		}
			print BYTES;
		exit;
	}'`
	
	# multiply by 1.05 and round to account for extra 2% allocation overhead +
	#  headroom
	EVENTS_SERVICE_HEAP=`( runuser cat $APPD_ROOT/bin/controller.sh ) \
		| awk -F= '/^[\t ]*EVENTS_SERVICE_HEAP_SETTINGS=/{
			$0=substr($2, match($2,/-Xmx[1-9][0-9]*[k,K,m,M,g,G]?/), RLENGTH)
			sub(/^-Xmx/,"")
				if(sub(/[k,K]$/,"")==1){
					BYTES=$0*1024
				}
				else if(sub(/[m,M]$/,"")==1){
					BYTES=$0*1048576
				}
				else if(sub(/[g,G]$/,"")==1){
					BYTES=$0*1073741824
				} else {
					gsub(/[^0-9]/,"")
					BYTES=$0
				}
			}
		END{
			BYTES=BYTES*1.05
			printf("%.0f\n", BYTES)
		}'`
	
	if [ -z "$EVENTS_SERVICE_HEAP" ] ; then
		EVENTS_SERVICE_HEAP=`( runuser cat $EVENTS_SERVICE_VMOPTIONS_FILE ) \
			| awk '/^[\t ]*-Xmx[1-9][0-9]*[k,K,m,M,g,G]?/{
				sub(/^-Xmx/,"")
					if(sub(/[k,K][\t ]*$/,"")==1){
						BYTES=$0*1024
					}
					else if(sub(/[m,M][\t ]*$/,"")==1){
						BYTES=$0*1048576
					}
					else if(sub(/[g,G][\t ]*$/,"")==1){
						BYTES=$0*1073741824
					} else {
						gsub(/[^0-9]/,"")
						BYTES=$0
					}
				}
			END{
				BYTES=BYTES*1.05
				printf("%.0f\n", BYTES)
			}'`
	fi

	if [ -z "$EVENTS_SERVICE_HEAP" ] ; then
		EVENTS_SERVICE_HEAP=0
	fi
		
	# Parse events service JVM options for MaxPermSize.  Default to 64M if not set
	EVENTS_SERVICE_MAXPERMSIZE=`( runuser cat $EVENTS_SERVICE_VMOPTIONS_FILE ) \
		| awk '/^[\t ]*-XX:MaxPermSize=[1-9][0-9]*[k,K,m,M,g,G]?/{
			sub(/^[\t ]*-XX:MaxPermSize=/,"")
				if(sub(/[k,K][\t ]*$/,"")==1){
					BYTES=$0*1024
				}
				else if(sub(/[m,M][\t ]*$/,"")==1){
					BYTES=$0*1048576
				}
				else if(sub(/[g,G][\t ]*$/,"")==1){
					BYTES=$0*1073741824
				} else {
					gsub(/[^0-9]/,"")
					BYTES=$0
				}
			}
		END{
			BYTES=BYTES*1.05
			printf("%.0f\n", BYTES)
		}'`
		
	if [ "$EVENTS_SERVICE_MAXPERMSIZE" -lt 1 ] ; then
		# Java permsize defaults to 64MiB
		EVENTS_SERVICE_MAXPERMSIZE=67108864
	fi
	
	((APPD_TOTAL_RESERVED_BYTES=\
CONTROLLER_HEAP+\
CONTROLLER_MAXPERMSIZE+\
INNODB_BUFFER_POOL+\
INNODB_ADDITIONAL_MEM+\
EVENTS_SERVICE_HEAP+\
EVENTS_SERVICE_MAXPERMSIZE))
	
	((APPD_HUGE_PAGES=APPD_TOTAL_RESERVED_BYTES/HUGE_PAGE_SIZE_BYTES))
	if [ $((APPD_TOTAL_RESERVED_BYTES%HUGE_PAGE_SIZE_BYTES)) -gt 0 ]
		then
		# Round up
		((APPD_HUGE_PAGES++))
	fi
	
	PAGE_SIZE_BYTES=`getconf PAGE_SIZE`
}

#
# Explicitly reserve memory for major contorller components
#
function reserve_memory (){
	#set swappiness to zero
	echo 0 > /proc/sys/vm/swappiness
	
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
			if [[ $(su -c "ulimit -l" $RUNUSER) != "unlimited" ]]
				then
				echo "$RUNUSER  soft  memlock  unlimited" >> /etc/security/limits.d/appdynamics.conf
				echo "$RUNUSER  hard  memlock  unlimited" >> /etc/security/limits.d/appdynamics.conf
			fi
		fi
		
		# check/tweak db.cnf
		if ! cat $DB_CNF | grep -Eq "^\s*large-pages"
			then
			runuser ex -s $APPD_ROOT/db/db.cnf <<- MYSQL_LARGE_PAGES
				/\[mysqld\]/
				+
				i
				large-pages
				.
				wq
			MYSQL_LARGE_PAGES
		fi
		
		# check/tweak domain.xml

		if ! echo "$JVM_OPTIONS" | grep -q "\-XX:+UseLargePages"
			then
			runuser ex -s $DOMAIN_XML <<- JAVA_LARGE_PAGES
				/<config name="server-config">/
				/java-config/
				+
				i
				<jvm-options>-XX:+UseLargePages</jvm-options>
				<jvm-options>-XX:LargePageSizeInBytes=$HUGE_PAGE_SIZE_BYTES</jvm-options>
				.
				wq
			JAVA_LARGE_PAGES
		elif [[ `echo "$JVM_OPTIONS" \
			| awk '/-XX:LargePageSizeInBytes/{
			gsub(/<\/?jvm-options>(-XX:LargePageSizeInBytes=)?/,"");
				if(sub(/[k,K]$/,"")==1){ 
					BYTES=$0*1024 
				}
				else if(sub(/[m,M]$/,"")==1){ 
					BYTES=$0*1048576 
				}
				else if(sub(/[g,G]$/,"")==1){ 
					BYTES=$0*1073741824 
				} else { 
					gsub(/[^0-9]/,"") 
					BYTES=$0 
				} 
				print BYTES; 
				exit;
			}'` != "$HUGE_PAGE_SIZE_BYTES" ]]
			then
				runuser ex -s $DOMAIN_XML <<- ADJUST_LARGE_PAGE_SIZE
					%s/>[\t ]*-XX:LargePageSizeInBytes=.*</>-XX:LargePageSizeInBytes=$HUGE_PAGE_SIZE_BYTES</
					wq
				ADJUST_LARGE_PAGE_SIZE
		fi
		
		# check / tweak events service settings
		if ! ( runuser cat $EVENTS_SERVICE_VMOPTIONS_FILE ) \
			| grep -q "\-XX:+UseLargePages" ; then
			runuser ex -s $EVENTS_SERVICE_VMOPTIONS_FILE <<- EVENTS_SERVICE_LARGE_PAGES
				a
				-XX:+UseLargePages 
				-XX:LargePageSizeInBytes=$HUGE_PAGE_SIZE_BYTES
				.
				wq
			EVENTS_SERVICE_LARGE_PAGES
		# simplify the awk-fu below...
		elif [[ `( runuser cat $EVENTS_SERVICE_VMOPTIONS_FILE ) \
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
			runuser ex -s $EVENTS_SERVICE_VMOPTIONS_FILE <<- ADJUST_EVENT_SERVICE_LARGE_PAGE_SIZE
				%s/-XX:LargePageSizeInBytes=[1-9][0-9]*[k,K,m,M,g,G]\?/-XX:LargePageSizeInBytes=$HUGE_PAGE_SIZE_BYTES/g
				wq
			ADJUST_EVENT_SERVICE_LARGE_PAGE_SIZE
		fi
	else
		# disable controller MySQL and Java huge page support, if it was previously enabled
		# remove "large-pages" from db.cnf
		if cat $DB_CNF | grep -Eq "^\s*large-pages"
			then
			runuser ex -s $APPD_ROOT/db/db.cnf <<- DELETE_MYSQL_LARGE_PAGES
				/^[\t ]*\[mysqld\][\t ]*$/
				/^[\t ]*large-pages[\t ]*$/
				d
				wq
			DELETE_MYSQL_LARGE_PAGES
		fi

		# check/tweak domain.xml
		if echo "$JVM_OPTIONS" | grep -q "\-XX:+UseLargePages"
			then
			runuser ex -s $DOMAIN_XML <<- DELETE_JAVA_LARGE_PAGES
				%s,[\t ]*<jvm-options>[\t ]*-XX:+UseLargePages[\t ]*</jvm-options>[\t ]*\n*,,g
				%s,[\t ]*<jvm-options>[\t ]*-XX:LargePageSizeInBytes=.*</jvm-options>[\t ]*\n*,,g
				wq
			DELETE_JAVA_LARGE_PAGES
		fi
		
		# remove events service large pages config from controller.sh
		if ( runuser cat $EVENTS_SERVICE_VMOPTIONS_FILE ) \
			 | grep -q "^[\t ]*\-XX:+UseLargePages[\t ]*" ; then
			runuser ex -s $EVENTS_SERVICE_VMOPTIONS_FILE <<- DELETE_EVENTS_SERVICE_LARGE_PAGES
				%s/^[\t ]*-XX:+UseLargePages[\t ]*\n//g
				%s/^[\t ]*-XX:LargePageSizeInBytes=.*\n//g
				wq
			DELETE_EVENTS_SERVICE_LARGE_PAGES
		fi
	fi
}

function unreserve_memory(){
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
	# call separately because if _stopControllerAppServer () can "exit 1"
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
controllerversion=`echo "select value from global_configuration_cluster where name='schema.version'" | runuser $APPD_BIN/controller.sh login-db | tail -1`
	if [ ! -z $controllerversion ] ; then
		echo version: $controllerversion
	fi
		echo -n "db running as $RUNUSER - "
		if active ; then
			echo "active"
		else
			echo "passive"
			if replication_disabled ; then
				echo replication disabled
			fi
		fi
		case `echo "select value from global_configuration_local where name='ha.controller.type'" | runuser $APPD_BIN/controller.sh login-db | tail -1` in
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
		
		echo "SHOW SLAVE STATUS\G" | \
			runuser $APPD_BIN/controller.sh login-db | awk \
			'/Slave_IO_State/ {print}
			/Seconds_Behind_Master/ {print} 
			/Master_Server_Id/ {print}
			/Master_Host/ {print}'
	else
		echo "db not running"
	fi
        exit 1  
;;

*)  
        echo "Usage: $0 {start|stop|restart|status}"  
        exit 1  
esac
exit 0 
