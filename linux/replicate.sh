#!/bin/bash
#
# $Id: replicate.sh 2.20 2015-08-24 14:38:56 cmayer $
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
primary=`hostname`
internal_vip=
external_vip=
secondary=
def_APPD_ROOT=$(cd $(dirname "$0"); cd .. ; pwd)
APPD_ROOT=$def_APPD_ROOT
dbport=`grep ^port= $APPD_ROOT/db/db.cnf | cut -d = -f 2`
datadir=
upgrade=
final=false
running_as_root=$( [[ $(id -u) -eq 0 ]] && echo "true" || echo "false" )
#
# the services in this list must appear in the order in which they should be
# stopped
#
appdynamics_service_list=( appdcontroller appdcontroller-db )

tmpdir=/tmp/ha.$$

rsync_opts="-PavpW --del --inplace --exclude=ibdata1 --exclude=ib_logfile*"
final_rsync_opts="-PavpW --del --inplace"
rsync_throttle="--bwlimit=20000"
start_appserver=true
watchdog_enable=false
rsync_compression=""
wildcard=

if [ -f /sbin/service ] ; then
	service_bin=/sbin/service
elif [ -f /usr/sbin/service ] ; then
	service_bin=/usr/sbin/service
else 
    echo service not found in /sbin or /usr/sbin - exiting
    exit 13
fi

# execute remote service operation
# args:  flags machine service verb
function remservice {
	if [ `id -u` == 0 ] ; then
		ssh $1 $2 $service_bin $3 $4
	else
		if ssh $2 [ -x /sbin/appdservice ] ; then
			ssh $1 $2 /sbin/appdservice $3 $4
		else
			ssh $1 $2 sudo -n $service_bin $3 $4
		fi
	fi
}

# execute service operation
# args: service verb
function service {
	if [ `id -u` == 0 ] ; then
		$service_bin $1 $2
	else
		if [ -x /sbin/appdservice ] ; then
			/sbin/appdservice $1 $2
		else
			sudo -n $service_bin $1 $2
		fi
	fi
}

function help()
{
	if [ -f README ] ; then
		if [ -n "$PAGER" ] ; then
			$PAGER README
		else
			cat README
		fi
	fi
}

function stop_appdynamics_services()
{
	local secondary=$1
	local errors=0
	for s in ${appdynamics_service_list[@]}
	do 
		if [ -z "$secondary" ] ; then
			service $s stop || ((errors++))
		else
			remservice -tq $secondary $s stop || ((errors++))
		fi
	done
	return $errors;
}

function verify_init_scripts()
{
	local secondary=$1
	local ssh=`[ -n "$secondary" ] && echo "ssh -tq"`
	local errors=0
	local NEWMD5=
	for s in ${appdynamics_service_list[@]}
	do 
		NEWMD5=`sed < $APPD_ROOT/HA/$s.sh \
			-e "/^APPD_ROOT=/s,=.*,=$APPD_ROOT," \
			-e "/^RUNUSER=/s,=.*,=$RUNUSER," | \
			md5sum | cut -d " " -f 1`
		if [[ "$NEWMD5" != `$ssh $secondary md5sum /etc/init.d/$s|cut -d " " -f 1` ]] ; then
			((errors++))
		fi
	done
	if [ $errors -gt 0 ] ; then
		if [ -z $secondary ] ; then
			echo "\
One or more AppDynamics init scripts are not installed or are out of date.
Please run $APPD_ROOT/HA/install-init.sh as root before proceeding."
		else
			echo "\
One or more AppDynamics init scripts are not installed or are out of date on
$secondary.  Please run $APPD_ROOT/HA/install-init.sh as root on $secondary
before proceeding."
		fi
	fi
	return $errors;
}

function verify_privilege_escalation(){
	local secondary=$1
	local ssh=`[ -n "$secondary" ] && echo "ssh -tq"`
	local errors=0
	for s in ${appdynamics_service_list[@]}
	do 
		if ! $ssh $secondary [ -x /sbin/appdservice ] ; then
			$ssh $secondary sudo -nl $service_bin $s start > /dev/null 2>&1 || ((errors++))
			$ssh $secondary sudo -nl $service_bin $s stop > /dev/null 2>&1 || ((errors++))
		fi
	done
	if [ $errors -gt 0 ] ; then
		if [ -z $secondary ] ; then
			echo "\
$RUNUSER is unable to start and stop appdynamics services
Please ensure that $APPD_ROOT/HA/install-init.sh has been run."
		else
			echo "\
$RUNUSER is unable to start and stop appdynamics services on $secondary.
Please ensure that $APPD_ROOT/HA/install-init.sh has been run on $secondary."
		fi
	fi
	return $errors;
}

