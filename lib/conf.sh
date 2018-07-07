#!/bin/bash
#
# $Id: lib/conf.sh 3.35 2018-07-06 22:51:53 cmayer $
#
# contains common code used to extract and set information in the
# config files.
#
# there is some hair here having to do with permissions,
# and we invoke runuser to do file access as the appropriate user
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
# all the configuration file names and locations
#

if ! declare -f runuser &> /dev/null ; then
        echo "ERROR: ${BASH_SOURCE[0]}: lib/runuser.sh not included. This is a coding error! " >&2
        exit 1
fi

lockfile=/var/lock/subsys/$NAME

DB_CONF=$APPD_ROOT/db/db.cnf
APPSERVER_DISABLE=$APPD_ROOT/HA/APPSERVER_DISABLE
SHUTDOWN_FAILOVER=$APPD_ROOT/HA/SHUTDOWN_FAILOVER
WATCHDOG_ENABLE=$APPD_ROOT/HA/WATCHDOG_ENABLE
WATCHDOG_SETTINGS=$APPD_ROOT/HA/watchdog.settings
ASSASSIN_PIDFILE=$APPD_ROOT/HA/appd_assassin.pid
WATCHDOG_PIDFILE=$APPD_ROOT/HA/appd_watchdog.pid
WATCHDOG_STATUS=$APPD_ROOT/logs/watchdog.status
WATCHDOG_ERROR=$APPD_ROOT/logs/watchdog.error
DOMAIN_XML=$APPD_ROOT/appserver/glassfish/domains/domain1/config/domain.xml
CONTROLLER_SH=$APPD_ROOT/bin/controller.sh
MYSQLCLIENT=$APPD_ROOT/HA/mysqlclient.sh

# must have accessible db.cnf
if ! [ -f $DB_CONF ] ; then
	echo $DB_CONF not readable
	exit 1
fi


# requires gnu sed
if ! sed --version >/dev/null 2>&1 ; then
	echo gnu sed required
	exit 1
fi

# the context for xml manipulation
xml_context="/<config name=\\\"server-config\\\">/,/<\/config>/"

