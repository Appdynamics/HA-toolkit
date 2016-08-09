#!/bin/bash
#
# $Id: replicate.sh 3.0.1 2016-08-08 13:40:17 cmayer $
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
cd $(dirname $0)

LOGNAME=replicate.log

# source function libraries
. lib/log.sh
. lib/runuser.sh
. lib/conf.sh
. lib/ha.sh
. lib/password.sh
. lib/sql.sh

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
rsync_opts="-PavpW --del --inplace --exclude=ibdata1 --exclude=ib_logfile\*"
final_rsync_opts="-PavpW --del --inplace"
machine_agent=""
ma_conf=""

#
# make sure that we are running as the appdynamics user in db.cnf
# if this is root, then we don't need a privilege escalation method
#
if [ `id -u` -eq 0 ] ; then
	if [ $db_user != root ] ; then
		fatal 1 "replicate must run as $db_user"
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
   	local chkconfig=$(ssh -q $host "which /sbin/chkconfig" 2>/dev/null)
   	local lservice=$service_bin

   	ssh -q $host "bash -c '[[ -f /etc/init.d/$svc_name ]]'" || return 1

   	if [[ -n "$chkconfig" ]] ; then
      		return $(ssh -q $host "$chkconfig --list $svc_name >/dev/null 2>&1")
   	fi

   	return $(ssh -q $host "$lservice --status-all 2>/dev/null" | grep -qw "$svc_name")
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
	if ! ssh -q $secondary which $1 2>&1 >/dev/null ; then
		echo "Unable to find $1 in $PATH on $secondary"
		echo "Please install with:"
		if ssh $secondary which apt-get 2>&1 >/dev/null ; then
			echo "apt-get update && apt-get install $3"
		elif ssh $secondary which yum 2>&1 >/dev/null ; then
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
			remservice -q $host $s stop || ((errors++))
		fi
	done
	return $errors;
}

