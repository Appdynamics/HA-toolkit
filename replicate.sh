#!/bin/bash
# $Id: replicate.sh 3.44 2018-12-18 13:53:13 cmayer $
#
# install HA to a controller pair
#
# this must be run on the primary, and ssh and rsync must be set up 
# on both machines.
#
# if replication isn't broken before you run this, it certainly will be
# during.
#
# this has very limited sanity checking, so please be very careful.
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

INTERLOCK=REPLICATE_RUNNING

cd $(dirname $0)

LOGFNAME=replicate.log

# source function libraries
. lib/log.sh
. lib/runuser.sh
. lib/conf.sh
. lib/ha.sh
. lib/password.sh
. lib/sql.sh
. lib/status.sh

#
# place to put certs for ssl replication
#
CERTS=$APPD_ROOT/ssl_certs

#
# the services in this list must appear in the order in which they should be
# stopped
#
appdynamics_service_list=( appdcontroller appdcontroller-db )

#
# a place to scribble
#
tmpdir=/tmp/ha.$$

#
# global variables that are to be changed by command line args
#
primary=`hostname`
internal_vip=
external_vip=
monitor=
secondary=
datadir=
innodb_logdir=
debug=false
appserver_only_sync=false
upgrade=false
final=false
hotsync=false
unencrypted=false
start_appserver=true
watchdog_enable=false
ssl_replication=false
ma_ssl_enabled=false
ssl_enabled=false
wildcard=false
unbreak=false
rsync_throttle="--bwlimit=20000"
rsync_compression=""
rsync_opts="-PavpW --del --inplace --exclude=ibdata1"
final_rsync_opts="-PavpW --del --inplace"
machine_agent=""
ma_conf=""
mysql_57=false

#
# make sure that we are running as the appdynamics user in db.cnf
# if this is root, then we don't need a privilege escalation method
#
if [ `id -u` -eq 0 ] ; then
	if [ $RUNUSER != root ] ; then
		fatal 1 "replicate must run as $RUNUSER"
	fi
	running_as_root=true
else
	running_as_root=false
fi

