#!/bin/bash
#
# $Id: ha.sh 3.34 2018-08-02 12:28:23 cmayer $
#
# ha.sh
# this file generally contains functions and definitions that are not included in the
# init scripts. it is the closest to the generic subroutine library for the HA package.
# as such, it is the natural place to put code that is shared by most of the HA functional
# programs
#
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

#
# defaults that can be overridden
#
SSH=ssh
SCP=scp

#
# if this file exists, source it to set any local customizations to the execution environment
# specifically, if you have a local ssh, point to it in here
#
if [ -s HA_ENVIRONMENT ] ; then
. HA_ENVIRONMENT
fi

if ! declare -f abend &> /dev/null ; then
	echo "ERROR: ${BASH_SOURCE[0]}: lib/log.sh not included. This is a coding error! " >&2
	exit 1
fi

# with help from:
# http://stackoverflow.com/questions/1923435/how-do-i-echo-stars-when-reading-password-with-read
function getpw { 
        (( $# == 1 )) || abend "Usage: ${FUNCNAME[0]} <variable name>"
        local pwch inpw1 inpw2=' ' prompt; 
        
        ref=$1 
	while [[ "$inpw1" != "$inpw2" ]] ; do
		prompt="Enter MySQL root password: "
		inpw1=''
		while IFS= read -p "$prompt" -r -s -n1 pwch ; do 
			if [[ -z "$pwch" ]]; then 
				[[ -t 0 ]] && echo 
				break 
			else 
				prompt='*'
				inpw1+=$pwch 
			fi 
		done 

		prompt="re-enter same password: "
		inpw2=''
		while IFS= read -p "$prompt" -r -s -n1 pwch ; do 
			if [[ -z "$pwch" ]]; then 
				[[ -t 0 ]] && echo
				break 
			else 
				prompt='*'
				inpw2+=$pwch 
			fi 
		done 
	
		[[ "$inpw1" == "$inpw2" ]] || echo "passwords unequal. Retry..." 1>&2
	done

	# indirect assignment (without local -n) needs eval. 
	# This only works with global variables :-( Please use weird variable names to
	# avoid namespace conflicts...
        eval "${ref}=\$inpw1"            # assign passwd to parameter variable
}

# helper function to allow separate setting of passwd from command line.
# Use this to persist an obfuscated version of the MySQL passwd to disk.
# Call as:
#  . hafunctions.sh
#  save_mysql_passwd $APPD_ROOT
function save_mysql_passwd {
	(( $# == 1 )) || abend "Usage: ${FUNCNAME[0]} <APPD_ROOT>"

	local thisfn=${FUNCNAME[0]} APPD_ROOT=$1 
	[[ -d $1 ]] || fatal "$thisfn: \"$1\" is not APPD_ROOT"
	local rootpw_obf="$APPD_ROOT/db/.rootpw.obf"

	getpw __inpw1 || exit 1		# updates __inpw1 *ONLY* if global variable
	obf=$(obfuscate "$__inpw1") || exit 1
	echo $obf > $rootpw_obf || fatal "$thisfn: failed to save obfuscated passwd to $rootpw_obf"
	chmod 600 $rootpw_obf || warn "$thisfn: failed to make $rootpw_obf readonly"
}

#
# find out which escalation method we are using
#
if [ -f /sbin/service ] ; then
    service_bin=/sbin/service
elif [ -f /usr/sbin/service ] ; then
    service_bin=/usr/sbin/service
else
    fatal 1 "service not found in /sbin or /usr/sbin"
fi

#
# abstract out the privilege escalation at run time
#
# remservice <flags> <machine> <service> <verb>
# service <service> <verb>
#
if [[ `id -u` == 0 ]] ; then
	function service {
		$service_bin $1 $2
	}   
        
	function remservice {
		$SSH $1 $2 $service_bin $3 $4
	}
else
	if [ -f $APPD_ROOT/HA/NOROOT ] ; then
		function service {
			$APPD_ROOT/HA/appdservice-noroot.sh $1 $2
		}
		function remservice {
			$SSH $1 $2 $APPD_ROOT/HA/appdservice-noroot.sh $3 $4
		}
	elif [ -x /sbin/appdservice ] ; then
		function service {
			/sbin/appdservice $1 $2
		}
		function remservice {
			$SSH $1 $2 /sbin/appdservice $3 $4
		}
	else
		function service {
			sudo $service_bin $1 $2
		}
		function remservice {
			$SSH $1 $2 sudo -n $service_bin $3 $4
		}
    fi
fi

#
# we do a boatload of sanity checks, and if anything is unexpected, we
# exit with a non-zero status and complain.
#
function check_sanity {
	if [ ! -d "$APPD_ROOT" ] ; then
		fatal 1 "controller root $APPD_ROOT is not a directory"
	fi
	if [ ! -w "$DB_CONF" ] ; then
		fatal 2 "db configuration $DB_CONF is not writable"
	fi
	if [ ! -x "$MYSQL" ] ; then
		fatal 3 "controller root $MYSQL is not executable"
	fi
	if [ `id -un` != $RUNUSER ] ; then
		fatal 4 "$0 must run as $RUNUSER"
	fi
}

#
# locate a machine agent install directory and print out it's path
#
function find_machine_agent {
	for ma_path in $(find ../.. .. -maxdepth 2 -type f -name machineagent.jar -print 2>/dev/null | sed "s,/[^/]*$,," | sort -u) ; do
		readlink -e $ma_path
	done
}

# output all the names and aliases on the input /etc/hosts file for the current
# hostname which starts with current hostname e.g. for hostname = serv01 it will match
# /etc/hosts entries for serv01.x.y or a.serv01.y.z or serv01
function get_names {
   (( $# == 1 )) || abend "Usage: ${FUNCNAME[0]} <hostname>"
   local host=$1

   awk '
   BEGIN	{ IGNORECASE = 1 }
   $1 ~ /^[[:space:]]*#/ {next} 
   $1 ~ /^127.0./ {next} 
   $1 ~ /[[:digit:]]+\.[[:digit:]]+\.[[:digit:]]+\.[[:digit:]]+$/ && $0 ~ /\y'$host'\y/ {for (i=2; i <= NF; ++i) print $i}'
}
export -f get_names

#
# Check for various problems that prevent passwordless ssh working from each
# node to the other.
# Checks all /etc/hosts names for $(hostname) calling ssh to all secondary's 
# /etc/hosts entries and vice versa.
# Return non-zero for caller to exit if required.
# Requires:
#  . lib/log.sh
# Call as:
#  check_ssh_setup $otherhostname || fatal "2-way passwordless ssh not setup"
# 
# e.g. if function running on primary then:
#  check_ssh_setup $secondary
#
function check_ssh_setup {
   # this gross hack is for those systems that don't have the ability to have reasonable hosts files
   # that depend on dns for everything.
   if [ -f NO_SSH_CHECK ] ; then
      return 0
   fi

   (( $# == 1 )) || abend "Usage: ${FUNCNAME[0]} <otherhostname>"
   local myhost=$(hostname) otherhost=$1 i j OUT=/tmp/.out.$$ ERR=/tmp/.errs.$$

   touch $OUT && [[ -w $OUT ]] || abend "${FUNCNAME[0]}: unable to write to $OUT"
   touch $ERR && [[ -w $ERR ]] || abend "${FUNCNAME[0]}: unable to write to $ERR"

   # suffers a slight chicken and egg problem as we need /etc/hosts of $otherhost
   # but have not established that ssh to secondary works yet... hence initial
   # test
   timeout 9s bash -c "$SSH -o StrictHostKeyChecking=no $otherhost pwd" >$OUT 2>$ERR
   retc=$?
   if (( $retc != 0 )) ; then
      gripe "ssh Test-0: $myhost unable to reach $otherhost: $(<$ERR)"
      return 2
   fi
   local pattern='^/.*'
   if [[ ! "$(<$OUT)" =~ $pattern ]] ; then
       gripe "ssh Test-0: $myhost unable to run 'pwd' on $otherhost: $(<$ERR). Please fix and re-try"
       return 3
   fi
   rm -f $OUT $ERR

   local myhosts=$(< /etc/hosts)
   if [[ -z "$myhosts" ]] ; then
      gripe "ssh Test-0: $myhost unable to read /etc/hosts. Please fix and re-try"
      return 4
   fi

   local mynames=$(get_names $myhost <<< "$myhosts" | sort -ur)
   if [[ -z "$mynames" ]] ; then
      gripe "ssh Test-0: $myhost unable to find any /etc/hosts entries for itself."
      gripe "Please ensure both primary and secondary servers list both servers in their /etc/hosts files...Skipping test"
      return 0
   fi

   local otherhosts=$($SSH -o StrictHostKeyChecking=no $otherhost cat /etc/hosts)
   if [[ -z "$otherhosts" ]] ; then
      gripe "ssh Test-0: $myhost unable to cat /etc/hosts on $otherhost. Please fix and re-try"
      return 4
   fi

   local othernames=$(get_names $otherhost <<< "$otherhosts")
   if [[ -z "$othernames" ]] ; then
      gripe "ssh Test-0: $otherhost unable to find any /etc/hosts entries for itself."
      gripe "Please ensure both primary and secondary servers list both servers in their /etc/hosts files...Skipping test"
      return 0
   fi

   # now check that all names for current hostname can make passwordless ssh call to all names
   # for $otherhost and vice-versa
   for i in $(sort -u <<< "$(printf '%s\n' $mynames)") ; do
      for j in $(sort -u <<< "$(printf '%s\n' $othernames)") ; do
         do_check_ssh_setup $i $j || return $?
      done
   done
}

# Helper function for check_ssh_setup() that tests ssh between two named hosts.
# Note that these tests will also add entries into the ~/.ssh/known_hosts
# files of both hosts.
function do_check_ssh_setup {
   (( $# == 2 )) || abend "Usage: ${FUNCNAME[0]} <myhostname> <otherhostname>"
   local myhost=$1 otherhost=$2 retc OUT=/tmp/.out.$$ ERR=/tmp/.errs.$$

   touch $OUT && [[ -w $OUT ]] || abend "${FUNCNAME[0]}: unable to write to $OUT"
   touch $ERR && [[ -w $ERR ]] || abend "${FUNCNAME[0]}: unable to write to $ERR"

   # Test-1: check whether possible to reach $otherhost with ssh - fingerprint known or not
   timeout 9s bash -c "$SSH -o StrictHostKeyChecking=no $otherhost echo '$(id -un):$(id -gn)'" >$OUT 2>$ERR
   retc=$?
   if (( $retc != 0 )) ; then
      message "ssh Test-1: $myhost unable to reach $otherhost: $(<$ERR)"
      return 5
   fi
   if [[ "$(<$OUT)" != "$(id -un):$(id -gn)" ]] ; then
       message "ssh Test-1: $myhost unable to determine username:groupname on $otherhost: $(<$ERR). Please ensure same username and groupname on both HA servers and re-try"
       return 6
   fi

   # Test-3: check whether otherhost can reach me with ssh - fingerprint known or not
   timeout 9s bash -c "$SSH $otherhost $SSH -o StrictHostKeyChecking=no $myhost id -un" &> $ERR
   retc=$?
   if (( $retc != 0 )) ; then
      message "ssh Test-3: $otherhost unable to reach $myhost: $(<$ERR)"
      return 8
   fi

   rm -f $OUT $ERR		# files are not deleted after unsuccessful earlier return
   return 0
}