function verify_init_scripts()
{
	local host=$1
	local ssh=`[ -n "$host" ] && echo "ssh -q"`
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
	local ssh=`[ -n "$host" ] && echo "ssh -q"`
	local escalation_type=
	local errors=0
	for s in ${appdynamics_service_list[@]}
	do 
		if $ssh $host test -x /sbin/appdservice ; then
			if dd if=/sbin/appdservice bs=11 count=1 2>/dev/null \
				| grep -q '^#!/bin/bash' ; then
				escalation_type="pbrun"
			else
				escalation_type="setuid"
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
User $dbuser is unable to start and stop appdynamics services
Please ensure that $APPD_ROOT/HA/install-init.sh has been run."
		((errors++))
	fi

	remote_priv_escalation=$(get_privilege_escalation $host)
	if [ $? -gt 0 ] ; then
		echo "\
User $dbuser is unable to start and stop appdynamics services on $host.
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

function usage()
{
	if [ $# -gt 0 ] ; then
		echo "$*"
	fi
	echo "usage: $0 <options>"
	echo "    -s <secondary hostname>"
#	echo "    [ -j ] Synchronize controller app server configurations and related binaries"
#	echo "           if secondary database is running, leave it running."
	echo "    [ -e [protocol://]<external vip>[:port] ]"
	echo "    [ -i [protocol://]<internal vip>[:port] ]"
	echo "    [ -m url=[protocol://]<controller_monitor>[:port],access_key=\"1-2-3-4\"[,app_name=\"ABC controller\"][,account_name=someaccount] ]"
	echo "    [ -a <machine agent install directory> ]"
	echo "    [ -f ]       do final install and activation"
	echo "    [ -t [rsync speed limit]]" if unspecified or 0, unlimited
	echo "    [ -U ] unencrypted rsync"
	echo "    [ -z ] enable rsync compression"
#	echo "    [ -u ] upgrade fixup"
	echo "    [ -E ] unbreak replication"
	echo "    [ -n ] no appserver start"
	echo "    [ -S ] enable SSL for replication traffic"
	echo "    [ -w ] enable watchdog on secondary"
	echo "    [ -W ] use wildcard host in grant"
	echo "    [ -h ] print help"
	exit 1
}

#
# given a name and url, crack the url and set the 3 variables:
# $name_host, $name_port, $name_protocol
#
function parse_vip()
{
	local vip_name=$1
	local vip_def=$2

	[[ -z "$vip_def" ]] && return

	echo $vip_def | awk -F: -v vip_name=$vip_name '
		BEGIN { 
			host=""; 
			protocol="http";
			port="8090"; 
		}
		/http[s]*:/ {protocol=$1; host=$2; port=$3;next}
		/:/ {host=$1; port=$2;next}
		{host=$1}
		END {
			if (port == "") {
				port = (protocol=="https")?443:8090;
			}
			gsub("^//","",host);
			gsub("[^0-9]*$","",port);
			printf("%s_host=%s\n", vip_name, host);
			printf("%s_port=%s\n", vip_name, port);
			printf("%s_protocol=%s\n", vip_name, protocol);
		}
	'
}

log_rename

#
# log versions and arguments
#
message "replication log " `date`
message "version: " `grep '$Id' $0 | head -1`
message "command line options: " "$@"
message "hostname: " `hostname`
message "appd root: $APPD_ROOT"
message "appdynamics run user: $dbuser"

while getopts :s:e:m:a:i:dfhjut:nwzEFHWUS flag; do
	case $flag in
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
		# parse a controller monitor definition.
		# this takes the form:
		# url=[protocol://]<controller_monitor>[:port],
		# access_key=\"1-2-3-4\"
		# [,app_name=\"ABC controller\"]
		# [,account_name=someaccount]
		#
		controller_monitor_args=$OPTARG
		declare -a vals A
		declare -A cmargs
		# vals array gets comma delimited settings
		IFS=, read -a vals <<< "$controller_monitor_args"
		for i in ${!vals[*]} ; do 
			# then, split the key, value pairs by equals sign
			IFS="=" read -a A <<< "${vals[$i]}"
			# remove any leading/trailing quotes
			noquote=$(sed -e 's/^["'\'']//' -e 's/["'\'']$//' <<< "${A[1]}")
			# assign associative array cmargs
			cmargs[${A[0]}]=${noquote}
		done
		;;
	j)
		appserver_only_sync=true
	    	;;
	n)
		start_appserver=false
		;;
	w)
		watchdog_enable=true
		;;
	S)
		ssl_replication=true
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
		machine_agent=$OPTARG
		[[ -f $machine_agent/machineagent.jar ]] || fatal 1 "-a directory $machine_agent is not a machine agent install directory"
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

if [ -z "$secondary" ] ; then
	usage "secondary hostname must be set"
fi

#
# search for a machine agent in a few likely places
#
if [ -z "$machine_agent" ] ; then
	for ma in ../* ../../* ; do
		if [ -f $ma/machineagent.jar ] ; then
			machine_agent=$ma
			break;
		fi
	done
fi
if [ -n "$machine_agent" ] ; then
	machine_agent=`cd $machine_agent ; pwd -P`
	ma_conf=$machine_agent/conf
	message "found machine agent in $machine_agent"
	message "copying monitors"
	cp -r monitors/* $machine_agent/monitors
	chmod +x $machine_agent/monitors/*/*.sh
fi

if [ -z "$internal_vip" ] ; then
	internal_vip=$external_vip
fi

monitor="${cmargs['url']}"
if [ -z "$monitor" ] ; then
	monitor=$internal_vip
fi

eval `parse_vip external_vip $external_vip`
eval `parse_vip internal_vip $internal_vip`
eval `parse_vip monitor $monitor`

#
# set the monitoring up to reasonable defaults if any portion is not set
#
monitor_access_key=${cmargs['access_key']}
monitor_account=${cmargs['account_name']}
monitor_application=${cmargs['app_name']}

if [ -z "$monitor_account" ] ; then
	if [ "$monitor" = "$internal_vip" ] ; then
		monitor_account=system
	else
		monitor_account=customer1
	fi