# wrapping bag of portable checks for installed service
function check_installed_service {
   	(( $# == 1 )) || abend "check_installed_service: needs 1 arg"
	
   	local svc_name=$1
   	local chkconfig=$(which /sbin/chkconfig 2>/dev/null)		# returns path if exists
   	local lservice=$service_bin

   	[[ -f /etc/init.d/$svc_name ]] || return 1
	
   	if [[ -n "$chkconfig" ]] ; then
		return $($chkconfig --list $svc_name >/dev/null 2>&1)
   	fi

   	return $($lservice --status-all 2>/dev/null| grep -q '\b'$svc_name'\b')
}

# wrapping bag of portable checks for installed remote service
function remote_check_installed_service {
   	(( $# == 2 )) || abend "check_installed_service: needs 2 args"

   	local host=$1
   	local svc_name=$2
   	local chkconfig=$($SSH -q $host "which /sbin/chkconfig" 2>/dev/null)
   	local lservice=$service_bin

   	$SSH -q $host bash -c "test -f /etc/init.d/$svc_name" || return 1

   	if [[ -n "$chkconfig" ]] ; then
      		return $($SSH -q $host "$chkconfig --list $svc_name >/dev/null 2>&1")
   	fi

   	return $($SSH -q $host "$lservice --status-all 2>/dev/null" | grep -qw "$svc_name")
}

# verify that a required executable / package is installed
# complain and return 1 if not
# local and remote
function require() {
	ret=0
	# args: executable "redhat package" "debian package" 
	if ! [[  -x `which $1 2>/dev/null` ]] ; then
		echo "Unable to find $1 in $PATH"
		echo "Please install with:"
		if [[ -x `which apt-get 2>/dev/null` ]] ; then
			echo "apt-get update && apt-get install $3"
		elif [[ -x `which yum 2>/dev/null` ]] ; then
			echo "yum install $2"
		fi
		ret=1
	fi
	if ! $SSH -q $secondary which $1 2>&1 >/dev/null ; then
		echo "Unable to find $1 in $PATH on $secondary"
		echo "Please install with:"
		if $SSH $secondary which apt-get 2>&1 >/dev/null ; then
			echo "apt-get update && apt-get install $3"
		elif $SSH $secondary which yum 2>&1 >/dev/null ; then
			echo "yum install $2"
		fi
		ret=1
	fi
	return $ret
}

function stop_appdynamics_services()
{
	local host=$1
	local errors=0
	for s in ${appdynamics_service_list[@]}
	do 
		if [ -z "$host" ] ; then
			service $s stop || ((errors++))
		else
			remservice -tq $host $s stop || ((errors++))
		fi
	done
	return $errors;
}

function verify_init_scripts()
{
	if [ -f $APPD_ROOT/HA/NOROOT ] ; then
		return 0
	fi
	local host=$1
	local ssh=`[ -n "$host" ] && echo "$SSH -q"`
	local errors=0
	local NEWMD5=
	for s in ${appdynamics_service_list[@]}
	do 
		NEWMD5=$(md5sum $APPD_ROOT/HA/$s.sh | cut -d " " -f 1)
		if [[ "$NEWMD5" != `$ssh $host md5sum /etc/init.d/$s|cut -d " " -f 1` ]] ; then
			((errors++))
		fi
	done
	if [ $errors -gt 0 ] ; then
		if [ -z $host ] ; then
			echo "\
One or more AppDynamics init scripts are not installed or are out of date.
Please run $APPD_ROOT/HA/install-init.sh as root before proceeding."
		else
			echo "\
One or more AppDynamics init scripts are not installed or are out of date on
$host. Please run $APPD_ROOT/HA/install-init.sh as root on $host
before proceeding."
		fi
	fi
	return $errors;
}

function get_privilege_escalation(){
	local host=$1
	local ssh=`[ -n "$host" ] && echo "$SSH -q"`
	local escalation_type=
	local errors=0
	for s in ${appdynamics_service_list[@]}
	do 
		if $ssh $host test -f $APPD_ROOT/HA/NOROOT ; then
			escalation_type="noroot"
		elif $ssh $host test -x /sbin/appdservice ; then
			if $ssh $host file /sbin/appdservice | grep -q setuid ; then
				escalation_type="setuid"
			else
				escalation_type="pbrun"
			fi
		else
			$ssh $host sudo -nl $service_bin $s start > /dev/null 2>&1 || ((errors++))
			$ssh $host sudo -nl $service_bin $s stop > /dev/null 2>&1 || ((errors++))
			if  [ $errors -lt 1 ] ; then
				escalation_type="sudo"
			else
				escalation_type="unknown"
			fi
		fi
	done
	echo $escalation_type
	return $errors
}

function verify_privilege_escalation(){
	local host=$1
	local errors=0
	local local_priv_escalation=
	local remote_priv_escalation=

	local_priv_escalation=$(get_privilege_escalation)
	if [ $? -gt 0 ] ; then
		echo "\
User $RUNUSER is unable to start and stop appdynamics services
Please ensure that $APPD_ROOT/HA/install-init.sh has been run."
		((errors++))
	fi

	remote_priv_escalation=$(get_privilege_escalation $host)
	if [ $? -gt 0 ] ; then
		echo "\
User $RUNUSER is unable to start and stop appdynamics services on $host.
Please ensure that $APPD_ROOT/HA/install-init.sh has been run on $host."
		((errors++))
	fi
	
	if [ $errors -lt 1 ] && [ "$local_priv_escalation" != "$remote_priv_escalation" ] ; then
		echo "\
The primary and secondary hosts are not using the same privilege escalation
wrapper.

Primary:   $local_priv_escalation
Secondary: $remote_priv_escalation

Please re-run install-init.sh on one or both hosts with the same options."
		((errors++))
	fi
	return $errors
}

function secondary_set_node_name() {
#
# write the secondary hostname into the node-name property
#
	ci_tmp=/tmp/ci-$$.xml
	rm -f $ci_tmp
	message "setting up controller agent on secondary"
	for ci in ${controller_infos[*]} ; do
		$SCP $secondary:$ci $ci_tmp
		controller_info_set $ci_tmp node-name $secondary
		$SCP $ci_tmp $secondary:$ci
	done
	rm -f $ci_tmp
}

function usage()
{
	if [ $# -gt 0 ] ; then
		echo "$*"
	fi
	echo "usage: $0 <options>"
	echo "    -s <secondary hostname>"
	echo "    [ -j ] Synchronize controller app server configurations and related binaries"
	echo "    [ -e [protocol://]<external vip>[:port] ]"
	echo "    [ -i [protocol://]<internal vip>[:port] ]"
	echo "    [ -m <monitoring descriptor> see setmonitor.sh -h"
	echo "    [ -a <machine agent install directory> ]"
	echo "    [ -f ] confirm & do final install and activation"
        echo "    [ -F ] just do final install and activation - no confirm"
	echo "    [ -t [rsync speed limit]]" if unspecified or 0, unlimited
	echo "    [ -U ] unencrypted rsync"
	echo "    [ -z ] enable rsync compression"
#	echo "    [ -u ] upgrade fixup"
	echo "    [ -M ] inhibit ssh connectivity check"
	echo "    [ -E ] unbreak replication"
	echo "    [ -n ] no appserver start"
	echo "    [ -S ] enable SSL for replication traffic"
	echo "    [ -w ] enable watchdog on secondary"
	echo "    [ -W ] use wildcard host in grant"
	echo "    [ -7 ] enable parallel replication for mysql 5.7"
	echo "    [ -h ] print help"
	echo "    [ -X ] use backup for hot sync"
	exit 1
}

#
# only allow one replicate at a time
#
if [ -f $INTERLOCK ] ; then
	#
	# since we scribble our pid into the interlock file
	# this is a soft test for a valid interlock
	#
	repl_pid=$(cat $INTERLOCK)
	if [ -d /proc/$(cat $INTERLOCK) ] ; then
		echo "only one replicate is allowed at a time; please check"
		echo "pid $repl_pid, and remove $INTERLOCK only if it is not a replicate"
		exit 1
	fi
	rm -f $INTERLOCK
fi
echo $$ > $INTERLOCK

log_rename

#
# log versions and arguments
#
message "replication log " `date` "for pid $$"
message "version: " `grep '$Id' $0 | head -1`
message "command line options: " "$@"
message "hostname: " `hostname`
message "appd root: $APPD_ROOT"
message "appdynamics run user: $RUNUSER"

while getopts :s:e:m:a:i:dfhjut:nwzEFHMWUS7X flag; do
	case $flag in
	7)
		mysql_57=true
		;;
	d)
		debug=true
		;;
	s)
		secondary=$OPTARG
		;;
	e)
		external_vip=$OPTARG
		;;
	U)
		unencrypted=true
		;;
	i)
		internal_vip=$OPTARG
		;;
	m)
		monitor_def="$OPTARG"
		monitor_def_flag="-m"
		;;
	j)
		appserver_only_sync=true
	    	;;
	n)
		start_appserver=false
		;;
	M)
		touch NO_SSH_CHECK
		;;
	w)
		watchdog_enable=true
		;;
	S)
		ssl_replication=true
		;;
	X)
		if grep -q ^server-id $APPD_ROOT/db/db.cnf ; then
			hotsync=true
		else
			echo "HA not enabled - hot sync not possible"
		fi
		;;
	u)
		upgrade=true
		echo "upgrade currently unsupported"
		exit 8
		;;
	:)
		# optional arguments are handled here
		if [ $OPTARG = 't' ] ; then
			rsync_throttle=""
		else
			echo "option '$OPTARG' requires a value" 1>&2
			usage
		fi
		;;
	t)
		if echo $OPTARG | grep -q '^-' ; then
			((OPTIND--))
			OPTARG=0
		fi
		if [ $OPTARG -eq 0 ] ; then
			rsync_throttle=""
		else
			rsync_throttle="--bwlimit=$OPTARG"
		fi
		;;
	z)
		rsync_compression="-z"
		;;
	a)
		machine_agent=$(readlink -e "$OPTARG")
		[[ -f "$machine_agent/machineagent.jar" ]] || fatal 1 "-a directory $machine_agent is not a machine agent install directory"
		;;
	F)
		final=true
		;;
	W)
		wildcard=true
		;;
	E)
		echo "type 'confirm' to re-enable replication"
		read confirm
		if [ "$confirm" != confirm ] ; then
			exit 2;
		fi
		unbreak=true
		;;	
	f)
		echo "type 'confirm' to stop appserver and install HA"
		read confirm
		if [ "$confirm" != confirm ] ; then
			exit 2;
		fi
		final=true
		;;
	h)
		if [ -f README ] ; then
			if [ -z "$PAGER" ] ; then
				PAGER=cat
			fi
			$PAGER README
		fi
		usage
		;;
	H|*)
		if [ $flag != H ] ; then
			echo "unknown option flag $OPTARG"
		fi
		usage
		;;
	esac