function usage()
{
	echo "usage: $0 <options>"
	echo "    -s <secondary hostname>"
	echo "    [ -j ] Synchronize controller app server configurations and related binaries"
	echo "           if secondary database is running, leave it running."
	echo "    [ -e [protocol://]<external vip>[:port]"
	echo "    [ -i [protocol://]<internal vip>[:port]"
	echo "    [ -c <controller root directory> ]"
	echo "       default: $def_APPD_ROOT"
	echo "    [ -f ]       do final install and activation"
	echo "    [ -t [rsync speed limit]]" if unspecified or 0, unlimited
	echo "    [ -u ] upgrade fixup"
	echo "    [ -n ] no appserver start"
	echo "    [ -w ] enable watchdog on secondary"
	echo "    [ -z ] enable rsync compression"
	echo "    [ -W ] use wildcard host in grant"
	echo "    [ -h ] print help"
	exit 1
}

function parse_vip()
{
	vip_name=$1
	vip_def=$2

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
			gsub("^//","",host);
			printf("%s_host=%s\n", vip_name, host);
			printf("%s_port=%s\n", vip_name, port);
			printf("%s_protocol=%s\n", vip_name, protocol);
		}
	'
}

while getopts :s:e:i:c:dfhjut:nwzFHW flag; do
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
	i)
		internal_vip=$OPTARG
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
	c)
		APPD_ROOT=$OPTARG
		;;
	F)
		final=true
		;;
	W)
		wildcard=true
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
		help
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

if [ -z "$internal_vip" ] ; then
	internal_vip=$external_vip
fi

eval `parse_vip external_vip $external_vip`
eval `parse_vip internal_vip $internal_vip`

# sanity check - verify that the appd_user and the directory owner are the same
if [ `ls -ld .. | awk '{print $3}'` != `id -un` ] ; then
	echo "Controller root directory not owned by current user"
	exit 1
fi

if [ "$appserver_only_sync" == "true" ] && [ "$final" == "true" ] ; then
	echo "\
App-server-only and final sync modes are mutually exclusive.  Please run with
-j or -f, not both."
	exit 1
fi

if [ "$debug" == "true" ] ; then
	if ! [[ -x `which parallel 2>&1` ]] ; then
		echo "Gnu Parallel must be installed on the local host in order to enable debug mode"
		debug="false"
	fi
	if ! ssh $secondary '[[ -x `which parallel 2>&1` ]]' ; then
		echo "Gnu Parallel must be installed on $secondary in order to enable debug mode"
		debug="false"
	fi
	if [ "$debug" == "false" ] ; then
		exit 1
	fi
fi

function cleanup() {
	rm -rf $tmpdir
}

trap cleanup EXIT
cleanup
mkdir -p $tmpdir

#
# set any variables dependent on command options
#
repl_log=$APPD_ROOT/logs/replicate.log
WATCHDOG_ENABLE=$APPD_ROOT/HA/WATCHDOG_ENABLE
#
# if there's already a replicate log, rename the old one
#
if [ -e $repl_log ] ; then
	echo "  -- replication log renamed" `date` | tee -a $repl_log
	mv $repl_log $repl_log.`date +%F.%T`
fi

#
# log versions and arguments
#
echo "  -- replication log " `date` > $repl_log
echo -n "  -- version: " >> $repl_log 
grep '$Id' $0 | head -1 >> $repl_log
echo "  -- command line options: " "$@" >> $repl_log
echo "  -- hostname: " `hostname` >> $repl_log
echo "  -- appd root: $APPD_ROOT" >> $repl_log

if [ ! -d "$APPD_ROOT" ] ; then
	echo controller root $APPD_ROOT is not a directory | tee -a $repl_log
	usage
fi

