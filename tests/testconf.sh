#!/bin/bash
# $Id: tests/testconf.sh 3.13 2017-03-09 16:26:33 cmayer $
# maybe want to redo using shunit2

set -e -E
testid=$1

if [ $(uname) == 'Darwin' ] ; then
	function readlink() {
		greadlink $@
	}
	export -f readlink
	function sed() {
		gsed "$@"
	}
	export -f sed
fi

tmpdir=/tmp

function runuser {
	echo "$*" | bash
}

export APPD_ROOT=.
. ../lib/log.sh
. ../lib/conf.sh

DELFILES=

function fail {
	echo fail "$@"
	DELFILES=
	exit 1
}

cat > testfile0.xml << FIN0
<controller-info>
	<foo>bletch</foo>
	<bar>"bax"</bar>
	<bax></bax>
	<freen>


    </freen>
</controller-info>
FIN0

DELFILES+=" testfile0.xml"

function logtest() {
	echo "test $1"
	if [ -n "$testid" ] ; then
		if [ "$testid" = "$1" ] ; then
			set -x
		fi
	fi
}

#
# check_cinfo_value <option> <value> <test code>
#
function check_cinfo_val() {
	logtest $3
	val=$(controller_info_get $xmlfile $1)
	if [ "$val" != "$2" ] ; then
		echo controller_info_get for $1 got "$val" expected "$2"
		echo xmlfile:
		cat $xmlfile
		fail $3
	fi
}

function cinfo_set_val() {
	controller_info_set $xmlfile $1 "$2"
}

xmlfile=testfile0.xml

check_cinfo_val freen "" 59
check_cinfo_val barf "" 58
check_cinfo_val bax "" 57
check_cinfo_val bar "\"bax\"" 56
check_cinfo_val foo "bletch" 55

check_cinfo_val narf "" 54

cinfo_set_val narf xyzzy
check_cinfo_val narf xyzzy 53
cinfo_set_val narf freen
check_cinfo_val narf freen 52
cinfo_set_val narf ""
check_cinfo_val narf "" 51

cat > testfile1.xml << FIN1
<domain>
	<configs port="1024">
		<config name="server-config">
			<java-config>
				<jvm-options>-Ddefined</jvm-options>
				<jvm-options>-DFroo=99</jvm-options>
				<jvm-options>-Dfoo.bar.baz=99</jvm-options>
				<jvm-options>-Dappdynamics.controller.port=8090</jvm-options>
				<jvm-options>-Dfoobie.bar.baz=88</jvm-options>
				<jvm-options>-XX:+LogVMOutput</jvm-options>
				<jvm-options>-XX:-LoseLose</jvm-options>
				<jvm-options>-Xmx1024m</jvm-options>
				<jvm-options>-XX:MaxPermSize=256m</jvm-options>
			</java-config>
		</config>
		<config name="default-config">
			<java-config>
				<jvm-options>-Ddefined</jvm-options>
				<jvm-options>-DFroo=199</jvm-options>
				<jvm-options>-Dfoo.bar.baz=199</jvm-options>
				<jvm-options>-Dappdynamics.controller.port=18090</jvm-options>
				<jvm-options>-Dfoobie.bar.baz=188</jvm-options>
				<jvm-options>-XX:-LogVMOutput</jvm-options>
				<jvm-options>-XX:+LoseLose</jvm-options>
				<jvm-options>-Xmx11024m</jvm-options>
				<jvm-options>-XX:MaxPermSize=1256m</jvm-options>
			</java-config>
		</config>
	</configs>
</domain>
FIN1

DOMAIN_XML=testfile1.xml
DELFILES+=" testfile1.xml"

#
# check_domain_jvm <option> <value> <test code>
#
function check_domain_jvm() {
	logtest $3
	val=$(domain_get_jvm_option $1)

	if [ "$val" != "$2"	] ; then
		echo domain_get_jvm_option for $1 got "$val" expected "$2"
		echo domain file:
		cat $DOMAIN_XML
		fail $3
	fi
}

check_domain_jvm defined true 1

check_domain_jvm foo.bar.baz 99 2
domain_set_jvm_option foo.bar.baz 77
check_domain_jvm foo.bar.baz 77 3

check_domain_jvm foo.bar.bax unset 4
domain_set_jvm_option foo.bar.bax 33
check_domain_jvm foo.bar.bax 33 5

domain_set_jvm_option foo.bar.bax
check_domain_jvm foo.bar.bax true 6

domain_unset_jvm_option foo.bar.bax
check_domain_jvm foo.bar.bax unset 7

check_domain_jvm +Gnarl unset 8
domain_set_jvm_option +Gnarl
check_domain_jvm -Gnarl "+" 9
domain_unset_jvm_option -Gnarl
check_domain_jvm -Gnarl unset 10

domain_set_jvm_option Froo host
check_domain_jvm Froo "host" 11
domain_set_jvm_option Froo cookie
check_domain_jvm Froo "cookie" 12

check_domain_jvm +LogVMOutput '+' 13
check_domain_jvm +LoseLose '-' 14
check_domain_jvm Xmx '1024m' 15

check_domain_jvm Xms unset 16
domain_set_jvm_option Xms 1024
check_domain_jvm Xms 1024 17
domain_unset_jvm_option Xms
check_domain_jvm Xms unset 18

domain_unset_jvm_option defined
check_domain_jvm defined unset 19
xml_context="/<config name=\"default-config\">/,/<\/config>/"
check_domain_jvm defined true 20

echo test 21
if use_privileged_ports ; then fail 21 ; fi

DOMAIN_XML=testfile2.xml
DELFILES+=" testfile2.xml"

cat > testfile2.xml << FIN
<domain>
	<configs port="1023"></configs>
</domain>
FIN

echo test 22
if ! use_privileged_ports ; then fail 22 ; fi

echo test 30
if [ "`echo '-Xmx512m -Xms512m' | 
	sed -e 's/ /\n/g' | 
	get_jvm_option Xmx | scale`" != 536870912 ] ; then 
	fail 30
fi

echo test 31
if [ "`echo '-Xmx512m -Xms512m' | 
	sed -e 's/ /\n/g' | 
	get_jvm_option Xmn | scale`" != "" ] ; then 
	fail 31 
fi

cat > testfile3 << FIN3
[mysqld]
innodb_io_capacity=99
use_losing_feature
FIN3

DB_CONF=testfile3
DELFILES+=" testfile3"

function check_dbcnf() {
	logtest $3
	val=$(dbcnf_get $1)
	if [ "$val" != "$2" ] ; then
		echo dbcnf_get for $1 got "$val" expected "$2"
		echo db_cnf file:
		cat DB_CONF
		fail $3
	fi
}

check_dbcnf use_losing_feature use_losing_feature 40
check_dbcnf missing_keyword unset 41
check_dbcnf innodb_io_capacity 99 42

dbcnf_set new_keyword 88
check_dbcnf new_keyword 88 43

dbcnf_set new_flag
check_dbcnf new_flag new_flag 44
dbcnf_unset new_flag
check_dbcnf new_flag unset 45
dbcnf_unset new_keyword
check_dbcnf new_keyword unset 46

rm -f $DELFILES