fi
if [ -z "$monitor_application" ] ; then
	pair=`echo -e "$primary\n$secondary" | sort | tr '\n' '-' | sed 's/-$//'`
	monitor_application="HA pair $pair"
fi
if [ -z "$monitor_access_key" ] ; then
	if [ "$monitor" != "$internal_vip" ] ; then
		fatal 10 "monitoring access key must be specified for external host"
	fi
fi

# sanity check - verify that the appd_user and the directory owner are the same
if [ `ls -ld .. | awk '{print $3}'` != `id -un` ] ; then
	echo "Controller root directory not owned by current user"
	exit 1
fi

if $appserver_only_sync && $final ; then
	fatal 1 "\
		App-server-only and final sync modes are mutually exclusive.  \
		Please run with -j or -f, not both."
fi

require "ex" "vim-minimal" "vim-tiny" || exit 1
require "rsync" "rsync" "rsync" || exit 1

if $debug ; then
	require "parallel" "moreutils-parallel" "parallel" || exit 1
fi

#
# kill a remote rsyncd if we have one
#
function kill_rsyncd() {
	rsyncd_pid=`ssh $secondary cat /tmp/replicate.rsync.pid 2>/dev/null`
	if [ ! -z "$rsyncd_pid" ] ; then
		ssh $secondary kill -9 $rsyncd_pid
	fi
	ssh $secondary rm -f /tmp/replicate.rsync.pid
}

function cleanup() {
	rm -rf $tmpdir
	kill_rsyncd
}

trap cleanup EXIT
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
if [ -z "$dbuser" ] ; then
	fatal 1 user not set in $APPD_ROOT/db/db.cnf
fi

#
# verify no-password ssh is set up
#
message "assert no password ssh"
if ! ssh -o PasswordAuthentication=no -o StrictHostKeyChecking=no $secondary true ; then
	fatal 4 "no-password ssh not set up"
fi

#
# find a compatible cipher - important for speed
#
for ssh_crypto in aes128-gcm@openssh.com aes128-ctr aes128-cbc arcfour128 3des-cbc lose ; do
	if ssh -c $ssh_crypto $secondary true >/dev/null 2>&1 ; then
		break;
	fi
done
if [ "$ssh_crypto" = "lose" ] ; then
	message "default crypto"
	export RSYNC_RSH=ssh
else
	message "using $ssh_crypto crypto"
	export RSYNC_RSH="ssh -c $ssh_crypto"
fi

#
# make sure we aren't replicating to ourselves!
#
myhostname=`hostname`
themhostname=`ssh $secondary hostname 2>/dev/null`

if [ "$myhostname" = "$themhostname" ] ; then
	fatal 14 "self-replication meaningless"
fi

#
# unbreak replication: only if both sides are kinda happy
#
if $unbreak ; then
	dbcnf_unset skip-slave-start
	dbcnf_unset skip-slave-start $secondary
	sql $primary "start slave"
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
	export RSYNC_RSH=ssh
	RSYNC_PORT=10000
	while echo "" | nc $secondary $RSYNC_PORT >/dev/null 2>&1 ; do
		RSYNC_PORT=$((RSYNC_PORT+1))
	done
	ROOTDEST=rsync://$secondary:$RSYNC_PORT/default$APPD_ROOT
	DATADEST=rsync://$secondary:$RSYNC_PORT/default$datadir
	MADEST=rsync://$secondary:$RSYNC_PORT/default$machine_agent
	kill_rsyncd
	ssh $secondary mkdir -p $APPD_ROOT/HA
	scp -q $APPD_ROOT/HA/rsyncd.conf $secondary:$APPD_ROOT/HA/rsyncd.conf
	ssh $secondary rm -f /tmp/rsyncd.log
	ssh $secondary rsync --daemon --config=$APPD_ROOT/HA/rsyncd.conf \
		--port=$RSYNC_PORT
else
	ROOTDEST=$secondary:$APPD_ROOT
	DATADEST=$secondary:$datadir
	MADEST=$secondary:$machine_agent
fi