done
shift $((OPTIND-1))
if [ $# -ne 0 ] ; then
	usage "bad argument: $1"
fi

if [ -z "$secondary" ] ; then
	usage "secondary hostname must be set"
fi

# find the java - we might need to copy it.
if ! export JAVA=$(find_java) ; then
	fatal 10 "cannot find java"
fi

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

if [ -f NO_MACHINE_AGENT ] ; then
	message "suppressing machine agent processing"
	machine_agent=""
fi

if [ -n "$machine_agent" ] ; then
	ma_conf="$machine_agent/conf"
	message "found machine agent in $machine_agent"
	message "copying monitors"
	cp -r monitors/* "$machine_agent/monitors"
	chmod +x "$machine_agent"/monitors/*/*.sh
fi

if [ -z "$internal_vip" ] ; then
	internal_vip=$external_vip
	if [ -z "$internal_vip" ] ; then
		internal_vip=localhost
	fi
fi

eval `parse_vip external_vip $external_vip`
eval `parse_vip internal_vip $internal_vip`

# sanity check - verify that the appd_user and the directory owner are the same
check_sanity
if [ `ls -ld .. | awk '{print $3}'` != `id -un` ] ; then
	echo "Controller root directory not owned by current user"
	exit 1
fi

# check 2-way passwordless ssh works
message "checking 2-way passwordless ssh"
check_ssh_setup $secondary || fatal 1 "2-way passwordless ssh healthcheck failed"

if $appserver_only_sync && $final ; then
	fatal 1 "\
		App-server-only and final sync modes are mutually exclusive.  \
		Please run with -j or -f, not both."
fi

require "ex" "vim-minimal" "vim-tiny" || exit 1
require "rsync" "rsync" "rsync" || exit 1

#
# kill a remote rsyncd if we have one
#
function kill_rsyncd() {
	rsyncd_pid=`$SSH $secondary cat /tmp/replicate.rsync.pid 2>/dev/null`
	if [ ! -z "$rsyncd_pid" ] ; then
		$SSH $secondary kill -9 $rsyncd_pid
	fi
	$SSH $secondary rm -f /tmp/replicate.rsync.pid
}

function cleanup() {
	if [ -n "$secondary" ] ; then
		$SSH $secondary rm -rf $tmpdir
	fi
	rm -rf $tmpdir
	kill_rsyncd
	rm -f $INTERLOCK
}

if ! $debug ; then
	trap cleanup EXIT
fi

cleanup
mkdir -p $tmpdir

function handle_interrupt(){
	echo "Caught interrupt."
	if [[ -n `jobs -p` ]] ; then
		echo "Killing child processes."
		kill $(jobs -p) 2>/dev/null
	fi
	echo "Exiting"
	exit
}

#
# helper function to wrap running a command and dying if it fails
#
function runcmd {
	local cmd="$*"
	if ! $cmd ; then
		fatal 1 "\"$cmd\" command failed"
	fi
}

function logcmd {
	local cmd=($*)
	# declare -p cmd
	echo "${cmd[*]}" | logonly
	${cmd[*]} | logonly 2>&1
}

trap handle_interrupt INT

#
# make sure we are running as the right user
#
if [ -z "$RUNUSER" ] ; then
	fatal 1 user not set in $APPD_ROOT/db/db.cnf
fi

#
# find a compatible cipher - important for speed
#
for ssh_crypto in aes128-gcm@openssh.com aes128-ctr aes128-cbc arcfour128 3des-cbc lose ; do
	if $SSH -c $ssh_crypto $secondary true >/dev/null 2>&1 ; then
		break;
	fi
done
if [ "$ssh_crypto" = "lose" ] ; then
	message "default crypto"
	export RSYNC_RSH=$SSH
else
	message "using $ssh_crypto crypto"
	export RSYNC_RSH="$SSH -c $ssh_crypto"
fi

#
# get the list of controller-info files
#
controller_infos=($(find $APPD_ROOT/appserver/glassfish/domains/domain1/appagent -name controller-info.xml -print))

#
# make sure we aren't replicating to ourselves!
#
myhostname=`hostname`
themhostname=`$SSH $secondary hostname 2>/dev/null`

if [ "$myhostname" = "$themhostname" ] ; then
	fatal 14 "self-replication meaningless"
fi

#
# unbreak replication: only if both sides are kinda happy
#
if $unbreak ; then
	$SCP $APPD_ROOT/bin/controller.sh $secondary:$APPD_ROOT/bin	

      	message "start secondary database"
      	if ! remservice -t $secondary appdcontroller-db start | logonly 2>&1 ; then
		fatal 10 "could not start secondary database"
      	fi

	sql $secondary \
		"update global_configuration_local set value='passive' where name = 'appserver.mode';"
	sql $secondary \
		"update global_configuration_local set value='secondary' where name = 'ha.controller.type';"
	if ! sql $secondary "select value from global_configuration_local" | \
		grep passive ; then
		fatal 17 "cannot unbreak - database on $secondary down"
	fi
	dbcnf_unset skip-slave-start
	dbcnf_unset skip-slave-start $secondary
	sql localhost "start slave"
	sql $secondary "start slave"
	./appdstatus.sh
	exit 0
fi

datadir=`grep ^datadir $APPD_ROOT/db/db.cnf | cut -d = -f 2`
innodb_logdir=`grep ^innodb_log_group_home_dir $APPD_ROOT/db/db.cnf | cut -d = -f 2`
if [ -z "$innodb_logdir" ] ; then
	innodb_logdir="$datadir"
fi

if $unencrypted ; then
	export RSYNC_RSH=$SSH
	RSYNC_PORT=10000
	while echo "" | nc $secondary $RSYNC_PORT >/dev/null 2>&1 ; do
		RSYNC_PORT=$((RSYNC_PORT+1))
	done
	ROOTDEST=rsync://$secondary:$RSYNC_PORT/default$APPD_ROOT
	DATADEST=rsync://$secondary:$RSYNC_PORT/default$datadir
	MADEST="rsync://$secondary:$RSYNC_PORT/default$machine_agent"
	JAVADEST="rsync://$secondary:$RSYNC_PORT/default${JAVA%bin/java}"
	kill_rsyncd
	$SSH $secondary mkdir -p $APPD_ROOT/HA
	$SCP -q $APPD_ROOT/HA/rsyncd.conf $secondary:$APPD_ROOT/HA/rsyncd.conf
	$SSH $secondary rm -f /tmp/rsyncd.log
	$SSH $secondary rsync --daemon --config=$APPD_ROOT/HA/rsyncd.conf \
		--port=$RSYNC_PORT
else
	ROOTDEST=$secondary:$APPD_ROOT
	DATADEST=$secondary:$datadir
	MADEST="$secondary:$machine_agent"
	JAVADEST="$secondary:${JAVA%bin/java}"
fi

if ! $appserver_only_sync ; then

	#
	# sanity check: make sure we don't have the controller.sh interlock active.
	# if there's no controller.sh file, we are the target of an incremental!
	message "assert executable controller.sh"
	if ! [ -x $APPD_ROOT/bin/controller.sh ] ; then
		fatal 15 "copying from disabled controller - BOGUS!"
	fi

	#
	# make sure that the primary database is up.  if not, start it
	#
	if echo "exit" | $APPD_ROOT/HA/mysqlclient.sh 2>&1 | grep -q "ERROR 2003" ; then
		message "starting primary database"
		$APPD_ROOT/bin/controller.sh start-db | logonly 2>&1
	fi

	#
	# make sure replication has stopped
	#
	message "stopping replication"
	sql localhost "STOP SLAVE;RESET SLAVE ALL;RESET MASTER;" >/dev/null 2>&1

	#
	# sanity check: make sure we are not the passive side. replicating the
	# broken half of an HA will be a disaster!  
	# this requires the database to be running on the active side.
	#
	message "assert active side"
	if [ "`get_replication_mode localhost`" != active ] ; then
		fatal 3 "copying from non-active controller - BOGUS!"
	fi

	#
	# force the ha.controller.type to primary, 
	# this should kill the assassin if it running.
	#
	message "force primary"
	sql localhost "update global_configuration_local set value='primary' \
		where name = 'ha.controller.type';"

	#
	# flush tables on the primary
	# this is to force mtimes to sync up with reality on an imperfect copy
	#
	message "flush tables"
	sql localhost "flush tables;"

	# stop the secondary database (and anything else)
	# this may fail totally
	#
	message "stopping secondary db if present"
	( stop_appdynamics_services $secondary || $SSH $secondary bash -c "test -x $APPD_ROOT/bin/controller.sh && $APPD_ROOT/bin/controller.sh stop" ) | logonly 2>&1

	#
	# the secondary loses controller.sh until we are ready
	# this inhibits starting an incomplete controller
	#
	message "inhibit running of secondary and delete mysql/innodb logfiles"
	$SSH $secondary rm -f $APPD_ROOT/bin/controller.sh \
		"$innodb_logdir/ib_logfile*" \
		"$datadir/*log*" \
		$datadir/ibdata1 2>&1 | logonly
	
	#
	# disable automatic start of replication slave
	#
	dbcnf_set skip-slave-start true
fi

#
# if final, make sure the latest init scripts are installed and stop the primary database
#
if $final ; then

	# make sure the latest init scripts are installed on both hosts
	if $running_as_root ; then
		$APPD_ROOT/HA/install-init.sh
		$SSH $secondary $APPD_ROOT/HA/install-init.sh
	else
		if ! verify_init_scripts; then
			missing_init="true" 
		fi
		if ! verify_init_scripts $secondary ; then
			missing_init="true"
		fi
		if [ "$missing_init" = "true" ] ; then
			fatal 7 "Cannot proceed"
		fi
		# verify that we can cause service state changes
		if ! verify_privilege_escalation $secondary ; then
			bad_privilege_escalation="true"
		fi
		if [ "$bad_privilege_escalation" = "true" ] ; then
			fatal 9 "Cannot proceed"
		fi
	fi

	if [ -x numa-patch-controller.sh ] ; then
		message "patching controller.sh for numa"
		./numa-patch-controller.sh
	fi
	if [[ -x userid-patch-controller.sh ]] ; then
		message "patching controller.sh to avoid userid startup/shutdown issues"
		./userid-patch-controller.sh
	fi

	if $hotsync ; then
		message "using backup - no need to stop primary"
	else
		message "stopping primary"
		sql localhost "set global innodb_fast_shutdown=0;"
		rsync_opts=$final_rsync_opts
		rsync_throttle=""
		( stop_appdynamics_services || $APPD_ROOT/bin/controller.sh stop ) | logonly 2>&1
	fi
fi

#
# make sure the db.cnf is HA-enabled.  if the string ^server-id is not there,
# then the primary has not been installed as an HA.
#
message "checking HA installation"
if grep -q ^server-id $APPD_ROOT/db/db.cnf ; then
	message "server-id present"
else
	message "server-id not present"
	cat <<- 'ADDITIONS' >> $APPD_ROOT/db/db.cnf
	# Replication -- MASTER MASTER (for HA installs) -- Should be appended 
	# to the end of the db.cnf file for the PRIMARY controller.
	binlog_cache_size=1M
	max_binlog_cache_size=10240M
	log_bin=bin-log
	log_bin_index=bin-log.index 
	relay_log=relay-log
	relay_log_index=relay-log.index
	innodb_support_xa=1
	sync_binlog=1
	log-slow-slave-statements
	# avoid bin-log writes on secondary
	log_slave_updates=0
	# set compression off if cpu is tight
	slave_compressed_protocol=1
	server-id=666  #  this needs to be unique server ID !!!
	replicate-same-server-id=0
	auto_increment_increment=10
	auto_increment_offset=1
	expire_logs_days=3
	binlog_format=MIXED
	replicate_ignore_table=controller.ejb__timer__tbl
	replicate_ignore_table=controller.connection_validation
	replicate_ignore_table=controller.global_configuration_local
	replicate_wild_ignore_table=controller.mq%
	replicate_wild_ignore_table=mysql.%
	slave-skip-errors=1507,1517,1062,1032,1451
	# added to speed up startup
	innodb_stats_sample_pages=1
	ADDITIONS
	if $mysql_57 ; then
	cat <<- 'ADDITIONS_FOR_57' >> $APPD_ROOT/db/db.cnf
	slave_parallel_type=LOGICAL_CLOCK
	slave_parallel_workers=10
	slave_preserve_commit_order=0
	slave_pending_jobs_size_max=1g
	gtid-mode=ON
	enforce-gtid-consistency=ON
	ADDITIONS_FOR_57
	fi
fi

dbcnf_set socket $datadir/mysql.sock

#
# force server id - for failback
#
dbcnf_set server-id 666

#
# make an empty directory on the secondary if needed
#
message "mkdir if needed"
runcmd $SSH $secondary mkdir -p $APPD_ROOT
runcmd $SSH $secondary mkdir -p $datadir

#
# do a permissive chmod on the entire destination
#
message "chmod destination"
runcmd $SSH $secondary "find $APPD_ROOT -type f -exec chmod u+wr {} +"

#
# check date on both nodes.  rsync is sensitive to skew
#
message "checking clocks"
message "primary date: " `date`
message "secondary date: " `$SSH $secondary date`
rmdate=`$SSH $secondary date +%s`
lodate=`date +%s`
skew=$((rmdate-lodate))
if [ $skew -gt 60 ] || [ $skew -lt -60 ]; then
	fatal 6 unacceptable clock skew: $rmdate $lodate $skew
fi
message "clock skew: $skew"

if $appserver_only_sync ; then
	message "Rsync'ing controller app server only: $APPD_ROOT"
	rsync $rsync_opts $rsync_throttle $rsync_compression               \
	    --exclude=app_agent_operation_logs/\*                          \
		--exclude=db/\*                                                \
		--exclude=logs/\*                                              \
		--exclude=tmp\*                                                \
		--exclude=license.lic					\
		$APPD_ROOT/ $ROOTDEST
		message "Rsyncs complete"
		secondary_set_node_name
		message "removing osgi-cache and generated"
		$SSH $secondary rm -rf \
			$APPD_ROOT/appserver/glassfish/domains/domain1/osgi-cache/\* \
			$APPD_ROOT/appserver/glassfish/domains/domain1/generated/\*
		message "App server only sync done"
	exit 0
fi

#
# clean out the old relay and bin-logs
#
message "Removing old replication logs"
$SSH $secondary "find $datadir -print | grep bin-log | xargs rm  -f"
$SSH $secondary "find $datadir -print | grep relay-log | xargs rm  -f"
$SSH $secondary rm -f $datadir/master.info

if ! $hotsync ; then
	runcmd rm -f $datadir/bin-log* $datadir/relay-log* $datadir/master.info
	#
	# maximum paranoia:  build summaries for the data files and 
	# prune differences
	# caution: gnarly quoting
	#
	# ibd files only do the 32kb at 256MB boundaries
	# innodb files have the following gross structure: 
	#
	# 16k file space header block - contains space id and extent map
	# 16k insert buffer bit map
	# <256MB - 32kb> data                
	#
	# 16k extent map                     | optional repeats
	# 16k insert buffer bit map          |
	# <256MB - 32kb> data                |
	#
	# to detect incomplete rsync's, do the 32k at eof too.
	#
	# all other files, the whole thing
	#
	message "Building data file maps"

	rm -f $tmpdir/ha.makemap \
		$tmpdir/map.local $tmpdir/map.remote \
		$tmpdir/worklist $tmpdir/difflist

cat <<- MAPPROG >$tmpdir/ha.makemap
find $datadir -type f -print | awk '
BEGIN {
	hunksize = (256 * 1024 * 1024);
}
{
        file = \$1;
        if (match(file, ".ibd\$")) {
        	stat = "stat --format=%s "file;
        	stat | getline size;
        	close(stat);
                cmd = "(";
                hunks = int(size / hunksize) + 1;
                for (hunk = 0; hunk < hunks; hunk++) {
                        skip = (hunk * hunksize) / 16384;
                        cmd = cmd"dd if="file" bs=16k count=2 skip="skip";";
                }
		skip = int(size / 16384) - 2;
		if (skip < 0) { skip = 0; }
                cmd = cmd"dd if="file" bs=16k count=2 skip="skip")";
        } else {
                cmd = "dd if="file
        }
        cmd = cmd" 2> /dev/null | sha1sum -";
        cmd | getline sha1;
        close(cmd);
        print file, sha1;
}' > $tmpdir/map.local
MAPPROG

	$SSH $secondary mkdir -p $datadir $tmpdir
	$SCP $tmpdir/ha.makemap $secondary:$tmpdir
	
	bash $tmpdir/ha.makemap
	sort -u $tmpdir/map.local > $tmpdir/map.local.sort

	$SSH $secondary bash $tmpdir/ha.makemap
	$SCP $secondary:$tmpdir/map.local $tmpdir/map.remote
	sort -u $tmpdir/map.remote > $tmpdir/map.remote.sort

	# the difflist is all files different md5's or non-existent on one
	diff $tmpdir/map.local.sort $tmpdir/map.remote.sort | awk '/^[><]/ {print $2}' | sort -u > $tmpdir/difflist

	# the worklist is all files that are different that exist on remote
	fgrep -f $tmpdir/difflist $tmpdir/map.remote | awk '{print $1}' > $tmpdir/worklist

	discrepancies=`wc -w $tmpdir/worklist | awk '{print $1}'`
	if [ $discrepancies -gt 0 ] ; then
		message "found $discrepancies discrepancies"
		cat $tmpdir/worklist | logonly
		$SCP -q $tmpdir/worklist $secondary:/tmp/replicate-prune-worklist
		$SSH $secondary "cat /tmp/replicate-prune-worklist | xargs rm -f"
	else
		message "no discrepancies"
	fi
fi

#
# copy the controller + data to the secondary
#

message "Rsync'ing Controller: $APPD_ROOT"
if ! echo $JAVA | grep -q $APPD_ROOT ; then
	message "Rsync'ing java: $JAVA"
	$SSH $secondary mkdir -p	${JAVA%bin/java}
	logcmd rsync $rsync_opts \
		$rsync_throttle $rsync_compression \
		${JAVA%bin/java} $JAVADEST
fi

logcmd rsync $rsync_opts \
	$rsync_throttle $rsync_compression \
	--exclude=lost+found \
	--exclude=bin/controller.sh \
	--exclude=license.lic \
	--exclude=HA/\*.pid \
	--exclude=db/\*.pid \
	--exclude=logs/\* \
	--exclude=db/data \
	--exclude=db/bin/.status \
	--exclude=app_agent_operation_logs \
	--exclude=appserver/glassfish/domains/domain1/appagent/logs/\* \
	--exclude=tmp \
	$APPD_ROOT/ $ROOTDEST

if [ -n "$machine_agent" ] ; then
	message "Rsync'ing Machine Agent: $machine_agent"
	logcmd rsync $rsync_opts \
		$rsync_throttle $rsync_compression \
		"$machine_agent/" "$MADEST"
fi

if $hotsync ; then
	message "hot sync"
	sql localhost "RESET MASTER; RESET SLAVE;"
	percona/bin/xtrabackup \
		--defaults-file=/opt/AppDynamics/Controller/db/db.cnf \
		--innodb-log-group-home_dir=$innodb_logdir \
		--backup \
		--user=root --password=secret \
		--socket=/ssd/data/mysql.sock \
		--stream=tar 2>/dev/null | $SSH $secondary tar --extract --file=- --directory=$datadir
	$SSH $secondary rm -f $innodb_logdir/ib_logfile\* $datadir/ib_logfile\*
	$SSH $secondary $APPD_ROOT/HA/percona/bin/xtrabackup --prepare --target-dir=$datadir --innodb-log-group-home_dir=$innodb_logdir
	if [ "$datadir" != "$innodb_logdir" ] ; then
		$SSH $secondary mv $datadir/ib_logfile\* $innodb_logdir
	fi
else
	message "Rsync'ing Data: $datadir"
	logcmd rsync $rsync_opts \
		$rsync_throttle $rsync_compression \
		--exclude=lost+found \
		--exclude=ib_logfile\* \
		--exclude=bin-log\* \
		--exclude=relay-log\* \
		--exclude=\*.log \
		--exclude=master.info \
		--exclude=\*.pid \
		--exclude=auto.cnf \
		$datadir/ $DATADEST
	message "Rsyncs complete"
fi

if $final ; then

	if $running_as_root ; then
		$SSH $secondary $APPD_ROOT/HA/install-init.sh
	fi

fi

#
# edit the secondary to change the server id
#
message "changing secondary server id"
dbcnf_set server-id 555 $secondary

#
# if we're only do incremental, then no need to stop primary
#
if ! $final ; then
	#
	# validate init scripts and sudo config
	# and warn user if they need to be updated before final
	#
	if ! $running_as_root ; then
		errors=0
		verify_init_scripts || ((errors++))
		verify_init_scripts $secondary || ((errors++))
		if [ $errors -lt 1 ] ; then
			verify_privilege_escalation $secondary
		fi
	fi
	message "incremental sync done $(date)"
	exit 0
fi

if ! $hotsync ; then
	#
	# restart the primary db
	#
	for logdir in $APPD_ROOT/logs $APPD_ROOT/db/logs ; do
		if [ -f $logdir/database.log ] ; then
			message "rename database log file in $logdir"
			mv $logdir/database.log $logdir/database.log.`date +%F.%T`
			touch $logdir/database.log
		fi
	done

	message "starting primary database"
	# Do not proceed unless the primary starts cleanly or we could end up with
	#  unexpected failovers.
	if ! service appdcontroller-db start | logonly 2>&1 ; then
		fatal 1 "failed to start primary database.  Exiting..."
	fi

	#
	# plug the various communications endpoints into domain.xml
	#
	if [ -n "$external_vip" ] ; then
		message "edit domain.xml deeplink"
		domain_set_jvm_option appdynamics.controller.ui.deeplink.url \
			"$external_vip_protocol://$external_vip_host:$external_vip_port/controller"
		message "set services host and port"
		domain_set_jvm_option appdynamics.controller.services.hostName $external_vip_host
		domain_set_jvm_option appdynamics.controller.services.port $external_vip_port
	fi
fi

#
# send the domain.xml
#
message "copy domain.xml to secondary"
runcmd $SCP -q -p $APPD_ROOT/appserver/glassfish/domains/domain1/config/domain.xml $secondary:$APPD_ROOT/appserver/glassfish/domains/domain1/config/domain.xml

if ! $hotsync ; then
	#
	# write the primary hostname into the node-name property
	#
	echo "setting up controller agent on primary"
	for ci in ${controller_infos[*]} ; do
		controller_info_set $ci node-name $primary
	done
fi

secondary_set_node_name

#
# call the setmonitor script to set the monitoring host and params
#
if [ -n "$machine_agent" ] ; then
	ma_def_flag="-a"
	ma_def="$machine_agent"
fi
./setmonitor.sh -s $secondary -i $internal_vip "$monitor_def_flag" "$monitor_def" "$ma_def_flag" "$ma_def"

if $wildcard ; then
	grant_primary='%'
	grant_secondary='%'
	grant_primary_users="'controller_repl'@'${grant_primary}' IDENTIFIED BY 'controller_repl'"
	grant_secondary_users="'controller_repl'@'${grant_secondary}' IDENTIFIED BY 'controller_repl'"
else
	#
	# Use all /etc/hosts names for both primary and secondary for MySQL GRANT commands - 
	# more robust in the event that /etc/hosts has missing fully qualified names on one
	# host or other /etc/hosts inconsistencies between HA nodes
	# Add to this list the FQDN that MySQL may be able to lookup.
	#
	grant_primary=$(get_names $(hostname) <<< "$(getent hosts $(hostname))" )
	if [[ -z "$grant_primary" ]] ; then
		gripe "Local /etc/hosts does not appear to contain an entry for current hostname: $(hostname)"
		gripe "Please ensure both primary and secondary servers list both servers in their /etc/hosts files...trying to continue"
		grant_primary=$(hostname)
	fi
	grant_secondary=$(get_names $secondary <<< "$($SSH -o StrictHostKeyChecking=no $secondary getent hosts $secondary)")
	if [[ -z "$grant_secondary" ]] ; then
		gripe "Secondary /etc/hosts does not appear to contain an entry for its hostname: $secondary"
		gripe "Please ensure both primary and secondary servers list both servers in their /etc/hosts files...trying to continue"
		grant_secondary=$secondary
	fi

	#
	# let's probe the canonical hostnames from the local database in case this results in different
	# hostname for MySQL to permit connections from
	#
	primary1=`$APPD_ROOT/db/bin/mysql --host=$primary --port=$dbport --protocol=TCP --user=impossible 2>&1 | awk '
		/ERROR 1045/ { gsub("^.*@",""); print $1;}
		/ERROR 1130/ { gsub("^.*Host ",""); print $1;}' | tr -d \'`
	secondary1=`$SSH $secondary $APPD_ROOT/db/bin/mysql --host=$primary --port=$dbport --protocol=TCP --user=impossible 2>&1 | awk '
		/ERROR 1045/ { gsub("^.*@",""); print $1;}
		/ERROR 1130/ { gsub("^.*Host ",""); print $1;}' | tr -d \'`

	#
	# print the canonical hostnames
	#
	if [ "$primary1" = 'ERROR' -o "$secondary1" = 'ERROR' -o -z "$primary1" -o -z "$secondary1" ] ; then
		gripe "cannot establish communications between mysql instances"
		gripe "check firewall rules"
		gripe "primary: $primary1"
		gripe "secondary: $secondary1"
		$APPD_ROOT/db/bin/mysql --host=$primary --port=$dbport --protocol=TCP --user=impossible 2>&1 | log
		$SSH $secondary $APPD_ROOT/db/bin/mysql --host=$primary --port=$dbport --protocol=TCP --user=impossible 2>&1 | log
		fatal 5
	fi
	[[ "$primary1" == "localhost" ]] && primary1=""		# lose this contribution if just localhost
	[[ "$secondary1" == "localhost" ]] && secondary1=""	# lose this contribution if just localhost

	# unique list of hostnames - they might not be reachable though...
	# Exempt special 'loghost' alias as it can appear on separate IP row for each HA server
	grant_primary_unique_hosts=$(sort -u <<< "$(printf '%s\n' $grant_primary $primary1 | fgrep -vw loghost)")
	grant_secondary_unique_hosts=$(sort -u <<< "$(printf '%s\n' $grant_secondary $secondary1 | fgrep -vw loghost)")

	# verify_no_shared_names "$grant_primary_unique_hosts" "$grant_secondary_unique_hosts" || exit 1
	for i in $grant_primary_unique_hosts ; do
		for j in $grant_secondary_unique_hosts ; do
			if [[ "$i" == "$j" ]] ; then
				fatal 5 "The HA servers share a common hostname or alias '$i'. Please fix this and re-run."
			fi
		done
	done

	# prepare comma separated user string for upcoming SQL grant command - duplicate hosts removed
	# e.g. 'controller_repl'@'host1','controller_repl'@'host1alias'
	for i in $grant_primary_unique_hosts; do
		primary_user_arr+=("'controller_repl'@'$i' IDENTIFIED BY 'controller_repl'")
	done
	grant_primary_users=$(IFS=,; echo "${primary_user_arr[*]}")		# comma separate
	for i in $grant_secondary_unique_hosts; do
		secondary_user_arr+=("'controller_repl'@'$i' IDENTIFIED BY 'controller_repl'")
	done
	grant_secondary_users=$(IFS=,; echo "${secondary_user_arr[*]}")		# comma separate
fi

message "primary: $primary grant to: "$grant_primary_unique_hosts
message "secondary: $secondary grant to: "$grant_secondary_unique_hosts

#
# do all the setup needed for ssl; db.cnf and cert creation
#
dbcnf_md5=`md5sum $APPD_ROOT/db/db.cnf | cut  -d " " -f 1`

#
# ssl replication
# start from scratch
#
rm -rf $CERTS
mkdir -p $CERTS
$SSH $secondary rm -rf $CERTS

dbcnf_unset ssl
dbcnf_unset ssl-ca
dbcnf_unset ssl-key
dbcnf_unset ssl-cert
dbcnf_unset ssl-cipher

dbcnf_unset ssl $secondary
dbcnf_unset ssl-ca $secondary
dbcnf_unset ssl-key $secondary
dbcnf_unset ssl-cert $secondary
dbcnf_unset ssl-cipher $secondary

if $ssl_replication ; then

	#
	# make a CA
	#
	openssl genrsa 2048 > $CERTS/ca-key.pem 2>/dev/null
	openssl req -new -x509 -nodes -days 3650 \
		-key $CERTS/ca-key.pem -out $CERTS/ca-cert.pem -subj "/CN=ca" >/dev/null 2>&1

	#
	# make a pair of host key pairs
	#
	for cn in $primary $secondary ; do
		base=$CERTS/$cn
		echo "making host $cn keypair"
		openssl req -newkey rsa:2048 \
			-subj "/CN=$cn" -nodes -days 3650 \
			-keyout $base-private.pem -out $base-public.pem >/dev/null 2>&1
		openssl rsa -in $base-private.pem -out $base-private.pem >/dev/null 2>&1
		openssl x509 -req -days 3560 -set_serial 01 \
			-in $base-public.pem -out $base-cert.pem \
			-CA $CERTS/ca-cert.pem -CAkey $CERTS/ca-key.pem >/dev/null 2>&1
	done

	$SCP -q -r $CERTS $secondary:$CERTS

	message "checking SSL configuration in db.cnf"

	dbcnf_set ssl "" 	
	dbcnf_set ssl-ca "$CERTS/ca-cert.pem"
	dbcnf_set ssl-key "$CERTS/$primary-private.pem"
	dbcnf_set ssl-cert "$CERTS/$primary-cert.pem"
	#dbcnf_set ssl-cipher "AES256-SHA:DHE-DSS-AES256-SHA:DHE-RSA-AES256-SHA"

	dbcnf_set ssl "" $secondary
	dbcnf_set ssl-ca "$CERTS/ca-cert.pem" $secondary
	dbcnf_set ssl-key "$CERTS/$secondary-private.pem" $secondary
	dbcnf_set ssl-cert "$CERTS/$secondary-cert.pem" $secondary
	#dbcnf_set ssl-cipher "AES256-SHA:DHE-DSS-AES256-SHA:DHE-RSA-AES256-SHA" $secondary

	USE_SSL="REQUIRE SSL"
	PRIMARY_SSL=",MASTER_SSL_CAPATH='$CERTS', MASTER_SSL_CA='$CERTS/ca-cert.pem',MASTER_SSL_KEY='$CERTS/$primary-private.pem',MASTER_SSL_CERT='$CERTS/$primary-cert.pem',MASTER_SSL=1"
	SECONDARY_SSL=",MASTER_SSL_CAPATH='$CERTS', MASTER_SSL_CA='$CERTS/ca-cert.pem',MASTER_SSL_KEY='$CERTS/$secondary-private.pem',MASTER_SSL_CERT='$CERTS/$secondary-cert.pem',MASTER_SSL=1"
else
	#
	# delete all the ssl properties in db.cnf
	#
	sed -i '/^[[:space:]]*ssl.*$/d' $APPD_ROOT/db/db.cnf >/dev/null
	USE_SSL=""
	PRIMARY_SSL=""
	SECONDARY_SSL=""
fi

#
# if our db.cnf changed, we need to bounce the local db
#
if [ "$dbcnf_md5" != `md5sum $APPD_ROOT/db/db.cnf | cut  -d " " -f 1` ] ; then
	if $hotsync ; then
		message "hot sync not possible - db.cnf changed"
		exit 1
	else
		message "bouncing database"
		if ! service appdcontroller-db stop ; then
			fatal 1 "-- failed to start primary database.  Exiting..."
		fi
		if ! service appdcontroller-db start ; then
			fatal 1 "-- failed to start primary database.  Exiting..."
		fi
	fi
fi

#
# build the scripts
#
cat >$tmpdir/ha.primary <<- PRIMARY
STOP SLAVE;
RESET SLAVE ALL;
RESET MASTER;
DELETE FROM mysql.user where user='controller_repl';
FLUSH PRIVILEGES;
GRANT REPLICATION SLAVE ON *.* TO $grant_secondary_users $USE_SSL;
CHANGE MASTER TO MASTER_HOST='$secondary', MASTER_USER='controller_repl', MASTER_PASSWORD='controller_repl', MASTER_PORT=$dbport $PRIMARY_SSL;
update global_configuration_local set value = 'active' where name = 'appserver.mode';
update global_configuration_local set value = 'primary' where name = 'ha.controller.type';
truncate ejb__timer__tbl;
PRIMARY

cat > $tmpdir/ha.secondary <<- SECONDARY
STOP SLAVE;
RESET SLAVE ALL;
RESET MASTER;
DELETE FROM mysql.user where user='controller_repl';
FLUSH PRIVILEGES;
GRANT REPLICATION SLAVE ON *.* TO $grant_primary_users $USE_SSL;
CHANGE MASTER TO MASTER_HOST='$primary', MASTER_USER='controller_repl', MASTER_PASSWORD='controller_repl', MASTER_PORT=$dbport $SECONDARY_SSL;
update global_configuration_local set value = 'passive' where name = 'appserver.mode';
update global_configuration_local set value = 'secondary' where name = 'ha.controller.type';
truncate ejb__timer__tbl;
SECONDARY

#
# make all the changes on the primary to force master
#
message "setting up primary slave"
cat $tmpdir/ha.primary | $APPD_ROOT/HA/mysqlclient.sh | logonly

#
# now we need a secondary controller.sh
#
message "copy controller.sh to secondary"
runcmd $SCP -q -p $APPD_ROOT/bin/controller.sh $secondary:$APPD_ROOT/bin

#
# but disable the appserver
#
message "disable secondary appserver"
runcmd $SSH $secondary touch $APPD_ROOT/HA/APPSERVER_DISABLE

#
# make sure the master.info is not going to start replication yet, since it will be
# a stale log position
#
message "remove secondary master.info"
runcmd $SSH $secondary rm -f $datadir/master.info

#
# if there is a secondary doublewrite file, remove it, since it will contain
# stale entries and prevent a successful database startup
#
doublewrite_file=$(dbcnf_get innodb_doublewrite_file)
if [ -n $doublewrite_file ] ; then
	runcmd $SSH $secondary rm -f $doublewrite_file
fi

#
# start the secondary database
#
for logdir in $APPD_ROOT/logs $APPD_ROOT/db/logs ; do
	if $SSH $secondary test -f $logdir/database.log ; then
		message "rename secondary database log file in $logdir"
		$SSH $secondary mv $logdir/database.log $logdir/database.log.`date +%F.%T`
	fi
done

message "start secondary database"
if ! remservice -t $secondary appdcontroller-db start | logonly 2>&1 ; then
	fatal 10 "could not start secondary database"
fi

#
# ugly hack here - there seems to be a small timing problem
#
message "wait for secondary to start"
until sql $secondary "show databases" | grep -q "information_schema" ; do
	message "waiting for mysql to start using $secondary" `date`
	sleep 2
done

#
# make all the changes on the secondary
#
message "setting up secondary slave"
cat $tmpdir/ha.secondary | $SSH $secondary $APPD_ROOT/HA/mysqlclient.sh

#
# close the loop.  make sure the secondary actually got the update
#
if [ "$(get_replication_mode $secondary)" != passive ] ; then
	fatal 18 "secondary set mode failed"
fi

message "removing skip-slave-start from primary"
dbcnf_unset skip-slave-start

message "removing skip-slave-start from secondary"
dbcnf_unset skip-slave-start $secondary

#
# if hot sync, set the log position
#
if $hotsync ; then
	read log_file log_offset <<< $($SSH $secondary cat $datadir/xtrabackup_binlog_info)
	sql $secondary "SET MASTER TO MASTER_LOG_FILE=$log_file, MASTER_LOG_POS=$log_offset'"
	message "SET MASTER TO MASTER_LOG_FILE=$log_file, MASTER_LOG_POS=$log_offset'"
fi

#
# start the replication slaves
#
message "start primary slave"
sql localhost "START SLAVE;"

message "start secondary slave"
sql $secondary "START SLAVE;"

#
# slave status on both ends
#
message "primary slave status"
sql localhost "SHOW SLAVE STATUS" | awk \
	'/Slave_IO_State/ {print}
	 /Seconds_Behind_Master/ {print} 
	 /Master_Server_Id/ {print}
	 /Master_Host/ {print}' | log
sql localhost "SHOW SLAVE STATUS" | awk \
	 '/Master_SSL_Allowed/ { 
		if ($2 == "Yes") {
			print "Using SSL Replication" 
		}
	 }' | log