if [ -z "$secondary" ] ; then
	echo secondary hostname must be set | tee -a $repl_log
	usage
fi

#
# make sure we are running as the right user
#
RUNUSER=`awk -F= '/^[\t ]*user=/ {print $2}' $APPD_ROOT/db/db.cnf`
if [ -z "$RUNUSER" ] ; then
        echo user not set in $APPD_ROOT/db/db.cnf | tee -a $repl_log
        exit 1
fi
if [ `id -un` != "$RUNUSER" ] ; then
	echo replicate script must be run as $RUNUSER | tee -a $repl_log
	exit 1
fi

echo "  -- appdynamics run user: $RUNUSER" | tee -a $repl_log

#
# verify no-password ssh is set up
#
echo "  -- assert no password ssh" | tee -a $repl_log
if ! ssh -o PasswordAuthentication=no -o StrictHostKeyChecking=no $secondary true ; then
	echo "no-password ssh not set up" | tee -a $repl_log
	exit 4
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
	echo "  -- default crypto" | tee -a $repl_log
	rsync_crypto=
else
	echo "  -- using $ssh_crypto crypto" | tee -a $repl_log
	rsync_crypto="--rsh=ssh -c $ssh_crypto"
fi

#
# make sure we aren't replicating to ourselves!
#
myhostname=`hostname`
themhostname=`ssh $secondary hostname 2>/dev/null`

if [ "$myhostname" = "$themhostname" ] ; then
	echo "  -- self-replication meaningless"
	exit 14
fi

datadir=`grep ^datadir $APPD_ROOT/db/db.cnf | cut -d = -f 2`

if [ "$appserver_only_sync" != "true" ] ; then
	#
	# make sure that the primary database is up.  if not, start it
	#
	if echo "exit" | $APPD_ROOT/bin/controller.sh login-db 2>&1 | grep -q "ERROR 2003" ; then
		echo "  -- starting primary database" | tee -a $repl_log
		$APPD_ROOT/bin/controller.sh start-db >> $repl_log 2>&1
	fi

	#
	# make sure replication has stopped
	#
	echo "  -- stopping replication" | tee -a $repl_log
	echo "STOP SLAVE;RESET SLAVE ALL;RESET MASTER;" | $APPD_ROOT/bin/controller.sh login-db >> $repl_log 2>&1

	#
	# sanity check: make sure we are not the passive side. replicating the
	# broken half of an HA will be a disaster!
	echo "  -- assert active side" | tee -a $repl_log
	if echo "select value from global_configuration where name = 'appserver.mode'" | $APPD_ROOT/bin/controller.sh login-db | grep -q passive ; then
		echo "copying from passive controller - BOGUS!" | tee -a $repl_log
		exit 3
	fi
	
	#
	# force the ha.controller.type to primary, 
	# this should kill the assassin if it running.
	#
	echo "  -- force primary" | tee -a $repl_log
	echo "update global_configuration_local set value='primary' where name = 'ha.controller.type';" | $APPD_ROOT/bin/controller.sh login-db >> $repl_log

	# stop the secondary database (and anything else)
	# this may fail totally
	#
	echo "  -- stopping secondary db if present" | tee -a $repl_log
	( stop_appdynamics_services $secondary || ssh $secondary $APPD_ROOT/bin/controller.sh stop ) >> $repl_log 2>&1

	#
	# the secondary loses controller.sh until we are ready
	# this inhibits starting an incomplete controller
	#
	echo "  -- inhibit running of secondary and delete mysql/innodb logfiles" | tee -a $repl_log
	ssh $secondary "rm -f $APPD_ROOT/bin/controller.sh $datadir/*log*" \
		$datadir/ibdata1 >> $repl_log 2>&1
	
	#
	# disable automatic start of replication slave
	#
	echo "skip-slave-start=true" >> $APPD_ROOT/db/db.cnf
fi