if ! $appserver_only_sync ; then

	#
	# sanity check: make sure we don't have the controller.sh interlock active.
	# if there's no controller.sh file, we are the target of an incremental!
	message "assert non-incremental"
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
	sql localhost "STOP SLAVE;RESET SLAVE ALL;RESET MASTER;"

	#
	# sanity check: make sure we are not the passive side. replicating the
	# broken half of an HA will be a disaster!
	message "assert active side"
	if [ "`get_replication_mode localhost`" = passive ] ; then
		fatal 3 "copying from passive controller - BOGUS!"
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
	( stop_appdynamics_services $secondary || ssh $secondary $APPD_ROOT/bin/controller.sh stop ) | logonly 2>&1

	#
	# the secondary loses controller.sh until we are ready
	# this inhibits starting an incomplete controller
	#
	message "inhibit running of secondary and delete mysql/innodb logfiles"
	ssh $secondary rm -f $APPD_ROOT/bin/controller.sh \
		"$innodb_logdir/ib_logfile*"
		"$datadir/*log*" \
		$datadir/ibdata1 | logonly 2>&1
	
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
		ssh $secondary $APPD_ROOT/HA/install-init.sh
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

	message "stopping primary"
	rsync_opts=$final_rsync_opts
	rsync_throttle=""
	( stop_appdynamics_services || $APPD_ROOT/bin/controller.sh stop ) | logonly 2>&1
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
	sync_binlog=0
	log-slow-slave-statements
	# avoid bin-log writes on secondary
	log_slave_updates=0
	# set compression off if cpu is tight
	slave_compressed_protocol=1
	server-id=666  #  this needs to be unique server ID !!!
	replicate-same-server-id=0
	auto_increment_increment=10
	auto_increment_offset=1
	expire_logs_days=8
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
fi

#
# force server id - for failback
#
dbcnf_set server-id 666

#
# make an empty directory on the secondary if needed
#
message "mkdir if needed"
runcmd ssh $secondary mkdir -p $APPD_ROOT
runcmd ssh $secondary mkdir -p $datadir

#
# do a permissive chmod on the entire destination
#
message "chmod destination"
runcmd ssh $secondary "find $APPD_ROOT -type f -exec chmod +wr {} +"

#
# check date on both nodes.  rsync is sensitive to skew
#
message "checking clocks"
message "primary date: " `date`
message "secondary date: " `ssh $secondary date`
rmdate=`ssh $secondary date +%s`
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
		$APPD_ROOT/ $ROOTDEST
		message "Rsyncs complete"
		message "App server only sync done"
		exit 0
