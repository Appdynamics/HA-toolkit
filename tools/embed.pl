#!/usr/bin/env perl

# $Id: embed.pl 1.2 2016-06-07 23:18:22 rob.navarro $

# Embed functions library into calling scripts to simplify client delivery.
# Mini mouse program to replace single row of Bash script that looks like:
#  embed dbfunctions.sh			# some comment
# OR
#  MYPATH=$(cd $(dirname "$0"); cd .. ; pwd -P)
#  $SOMELIB=hafunctions.sh		# some comment
#  embed $MYPATH/$SOMELIB
# with the contents of that file
#
# WILL NOT WORK WITH:
# 1. variable defined across multiple text rows
# 2. conditionally defined variables across multiple rows
# 3. variables affected by non-variable command eg pwd
#
# Call as:
# perl embed.pl controller_dbtool.sh > controller_dbtool_e.sh

use strict;
use warnings;

my %stash;				# all variable definitions

# recursive helper function to accept the RHS of a bash variable definition string (1 row) and
# return an array that lists all the variable definitions needed to instantiate
# the original variable. For example:
#  def_APPD_ROOT=$(cd $(dirname "$0"); cd .. ; pwd -P)
#  APPD_ROOT=$def_APPD_ROOT
#  FUNCLIB="$APPD_ROOT/HA/hafunctions.sh"
#  ...
#  embed $FUNCLIB
# will result in:
#  [0] def_APPD_ROOT=$(cd $(dirname "$0"); cd .. ; pwd -P)
#  [1] APPD_ROOT=$def_APPD_ROOT
#  [2] FUNCLIB="$APPD_ROOT/HA/hafunctions.sh"
sub expand {
   my $val = $_[0];
   defined $val or die "@{[(caller(0))[3]]}: needs <value> arg";
   my @retval;
   
   my @varnames = $val =~ m/\$(\{[^\}]+\}|(?:[a-zA-Z_][a-zA-Z0-9_.]*))/g; 	# get var names
   @varnames = map { (my $t = $_) =~ s/^\{([^}]+)\}$/$1/;$t } @varnames;	# remove braces
   for my $v ( @varnames ) {
      exists $stash{ $v } or die "$0: missing variable definition for $v";
      push @retval, (expand( $stash{ $v } ), "$v=$stash{ $v }"); # last variable at end of array
   }
   return @retval;
}

my $keyword = "embed";			# trigger embed logic on this word
my $re = qr/^\s*$keyword\s+\$?\S+/;	# only match 'embed...'
my $fpath;

while (defined(my $r = <>)) {
   # Save away all variable definitions that occur on their own row. 
   # Note this will break with multi-line statements or conditionals containing
   # variable definitions.
   if ($r =~ m/^\s*([a-zA-Z_][a-zA-Z0-9_.]*)=(.*)$/) {	
      my $vname = $1;

      # remove any comments i.e. chars after a '#' with a preceding whitespace chr
      (my $clean_rhs = $2) =~ s/(?:\s#.*)|(?:\s*)$//; 

      # deal with any $0 or ${0}. In this context $0 in a script being scanned for
      # embedding requirements means the name of that outer script file. If $0 is 
      # left alone then interpreting it within a new call to bash -c '$str' will
      # give the wrong answer i.e. '-bash' and not the file name.
      $fpath = $ARGV;			# get current filename for <> operator
      defined $fpath or die "$0: unable to establish current filename '$ARGV'";
      $clean_rhs =~ s/\$0/$fpath/g; $clean_rhs =~ s/\$\{0\}/$fpath/g;	# replace $0 or ${0}

      $stash{ $vname } = $clean_rhs;
   }

   if ($r =~ m/$re/) {					# found a 'embed' row
      my ($lib, $libfname);
      ($lib) = $r =~ m/^\s*$keyword\s+(\S+)/;
      if ($lib =~ tr/\$/\$/) {				# got variables to expand
         my $str = join("\n", expand( $lib ))."; echo $lib";
	 my $retstr = qx{/bin/bash -c '$str'};		# echo final variable value
	 $libfname = $retstr;
	 chomp $libfname;
	 defined $libfname or die "$0: unable to get filename from '$str'";
      } else {						# just a pathname/filename
         $libfname = $lib;
      }

      open(my $fh, "<", $libfname) || die "$0: failed to open $libfname: $!";
      my @r = <$fh>;					# suck all rows into array
      close( $fh );
      print STDOUT "\n###################### Start of embedded file: $libfname\n";
      print STDOUT join("", @r);
      print STDOUT "###################### End of embedded file: $libfname\n\n";
   } else {
      print STDOUT $r
   }
}