#
# if final, make sure the latest init scripts are installed and stop the primary database
#
if [ $final == 'true' ] ; then

	# make sure the latest init scripts are installed on both hosts
	if [ "$running_as_root" == "false" ] ; then
		if ! verify_init_scripts; then
			missing_init="true" 
		fi
		if ! verify_init_scripts $secondary ; then
			missing_init="true"
		fi
		if [ "$missing_init" = "true" ] ; then
			echo "Cannot proceed"
			exit 7
		fi
		# verify that we can cause service state changes
		if ! verify_privilege_escalation ; then
			bad_sudo="true"
		fi
		if ! verify_privilege_escalation $secondary ; then
			bad_sudo="true"
		fi
		if [ "$bad_sudo" = "true" ] ; then
			echo "Cannot proceed"
			exit 9
		fi
	else
		$APPD_ROOT/HA/install-init.sh
		ssh $secondary $APPD_ROOT/HA/install-init.sh
	fi

	echo "  -- stopping primary" | tee -a $repl_log
	rsync_opts=$final_rsync_opts
	rsync_throttle=""
	( stop_appdynamics_services || $APPD_ROOT/bin/controller.sh stop ) >> $repl_log 2>&1
fi

#
# make sure the db.cnf is HA-enabled.  if the string ^server-id is not there,
# then the primary has not been installed as an HA.
#
echo "  -- checking HA installation" | tee -a $repl_log
if grep -q ^server-id $APPD_ROOT/db/db.cnf ; then
	echo "  --   server-id present" | tee -a $repl_log
else
	echo "  --   server-id not present" | tee -a $repl_log
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
	log-slave-updates
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
#ed -s $APPD_ROOT/db/db.cnf <<- SETID
ex -s $APPD_ROOT/db/db.cnf <<- SETID
/^server-id=/s,=.*,=666,
wq
SETID

#
# make an empty directory on the secondary if needed
#
echo "  -- mkdir if needed" | tee -a $repl_log
ssh $secondary mkdir -p $APPD_ROOT >> $repl_log 2>&1 
ssh $secondary mkdir -p $datadir >> $repl_log 2>&1 

#
# do a permissive chmod on the entire destination
#
echo "  -- chmod destination" | tee -a $repl_log
ssh $secondary "find $APPD_ROOT -type f -exec chmod +wr {} +" >> $repl_log 2>&1 

#
# check date on both nodes.  rsync is sensitive to skew
#
echo "  -- checking clocks" | tee -a $repl_log
echo -n "primary date: " >> $repl_log
date >> $repl_log 2>&1 
echo -n "secondary date: " >> $repl_log
ssh $secondary date >> $repl_log 2>&1 
rmdate=`ssh $secondary date +%s`
lodate=`date +%s`
skew=`echo "sqrt(($rmdate-$lodate)^2)" | bc`
if [ $skew -gt 60 ] ; then
	echo unacceptable clock skew: $rmdate $lodate $skew
	exit 6
fi
echo "  --   clock skew: $skew" | tee -a $repl_log

if [ "$appserver_only_sync" == "true" ] ; then
	echo "  -- Rsync'ing controller app server only: $APPD_ROOT" | tee -a $repl_log
	rsync $rsync_opts "$rsync_crypto" $rsync_throttle $rsync_compression               \
	    --exclude=app_agent_operation_logs/\*                          \
		--exclude=db/\*                                                \
		--exclude=logs/\*                                              \
		--exclude=tmp\*                                                \
		$APPD_ROOT/ $secondary:$APPD_ROOT >> $repl_log
		echo "  -- Rsyncs complete" | tee -a $repl_log
		echo "  -- App server only sync done" | tee -a $repl_log
		exit 0