else
	#
	# clean out the old relay and bin-logs
	#
	message "Removing old replication logs"
	runcmd rm -f $datadir/bin-log* $datadir/relay-log* $datadir/master.info
	runcmd ssh $secondary "find $datadir -print | grep bin-log | xargs rm  -f"
	runcmd ssh $secondary "find $datadir -print | grep relay-log | xargs rm  -f"
	runcmd ssh $secondary rm -f $datadir/master.info

	#
	# maximum paranoia:  build space ID maps of each of the innodb data files and 
	# prune differences
	# caution: gnarly quoting
	#
	# also, for files <= 1M, checksum the whole thing, not just the first block
	#
	message "Building innodb file maps"
	rm -f $tmpdir/ibdlist.local $tmpdir/ibdlist.remote

	find $datadir/controller \
		-name \*.ibd \
		\( -size -1M -o -size 1M \) \
		-exec sh -c 'echo -n "{} " ; cat {} | md5sum' \; | \
		sort > $tmpdir/ibdlist.small.local

	find $datadir/controller \
		-name \*.ibd \
		-size +1M \
		-exec sh -c 'echo -n "{} " ; od -N 150 -t x4 -A none {} | md5sum' \; | \
		sort > $tmpdir/ibdlist.large.local

	ssh $secondary "find $datadir/controller \
		-name \*.ibd \( -size -1M -o -size 1M \) \
		-exec sh -c 'echo -n \"{} \" ; cat {} | md5sum' \;" | \
		sort > $tmpdir/ibdlist.small.remote
	ssh $secondary "find $datadir/controller \
		-name \*.ibd -size +1M \
		-exec sh -c 'echo -n \"{} \" ; od -N 150 -t x4 -A none {} | md5sum' \;" | \
		sort > $tmpdir/ibdlist.large.remote

	diff $tmpdir/ibdlist.small.local $tmpdir/ibdlist.small.remote | \
		awk '/^>/ {print $2}' > $tmpdir/worklist
	diff $tmpdir/ibdlist.large.local $tmpdir/ibdlist.large.remote | \
		awk '/^>/ {print $2}' >> $tmpdir/worklist
	
	discrepancies=`wc -w $tmpdir/worklist | awk '{print $1}'`
	if [ $discrepancies -gt 0 ] ; then
		message "found $discrepancies discrepancies"
		cat $tmpdir/worklist | logonly
		scp -q $tmpdir/worklist $secondary:/tmp/replicate-prune-worklist
		ssh $secondary "cat /tmp/replicate-prune-worklist | xargs rm -f"
	else
		message "no discrepancies\n"
	fi

	#
	# copy the controller + data to the secondary
	#

	message "Rsync'ing Controller: $APPD_ROOT"
	logcmd rsync $rsync_opts \
		$rsync_throttle $rsync_compression \
		--exclude=lost+found \
	    --exclude=bin/controller.sh \
	    --exclude=license.lic \
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
			$machine_agent/ $MADEST
	fi

	message "Rsync'ing Data: $datadir"
	logcmd rsync $rsync_opts \
		$rsync_throttle $rsync_compression \
		--exclude=lost+found \
	    --exclude=bin-log\* \
	    --exclude=relay-log\* \
	    --exclude=\*.log \
	    --exclude=master.info \
	    --exclude=\*.pid \
	    $datadir/ $DATADEST
	message "Rsyncs complete"
fi

if $final ; then

	if $running_as_root ; then
		ssh $secondary $APPD_ROOT/HA/install-init.sh
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
	message "incremental sync done"
	exit 0
fi

#
# restart the primary db
#
message "starting primary database"
# Do not proceed unless the primary starts cleanly or we could end up with
#  unexpected failovers.
if ! service appdcontroller-db start | logonly 2>&1 ; then
	fatal 1 "failed to start primary database.  Exiting..."
fi

if [ -z "$monitor_access_key" ] ; then
	monitor_access_key=`sql localhost "select access_key from account where name = '$monitor_account'" | get access_key`
	if [ -z "$monitor_access_key" ] ; then
		fatal 11 "could not fetch access key for $monitor_account"
	fi
fi

#
# worst case defaults
#
monitor_host=${monitor_host:-localhost}
monitor_protocol=${monitor_protocol:-http}
monitor_port=${monitor_port:-8090}

message "monitoring host: $monitor_host"
message "monitoring protocol: $monitor_protocol"
message "monitoring port: $monitor_port"
message "monitoring account: $monitor_account"
message "monitoring access key: $monitor_access_key"
message "monitoring application: $monitor_application"

#
# plug the various communications endpoints into domain.xml
#
if [ -n "$external_vip" ] ; then
	message "edit domain.xml deeplink"
	domain_set_jvm_option appdynamics.controller.ui.deeplink.url \
		"$external_vip_protocol://$external_vip_host:$external_vip_port"
fi

if [ -n "$monitor_host" ] ; then
	message "edit domain.xml controller monitoring"
	domain_set_jvm_option appdynamics.controller.hostName $monitor_host
	domain_set_jvm_option appdynamics.controller.port $monitor_port
fi

if [ "$monitor_protocol" == "https" ] ; then
	message "set controller monitoring ssl"
	domain_set_jvm_option appdynamics.controller.ssl.enabled true
fi

if [ -n "$internal_vip_host" ] ; then
	message "set services host and port"
	domain_set_jvm_option appdynamics.controller.services.hostName $internal_vip_host
	domain_set_jvm_option appdynamics.controller.services.port $internal_vip_port
fi

if [ -n "$monitor_account" ] ; then
	message "set controller monitoring account"
	domain_set_jvm_option appdynamics.agent.accountName "$monitor_account"
