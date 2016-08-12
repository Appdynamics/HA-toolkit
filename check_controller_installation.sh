#!/bin/bash
#
# $Id: check-controller-installation.sh 3.0 2016-08-03 19:23:30 cmayer $
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
# validate that the controller installation meets some minimum requirements
# set by the large installation guide
#

SWAP=10
NOFILES=8192
PROCESSES=2048

losecount=0
function lose {
	echo "$*"
	(( losecount++ ))	
}

#
# check ulimit
#
if [ `ulimit -n` -lt $NOFILES ] ; then
	lose "open file limit less than $NOFILES"
fi
if [ `ulimit -u` -lt $PROCESSES ] ; then
	lose "process limit less than $PROCESSES"
fi

#
# check i/o scheduler
#
if ! grep -s "[cfq]" /sys/block/queue/*/scheduler ; then
	lose "at least one block device does not use the deadline scheduler"
fi

#
# check swap space
#
if [ `free -g | awk '/^Swap/ {print $4}'` -lt $SWAP ] ; then
	lose "swap space is less than $SWAP GB"

fi

if [ $losecount -gt 0 ] ; then
	echo your system is not configured properly for a controller
	exit 1
fi
echo installation check passed
exit 0