else
	#
	# clean out the old relay and bin-logs
	#
	echo "  -- Removing old replication logs" | tee -a $repl_log
	rm -f $datadir/bin-log* $datadir/relay-log* $datadir/master.info | tee -a $repl_log 2>&1
	ssh $secondary "find $datadir -print | grep bin-log | xargs rm  -f" | tee -a $repl_log 2>&1
	ssh $secondary "find $datadir -print | grep relay-log | xargs rm  -f" | tee -a $repl_log 2>&1
	ssh $secondary rm -f $datadir/master.info | tee -a $repl_log 2>&1

	#
	# maximum paranoia:  build space ID maps of each of the innodb data files and prune differences
	# caution: gnarly quoting
	#
	echo "  -- Building innodb file maps" | tee -a $repl_log
	rm -f $tmpdir/ibdlist.local $tmpdir/ibdlist.remote
	find $datadir/controller \
		-name \*.ibd \
		-exec sh -c 'echo -n {} ; od -j 40 -N 4 -t d4 -A none {}' \; | \
		sort > $tmpdir/ibdlist.local

	ssh $secondary "find $datadir/controller -name \*.ibd -exec sh -c 'echo -n {} ; od -j 40 -N 4 -t d4 -A none {}' \;" | sort > $tmpdir/ibdlist.remote

	diff $tmpdir/ibdlist.local $tmpdir/ibdlist.remote | awk '/^>/ {print $2}' > $tmpdir/worklist
	
	discrepancies=`wc -w $tmpdir/worklist | awk '{print $1}'`
	if [ $discrepancies -gt 0 ] ; then
		printf "  --   found %d discrepancies\n" $discrepancies | tee -a $repl_log
		cat $tmpdir/worklist | tee -a $repl_log
		scp $tmpdir/worklist $secondary:/tmp/replicate-prune-worklist
		ssh $secondary "cat /tmp/replicate-prune-worklist | xargs rm"
	fi

	#
	# copy the controller + data to the secondary
	#
	echo "  -- Rsync'ing Controller: $APPD_ROOT" | tee -a $repl_log
	rsync $rsync_opts "$rsync_crypto" $rsync_throttle $rsync_compression                \
	    --exclude=bin/controller.sh					                    \
	    --exclude=license.lic						                    \
		--exclude=logs/\*							                    \
		--exclude=db/data/\*                                            \
		--exclude=db/bin/.status                                        \
		--exclude=app_agent_operation_logs/\*                           \
		--exclude=appserver/glassfish/domains/domain1/appagent/logs/\*  \
		--exclude=tmp/\*                                                \
		$APPD_ROOT/ $secondary:$APPD_ROOT >> $repl_log
	echo "  -- Rsync'ing Data: $datadir" | tee -a $repl_log
	rsync $rsync_opts "$rsync_crypto" $rsync_throttle $rsync_compression                \
	    --exclude=bin-log\*						                        \
	    --exclude=relay-log\*					                        \
	    --exclude=\*.log						                        \
	    --exclude=master.info                                           \
	    --exclude=\*.pid                                                \
	    --exclude=ib_logfile\*                                          \
	    $datadir/ $secondary:$datadir >> $repl_log
	if [ "$final" == "true" ] ; then
		echo "  -- Rsync'ing Partmax Data files: $datadir" | tee -a $repl_log
		rsync $rsync_opts "$rsync_crypto" -c $rsync_compression                         \
		$datadir/controller/*PARTMAX* $secondary:$datadir/controller >> $repl_log
	fi
	echo "  -- Rsyncs complete" | tee -a $repl_log
fi

if [ "$final" == "true" ] ; then

	if [ "$running_as_root" == "true" ] ; then
		ssh $secondary $APPD_ROOT/HA/install-init.sh
	fi

	#
	# make sure the machine agent, if installed, reports to the internal vip
	# since we don't know where the machine agent is, look in a few likely places
	#
	for mif in $APPD_ROOT/MachineAgent/conf/controller-info.xml \
			$APPD_ROOT/../MachineAgent/conf/controller-info.xml ; do
		if [ -f $APPD_ROOT/MachineAgent/conf/controller-info.xml ] ; then
			if [ -f "$mif" ] ; then
				ex -s $mif <<- SETMACHINE
					%s/\(<controller-host>\)[^<]*/\1$internal_vip_host/
					%s/\(<controller-port>\)[^<]*/\1$internal_vip_port/
					wq
				SETMACHINE
			fi
		fi
	done
fi

#
# always update the changeid - this marks the secondary
#
cat > $tmpdir/ha.changeid <<- 'CHANGEID'
/^server-id=/s,666,555,
wq
CHANGEID

#
# edit the secondary to change the server id
#
echo "  -- changing secondary server id" | tee -a $repl_log
cat $tmpdir/ha.changeid | ssh $secondary ex -s $APPD_ROOT/db/db.cnf >> $repl_log 2>&1

#
# if we're only do incremental, then no need to stop primary
#
if [ $final == 'false' ] ; then
	#
	# validate init scripts and sudo config
	# and warn user if they need to be updated before final
	#
	if [ "$running_as_root" == 'false' ] ; then
		verify_init_scripts
		verify_init_scripts $secondary
		verify_privilege_escalation
		verify_privilege_escalation $secondary
	fi
	echo "  -- incremental sync done" | tee -a $repl_log
	exit 0
