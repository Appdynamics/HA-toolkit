#!/bin/bash
#
# $Id: make_ssh_keys.sh 3.0 2016-08-03 19:23:30 cmayer $
# ha setup requires ssh keys on both nodes for the appdynamics user
#
# this script creates the keys and plugs them in to both nodes.
# it will prompt for passwords to propagate the keys
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
# make 2 keypairs
#
primary=`hostname`
secondary=

function usage {
	echo "usage: $0 [options]"
	echo "       -s <secondary host name>"
	echo "       -h get help"
	exit 1
}

while getopts s:h flag; do
	case $flag in
	s)
		secondary=$OPTARG
		;;
	h)
		usage
		;;
	esac
done

if [ -z "$secondary" ] ; then
	echo "must specify secondary hostname"
	usage
fi

if [ -d ~/.ssh ] ; then
	echo ~/.ssh already exists
	exit 2
fi

if [ -f ~/.ssh/authorized_hosts ] ; then
	echo ~/.ssh/authorized_hosts already exists
	exit 3
fi

PRIMARY_SSH=/tmp/key-create/$primary/.ssh
SECONDARY_SSH=/tmp/key-create/$secondary/.ssh
mkdir -p $PRIMARY_SSH
mkdir -p $SECONDARY_SSH
chmod 600 $PRIMARY_SSH
chmod 600 $SECONDARY_SSH

ssh-keygen -N "" -f $PRIMARY_SSH/id_rsa >/dev/null 2>&1
ssh-keygen -N "" -f $SECONDARY_SSH/id_rsa >/dev/null 2>&1

cat $PRIMARY_SSH/id_rsa.pub $SECONDARY_SSH/authorized_hosts
cp $SECONDARY_SSH/id_rsa.pub $PRIMARY_SSH/authorized_hosts
chmod 600 $PRIMARY_SSH/authorized_hosts
chmod 600 $SECONDARY_SSH/authorized_hosts

scp -rp $SECONDARY_SSH secondary:
cp -rp $PRIMARY_SSH ~
