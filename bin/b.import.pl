#!/usr/bin/perl -w

use strict;
use warnings;
no warnings 'uninitialized';
use Carp qw(confess);

my $debug=1;

sub Usage() {
	print STDERR <<END;
Usage: $0 Comment...
END
	exit 1;
}

Usage unless @ARGV;
my $cmt = "@ARGV"; $cmt =~ s/"/'/g;

$ENV{BK_LICENSE}="ACCEPTED";
$|=1;

use Shell qw(); ## bk prcs

sub bk {
	my @cmd = @_;

	if(defined $cmd[0]) {
		unshift(@cmd,"bk");
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
	wantarray ? @res : join(" ",@res);
}

sub bkfiles($) {
	my($f) = @_;
	my @new = grep {
		 m#/SCCS/#
		? undef
		: ( chmod((0600|0777&((stat $_)[2])),$_) or 1 );
	} bk(sfiles=>"-U$f");
	@new;
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
}

bk('-r', ci => '-qG', "-y\"$cmt\"");
bk(undef,"bk sfiles -pC | bk cset -q -y\"$cmt\"");

