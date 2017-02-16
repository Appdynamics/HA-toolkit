#!/bin/bash
#
# $Id: lib/conf.sh 3.10 2017-02-15 17:38:25 cmayer $
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
lockfile=/var/lock/subsys/$NAME

DB_CONF=$APPD_ROOT/db/db.cnf
APPSERVER_DISABLE=$APPD_ROOT/HA/APPSERVER_DISABLE
SHUTDOWN_FAILOVER=$APPD_ROOT/HA/SHUTDOWN_FAILOVER
WATCHDOG_ENABLE=$APPD_ROOT/HA/WATCHDOG_ENABLE
ASSASSIN_PIDFILE=$APPD_ROOT/HA/appd_assassin.pid
WATCHDOG_PIDFILE=$APPD_ROOT/HA/appd_watchdog.pid
WATCHDOG_STATUS=$APPD_ROOT/logs/watchdog.status
WATCHDOG_ERROR=$APPD_ROOT/logs/watchdog.error
DOMAIN_XML=$APPD_ROOT/appserver/glassfish/domains/domain1/config/domain.xml
CONTROLLER_SH=$APPD_ROOT/bin/controller.sh
MYSQLCLIENT=$APPD_ROOT/HA/mysqlclient.sh

XMLBASE=/domain/configs/config[1]/java-config/jvm-options

#
# lose trailing and leading white space
#
function strip_white() {
	sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

#
# get a property from a controller_info file
#
function controller_info_get() {
	local xml=$1
	local property=$2
	local root="/controller-info"
	local xpath="$root/$property"

	runuser xmlstarlet sel -T -t -v "$xpath" $xml | strip_white
}

#
# set a property into a controller_info file
#
function controller_info_set() {
	local xml=$1
	local property=$2
	local value=$3
	local root="/controller-info"
	local xpath="$root/$property"

	if runuser xmlstarlet sel -T -t -v "count($xpath)" $xml |
		grep -s -w 0 -q ; then
		xmlstarlet ed -L -s "$root" -t elem -n $property -v "$value" $xml
	else
		xmlstarlet ed -L -u "$xpath" -v "$value" $xml
	fi
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
		selector="starts-with(.,'-$property')"
		stripper=(-e s/-$property//)
		;;

	# like -XX:+foo or -XX:-foo
	+*|-*) 
		base=${property:1}
		selector="string(.)='-XX:-$base' or string(.)='-XX:+$base'"
		stripper=(-e "s/-XX:\([+-]\)$base/\1/")
		;;

	# like -Dfoo and -Dfoo=77
	*)
		selector="starts-with(.,'-D$property=') or (string(.)='-D$property')"
		stripper=(-e s/-D$property$/true/ -e s/-D$property=//)
		;;
	esac

	xpath="$XMLBASE[$selector]"

	val=$(runuser xmlstarlet sel -T -t -v "$xpath" $DOMAIN_XML | 
		strip_white | sed ${stripper[@]})
	if [ -z $val ] ; then
		echo "unset"
	else
		echo $val
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
		selector="starts-with(.,'-$property')"
		;;

	# like -XX:+foo or -XX:-foo
	+*|-*)
		base=${property:1}
		selector="string(.)='-XX:-$base' or string(.)='-XX:+$base'"
		;;

	# like -Dfoo and -Dfoo=77
	*)
		selector="starts-with(.,'-D$property=') or (string(.)='-D$property')"
		;;
	esac

	xpath=$XMLBASE[$selector]

	runuser xmlstarlet ed -L -d "$xpath" $DOMAIN_XML
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
		selector="starts-with(.,'-$property')"
		setter="-$property$value"
		;;

	# like -XX:+foo or -XX:-foo
	+*|-*)
		base=${property:1}
		selector="string(.)='-XX:-$base' or string(.)='-XX:+$base'"
		setter="-XX:$property"
		;;

	# like -Dfoo and -Dfoo=77
	*)
		selector="starts-with(.,'-D$property=') or (string(.)='-D$property')"
		if [ -n "$value" ] ; then
			value="=$value"
		fi
		setter="-D$property$value"
		;;
	esac

	xpath="$XMLBASE[$selector]"

	if runuser xmlstarlet sel -T -t -v "count($xpath)" $DOMAIN_XML |
		grep -s -w 0 -q ; then
		xpath="$XMLBASE/.."
		xmlstarlet ed -L -s "$xpath" -t elem -n jvm-options -v "$setter" $DOMAIN_XML
	else
		xmlstarlet ed -L -u "$xpath" -v "$setter" $DOMAIN_XML
	fi
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
		CP="scp -q"
	fi
	runuser $CP $DBCNF $IN
	cp $IN $OUT

	if grep -q "^[[:space:]]*$property\(=\|$\)" $IN ; then
		if ! [ -z "$value" ] ; then
			sed -i "s,\(^[[:space:]]*$property=\).*$,\1$value," $OUT >/dev/null
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
		CP="scp -q"
	fi
	runuser $CP $DBCNF $IN
	cp $IN $OUT

	sed -i "/^[[:space:]]*$property\b/d" $OUT >/dev/null

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

	val=`runuser grep "^[[:space:]]*$property=" $DB_CONF | awk -F= '{print $2}'`
	if [ -n "$val" ] ; then
		echo $val
	elif runuser grep -q "^[[:space:]]*\b$property\b" $DB_CONF ; then
		echo $property
	else
		echo unset
	fi
}

#
# look in the domain.xml to see if any privileged ports are in use
# return success if they are
#
function use_privileged_ports {
	echo 'cat //*[@port<1024]' | runuser xmllint --shell $DOMAIN_XML | grep -q port
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