message "secondary slave status"
sql $secondary "SHOW SLAVE STATUS" | awk \
	'/Slave_IO_State/ {print}
	 /Seconds_Behind_Master/ {print} 
	 /Master_Server_Id/ {print}
	 /Master_Host/ {print} ' | log
sql localhost "SHOW SLAVE STATUS" | awk \
	 '/Master_SSL_Allowed/ { 
		if ($2 == "Yes") {
			print "Using SSL Replication" 
		}
	 }' | log

#
# enable the watchdog, or not.
#
if [ $watchdog_enable = "true" ] ; then
	touch $WATCHDOG_ENABLE
	$SSH $secondary touch $WATCHDOG_ENABLE
else
	rm -f $WATCHDOG_ENABLE
	$SSH $secondary rm -f $WATCHDOG_ENABLE
fi

#
# handle license files - compare creation times, and use latest one
# grab the one over there if newer
#
remote_lic=0
local_lic=0
if $SSH $secondary test -f $APPD_ROOT/license.lic ; then
	remote_lic=`$SSH $secondary grep creationDate $APPD_ROOT/license.lic | \
		 awk -F= '{print $2}'`
fi
if [ -f $APPD_ROOT/license.lic.$secondary ] ; then
	local_lic=`grep creationDate $APPD_ROOT/license.lic.$secondary | \
		awk -F= '{print $2}'`
