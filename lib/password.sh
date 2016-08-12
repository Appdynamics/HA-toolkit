#!/bin/bash
#
# $Id: lib/password.sh 3.0 2016-08-04 03:09:03 cmayer $
#
# passwordfunctions.sh
# contains common code used by the HA toolkit
#
# policy:
# intended to be minimalized for inclusion into the init functions
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
# Collection of routines to deal with MySQL root password
#

if [ "`uname`" == "Linux" ] ; then
	BASE64_NO_WRAP="-w 0"
else
	BASE64_NO_WRAP=""
fi

#
# prerequisites - die immediately if not present
#
which tr >& /dev/null || fatal 2 "needs \'tr\'"
which base64 >& /dev/null || fatal 3 "needs \'base64\'"

# one of pair of low level functions {obf,deobf}_<some extention>
# Expected to output to STDOUT:
#  ofa1 <obfuscated value of input parameter>
#
# Call as:
#  obf_ofa1 <data>
function obf_ofa1 {
	local thisfn=${FUNCNAME[0]} step1 obf
	(( $# == 1 )) || abend "Usage: $thisfn <clear_data>"

	step1=$(tr '\!-~' 'P-~\!-O' < <(echo -n $1)) || exit 1
	[[ -n "$step1" ]] || fatal 2 "produced empty step1 obfuscation"
	obf=$(base64 $BASE64_NO_WRAP < <(echo -n $step1)) || exit 1
	[[ -n "$obf" ]] || fatal 3 "produced empty obfuscation"

	# use part of function name after last '_' as obfuscator type
	echo "${thisfn##*_} "$obf
}
export -f obf_ofa1

# one of pair of low level functions {obf,deobf}_<some extention>
# Expected to output to STDOUT:
#  <deobfuscated value of input parameter>\n
# Call as:
#  deobf_ofa1 <data>
function deobf_ofa1 {
	local step1 clear
	(( $# == 1 )) || abend "Usage: ${FUNCNAME[0]} <obf_data>"

	step1=$(base64 --decode $BASE64_NO_WRAP < <(echo -n $1)) || exit 1
	[[ -n "$step1" ]] || fatal 2 "produced empty step1 deobfuscation"
	clear=$(tr '\!-~' 'P-~\!-O' < <(echo -n $step1)) || exit 1
	[[ -n "$clear" ]] || fatal 3 "produced empty cleartext"

	echo $clear
}
export deobf_ofa1

# one of pair of low level functions {obf,deobf}_<some extention>
# Expected to output to STDOUT:
#  ofa2 <obfuscated value of input parameter>
#
# Call as:
#  obf_ofa2 <data>
function obf_ofa2 {
	local thisfn=${FUNCNAME[0]} step1 otype obf
	(( $# == 1 )) || abend "Usage: $thisfn <clear_data>"

	obf=$(tr 'A-Za-z' 'N-ZA-Mn-za-m' < <(echo -n $1)) || exit 1
	[[ -n "$obf" ]] || fatal 2 "produced empty obfuscation"

	# use part of function name after last '_' as obfuscator type
	echo "${thisfn##*_} "$obf
}
export -f obf_ofa2

# one of pair of low level functions {obf,deobf}_<some extention>
# Expected to output to STDOUT:
#  <deobfuscated value of input parameter>\n
# Call as:
#  deobf_ofa2 <data>
function deobf_ofa2 {
	local step1 clear
	(( $# == 1 )) || abend "Usage: ${FUNCNAME[0]} <obf_data>"

	clear=$(tr 'A-Za-z' 'N-ZA-Mn-za-m' < <(echo -n $1)) || exit 1
	[[ -n "$clear" ]] || fatal 2 "produced empty cleartext"

	echo $clear
}
export -f deobf_ofa2

# overall wrapper function for obfuscation 
# Call as
#  obfuscate <obf type> <data>
# or
#  obfuscate <data>
function obfuscate {
	local data otype
	(( $# == 1 || $# == 2 )) || abend "Usage: ${FUNCNAME[0]} [<obf type>] <data>"

	if (( $# == 2 )) ; then
		otype=$1
		data=$2
	else
		otype=''
		data=$1
	fi
	case $otype in
		ofa1 | '' )	obf_ofa1 $data ;;	# default case
		ofa2)		obf_ofa2 $data ;;
		*)		abend "unknown obfuscation type \"$otype\"" ;;
	esac
}
export -f obfuscate

# overall wrapper for various de-obfuscator functions
# Call as:
#  deobfuscate <otype> <obf_data>
function deobfuscate {
	local otype=$1 data=$2
	(( $# == 2 )) || abend "Usage: ${FUNCNAME[0]} <obf type> <obf_data>"

	case $otype in
		ofa1)	deobf_ofa1 "$data" ;;
		ofa2)	deobf_ofa2 "$data" ;;
		*)	abend "unknown obfuscation type \"$otype\"" ;;
	esac
}
export -f deobfuscate

###
# get MySQL root password in a variety of ways.
# 1. respect MYSQL_ROOT_PASSWD if present; please pass down to sub-scripts. 
#    Do NOT persist to disk.
# 2. respect $APPD_ROOT/db/.rootpw if present
# 3. respect $APPD_ROOT/db/.rootpw.obf if present
# 4. gripe, letting them know how to persist a password
#
# Call as:
#  dbpasswd=`get_mysql_passwd`
function get_mysql_passwd {
	local clear obf otype inpw2=' '
	local rootpw="$APPD_ROOT/db/.rootpw" rootpw_obf="$APPD_ROOT/db/.rootpw.obf"

	if [[ -n "$MYSQL_ROOT_PASSWD" ]] ; then
		echo $MYSQL_ROOT_PASSWD
	elif [[ -s $rootpw && -r $rootpw ]] ; then 
		echo $(<$rootpw)
	elif [[ -s $rootpw_obf ]] ; then
		IFS=$' ' read -r otype obf < $rootpw_obf
		[[ -n "$otype" && -n "$obf" ]] || \
			fatal 1 "unable to read obfuscated passwd from $rootpw_obf"
		clear=$(deobfuscate $otype $obf)
		[[ -n "$clear" ]] || \
			fatal 2 "unable to deobfuscate passwd from $rootpw_obf"
		echo $clear
	else
		fatal 3 "no password in db/.rootpw, db/.rootpw.obf or MYSQL_ROOT_PASSWORD"
	fi
}
export -f get_mysql_passwd
