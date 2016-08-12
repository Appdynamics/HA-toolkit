#!/bin/bash
# $Id: testconf.sh 3.0 2016-08-03 19:23:30 cmayer $
# must run this on linux!

tmpdir=/tmp

. ../lib/log.sh
. ../lib/conf.sh

DELFILES=

function runuser {
	"$@"
}

function fail {
	echo fail "$@"
	DELFILES=
	exit 1
}

rm -f testfile.xml

cat > testfile1.xml << FIN1
<domain>
	<configs port="1024">
		<config>
			<java-config>
				<jvm-options>-Dfoo.bar.baz=99</jvm-options>
				<jvm-options>-Dappdynamics.controller.port=8090</jvm-options>
				<jvm-options>-Dfoobie.bar.baz=88</jvm-options>
				<jvm-options>-XX:+LogVMOutput</jvm-options>
				<jvm-options>-XX:-LoseLose</jvm-options>
				<jvm-options>-Xmx1024m</jvm-options>
				<jvm-options>-XX:MaxPermSize=256m</jvm-options>
			</java-config>
		</config>
	</configs>
</domain>
FIN1

DOMAIN_XML=testfile1.xml
DELFILES+=" testfile1.xml"

if [ "`domain_get_jvm_option foo.bar.baz`" != 99 ] ; then fail 1 ; fi
domain_set_jvm_option foo.bar.baz 77
if [ "`domain_get_jvm_option foo.bar.baz`" != 77 ] ; then fail 2 ; fi

if [ "`domain_get_jvm_option foo.bar.bax`" != "" ] ; then fail 3 ; fi
domain_set_jvm_option foo.bar.bax 33
if [ "`domain_get_jvm_option foo.bar.bax`" != 33 ] ; then fail 4 ; fi
domain_unset_jvm_option foo.bar.bax
if [ "`domain_get_jvm_option foo.bar.bax`" != "" ] ; then fail 5 ; fi

if [ "`domain_get_jvm_option Gnarl`" != "" ] ; then fail 5 ; fi
domain_set_jvm_option +Gnarl
if [ "`domain_get_jvm_option Gnarl`" != "+" ] ; then fail 6 ; fi
domain_unset_jvm_option +Gnarl
if [ "`domain_get_jvm_option Gnarl`" != "" ] ; then fail 7 ; fi

if [ "`domain_get_jvm_option foo.bar.bax`" != "" ] ; then fail 5 ; fi

if [ "`domain_get_jvm_option +LogVMOutput`" != '+' ] ;then fail 10 ; fi
if [ "`domain_get_jvm_option +LoseLose`" != '-' ] ;then fail 11 ; fi
if [ "`domain_get_jvm_option Xmx`" != '1024m' ] ;then fail 12 ; fi
if [ "`domain_get_jvm_option Xmx | scale`" != 1073741824 ] ;then fail 13 ; fi

if [ "`domain_get_jvm_option Xms`" != "" ] ;then fail 14 ; fi
domain_set_jvm_option Xms 1024
if [ "`domain_get_jvm_option Xms`" != "1024" ] ;then fail 15 ; fi
domain_unset_jvm_option Xms
if [ "`domain_get_jvm_option Xms`" != "" ] ;then fail 16 ; fi

if use_privileged_ports ; then fail 20 ; fi

DOMAIN_XML=testfile2.xml
DELFILES+=" testfile2.xml"

cat > testfile2.xml << FIN
<domain>
	<configs port="1023"></configs>
</domain>
FIN

if ! use_privileged_ports ; then fail 21 ; fi

if [ "`echo '-Xmx512m -Xms512m' | sed -e 's/ /\n/g' | get_jvm_option Xmx | scale`" != 536870912 ] ; then fail 30 ; fi
if [ "`echo '-Xmx512m -Xms512m' | sed -e 's/ /\n/g' | get_jvm_option Xmn | scale`" != "" ] ; then fail 31 ; fi


cat > testfile3 << FIN3
[mysqld]
innodb_io_capacity=99
use_losing_feature
FIN3

DB_CONF=testfile3
DELFILES+=" testfile3"

if [ "`dbcnf_get use_losing_feature`" != 'use_losing_feature' ] ; then fail 40 ; fi
if [ "`dbcnf_get missing_keyword`" != '' ] ; then fail 41 ; fi
if [ "`dbcnf_get innodb_io_capacity`" != '99' ] ; then fail 42 ; fi
dbcnf_set new_keyword 88
if [ "`dbcnf_get new_keyword`" != '88' ] ; then fail 43 ; fi
dbcnf_set new_flag
if [ "`dbcnf_get new_flag`" != 'new_flag' ] ; then fail 44 ; fi
dbcnf_unset new_flag
if [ "`dbcnf_get new_flag`" != '' ] ; then fail 45 ; fi
dbcnf_unset new_keyword
if [ "`dbcnf_get new_keyword`" != '' ] ; then fail 46 ; fi

rm -f $DELFILES