fi

if [ $local_lic -lt $remote_lic ] ; then
	message "copying license file from secondary"
	$SCP -q $secondary:$APPD_ROOT/license.lic $APPD_ROOT/license.lic.$secondary 
elif [ $local_lic -ne 0 ] ; then
	message "copying license file to  secondary"
	$SCP -q $APPD_ROOT/license.lic.$secondary $secondary:$APPD_ROOT/license.lic
else
	message "SECONDARY LICENSE FILE REQUIRED"
fi

#
# handle odd case - license.lic.$primary is newer
#
copy_lic=0
lic=0
if [ -f $APPD_ROOT/license.lic ] ; then
	lic=`grep creationDate $APPD_ROOT/license.lic | awk -F= '{print $2}'`
fi
if [ -f $APPD_ROOT/license.lic.$primary ] ; then
	copy_lic=`grep creationDate $APPD_ROOT/license.lic.$primary | \
		awk -F= '{print $2}'`
fi

if [ $lic -lt $copy_lic ] ; then
	message "using newer license.lic.$primary"
	cp $APPD_ROOT/license.lic.$primary $APPD_ROOT/license.lic
elif [ $lic -ne 0 ] ; then
	message "saving license to license.lic.$primary"
	cp $APPD_ROOT/license.lic $APPD_ROOT/license.lic.$primary
else
	message "no primary license file"
fi

message "sending primary license file"
$SCP -q $APPD_ROOT/license.lic.$primary $secondary:$APPD_ROOT

#
# now enable the secondary appserver
#
message "enable secondary appserver"
$SSH $secondary rm -f $APPD_ROOT/HA/APPSERVER_DISABLE

#
# restart the appserver
#
if $start_appserver ; then
	message "start primary appserver"
	if ! service appdcontroller start | logonly 2>&1 ; then
		fatal 12 "could not start primary appdcontroller service"
	fi

	message "secondary service start"
	# issues with the command actually starting the watchdog on the secondary.
	# further troubleshooting needed
	if ! remservice -t $secondary appdcontroller start | logonly 2>&1 ; then
		fatal 11 "could not start secondary appdcontroller service"
	fi

	if [ -n "$machine_agent" ] ; then

		message "restart local machine agent"
		service appdynamics-machine-agent stop
		service appdynamics-machine-agent start

		message "restart remote machine agent"
		remservice -t $secondary appdynamics-machine-agent stop
		remservice -t $secondary appdynamics-machine-agent start
	fi
	message "HA setup complete."
fi

cleanup