fi

if [ -n "$monitor_access_key" ] ; then
	message "set controller monitoring account key"
	domain_set_jvm_option appdynamics.agent.accountAccessKey "$monitor_access_key"
fi

if [ -n "$monitor_application" ] ; then
	message "set controller monitoring app name"
	domain_set_jvm_option appdynamics.agent.applicationName "$monitor_application"
fi

#
# make sure all controller-info.xml's are set up properly
# this means the machine agent as well as the appagent
#
controller_infos=(`find $ma_conf \
	$APPD_ROOT/appserver/glassfish/domains/domain1/appagent -name controller-info.xml -print`)

for info in ${controller_infos[*]} ; do
	if [ -f $info ] ; then
		ex -s $info <<- SETMACHINE
			%s/\(<controller-host>\)[^<]*/\1$monitor_host/
			%s/\(<controller-port>\)[^<]*/\1$monitor_port/
			%s/\(<application-name>\)[^<]*/\1$monitor_application/
			%s/\(<account-name>\)[^<]*/\1$monitor_account/
			%s/\(<account-access-key>\)[^<]*/\1$monitor_access_key/
			wq
		SETMACHINE
	fi
	scp -q $info $secondary:$info
done

#
# send the edited domain.xml
#
message "copy domain.xml to secondary"
runcmd scp -q -p $APPD_ROOT/appserver/glassfish/domains/domain1/config/domain.xml $secondary:$APPD_ROOT/appserver/glassfish/domains/domain1/config/domain.xml

#
# write the primary hostname into the node-name property
#
echo "setting up controller agent on primary"
for ci in $APPD_ROOT/appserver/glassfish/domains/domain1/appagent/conf/controller-info.xml \
	$APPD_ROOT/appserver/glassfish/domains/domain1/appagent/ver*/conf/controller-info.xml ; do
	ex -s $ci <<- SETNODE1
		%s/\(<node-name>\)[^<]*/\1$primary/
		wq
	SETNODE1
done

#
# write the secondary hostname into the node-name property
#
message "setting up controller agent on secondary"
for ci in $APPD_ROOT/appserver/glassfish/domains/domain1/appagent/conf/controller-info.xml \
	$APPD_ROOT/appserver/glassfish/domains/domain1/appagent/ver*/conf/controller-info.xml ; do
	ssh $secondary ex -s $ci <<- SETNODE2
		%s/\(<node-name>\)[^<]*/\1$secondary/
		wq
	SETNODE2
done

