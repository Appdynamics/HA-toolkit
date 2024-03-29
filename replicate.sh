#!/bin/bash
# $Id: replicate.sh 3.67 2021-02-15 18:40:32 robnav $
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
CHECKSUM_RUN=ha.run_checksum
DEFAULT_CHECK_PAR_ACROSS_SERVERS=1
DEFAULT_CHECK_REQUESTED_SPLIT=1		# default currently updated below
DEFAULT_RSYNC_REQUESTED_SPLIT=1
DB_START_WAIT=300

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
	local errors=0 i VAL
	local NEWMD5=
	for s in ${appdynamics_service_list[@]}
	do 
		NEWMD5=$(md5sum $APPD_ROOT/HA/$s.sh | cut -d " " -f 1)
		if [[ "$NEWMD5" != `$ssh $host md5sum /etc/init.d/$s 2>/dev/null|cut -d " " -f 1` ]] ; then
			((errors++))
		fi
		for i in default sysconfig ; do
			if [[ -s "/etc/$i/$s" ]] ; then
				VAL=$($ssh $host cat "/etc/$i/$s" 2>/dev/null | awk -F= '$1=="APPD_ROOT" {print $2}')
				[[ -n "$VAL" && "$APPD_ROOT" == "$VAL" ]] || (( ++errors ))
				VAL=$($ssh $host cat "/etc/$i/$s" 2>/dev/null | awk -F= '$1=="RUNUSER" {print $2}')
				[[ -n "$VAL" && "$RUNUSER" == "$VAL" ]] || (( ++errors ))
			fi
		done
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
	local ssh=`[ -n "$host" ] && echo "$SSH -qt"`
	local escalation_type=
	local errors=0
	for s in ${appdynamics_service_list[@]}
	do 
		if $ssh $host test -f $APPD_ROOT/HA/NOROOT > /dev/null ; then
			escalation_type="noroot"
		elif $ssh $host test -x /sbin/appdservice > /dev/null ; then
			if $ssh $host file /sbin/appdservice | grep -q setuid > /dev/null ; then
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
	echo "    [ -P 'c(x,y),r(z)' ] where 'c' is for checksum parallelism, 'r' for rsync parallelism e.g. 'c10,r4' or 'r2'"
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
		warn "only one replicate is allowed at a time; please check"
		warn "pid $repl_pid, and remove $INTERLOCK only if it is not a replicate"
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

#
# determine default job split/parallelisation level - within a host
# (assuming that sha1sum1 mostly consumes CPU and then disk I/O and that available CPU
# is approximated by the number of available CPUs)
#
p=$(wc -l < <(lscpu -p 2>/dev/null | sed '/^#/d'))
if (( p > 0 )) ; then
	DEFAULT_CHECK_REQUESTED_SPLIT=$p
else
	DEFAULT_CHECK_REQUESTED_SPLIT=1		# assume 1 CPU if lscpu -p does not work
fi
# Currently have no clear way to determine available rsync network bandwidth and therefore
# unable to determine whether parallelism > 1 is likely to slow current serial implementation.
# Hence currently leaving DEFAULT_RSYNC_REQUESTED_SPLIT=1

