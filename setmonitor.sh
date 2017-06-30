#!/bin/bash
#
# $Id: setmonitor.sh 3.18 2017-04-26 01:25:28 cmayer $
#
# instrument controller and machine agents to a monitoring host
#
# this writes various configuration files
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

LOGNAME=setmonitor.log
need_encryption=false

# source function libraries
. lib/log.sh
. lib/runuser.sh
. lib/conf.sh
. lib/ha.sh
. lib/password.sh
. lib/sql.sh

#
# make sure we are running as the right user
#
if [ -z "$RUNUSER" ] ; then
	fatal 1 user not set in $APPD_ROOT/db/db.cnf
fi

#
# global variables that are to be changed by command line args
#
primary=`hostname`
monitor=
secondary=
machine_agent=""
ma_conf=""

function shortname() {
	echo $1 | sed -e 's/\..*$//'	
}

function usage()
{
	if [ $# -gt 0 ] ; then
		echo "$*"
	fi
	echo "usage: $0 <options>"
	echo "    [ -i <internal vip> ]"
	echo "    [ -s <secondary hostname> ]"
	echo "    [ -m [attribute...] where attributes comma seperated:"
	echo "         url=[protocol://]<controller_monitor>[:port]"
	echo "         access_key=\"1-2-3-4\""
	echo "         app_name=\"ABC controller\""
	echo "         account_name=system"
	echo "         tier_name=\"App Server\""
	echo "    [ -a <machine agent install directory> ]"
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

declare -A cmargs

#
# parse a controller monitor definition.
# this takes the form:
# url=[protocol://]<controller_monitor>[:port],
# access_key=\"1-2-3-4\"
# [,app_name=\"ABC controller\"]
# [,account_name=someaccount]
# [,tier_name=foo]

function parse_monitor_def() {

	local controller_monitor_args="$1"

	declare -a vals A
	# vals array gets comma delimited settings
	IFS=, read -a vals <<< "$controller_monitor_args"
	for i in ${!vals[*]} ; do 
		# then, split the key, value pairs by equals sign
		key="${vals[$i]%%=*}" ; value="${vals[$i]#*=}"
		# remove any leading/trailing quotes
		noquote=$(sed -e 's/^["'\'']//' -e 's/["'\'']$//' <<< "$value")
		# assign associative array cmargs
		cmargs[$key]="${noquote}"
	done
}

if [ -f MONITOR ] ; then
	parse_monitor_def "`cat MONITOR`"
fi

log_rename

#
# log versions and arguments
#
message "setmonitor log " `date`
message "version: " `grep '$Id' $0 | head -1`
message "command line options: " "$@"
message "hostname: " `hostname`
message "appd root: $APPD_ROOT"
message "appdynamics run user: $RUNUSER"

while getopts s:m:a:i:h flag; do
	case $flag in
	a)
		machine_agent=$OPTARG
		;;
	s)
		secondary=$(ssh $OPTARG hostname)
		;;
	m)
		parse_monitor_def "$OPTARG"
		comma= ; cmlist=
		for key in ${!cmargs[*]} ; do
			cmlist=$cmlist$comma$key=\""${cmargs[$key]}"\"
			comma=','
		done
		echo "$cmlist" > MONITOR
		;;
	i)
		internal_vip=$OPTARG
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
	*)
		if [ $flag != H ] ; then
			echo "unknown option flag $OPTARG"
		fi
		usage
		;;
	esac
done

pri_short=$(shortname $primary)
sec_short=$(shortname $secondary)

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
	ma_conf="$machine_agent/conf"
	message "found machine agent in $machine_agent"
fi

monitor="${cmargs['url']}"
if [ -z "$monitor" ] ; then
	monitor=$internal_vip
fi

eval `parse_vip internal_vip $internal_vip`
eval `parse_vip monitor $monitor`

#
# set the monitoring up to reasonable defaults if any portion is not set
#
monitor_access_key="${cmargs['access_key']}"
monitor_account="${cmargs['account_name']}"
monitor_application="${cmargs['app_name']}"
monitor_tier="${cmargs['tier_name']}"

if [ -z "$monitor_account" ] ; then
	if [ "$monitor" = "$internal_vip" ] ; then
		monitor_account=system
	else
		monitor_account=customer1
	fi
fi
if [ -z "$monitor_application" ] ; then
	if [ -n "$secondary" ] ; then
		pair=`echo -e "$pri_short\n$sec_short" | sort | tr '\n' ':' | sed 's/:$//'`
		monitor_application="HA pair $pair"
	else
		monitor_application="$pri_short controller"
	fi