if $debug ; then
	message "building file lists"
	ls -1 $datadir/controller/* | parallel md5sum | sort -k 2 --buffer-size=10M > $APPD_ROOT/logs/filelist.primary &
	ssh $secondary 'ls -1 '$datadir'/controller/* | parallel md5sum' | sort -k 2 --buffer-size=10M > $APPD_ROOT/logs/filelist.secondary &
	wait
fi

if [ -z $wildcard ] ; then
	#
	# let's probe the canonical hostnames from the local database
	#
	message "canonicalize hostnames"
	primary1=`$APPD_ROOT/db/bin/mysql --host=$primary --port=$dbport --protocol=TCP --user=impossible 2>&1 | awk '
		/ERROR 1045/ { gsub("^.*@",""); print $1;}
		/ERROR 1130/ { gsub("^.*Host ",""); print $1;}' | tr -d \'`

	secondary1=`ssh $secondary $APPD_ROOT/db/bin/mysql --host=$primary --port=$dbport --protocol=TCP --user=impossible 2>&1 | awk '
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
		ssh $secondary $APPD_ROOT/db/bin/mysql --host=$primary --port=$dbport --protocol=TCP --user=impossible 2>&1 | log
		fatal 5
	fi

	[[ $primary1 != localhost ]] && primary=$primary1	# avoid issues with 127.0.0.1 having been set to hostname in /etc/hosts
	[[ $secondary1 != localhost ]] && secondary=$secondary1	# avoid issues with 127.0.0.1 having been set to hostname in /etc/hosts
	grant_primary=$primary
	grant_secondary=$secondary
else
	grant_primary='%'
	grant_secondary='%'
fi

message "primary: $primary"
message "secondary: $secondary"

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
ssh $secondary rm -rf $CERTS

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

	scp -q -r $CERTS $secondary:$CERTS

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
	message "bouncing database"
	if ! service appdcontroller-db stop ; then
		fatal 1 "-- failed to start primary database.  Exiting..."
	fi
	if ! service appdcontroller-db start ; then
		fatal 1 "-- failed to start primary database.  Exiting..."
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
GRANT ALL ON *.* TO 'controller_repl'@'$grant_secondary' IDENTIFIED BY 'controller_repl' $USE_SSL;
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
GRANT ALL ON *.* TO 'controller_repl'@'$grant_primary' IDENTIFIED BY 'controller_repl' $USE_SSL;
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
runcmd scp -q -p $APPD_ROOT/bin/controller.sh $secondary:$APPD_ROOT/bin

#
# but disable the appserver
#
message "disable secondary appserver"
runcmd ssh $secondary touch $APPD_ROOT/HA/APPSERVER_DISABLE

#
# make sure the master.info is not going to start replication yet, since it will be
# a stale log position
#
message "remove master.info"
runcmd ssh $secondary rm -f $datadir/master.info

#
# start the secondary database
#
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
cat $tmpdir/ha.secondary | ssh $secondary $APPD_ROOT/HA/mysqlclient.sh

message "removing skip-slave-start from primary"
dbcnf_unset skip-slave-start

message "removing skip-slave-start from secondary"
dbcnf_unset skip-slave-start $secondary

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
	ssh $secondary touch $WATCHDOG_ENABLE
else
	rm -f $WATCHDOG_ENABLE
	ssh $secondary rm -f $WATCHDOG_ENABLE
fi

#
# handle license files - compare creation times, and use latest one
# grab the one over there if newer
#
remote_lic=0
local_lic=0
if ssh $secondary test -f $APPD_ROOT/license.lic ; then
	remote_lic=`ssh $secondary grep creationDate $APPD_ROOT/license.lic | \
		 awk -F= '{print $2}'`
fi
if [ -f $APPD_ROOT/license.lic.$secondary ] ; then
	local_lic=`grep creationDate $APPD_ROOT/license.lic.$secondary | \
		awk -F= '{print $2}'`
fi

if [ $local_lic -lt $remote_lic ] ; then
	message "copying license file from secondary"
	scp -q $secondary:$APPD_ROOT/license.lic $APPD_ROOT/license.lic.$secondary 
elif [ $local_lic -ne 0 ] ; then
	message "copying license file to  secondary"
	scp -q $APPD_ROOT/license.lic.$secondary $secondary:$APPD_ROOT/license.lic
else
	message "secondary license file required"
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
	message "using newer $license.lic.$primary"
	cp $APPD_ROOT/license.lic.$primary $APPD_ROOT/license.lic
elif [ $lic -ne 0 ] ; then
	message "saving license to $license.lic.$primary"
	cp $APPD_ROOT/license.lic $APPD_ROOT/license.lic.$primary
else
	message "no primary license file"
fi

message "sending primary license file"
scp -q $APPD_ROOT/license.lic.$primary $secondary:$APPD_ROOT

#
# now enable the secondary appserver
#
message "enable secondary appserver"
ssh $secondary rm -f $APPD_ROOT/HA/APPSERVER_DISABLE

#
# make sure host keys are properly set to prevent ssh from hanging
#
message "checking for ssh access issues"
sechost=`sql localhost "show slave status" | get Master_Host`
prihost=`sql $secondary "show slave status" | get Master_Host`
if [ -z "$sechost" -o -z "$prihost" ] ; then
	fatal 21 "prihost: $prihost sechost: $sechost setting failed"
fi

runcmd ssh -o StrictHostKeyChecking=no $sechost ssh -o StrictHostKeyChecking=no $prihost /bin/true

#
# restart the appserver
#
if [ $start_appserver = "true" ] ; then
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