fi

#
# plug the external hostname, protocol and port into the domain.xml
#
if [ -n "$external_vip" ] ; then
	echo "  -- edit domain.xml to point at external host" | tee -a $repl_log
	if [ "$internal_vip_protocol" == "https" ] ; then
		if grep -q appdynamics.controller.ssl.enabled $APPD_ROOT/appserver/glassfish/domains/domain1/config/domain.xml ; then
			ex -s $APPD_ROOT/appserver/glassfish/domains/domain1/config/domain.xml <<- SETHTTPS
				%s/\(-Dappdynamics.controller.ssl.enabled=\)[^<]*/\1true/
			SETHTTPS
		else
			ex -s $APPD_ROOT/appserver/glassfish/domains/domain1/config/domain.xml <<- ADDHTTPS
				/-Dappdynamics.controller.hostName/a
				<jvm-options>-Dappdynamics.controller.ssl.enabled=true</jvm-options>
				.
			ADDHTTPS
		fi
	fi
	ex -s $APPD_ROOT/appserver/glassfish/domains/domain1/config/domain.xml <<- SETHOST
		%s/\(-Dappdynamics.controller.hostName=\)[^<]*/\1$internal_vip_host/
		%s/\(-Dappdynamics.controller.port=\)[^<]*/\1$internal_vip_port/
		%s/\(-Dappdynamics.controller.services.hostName=\)[^<]*/\1$internal_vip_host/
		%s/\(-Dappdynamics.controller.services.port=\)[^<]*/\1$internal_vip_port/
		%s,\(-Dappdynamics.controller.ui.deeplink.url=\)[^<]*,\1$external_vip_protocol://$external_vip_host:$external_vip_port,
		wq
	SETHOST
fi

#
# send the edited domain.xml
#
echo "  -- copy domain.xml to secondary" | tee -a $repl_log
scp -p $APPD_ROOT/appserver/glassfish/domains/domain1/config/domain.xml $secondary:$APPD_ROOT/appserver/glassfish/domains/domain1/config/domain.xml >> $repl_log 2>&1

#
# write the primary hostname into the node-name property
#
echo "  -- setting up controller agent on primary" | tee -a $repl_log
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
echo "  -- setting up controller agent on secondary" | tee -a $repl_log
for ci in $APPD_ROOT/appserver/glassfish/domains/domain1/appagent/conf/controller-info.xml \
	$APPD_ROOT/appserver/glassfish/domains/domain1/appagent/ver*/conf/controller-info.xml ; do
	ssh $secondary ex -s $ci <<- SETNODE2
		%s/\(<node-name>\)[^<]*/\1$secondary/
		wq
	SETNODE2
done

