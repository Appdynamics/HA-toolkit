#!/bin/bash

# $Id: ./upver.sh 3.35 2018-05-18 13:33:57 cmayer Exp $

function usage() {
	echo usage: $0 [filenames]
	exit
}

version=
if [ -f VERSION ] ; then
	version=$(cat VERSION)
fi
while getopts "v:" flag ; do
	case $flag in
	v)
		version=$OPTARG
		;;
	*)
		usage
		;;
	esac
done

function revfile() {
	fn=$1
	bn=`basename $1`
	echo $1
	mv $fn $fn.old 
	awk -v VER=$version -v fn=$fn -v dt=`date +%F` -v tm=`date +%T` -v us=`whoami` '
		function bumpver(v) {
			if (length(VER)) {
				return VER;
			}
			p=split(v,va,".");
			va[p] += 1;
			v=va[1];
			for (n=2; n <= p; n++) {
				v = v "." va[n];
			}
			return v;
		}
		/\$Id:[ ]/ {
			pr="";
			co=match($0, "^[ \t]*");
			if (co) {
				pr=substr($0,RSTART,RLENGTH);
			}
			for (i=1; i <= NF; i++) {
				if ($i == "$Id:") {
					k=i+1; $k = fn;
					k=i+2; $k = bumpver($k);
					k=i+3; $k = dt;
					k=i+4; $k = tm;
					k=i+5; $k = us;
					break;
				}
			} 
			printf("%s%s\n", pr ,$0);
			next;
		}
		{ print }
	' < $fn.old >$fn
	diff $fn.old $fn
	rm $fn.old
}
shift $((OPTIND-1))

for i in $* ; do
	revfile $i
done
