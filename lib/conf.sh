#!/bin/bash
#
# $Id: lib/conf.sh 3.0 2016-08-04 03:09:03 cmayer $
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
# filenames
#
DOMAIN_XML=$APPD_ROOT/appserver/glassfish/domains/domain1/config/domain.xml
DB_CONF=$APPD_ROOT/db/db.cnf

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
# domain_set_jvm_option <property> [<value>]
#
function domain_set_jvm_option {
	local property=$1
	local value="$2"
	local valueset=""

	case $property in
	X*)
		if [ -n "$value" ] ; then
			valueset="$value"
		fi
		selector="-X$property"
		setter="/appdynamics.controller.port.*\$/a<jvm-options>-$property$valueset</jvm-options>"
		changer="s,\($property\)[=]*[^<]*,\1$valueset,"
		;;
	+*|-*)
		base=${property:1}
		selector="XX:[+-]$base"
		setter="/appdynamics.controller.port.*\$/a<jvm-options>-XX:$property</jvm-options>"
		changer="s,-XX:$base,-XX:$property,"
		;;
	*)
		if [ -n "$value" ] ; then
			valueset="=$value"
		fi
		selector=-D$property
		setter="/appdynamics.controller.port.*\$/a<jvm-options>-D$property$valueset</jvm-options>"
		changer="s,\(-D$property\)[=]*[^<]*,\1$valueset,"
		;;
	esac

	if runuser xmllint --xpath '/domain/configs/config[1]/java-config/*' $DOMAIN_XML | \
		grep -q -e "$selector" ; then
		# if property already present
		runuser sed -i "$changer" $DOMAIN_XML
	else
		# property needs to be added
		runuser sed -i "$setter" $DOMAIN_XML
	fi
} 

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
# read a jvm_option from the domain.xml
#
# domain_get_jvm_option
function domain_get_jvm_option {
	local property=$1

	runuser xmllint --xpath '/domain/configs/config[1]/java-config/*' $DOMAIN_XML | \
		sed -e 's/<[^>]*>/\n/g' -e 's/\n\n/\n/g' | \
		get_jvm_option $property
}

#
# function to unset a domain.xml property
#
function domain_unset_jvm_option {
	local property=$1

	case $property in
	X*)
		selector="-$property"
		;;
	+*|-*)
		base=${property:1}
		selector="XX:[+-]$base"
		;;
	*)
		selector=-D$property
		;;
	esac

	runuser sed -i "/$selector/d" $DOMAIN_XML
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
		echo ""
	fi
}

#
# look in the domain.xml to see if any privileged ports are in use
# return success if they are
#
function use_privileged_ports {
	runuser xmllint --xpath '//*[@port<1024]' $DOMAIN_XML >/dev/null 2>&1
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
