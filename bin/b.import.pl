#!/usr/bin/perl -w

use strict;
use warnings;
no warnings 'uninitialized';
use Carp qw(confess);
use Time::Local qw(timegm);

my $debug=1;
my @DT;

sub Usage() {
	print STDERR <<END;
Usage: $0 Comment...
END
	exit 1;
}

Usage unless @ARGV;
if($ARGV[0] =~ /^(\d\d\d\d)-(\d\d)-(\d\d)$/) {
	my $sec = timegm(0,0,0,$3,$2-1,$1-1900);
	shift;
	my $dtf;
	if(-f "/usr/lib/datefudge.so") {
    	$dtf = "/usr/lib";
	} elsif(-f "/home/smurf/datefudge/datefudge.so") {
    	$dtf = "/home/smurf/datefudge";
	} else {
    	die "No DateFudge";
	}
	@DT = ("LD_PRELOAD=$dtf/datefudge.so","DATEFUDGE=".(time-$sec));
}
my $cmt = "@ARGV"; $cmt =~ s/"/'/g;

$ENV{BK_LICENSE}="ACCEPTED";
$ENV{CLOCK_DRIFT}="1";

$|=1;

use Shell qw(); ## bk prcs

sub bk {
	my @cmd = @_;

	if(defined $cmd[0]) {
		unshift(@cmd,"env",@DT,"bk");
	} else {
		shift(@cmd);
	}
	open(FP,"-|") or do {
		exec @cmd;
		exit(99);
	};
	my @res;
	while(<FP>) {
		chop;
		push(@res,$_);
	}
	close(FP) or do {
		warn $! ? "*** Error closing pipe: $!" : "Exit status $? from BK";
		return undef;
	};
	wantarray ? @res : (0+@res);
}

bk("-r","unlock","-fpxz");

sub bkfiles($) {
	my($f) = @_;
	my @new = grep {
		 m#/SCCS/#
		? undef
		: ( chmod((0600|0777&((stat $_)[2])),$_) or 1 );
	} bk(sfiles=>"-U$f");
	@new;
}

{
	my $cv;
	foreach my $fn(bk("get","-q","-p","BitKeeper/etc/ignore")) {
		$cv++ if $fn =~ /CVS/;
	}
	unless($cv) {
		print STDERR "Ignoriere CVS...\n";
		bk("ignore","CVS",".cvsignore","CVSROOT");
		bk(undef,"bk sfiles -pC | env @DT bk cset -q -y\"CVS-Ignore\"");
	}
}

my @new = grep { if(-l $_) { unlink $_; undef; } else { 1; } } bkfiles("x");
my @cur = ();
my @gone = grep { 
	if(-e $_) {
		push(@cur,$_);
		if(@cur >= 100) {
			bk(get => "-qeg",@cur);
			@cur = ();
		}
		undef;
	} else {
		1;
	}
} bkfiles("g");
bk(get => "-qeg",@cur) if @cur;

if(@new and @gone) {
	bk(get=>"-qeg",@gone);
	open(RN,"| bk renametool");
	foreach my $f(sort { $a cmp $b } @gone) { print RN "$f\n"; }
	print RN "\n";
	foreach my $f(sort { $a cmp $b } @new) { print RN "$f\n"; }
	close(RN);
	confess "No rename" if $?;
} elsif(@new) {
	bk(new => '-qG', "-yNew:$cmt", @new);
} elsif(@gone) {
	bk(rm => @gone);
} else {
	open(CH,"bk -r diffs | head -1 |");
	my $ch = <CH>;
	close(CH);
	unless(defined $ch) {
		print STDERR "...no changes.\n";
		bk("-r","unlock","-f");
		exit 0;
	}
}

bk('-r', ci => '-qG', "-y$cmt");
bk(undef,"bk sfiles -pC | env @DT bk cset -q -y\"$cmt\"");