fi
if [ -z "$monitor_tier" ] ; then
	monitor_tier="App Server"
fi
if [ -z "$monitor_access_key" ] ; then
	if [ "$monitor" != "$internal_vip" ] ; then
		fatal 10 "monitoring access key must be specified for external host"
	fi
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
if [ "$monitor_protocol" == "https" ] ; then
	monitor_ssl=true
else
	monitor_ssl=false
fi

message "monitoring host: $monitor_host"
message "monitoring protocol: $monitor_protocol"
message "monitoring port: $monitor_port"
message "monitoring account: $monitor_account"
message "monitoring application: $monitor_application"
message "monitoring tier: $monitor_tier"
message "monitoring access key: $monitor_access_key"

controller_infos=(`find $ma_conf \
	$APPD_ROOT/appserver/glassfish/domains/domain1/appagent -name controller-info.xml -print`)

credfile=
credpass=

if echo $monitor_access_key | grep -q -s "^-001" ; then
	message "key appears to require decryption"
	need_encryption=true

	# let's load up the credential store params from the first nonblank
	for info in ${controller_infos[*]} ; do
		if [ -f "$info" ] ; then
			xcredfile=$(controller_info_get $info credential-store-filename)
			if [ -z "$credfile" -a "$xcredfile" != unset ] ; then
				credfile=$xcredfile
			fi
			xcredpass=$(controller_info_get $info credential-store-password)
			if [ -z "$credpass" -a "$xcredpass" != unset ] ; then
				credpass=$xcredpass
			fi
		fi
	done
fi

#
# plug the various communications endpoints into domain.xml
#
domain_set_jvm_option appdynamics.controller.hostName $monitor_host
domain_set_jvm_option appdynamics.controller.port $monitor_port
domain_set_jvm_option appdynamics.controller.ssl.enabled $monitor_ssl
domain_set_jvm_option appdynamics.agent.accountName "$monitor_account"
domain_set_jvm_option appdynamics.agent.accountAccessKey "$monitor_access_key"
domain_set_jvm_option appdynamics.agent.applicationName "$monitor_application"

#
# make sure all controller-info.xml's are set up properly
# this means the machine agent as well as the appagent
#
for info in ${controller_infos[*]} ; do
	if [ -f $info ] ; then
		message "modify $info"

		controller_info_set $info controller-host $monitor_host
		controller_info_set $info controller-port $monitor_port
		controller_info_set $info application-name "$monitor_application"
		controller_info_set $info tier-name "$monitor_tier"
		controller_info_set $info account-name "$monitor_account"
		controller_info_set $info account-access-key "$monitor_access_key"
		controller_info_set $info controller-ssl-enabled "$monitor_ssl"
		controller_info_set $info node-name $pri_short

		if $need_encryption ; then
			controller_info_set $info use-encrypted-credentials true
    		controller_info_set $info credential-store-filename $credfile
    		controller_info_set $info credential-store-password $credpass
		else
			controller_info_set $info use-encrypted-credentials false
    		controller_info_unset $info credential-store-filename
    		controller_info_unset $info credential-store-password
		fi

	# todo: gracefully handle
    # use-ssl-client-auth
    # asymmetric-keystore-filename
    # asymmetric-keystore-password
    # asymmetric-key-password

		ex -s $info <<- SETMACHINE
			%s/\(<controller-host>\)[^<]*/\1$monitor_host/
			%s/\(<controller-port>\)[^<]*/\1$monitor_port/
			%s/\(<application-name>\)[^<]*/\1$monitor_application/
			%s/\(<tier-name>\)[^<]*/\1$monitor_tier/
			%s/\(<account-name>\)[^<]*/\1$monitor_account/
			%s/\(<account-access-key>\)[^<]*/\1$monitor_access_key/
			wq
		SETMACHINE
	fi
	if [ -n "$secondary" ] ; then
		ci_tmp=/tmp/ci.$$.xml
		rm -f $ci_tmp
		message "copy $info to secondary"
		cp $info $ci_tmp
		controller_info_set $ci_tmp node-name $sec_short
		scp -q $ci_tmp $secondary:$info
		rm -f $ci_tmp
	fi
done

#
# send the edited domain.xml
#
if [ -n "$secondary" ] ; then
	message "copy domain.xml to secondary"
	scp -q -p $APPD_ROOT/appserver/glassfish/domains/domain1/config/domain.xml $secondary:$APPD_ROOT/appserver/glassfish/domains/domain1/config/domain.xml
	message "copy MONITOR to secondary"
	scp -q -p $APPD_ROOT/HA/MONITOR $secondary:$APPD_ROOT/HA/MONITOR
fi