if [ "$debug" = "true" ] ; then
	echo "  -- building file lists" | tee -a $repl_log
	ls -1 $datadir/controller/* | parallel md5sum | sort -k 2 --buffer-size=10M > $APPD_ROOT/logs/filelist.primary &
	ssh $secondary 'ls -1 '$datadir'/controller/* | parallel md5sum' | sort -k 2 --buffer-size=10M > $APPD_ROOT/logs/filelist.secondary &
	wait
fi

#
# restart the primary db
#
echo "  -- starting primary database" | tee -a $repl_log
# Do not proceed unless the primary starts cleanly or we could end up with
#  unexpected failovers.
if ! service appdcontroller-db start >> $repl_log 2>&1 ; then
	echo "-- failed to start primary database.  Exiting..." | tee -a $repl_log
	exit 1
fi

if [ -z $wildcard ] ; then
	#
	# let's probe the canonical hostnames from the local database
	#
	echo "  -- canonicalize hostnames" | tee -a $repl_log
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
		echo "cannot establish communications between mysql instances" | tee -a $repl_log
		echo "check firewall rules" | tee -a $repl_log
		echo "primary: $primary1" | tee -a $repl_log
		echo "secondary: $secondary1" | tee -a $repl_log
		$APPD_ROOT/db/bin/mysql --host=$primary --port=$dbport --protocol=TCP --user=impossible 2>&1 | tee -a $repl_log
		ssh $secondary $APPD_ROOT/db/bin/mysql --host=$primary --port=$dbport --protocol=TCP --user=impossible 2>&1 | tee -a $repl_log
		exit 5
	fi

	primary=$primary1
	secondary=$secondary1
	grant_primary=$primary
	grant_secondary=$secondary
else
	grant_primary='%'
	grant_secondary='%'
fi

echo "  -- primary: $primary" | tee -a $repl_log
echo "  -- secondary: $secondary" | tee -a $repl_log

#
# build the scripts
#

cat >$tmpdir/ha.primary <<- PRIMARY
STOP SLAVE;
RESET SLAVE ALL;
RESET MASTER;
GRANT ALL ON *.* TO 'controller_repl'@'$grant_secondary' IDENTIFIED BY 'controller_repl';
FLUSH HOSTS;
CHANGE MASTER TO MASTER_HOST='$secondary', MASTER_USER='controller_repl', MASTER_PASSWORD='controller_repl', MASTER_PORT=$dbport;
update global_configuration_local set value = 'active' where name = 'appserver.mode';
update global_configuration_local set value = 'primary' where name = 'ha.controller.type';
truncate ejb__timer__tbl;
PRIMARY

cat > $tmpdir/ha.secondary <<- SECONDARY
STOP SLAVE;
RESET SLAVE ALL;
RESET MASTER;
GRANT ALL ON *.* TO 'controller_repl'@'$grant_primary' IDENTIFIED BY 'controller_repl'; FLUSH HOSTS;
CHANGE MASTER TO MASTER_HOST='$primary', MASTER_USER='controller_repl', MASTER_PASSWORD='controller_repl', MASTER_PORT=$dbport;
update global_configuration_local set value = 'passive' where name = 'appserver.mode';
update global_configuration_local set value = 'secondary' where name = 'ha.controller.type';
truncate ejb__timer__tbl;
SECONDARY

cat > $tmpdir/ha.enable <<- 'DISABLE'
g/^skip-slave-start/d
wq
DISABLE

#
# make all the changes on the primary to force master
#
echo "  -- setting up primary slave" | tee -a $repl_log
cat $tmpdir/ha.primary | $APPD_ROOT/bin/controller.sh login-db >> $repl_log 2>&1

#
# now we need a secondary controller.sh
#
echo "  -- copy controller.sh to secondary" | tee -a $repl_log
scp -p $APPD_ROOT/bin/controller.sh $secondary:$APPD_ROOT/bin >> $repl_log 2>&1

#
# but disable the appserver
#
echo "  -- disable secondary appserver" | tee -a $repl_log
ssh $secondary touch $APPD_ROOT/HA/APPSERVER_DISABLE >> $repl_log 2>&1

#
# make sure the master.info is not going to start replication yet, since it will be
# a stale log position
#
echo "  -- remove master.info" | tee -a $repl_log
ssh $secondary rm -f $datadir/master.info >> $repl_log 2>&1

#
# start the secondary database
#
echo "  -- start secondary database" | tee -a $repl_log
if ! remservice -t $secondary appdcontroller-db start >> $repl_log 2>&1 ; then
	echo "could not start secondary database"
	exit 10
fi

#
# ugly hack here - there seems to be a small timing problem
#
echo "  -- wait for secondary to start" | tee -a $repl_log
until echo "show databases" | ssh $secondary $APPD_ROOT/bin/controller.sh login-db | grep -q "information_schema" ; do
	echo `date` "waiting for mysql to start using $secondary" | tee -a $repl_log
	sleep 2
done

#
# make all the changes on the secondary
#
echo "  -- setting up secondary slave" | tee -a $repl_log
cat $tmpdir/ha.secondary | ssh $secondary $APPD_ROOT/bin/controller.sh login-db >> $repl_log 2>&1

echo "  -- removing skip-slave-start from primary" | tee -a $repl_log
cat $tmpdir/ha.enable | ex -s $APPD_ROOT/db/db.cnf
echo "  -- removing skip-slave-start from secondary" | tee -a $repl_log
cat $tmpdir/ha.enable | ssh $secondary ex -s $APPD_ROOT/db/db.cnf

#
# start the replication slaves
#
echo "  -- start primary slave" | tee -a $repl_log
echo "START SLAVE;" | $APPD_ROOT/bin/controller.sh login-db >> $repl_log 2>&1

echo "  -- start secondary slave" | tee -a $repl_log
echo "START SLAVE;" | ssh $secondary $APPD_ROOT/bin/controller.sh login-db >> $repl_log 2>&1

#
# slave status on both ends
#
echo "  -- primary slave status " | tee -a $repl_log
echo "SHOW SLAVE STATUS\G" | \
	$APPD_ROOT/bin/controller.sh login-db | \
	awk '/Slave_IO_State/ {print}
	/Seconds_Behind_Master/ {print} 
	/Master_Server_Id/ {print}
	/Master_Host/ {print}' | \
	tee -a $repl_log 2>&1
echo "  -- secondary slave status " | tee -a $repl_log
echo "SHOW SLAVE STATUS\G" | \
	ssh $secondary $APPD_ROOT/bin/controller.sh login-db | \
	awk '/Slave_IO_State/ {print}
	/Seconds_Behind_Master/ {print} 
	/Master_Server_Id/ {print}
	/Master_Host/ {print}' | \
	tee -a $repl_log

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
if ssh $secondary [ -f $APPD_ROOT/license.lic ] ; then
	remote_lic=`ssh $secondary grep creationDate $APPD_ROOT/license.lic | \
		 awk -F= '{print $2}'`
fi
if [ -f $APPD_ROOT/license.lic.$secondary ] ; then
	local_lic=`grep creationDate $APPD_ROOT/license.lic.$secondary | \
		awk -F= '{print $2}'`
fi

if [ $local_lic -lt $remote_lic ] ; then
	echo "  -- copying license file from secondary" | tee -a $repl_log
	scp $secondary:$APPD_ROOT/license.lic $APPD_ROOT/license.lic.$secondary 
elif [ $local_lic -ne 0 ] ; then
	echo "  -- copying license file to  secondary" | tee -a $repl_log
	scp $APPD_ROOT/license.lic.$secondary $secondary:$APPD_ROOT/license.lic
else
	echo "  -- secondary license file required" | tee -a $repl_log
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
	echo "  -- using newer $license.lic.$primary" | tee -a $repl_log
	cp $APPD_ROOT/license.lic.$primary $APPD_ROOT/license.lic
elif [ $lic -ne 0 ] ; then
	echo "  -- saving license to $license.lic.$primary" | tee -a $repl_log
	cp $APPD_ROOT/license.lic $APPD_ROOT/license.lic.$primary
else
	echo "  -- no primary license file" | tee -a $repl_log
fi

echo "  -- sending primary license file" | tee -a $repl_log
scp $APPD_ROOT/license.lic.$primary $secondary:$APPD_ROOT

#
# now enable the secondary appserver
#
echo " -- enable secondary appserver" | tee -a $repl_log
ssh $secondary rm -f $APPD_ROOT/HA/APPSERVER_DISABLE >> $repl_log 2>&1

#
# make sure host keys are properly set to prevent ssh from hanging
#
eval `echo "show slave status\G" | $APPD_ROOT/bin/controller.sh login-db |
	awk 'BEGIN {OFS=""} /Master_Host/ {print "sechost=",$2}'`
eval `echo "show slave status\G" | ssh $secondary $APPD_ROOT/bin/controller.sh login-db |
	awk 'BEGIN {OFS=""} /Master_Host/ {print "prihost=",$2}'`
ssh -o StrictHostKeyChecking=no $sechost ssh -o StrictHostKeyChecking=no $prihost /bin/true

#
# restart the appserver
#
if [ $start_appserver = "true" ] ; then
	echo "  -- start primary appserver" | tee -a $repl_log
	if ! service appdcontroller start >> $repl_log 2>&1 ; then
		echo "could not start primary appdcontroller service"
		exit 12
	fi

	echo "  -- secondary service start" | tee -a $repl_log
	# issues with the command actually starting the watchdog on the secondary.
	# further troubleshooting needed
	if ! remservice -t $secondary appdcontroller start >> $repl_log 2>&1; then
		echo "could not start secondary appdcontroller service"
		exit 11
	fi
	echo "  -- HA setup complete." | tee -a $repl_log
fi