# helper function: ensure that if incoming variable == 0 then it is set to 1
function zero_to_one {
	(( $# == 1 )) || abend "Usage: ${FUNCNAME[0]} <integer>" 
	(( ${!1} == 0 )) && printf -v "$1" %s 1
}
# helper function: ensure incoming variable remains zero else is set to 1
function zero_else_one {
	(( $# == 1 )) || abend "Usage: ${FUNCNAME[0]} <integer>"
	(( ${!1} == 0 )) || printf -v "$1" %s 1
}

# logic to hide the parameter precedence internals and simply echo the correct value
#  CHECK_REQUESTED_SPLIT overrides
#  GLOBAL_REQUESTED_SPLIT overrides
#  DEFAULT_CHECK_REQUESTED_SPLIT
# And
#  CHECK_PAR_ACROSS_SERVERS overrides
#  GLOBAL_PAR_ACROSS_SERVERS overrides
#  DEFAULT_CHECK_PAR_ACROSS_SERVERS
# e.g. 
#  DEFAULT_CHECK_REQUESTED_SPLIT=1 
#  GLOBAL_REQUESTED_SPLIT=12 
#  CHECK_REQUESTED_SPLIT=
# then REQUESTED_SPLIT inside the Checksum component needs to see: 12
# With:
#  DEFAULT_CHECK_REQUESTED_SPLIT=1 
#  GLOBAL_REQUESTED_SPLIT= 
#  CHECK_REQUESTED_SPLIT=
# then REQUESTED_SPLIT inside the Checksum component needs to see: 1
# With:
#  DEFAULT_CHECK_REQUESTED_SPLIT=1 
#  GLOBAL_REQUESTED_SPLIT=
#  CHECK_REQUESTED_SPLIT=19
# then REQUESTED_SPLIT inside the Checksum component needs to see: 19
function get_value {
	(( $# == 1 )) || abend "Usage: ${FUNCNAME[0]} <variable name>"
	# assumes variable name: <MODULE NAME>_<VARIABLE NAME> 
	# where module name cannot contain '_'
	local module=${1%%_*} var=${1#*_} arg=$1 lval
	
	if [[ -n "${!1}" ]] ; then 
		echo ${!1}
	elif lval="GLOBAL_$var" && [[ -n "${!lval}" ]] ; then
		echo "${!lval}"
	elif lval="DEFAULT_${module}_$var" && [[ -n "${!lval}" ]] ; then
		echo "${!lval}"
	else
		echo "get_value: unable to fetch value for: $arg" 1>&2
		return 1
	fi
}

# encapsulate the complex command line parametrization for parallelisation specification
# Sets the global variables:
# GLOBAL_REQUESTED_SPLIT
# GLOBAL_PAR_ACROSS_SERVERS
# CHECK_REQUESTED_SPLIT
# CHECK_PAR_ACROSS_SERVERS
# RSYNC_REQUESTED_SPLIT
#
# Concept is that there is default parametrization for parallelism (no -P command line option)
# which can be overridden from command line either globally for all HA Toolkit components that want 
# to use parallelism else specific Toolkit components can override with tailored parameters.
# The long form for specific component parameters currently looks like:
# -P c(m,n),r(x) which can be shortened to -P c(m,n),rx
# Simply specifying the same level of parametrization for all components is:
# -P (x,y) which can be shortened to -P x,y
# Not specifying the parameters for a component will leave them at their defaults
# -P r(9) which can be shortened to -P r9 sets rsync, r, parallelism at 9 and leaves 
# checksum, c, at its default parallelisation
#
# parallelisation required: <within a server's workload>[,<1 to parallelise across servers, 0 for serial>]
# For example: 25,0 <=> globally split a server's workload 25 ways but run in series with other servers
# x,y        <=> x,(y in (0,1))? y : 1
# x          <=> x,1 if x >= 0
# 0          <=> 1
# <DEFAULT>  <=> c(<# CPUs>,1),r(1)
# <DISABLED> <=> 0,0
#
function parse_parallel_opts {
	(( $# == 1 )) || abend "Usage: ${FUNCNAME[0]} <-P arg>"
	# Global parallelisation parameters
	# -P x OR -P x,y OR -P (x,y)
	global_pattern1='^([[:digit:]]+)(,([[:digit:]]+))?$'
	global_pattern2='^\(([[:digit:]]+)(,([[:digit:]]+))?\)$'
	# component specific parameters
	# -P cx OR -P cx,ry OR c(x,y) OR -P c(x,y),r(m)
	cfirst_all_pattern1='^c([[:digit:]]+)(,r([[:digit:]]+))?$'
	cfirst_all_pattern2='^c\(([[:digit:]]+)(,([[:digit:]]+))?\)(,r\(([[:digit:]]+)\))?$'
	# -P rx OR -P rx,cy OR -P r(x) OR -P r(x),c(m)
	rfirst_all_pattern1='^r([[:digit:]]+)(,c([[:digit:]]+))?$'
	rfirst_all_pattern2='^r\(([[:digit:]]+)\)(,c\(([[:digit:]]+)(,([[:digit:]]+))?\))?$'
	local arg=$1
	if [[ $arg =~ $global_pattern1 || $arg =~ $global_pattern2 ]] ; then
		GLOBAL_REQUESTED_SPLIT=${BASH_REMATCH[1]}
		zero_to_one GLOBAL_REQUESTED_SPLIT
		if [[ -n "${BASH_REMATCH[3]}" ]] ; then
			GLOBAL_PAR_ACROSS_SERVERS=${BASH_REMATCH[3]}
			zero_else_one GLOBAL_PAR_ACROSS_SERVERS
		fi
	elif [[ $arg =~ $cfirst_all_pattern1 ]] ; then
		CHECK_REQUESTED_SPLIT=${BASH_REMATCH[1]}
		zero_to_one CHECK_REQUESTED_SPLIT
		if [[ -n "${BASH_REMATCH[3]}" ]] ; then
			RSYNC_REQUESTED_SPLIT=${BASH_REMATCH[3]}
			zero_to_one RSYNC_REQUESTED_SPLIT
		fi
	elif [[ $arg =~ $cfirst_all_pattern2 ]] ; then
		CHECK_REQUESTED_SPLIT=${BASH_REMATCH[1]}
		zero_to_one CHECK_REQUESTED_SPLIT
		if [[ -n "${BASH_REMATCH[3]}" ]] ; then
			CHECK_PAR_ACROSS_SERVERS=${BASH_REMATCH[3]}
			zero_else_one CHECK_PAR_ACROSS_SERVERS
		fi
		if [[ -n "${BASH_REMATCH[5]}" ]] ; then
			RSYNC_REQUESTED_SPLIT=${BASH_REMATCH[5]}
			zero_to_one RSYNC_REQUESTED_SPLIT
		fi
	elif [[ $arg =~ $rfirst_all_pattern1 ]] ; then
		RSYNC_REQUESTED_SPLIT=${BASH_REMATCH[1]}
		zero_to_one RSYNC_REQUESTED_SPLIT
		if [[ -n "${BASH_REMATCH[3]}" ]] ; then
			CHECK_REQUESTED_SPLIT=${BASH_REMATCH[3]}
			zero_to_one CHECK_REQUESTED_SPLIT
		fi
	elif [[ $arg =~ $rfirst_all_pattern2 ]] ; then
		RSYNC_REQUESTED_SPLIT=${BASH_REMATCH[1]}
		zero_to_one RSYNC_REQUESTED_SPLIT
		if [[ -n "${BASH_REMATCH[3]}" ]] ; then
			CHECK_REQUESTED_SPLIT=${BASH_REMATCH[3]}
			zero_to_one CHECK_REQUESTED_SPLIT
		fi
		if [[ -n "${BASH_REMATCH[5]}" ]] ; then
			CHECK_PAR_ACROSS_SERVERS=${BASH_REMATCH[5]}
			zero_else_one CHECK_PAR_ACROSS_SERVERS
		fi
	else
		usage
		exit 1
	fi
}

# quick way to take a file of 'file-size filename' and a split factor and then create "split" 
# output files each containing roughly 1/split of total disk volume in file names.
# Output 'file-size filename' is written to /tmp/split.N.txt - which are removed to begin with.
# The idea here is to use the output for various parallel tasks each wanting about
# the same amount of work to do.
#
# Assigns to variable named as third parameter.
#
# Some tasks, like rsync, are not perfectly balanced with similar amounts of bytes. There
# appears to be a per-file cost that makes processing many small files slower than fewer
# larger files. This militates for more sophisticated job-split logic in future.
#
# Call as:
#  split_file <file of 'size filename'> <split factor> <local_actual_split_variable_name>
function split_file {
	(( $# == 3 )) || abend "Usage: ${FUNCNAME[0]} <file of 'size filename'> <split factor> <variable to assign ACTUAL_SPLIT to>"
	[[ -f $1 ]] && ( [[ -s $1 ]] || fatal 1 "empty file: $1" )
	local allfiles=$(<$1) 		# local copy in case 1st arg is FIFO
	local pattern='^[[:digit:]]+$' split limit total i sofar sz fn actual_split=$3
	[[ "$2" =~ $pattern ]] || fatal 1 "non numeric arg: $2"
	split=$2

	rm -f ${tmpdir}/split.*.txt
	# get total storage of .ibd files
	total=$(awk '{s+= $1} END {print s}' <<< "${allfiles}")
	(( total > 0 )) || { warn "unable to size input files within $1"; exit 1; }
	limit=$((total / split))

	# send files to each of split.X.txt files in turn until each has ~ 1/$split
	# of total storage. Expect threads to be balanced with roughly same volumes
	# of .ibd data (for seek & sha1sum process)
	for i in $(seq 1 $split); do
   		sofar=0
   		(( i == split )) && limit=total                 # avoid rounding issues, last file gets all remainder
   		while (( sofar < limit )) ; do
      			IFS=$' ' read -r sz fn || break         # no more input
      			echo "$sz $fn" >> ${tmpdir}/split.${i}.txt
      			(( sofar += sz ))
			printf -v "${actual_split}" %s $i	# assigns to variable supplied as 3rd function arg
   		done
	done <<< "${allfiles}"
}

#
# using files fetched from secondary, prepare a checksum script to be run in parallel across
# primary and secondary (and also in parallel on each node if enabled)
#
function prepare_checksum_work {
	(( $# == 1 )) || fatal 1 "prepare_checksum_work needs single integer arg"
	local split=$1
	local allibds=${tmpdir}/secondary.ibds

	[[ -f "${allibds}" ]] || fatal 1 "unable to open ${allibds}"
	if [[ -s "$tmpdir/secondary.ibds" ]] ; then
		split_file ${allibds} ${split} CHECK_ACTUAL_SPLIT	# assigns CHECK_ACTUAL_SPLIT
		$SCP -q $tmpdir/split*.txt $secondary:$tmpdir || fatal 1 "ERROR: unable to scp (path=$SCP) to $secondary"
	fi

	cat <<- 'EOT' > ${tmpdir}/$CHECKSUM_RUN
(( $# >= 3 )) || { echo "ERROR: ha.run_checksum needs at least 3 args on $(hostname)" 1>&2; exit 1; }
split=$1
pattern='^[[:digit:]]+$'
[[ "$split" =~ $pattern ]] || { echo "ERROR: split arg1 is not numeric on $(hostname)" 1>&2; exit 1; }
tmpdir=$2
[[ -d "$tmpdir" ]] || { echo "ERROR: tmpdir does not already exist on $(hostname): $tmpdir" 1>&2; exit 1; }
datadir=$3
[[ -d "$datadir"/controller ]] || { echo "ERROR: unable to find $datadir/controller on $(hostname) - wrong datadir?" 1>&2; exit 1; }
sequence=${4:-0}
[[ "$sequence" =~ $pattern ]] || { echo "ERROR: sequence arg is not numeric on $(hostname)" 1>&2; exit 1; }

function checksum_ibd {
	local sequence=${1:-0}

	awk '
	BEGIN {
        	hunksize = (256 * 1024 * 1024);
		first = 64;
		later = 2;
	}
	{
		size = $1;
		file = $2;
		blocks = int(size / 16384);
        	if (match(file, ".ibd$")) {
                	cmd = "(";
                	hunks = int(size / hunksize) + 1;
			count = first;
			if (blocks < first) { count = blocks; }
                	for (hunk = 0; hunk < hunks; hunk++) {
                        	skip = (hunk * hunksize) / 16384;
                        	cmd = cmd"dd if="file" bs=16k count="count" skip="skip";";
				count = later;
                	}
			if (blocks > first) {
				skip = blocks - 2;
				if (skip < 0) { skip = 0; }
				cmd = cmd"dd if="file" bs=16k count=2 skip="skip;
			}
        		cmd = cmd") 2> /dev/null | sha1sum -";
        		cmd | getline sha1;
        		close(cmd);
        		print file, sha1;
        	}
	}'
}

# older 3.2.57 Bash shells do not support references for array name passing - so use globals
function wait_for_pids {
	local i retc
	
	(( ${#pids[*]} > 0 )) || { echo "ERROR: ${FUNCNAME[0]}: pids array empty" 1>&2; exit 1; }
	(( ${#status[*]} == ${#pids[*]} )) || { echo "ERROR: ${FUNCNAME[0]}: status(${#status[*]}) & pids(${#pids[*]}) arrays not same size" 1>&2; }
	for i in ${pids[*]} ; do
   		wait $i
		retc=$?
		(( retc == 0 )) || { echo "${status[$i]} exited with non-zero $retc" 1>&2; return $retc; }
	done
	return 0
}

if [[ -s "$tmpdir/secondary.ibds" ]] ; then
	# checksum bulk .ibd files
	for i in $(seq 1 $split); do
		[[ -f "${tmpdir}"/split.${i}.txt ]] || { echo "ERROR: unable to find ${tmpdir}/split.${i}.txt on $(hostname)" 1>&2; exit 1; }
	done
	for i in $(seq 1 $split); do
		checksum_ibd $i < ${tmpdir}/split.${i}.txt > ${tmpdir}/split.${i}.out &
		pids+=($!)
		status[$!]="split $i of $split on $(hostname)"	# help narrow down failing sub-task
	done

	wait_for_pids || exit $?

	for i in $(seq 1 $split); do 				# assemble outputs in known location
		cat ${tmpdir}/split.${i}.out >> ${tmpdir}/map.local
	done
fi

if [[ -s "$tmpdir/secondary.nonibds" ]] ; then
	# Checksum smaller files i.e. everything else relevant in $datadir
	# Do not check return code of xargs because there may be many files on $secondary that do not exist on primary
	xargs sha1sum < $tmpdir/secondary.nonibds > >(awk 'NF == 2 { print $2" "$1 } NF > 2 {s=$1; $1=""; $(NF+1)=s; print substr($0,2)}' > ${tmpdir}/nonibds.out) 2> /dev/null

	# instead just check that xargs output file is non-zero in size
	[[ -s "${tmpdir}"/nonibds.out ]] || { echo "ERROR: unable to checksum non-ibd files on $(hostname)" 1>&2; exit 1; }

	# assemble all output in known location
	cat ${tmpdir}/nonibds.out >> ${tmpdir}/map.local
fi

[[ -s "${tmpdir}"/map.local ]] || { echo "ERROR: empty ${tmpdir}/map.local found on $(hostname)" 1>&2; exit 1; }
LC_ALL=C sort -u -k 1 ${tmpdir}/map.local > ${tmpdir}/map.local.sort
	EOT

	$SCP -q ${tmpdir}/$CHECKSUM_RUN $secondary:$tmpdir || fatal 1 "ERROR: unable to scp (path=$SCP) to $secondary"
	# now both primary and secondary should have all they need to run checksums over same filenames at same time
}

#
# run same checksum script on both local and remote node at same time if CHECK_PAR_ACROSS_SERVERS == 1
#
function run_checksums {
	(( $# == 1 )) || fatal 1 "run_checksums needs single integer arg"
	[[ -f "$tmpdir"/$CHECKSUM_RUN ]] || fatal 1 "checksum prepare file does not exist: $tmpdir/$CHECKSUM_RUN"
	local split=$1 i startsecs endsecs pid_prim pid_sec retc=0

	[[ -f "${tmpdir}/$CHECKSUM_RUN" ]] || fatal 1 "ERROR: no ${tmpdir}/$CHECKSUM_RUN found on $(hostname)"
	ssh $secondary "bash -c '[[ -f ${tmpdir}/$CHECKSUM_RUN ]]'" || fatal 1 "ERROR: no ${tmpdir}/$CHECKSUM_RUN found on $secondary"
	
	startsecs=$(date +%s)
	if (( CHECK_PAR_ACROSS_SERVERS > 0 )) ; then
		/bin/bash ${tmpdir}/$CHECKSUM_RUN $split $tmpdir $datadir 1 &
		pid_prim=$!
		$SSH -n $secondary /bin/bash ${tmpdir}/$CHECKSUM_RUN $split $tmpdir $datadir 2 &
		pid_sec=$!
		wait $pid_prim || retc=$?
		wait $pid_sec  || retc=$?	# wait for all children to finish regardless
		(( retc == 0 )) || exit $retc	# return latest error code to shell
	else
		/bin/bash ${tmpdir}/$CHECKSUM_RUN $split $tmpdir $datadir || exit $?
		$SSH -n $secondary /bin/bash ${tmpdir}/$CHECKSUM_RUN $split $tmpdir $datadir || exit $?
	fi
	endsecs=$(date +%s)

	message "checksumming files ($split,$CHECK_PAR_ACROSS_SERVERS) took: $(( endsecs-startsecs )) seconds"

	$SCP -q $secondary:$tmpdir/map.local $tmpdir/map.remote
	$SCP -q $secondary:$tmpdir/map.local.sort $tmpdir/map.remote.sort
}

# older 3.2.57 Bash shells do not support references for array name passing - so use globals
# assumes existence of external arrays: pids status
# ASSUMPTION:
#  this wait_for_pids is assumed to be checking rsync return codes, hence 0, 24 are ignorable
#  called with optional ignorable return codes
function wait_for_pids {
	local i retc

	# simplifies the later stating of return codes that should be ignored
	function ignorable {
        	(( $# > 1 )) || abend "needs at least 2 parameters"
        	local retc=$1
        	local not_found=1 i

        	shift
        	for i in $@ ; do
                	(( retc == i )) && not_found=0 && break
        	done
        	return $not_found
	}
	
	(( ${#pids[*]} > 0 )) || abend "pids array empty"
	(( ${#status[*]} == ${#pids[*]} )) || abend "status(${#status[*]}) & pids(${#pids[*]}) arrays not same size"
	for i in ${pids[*]} ; do
   		wait $i
		retc=$?
		ignorable $retc 0 $@ || fatal 1 "${status[$i]} exited with non-zero return code: $retc"
	done
	return 0
}

#
# Uses existing static workload split logic and available parallelism varaiables to implement a parallel
# rsync with each thread running on a partition of the total files to be considered (--files-from arg).
# Interestingly, the parallel rsync threads all output to same replicate.log file to provide 
# real-time progress by thread.
#
# prsync does not currently work with controller install directory as --files-from overrides existing --exclude 
# options fixing this seems to currently imply either a customised find based on rsync --exclude options or a 
# rewrite of the --exclude option syntax. Otherwise an embedded db/data is also copied and this prevents 
# later replication from working (duplicate UUID etc). 
function prsync {
	(( $# >=2 )) || abend "${FUNCNAME[0]} needs at least 2 args"
	local srcdir=${@: -2:1}		# second last arg is src directory
	local -a pids status
	local startsecs endsecs i cmd fifo RSYNC_ACTUAL_SPLIT local_requested_split

	# get appropriate parallelism value from parameter hierarchy
	local_requested_split=$(get_value RSYNC_REQUESTED_SPLIT) || fatal 1 "get_value error"
	# collect list of files to be rsync'd and then partition them in some way into ${tmpdir}/split.*.txt
	# split_file() assigns local: RSYNC_ACTUAL_SPLIT
	split_file <(cd $srcdir; find . -type f -exec ls -n '{}' + | awk '{s=$5;$1=$2=$3=$4=$5=$6=$7=$8=""; print s,substr($0,9)}' | shuf) $local_requested_split RSYNC_ACTUAL_SPLIT

	startsecs=$(date +%s)
	if (( RSYNC_ACTUAL_SPLIT > 1 )) ; then
		message "  starting parallel ${RSYNC_ACTUAL_SPLIT}-way rsync of $srcdir"

		for i in $(seq 1 $RSYNC_ACTUAL_SPLIT) ; do
			# duplicate code here because want to log exact syntax but shell interpretation of <(...) 
			# happens before "..." expansion AND need output to go to unbuffered sed pipe
			logonly <<< "rsync --files-from=<(awk '{print \$2}' ${tmpdir}/split.$i.txt) $@ 2> >(tee >(cat 1>&2)) | sed -u 's/^/Thread'$i': /"
			# will lose rsync return code unless 'set -o pipefail' in sub-shell
			# note extra logic here to copy STDERR text to STDOUT so that it appears on screen and within log file: 2> >(tee >(cat 1>&2))
			( set -o pipefail; rsync --files-from=<(awk '{print $2}' ${tmpdir}/split.$i.txt) "$@" 2> >(tee >(cat 1>&2)) | sed -u 's/^/Thread'$i': /' >> >(logonly) ) &
			pids+=($!)
			status[$!]="rsync partition $i of $RSYNC_ACTUAL_SPLIT"  # help narrow down failing sub-task
		done

		wait_for_pids 24 || exit $?			# rsync retc==24 if src file has vanished
	elif (( RSYNC_ACTUAL_SPLIT == 1 )) ; then
		logcmd rsync "$@" || exit 1
	else
		fatal 1 "unexpected value: $RSYNC_ACTUAL_SPLIT for RSYNC_ACTUAL_SPLIT"
	fi
	endsecs=$(date +%s)

	message "  rsync of $srcdir completed in $(( endsecs-startsecs )) seconds"
}

# return true if directory X *strictly* contains directory Y else false e.g. 
# includes_dir / /tmp 	returns true
# includes_dir / / 	returns false 		# must strictly contain
function includes_dir {
	(($# == 2 )) || fatal 10 "Usage: ${FUNCNAME[0]} <dir1> <dir2>"
	local dir1=$(cd $1 &> /dev/null && pwd -P)	# normalise directory to ignore symbolic link
	local dir2=$(cd $2 &> /dev/null && pwd -P)	# normalise directory to ignore symbolic link

	if [[ -n "$dir1" && -n "$dir2" ]] && (( ${#dir1} < ${#dir2} )) && [[ "${dir2:0:${#dir1}}" == "$dir1" ]]; then
		return 0
	else
		return 1
	fi
}
#
# *If* MySQL datadir is contained within $APPD_ROOT then we need to exclude it from controller-only copy.
# rsync has odd exclude rules (See "Include/Exclude Pattern Rules" section within https://linux.die.net/man/1/rsync) 
# and so need to catch this case and create a special rsync exclude path that works for rsync e.g.
# datadir in $APPD_ROOT/data    requires EXCLUDE_DATADIR="--exclude=/data"
# datadir in $APPD_ROOT/db/data requires EXCLUDE_DATADIR="--exclude=/db/data"
# else
# datadir outside $APPD_ROOT requires EXCLUDE_DATADIR=""
#
function make_rsync_exclude {
	(($# == 2 )) || fatal 11 "Usage: ${FUNCNAME[0]} <APPD_ROOT> <datadir>"
	local dir1=$(cd $1 &> /dev/null && pwd -P)	# normalise directory to ignore symbolic link
	local dir2=$(cd $2 &> /dev/null && pwd -P)	# normalise directory to ignore symbolic link
	local exclude_dir=""

	if includes_dir "$dir1" "$dir2"; then
		exclude_dir="${dir2:${#dir1}}"		# all of $dir2 minus $dir1
		[[ ${exclude_dir:0:1} == '/' ]] || exclude_dir="/$exclude_dir"	# ensure leading '/'
		exclude_dir="--exclude=$exclude_dir"
	fi
	echo "$exclude_dir"
}

while getopts :s:e:m:a:i:dfhjut:P:nwzEFHMWUS7X flag; do
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
		warn "upgrade currently unsupported"
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
	P)	# <DEFAULT> <=> -P 'c(<# CPUs>,1),r(1)'
		# <ALL PARALLELISM DISABLED> <=> -P 0,0
		# Global settings:
		# -P x OR -P x,y OR -P (x,y)
		# Component specific settings:
		# -P cx OR -P cx,ry OR c(x,y) OR -P c(x,y),r(m)
		# -P rx OR -P rx,cy OR -P r(x) OR -P r(x),c(m)
		parse_parallel_opts $OPTARG
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
		warn "too many machine agents: ${machine_agent[@]} select one, and specify it using -a"
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
	warn "Controller root directory not owned by current user"
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
type awk &> /dev/null || fatal 1 "awk or gawk must be installed"
type shuf &> /dev/null || fatal 1 "GNU coreutils must be installed (for shuf)"

# Emit warning, but do not stop script, if either "Max processes" or "Max open files" not large enough
check_system_limits || warn "IMPORTANT: Controller may break in strange ways unless shell resource limits are large enough."

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
	( set -o pipefail; ${cmd[*]} | logonly 2>&1 )
	return $?	# return with same return code of executed command before pipe
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
	message "stopping local slave"
	sql localhost "STOP SLAVE" >/dev/null 2>&1

	message "delete relay logs"
	sql localhost "RESET SLAVE ALL" >/dev/null 2>&1

	message "delete bin logs"
	sql localhost "RESET MASTER" >/dev/null 2>&1

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
		"$innodb_logdir/ib_logfile*" "$innodb_logdir/ib*_trunc.log" \
		"$datadir/relay-log*" \
		"$datadir/bin-log*" \
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
	if [[ -x check_breaking_changes.sh ]] ; then
		message "checking for version issues"
		./check_breaking_changes.sh 1
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
	replicate_ignore_table=mds_license.enterprise_license
	replicate_wild_ignore_table=controller.mq%41s1
	replicate_wild_ignore_table=controller.cssys%
	replicate_wild_ignore_table=mysql.%
	slave-skip-errors=1507,1517,1062,1032,1451,1237
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
		--exclude=$datadir						\
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
	# all other datadir files, the whole thing
	#
	CHECK_REQUESTED_SPLIT=$(get_value CHECK_REQUESTED_SPLIT) || exit 1
	CHECK_PAR_ACROSS_SERVERS=$(get_value CHECK_PAR_ACROSS_SERVERS) || exit 1
	message "Building data file maps ( with -P 'c($CHECK_REQUESTED_SPLIT,$CHECK_PAR_ACROSS_SERVERS)' )"

	$SSH $secondary mkdir -p $tmpdir
	$SSH $secondary find $datadir  -type f ! -name "auto.cnf" ! -name "relay-log*" ! -name "bin-log*" ! -name "*".ibd -print > $tmpdir/secondary.nonibds
        $SSH $secondary find $datadir  -type f ! -name "relay-log*" ! -name "bin-log*" -name "*".ibd -exec ls -n '{}' + | awk '{s=$5;$1=$2=$3=$4=$5=$6=$7=$8=""; print s,substr($0,9)}' > $tmpdir/secondary.ibds
        $SCP -q $tmpdir/secondary.nonibds $tmpdir/secondary.ibds $secondary:$tmpdir		# ensure same filenames from secondary are compared on both hosts

	if [[ -s "$tmpdir/secondary.nonibds" || -s "$tmpdir/secondary.ibds" ]] ; then
		rm -f $tmpdir/ha.makemap \
			$tmpdir/map.local $tmpdir/map.remote \
			$tmpdir/worklist $tmpdir/difflist

		prepare_checksum_work $CHECK_REQUESTED_SPLIT		# function sets CHECK_ACTUAL_SPLIT
		echo "...using CHECK_REQUESTED_SPLIT=$CHECK_REQUESTED_SPLIT CHECK_ACTUAL_SPLIT=$CHECK_ACTUAL_SPLIT CHECK_PAR_ACROSS_SERVERS=$CHECK_PAR_ACROSS_SERVERS" | logonly
		run_checksums $CHECK_ACTUAL_SPLIT

		# the worklist is all filenames from secondary with different local checksums
		diff $tmpdir/map.local.sort $tmpdir/map.remote.sort | awk '/^[><]/ {print $2}' | sort -u > $tmpdir/worklist

		discrepancies=$(cat $tmpdir/worklist | wc -l)		# reliably returns 0 for missing files also
		# .ibd and non-ibd files are checked separately, so either class absent on secondary can lead to undercounting discrepencies
		if [ $discrepancies -gt 0 ] ; then
			MSG=""
			[[ -s "$tmpdir/secondary.nonibds" ]] || MSG=" + all non .ibd files missing on secondary"
			[[ -s "$tmpdir/secondary.ibds" ]] || MSG=" + all .ibd files missing on secondary"
			message "found $discrepancies datadir discrepancies$MSG"
			cat $tmpdir/worklist | logonly
			$SCP -q $tmpdir/worklist $secondary:/tmp/replicate-prune-worklist
			$SSH $secondary "cat /tmp/replicate-prune-worklist | xargs rm -f"
		else	
			MSG="no datadir discrepancies"
			[[ -s "$tmpdir/secondary.nonibds" ]] || MSG="many datadir discrepencies - only .ibd files present on secondary"
			[[ -s "$tmpdir/secondary.ibds" ]] || MSG="many datadir discrepencies - all .ibd files missing on secondary"
			message "$MSG"
		fi
	else
		message "empty secondary datadir - so everything needs to be copied over"
	fi
fi

#
# copy the controller + data to the secondary
#

if ! echo $JAVA | grep -q $APPD_ROOT ; then
	message "Rsync'ing java: $JAVA"
	$SSH $secondary mkdir -p	${JAVA%bin/java}
	logcmd rsync $rsync_opts \
		$rsync_throttle $rsync_compression \
		${JAVA%bin/java} $JAVADEST
fi

# build special rsync exclude path when datadir inside APPD_ROOT
EXCLUDE_DATADIR=$(make_rsync_exclude $APPD_ROOT $datadir)

message "Rsync'ing Controller: $APPD_ROOT"
logcmd rsync $rsync_opts \
	$rsync_throttle $rsync_compression \
	--exclude=lost+found \
	--exclude=bin/controller.sh \
	--exclude=license.lic \
	--exclude=HA/\*.pid \
	--exclude=db/\*.pid \
	--exclude=logs/\* \
	"$EXCLUDE_DATADIR" \
	--exclude=backup \
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
	message "Rsync'ing Data: $datadir ( with -P 'r($(get_value RSYNC_REQUESTED_SPLIT))' )"
	$SSH $secondary mkdir -p $datadir
	prsync $rsync_opts \
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
	grant_primary=$(get_names $(hostname) <<< "$(getent hosts $(awk 'NR==1 {print $1;exit}' <<< "$(getent ahostsv4 $(hostname))"))" )
	if [[ -z "$grant_primary" ]] ; then
		gripe "Local /etc/hosts does not appear to contain an entry for current hostname: $(hostname)"
		gripe "Please ensure both primary and secondary servers list both servers in their /etc/hosts files...trying to continue"
		grant_primary=$(hostname)
	fi
	grant_secondary=$(get_names $secondary <<< "$($SSH -o StrictHostKeyChecking=no $secondary getent hosts $(awk 'NR==1 {print $1;exit}' <<< "$(getent ahostsv4 $secondary)"))")
	if [[ -z "$grant_secondary" ]] ; then
		gripe "Secondary /etc/hosts does not appear to contain an entry for its hostname: $secondary"
		gripe "Please ensure both primary and secondary servers list both servers in their /etc/hosts files...trying to continue"
		grant_secondary=$secondary
	fi

	#
	# let's probe the canonical hostnames from the local database in case this results in different
	# hostname for MySQL to permit connections from
	#
	sql localhost "FLUSH HOSTS" >/dev/null 2>&1
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
	$OPENSSL genrsa 2048 > $CERTS/ca-key.pem 2>/dev/null
	$OPENSSL req -new -x509 -nodes -days 3650 \
		-key $CERTS/ca-key.pem -out $CERTS/ca-cert.pem -subj "/CN=ca" >/dev/null 2>&1

	#
	# make a pair of host key pairs
	#
	for cn in $primary $secondary ; do
		base=$CERTS/$cn
		echo "making host $cn keypair"
		$OPENSSL req -newkey rsa:2048 \
			-subj "/CN=$cn" -nodes -days 3650 \
			-keyout $base-private.pem -out $base-public.pem >/dev/null 2>&1
		$OPENSSL rsa -in $base-private.pem -out $base-private.pem >/dev/null 2>&1
		$OPENSSL x509 -req -days 3560 -set_serial 01 \
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
dbstartlimit=$(expr $(date +%s) + $DB_START_WAIT)

message "wait for secondary to start"
until sql $secondary "show databases" 2>/dev/null | grep -q "information_schema" ; do
	message "waiting " $(expr $dbstartlimit - $(date +%s)) " more seconds for mysql on $secondary"
	sleep 2
	if [ $(date +%s) -gt $dbstartlimit ] ; then
		fatal 10 "mysql on $secondary failed to start"
	fi
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