#
# lose trailing and leading white space
#
function strip_white() {
	sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

#
# get possible multiple values from named XML file and element, one per row
# Call as:
#  runuser get_xml_element_value $DOMAIN $property
#
function get_xml_element_value {
	local thisfn=${FUNCNAME[0]}
	(( $# == 2 )) || abend "Usage: $thisfn <xml file> <node name>"
	local xml=$1
 	local property=$2

	[[ -r $xml ]] || abend "$thisfn: unable to read $xml"
	[[ -n $property ]] || abend "$thisfn: needs non-empty property name"
	awk '$0 !~ /^\/ >|^ -/ {print}' < <(xmllint --shell $1 <<< "cat //$2/text()")
}
export -f get_xml_element_value

#
# count how many nodes of given name in supplied XML file
#
# This is helpful because no/0 elements of given name imply a insert
# where as 1 or more, whether empty or not, imply an update
#
function count_xml_element {
	local thisfn=${FUNCNAME[0]}
	(( $# == 2 )) || abend "Usage: $thisfn <xml file> <node name>"
	local xml=$1
 	local property=$2

	[[ -r $xml ]] || abend "$thisfn: unable to read $xml"
	[[ -n $property ]] || abend "$thisfn: needs non-empty property name"
	awk '$0 ~ /is a number/ {print $NF}' < <(xmllint --shell $xml <<< "xpath count(//$property)")
#	awk '	$0 ~ /^\/ > .{2} > $/ 		{print $3} 
#		$0 ~ /^\/\/.*Node Set$/ 	{print $(NF-2)} 
#		$0 ~ /^\/ > '$property' > $/ 	{print "1"}' < <(xmllint --shell $xml <<< "cd //$property" 2>&1)
}
export -f count_xml_element

#
# get a property from a controller_info file
#
# Need to differentiate between <x></x> existing but with no contained value
# and between simple absence of <x>.*</x>
#
function controller_info_get() {
	local xml=$1
	local property=$2

	runuser get_xml_element_value $xml $property
}
export -f controller_info_get

#
# set a property into a controller_info file
#
function controller_info_set() {
	local xml=$1
	local property=$2
	local value=$3

	if (( $(count_xml_element $xml $property) == 0 )) ; then
		tmpfile=/tmp/cinfo_set.$$ ; rm -f $tmpfile
		echo "<$property>$value</$property>" > $tmpfile
		chmod 755 $tmpfile
		runuser sed -i.$(date +%s) -e "\"/<controller-info>/r $tmpfile\"" $xml
		rm -f $tmpfile
	else
		runuser sed -i.$(date +%s) -e "\"s,\(<$property>\).*\(</$property>\),\1$value\2,\"" $xml
	fi
}
export -f controller_info_set

#
# unset a property in a controller_info file
#
function controller_info_unset() {
	local xml=$1
	local property=$2

	runuser sed -i.$(date +%s) -e "\"s/<$property>.*<\/$property>//\"" $xml
}

#
# simplifies processing jvm options from domain.xml
#
# different types of jvm_options are settable, unsettable, and gettable
# they are denoted by a prefix character
# -Xmx		prefix character X
# -XX:+foo	prefix character +|-	we can ask for either sense
# -XX:-foo
# -Dfoo		no prefix

#
# extract a specific jvm option value from a stream
#
# get_jvm_option <property>
#
function get_jvm_option
{
	local property=$1

	awk -F= "/^-XX:$property=/ { print \$2 }
		/^-XX:\+$property/ { print \"+\" }
		/^-XX:-$property/ { print \"-\" }
		/^-D$property=/ { print \$2 }
		/^-$property/ { sub(\"-$property\",\"\"); print }"
}

#
# domain_get_jvm_option <property>
#
function domain_get_jvm_option {
	local property=$1
	local selector
	local xpath
	local base
	local stripper

	case $property in

	# like -Xmx34g
	X*)
		selector="<jvm-options>-$property"
		stripper=(-e s/-$property//)
		;;

	# like -XX:+foo or -XX:-foo
	+*|-*) 
		base=${property:1}
		stripper=(-e "s/-XX:\([+-]\)$base/\1/")
		selector="<jvm-options>-XX:[+-]$base"
		;;

	# like -Dfoo and -Dfoo=77
	*)
		selector="<jvm-options>-D$property"
		stripper=(-e s/-D$property$/true/ -e s/-D$property=//)
		;;
	esac

	val=$(runuser cat $DOMAIN_XML | sed -e "$xml_context!d" | \
		grep $selector | sed -e 's,</*jvm-options>,,g' ${stripper[@]} | strip_white)
	if [ -z "$val" ] ; then
		echo "unset"
	else
		echo "$val"
	fi
}

#
# function to unset a domain.xml property
#
function domain_unset_jvm_option {
	local property=$1
	local selector
	local base
	local xpath

	case $property in

	# like -Xmx34g
	X*)
		selector="-$property"
		# selector="starts-with(.,'-$property')"
		;;

	# like -XX:+foo or -XX:-foo
	+*|-*)
		base=${property:1}
		# selector="string(.)='-XX:-$base' or string(.)='-XX:+$base'"
		selector="-XX:[+-]$base"
		;;

	# like -Dfoo and -Dfoo=77
	*)
		# selector="starts-with(.,'-D$property=') or (string(.)='-D$property')"
		selector="-D$property[=]*"
		;;
	esac

	runuser sed -i.$(date +%s) -e "\"$xml_context{/$selector/d}\"" $DOMAIN_XML
}

#
# domain_set_jvm_option <property> [<value>]
# 
function domain_set_jvm_option {
	local property=$1
	local value="$2"
	local base
	local selector
	local xpath

	case $property in

	# like -Xmx34g
	X*)
		valueset="-$property$value"
		propmatch="-$property.*"
		;;

	# like -XX:+foo or -XX:-foo
	+*|-*)
		valueset="-XX:$property"
		propmatch="-XX:[+-]${property:1}"
		;;

	# like -Dfoo and -Dfoo=77
	*)
		if [ -n "$value" ] ; then
			value="=$value"
		fi
		valueset="-D$property$value"
		propmatch="-D$property=*.*"
		;;
	esac

	setter="/<\/java-config>/s,</java-config>,<jvm-options>$valueset</jvm-options>\n&,"
	changer="s,\(<jvm-options>\)$propmatch\(</jvm-options>\),\1$valueset\2,"

	if [ "$(domain_get_jvm_option $property)" != "unset" ] ; then
		setter="$changer"
	fi
	sed -i.$(date +%s) -e "$xml_context{$setter}" $DOMAIN_XML
}

# set a property into the db.cnf file
# if the property is already there, edit it, else append it
# if remotehost clear, do it locally
function dbcnf_set {
	local property=$1
	local value="$2"
	local remotehost=$3
	local IN=/tmp/db.cnf.in.$$
	local OUT=/tmp/db.cnf.out.$$
	
	rm -f $IN $OUT

	if [ -z "$remotehost" ] ; then
		DBCNF=$DB_CONF
		CP="cp"
	else
		DBCNF=$remotehost:$DB_CONF
		CP="$SCP -q"
	fi
	runuser $CP $DBCNF $IN
	cp $IN $OUT

	# patch odd failure case when file does not end with newline
	# (idea from http://backreference.org/2010/05/23/sanitizing-files-with-no-trailing-newline/)
	tail -c1 $OUT | read -r _ || echo >> $OUT

	if grep -q "^[[:space:]]*$property\(=\|$\)" $IN ; then
		if ! [ -z "$value" ] ; then
			sed -i.$(date +%s) "s,\(^[[:space:]]*$property=\).*$,\1$value," $OUT >/dev/null
		fi
	else
		if [ -z "$value" ] ; then
			echo "$property" >> $OUT
		else
			echo "$property=$value" >> $OUT
		fi
	fi

	if ! cmp -s $IN $OUT ; then
		runuser $CP $OUT $DBCNF
	fi
	rm -f $IN $OUT
}

#
# remove a property setting from the db.cnf file
#
function dbcnf_unset {
	local property=$1
	local remotehost=$2
	local IN=/tmp/db.cnf.in.$$
	local OUT=/tmp/db.cnf.out.$$

	rm -f $IN $OUT

	if [ -z "$remotehost" ] ; then
		DBCNF=$DB_CONF
		CP=cp
	else
		DBCNF=$remotehost:$DB_CONF
		CP="$SCP -q"
	fi
	runuser $CP $DBCNF $IN
	cp $IN $OUT

	sed -i.$(date +%s) "/^[[:space:]]*$property\b/d" $OUT >/dev/null

	if ! cmp -s $IN $OUT ; then
		$CP $OUT $DBCNF
	fi
	rm -f $IN $OUT
}

#
# read the db.cnf file and extract an attribute
#
function dbcnf_get {
	local property=$1

	val=`runuser grep "\"^[[:space:]]*$property=\"" $DB_CONF | awk -F= '{print $2}'`
	if [ -n "$val" ] ; then
		echo $val
	else
		echo unset
	fi
}

#
# look in the domain.xml to see if any privileged ports are in use
# return success if they are
#
function use_privileged_ports {
	runuser xmllint --xpath "\"//*[@port<1024]\"" $DOMAIN_XML 2>/dev/null | grep -q -s port
}

#
# scale a size by a suffix [KkMmGg] if present
# also, add some fluff if specified
#
# input on stdin
function scale {
	local fluff=1
	if [ $# = 1 ] ; then fluff=$1 ; fi

	awk "{
		if(sub(/[Kk]/,\"\",\$1) == 1){
			BYTES=\$1*1024
		}
		else if(sub(/[Mm]/,\"\",\$1)==1){
			BYTES=\$1*1048576
		}
		else if(sub(/[Gg]/,\"\",\$1)==1){
			BYTES=\$1*1073741824
		} else {
			gsub(/[^0-9]/,\"\",\$1)
			BYTES=\$1
		}
		printf(\"%.0f\n\", BYTES * $fluff)
		exit;
	}"
}

#
# read some things from the db.cnf
#
DB_PID_FILE=`dbcnf_get pid-file`
DB_DATA_DIR=`dbcnf_get datadir`
FILE_RUNUSER=$(dbcnf_get user)

#
# a trivial sanity check - if runuser is defined, it better be what is in
# the database config file
#
if [ -n "$RUNUSER" ] ; then
	if [ $FILE_RUNUSER != $RUNUSER ] ; then
		echo "runuser inconsistent: sysconfig: $RUNUSER db.cnf: $FILE_RUNUSER"
	fi
fi
RUNUSER=$FILE_RUNUSER

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
                        gsub("/.*$","",host);   # drop any trailing /controller
                        gsub("[^0-9]*$","",port);
                        printf("%s_host=%s\n", vip_name, host);
                        printf("%s_port=%s\n", vip_name, port);
                        printf("%s_protocol=%s\n", vip_name, protocol);
                }
        '
}
