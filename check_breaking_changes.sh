#!/bin/bash
# $Id: check_breaking_changes.sh 1.0 2019-05-31 12:40:00 robnav $
#
# A place where newly introduced breaking changes can be checked for in current
# HA Toolkit and controller installation.
#
# The goal here is to either automatically remediate issues with older code
# or at least warn user of need for manual Admin.
#
# Copyright 2016-2019 AppDynamics, Inc
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

if (( "${1:-0}" == 1 )) ; then
	LOGFNAME=replicate.log
else		# standalone calls to log to separate file
	LOGFNAME=check_breaking_changes.log
fi

# source function libraries
. lib/log.sh
. lib/runuser.sh
. lib/conf.sh
. lib/ha.sh
. lib/password.sh
. lib/sql.sh
. lib/status.sh

# Vamshi B says (31-May-2019) can depend on existence of version.properties within
# Glassfish hierarchy. Very useful because does not depend on MySQL running.
# Vamshi B says (31-May-2019) version scheme may change into date style: YY.MM.DD
# Goal here is to produce integer from version number that permits <=, =, >= comparisons
function get_controller_version {
	awk -F. '{printf "%01.1d%01.1d%02.2d\n", $1, $2, $3}' <(awk -F= '$1=="version" {print $2}' $APPD_ROOT/appserver/glassfish/domains/domain1/applications/controller/controller-web_war/version.properties)
}

# return 0 if all replicate ignore configs are present exactly once as required for v4.5.6+ controllers, else 1
# Call as:
#  dbcnf_ignore_ok_post_4506
#  or
#  dbcnf_ignore_ok_post_4506 <(echo "$somevar")
function dbcnf_ignore_ok_post_4506 {
	local L M in_DB_CNF=${1:-$APPD_ROOT/db/db.cnf}
	local DB_CNF=$(<$in_DB_CNF)		# local copy of input in case it's a FIFO
	local -a A S

	# check for presence in db/db.cnf of 1 value of all 7 required replicate_* statements
	while read -r L ; do
		fgrep -xq "$L" <(echo "$DB_CNF") && (( $(fgrep -cx "$L" <(echo "$DB_CNF")) == 1 ))
		(( M+=$? ))
	done < <(egrep -e '^\s*replicate_' $APPD_ROOT/HA/replicate.sh)
	(( M==0 )) || return 1

	# check that slave-skip-errors contains required 6 codes
	IFS=, read -a A < <(awk -F= '$1=="slave-skip-errors" {print $2}' <(echo "$DB_CNF"))
	S=$(sort -n < <(IFS=$'\n'; echo "${A[*]}") | tr '\n' ' ')
	[[ "$S" == "1032 1062 1237 1451 1507 1517 " ]] || return 1	# trailing space to match tr output

	return 0
}

# backup and attempt to edit db.cnf into currently understood correct form, else print manual instructions
function verify_repl_ignore_post_4506 {
	local version backup=$APPD_ROOT/db/db.cnf.$(date +%s) new pattern='^[[:digit:]]+$'

	version=$(get_controller_version) && [[ "$version" =~ $pattern ]] || { warn "${FUNCNAME[0]}: failed to get recognisable controller version ($version)...skipping"; return 1; }
	if (( version >= 4506 )) ; then
		dbcnf_ignore_ok_post_4506 && return 0		# nothing to do

		# sed multi-line match and multi-line replace - uses Bash to avoid tmp file
		# ideas from: 
		# https://askubuntu.com/questions/533221/how-do-i-replace-multiple-lines-with-single-word-in-fileinplace-replace
		# https://superuser.com/questions/456246/sed-weirdness-unmatched
		new=$(sed  -e ':a;N;$!ba' -e "s/replicate_ignore_table=.*1451/X@X@/g" $APPD_ROOT/db/db.cnf | sed "/X@X@/{
		r "<(egrep -e '^\s*replicate_|^\s*slave-skip-errors' $APPD_ROOT/HA/replicate.sh | tr -d ' \t')"
		d}")

		# try hard to not update db/db.cnf unless update looks sensible
		if (( $? == 0 )) && dbcnf_ignore_ok_post_4506 <(echo "$new") && ! cmp -s <(echo "$new") $APPD_ROOT/db/db.cnf ; then
			cp $APPD_ROOT/db/db.cnf $backup
			echo "$new" > $APPD_ROOT/db/db.cnf
			message "modified db.cnf with updated replication settings - backup in: $backup"
		else
			if ! dbcnf_ignore_ok_post_4506; then	# auto update failed & db.cnf still not acceptable...
				warn "${FUNCNAME[0]}: to ensure all v4.5.6+ tables are replicated please manually edit
$APPD_ROOT/db/db.cnf and replace the existing configs: 

$(egrep -e '^\s*replicate_|^\s*slave-skip-errors' $APPD_ROOT/db/db.cnf)

with the updated configs: 

$(egrep -e '^\s*replicate_|^\s*slave-skip-errors' $APPD_ROOT/HA/replicate.sh | tr -d ' \t')"
				return 1
			fi
		fi
	fi
	return 0
}


###
# Main body
###
RETC=0

verify_repl_ignore_post_4506 || (( ++errors ))

(( errors == 0 )) || RETC=1
exit $RETC
