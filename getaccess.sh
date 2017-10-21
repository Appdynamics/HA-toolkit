#!/bin/bash
#
# $Id: getaccess.sh 3.13 2017-10-21 00:45:29 rob.navarro $
# helper script to get the access key from an account table
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

APPD_ROOT=`readlink -e ..`
account=system
host=localhost

LOGNAME=getaccess.log

. lib/log.sh
. lib/runuser.sh
. lib/conf.sh
. lib/password.sh
. lib/sql.sh

function usage {
	echo "$0 [options]"
	echo " [-c <appdynamics root dir> default: $APPD_ROOT]"
	echo " [-a <account name>]"
	echo " [-p <password>]"
	echo " [-h <host>[:port]]"
	exit 1
}

while getopts :c:a:p:h: flag; do
	case $flag in
	c)
		APPD_ROOT=$OPTARG
		;;
	a)
		account=$OPTARG
		;;
	p)
		dbpasswd=$OPTARG
		;;
	h)
		host=$OPTARG
		if echo $host | grep -s : ; then
			host=`echo $host | awk -F: '{print $1}'`
			dbport=`echo $host | awk -F: '{print $2}'`
		fi
		;;
	*)
		usage
		;;	
	esac
done

sql $host "select access_key from account where name = '$account'" | get access_key
