#!/usr/bin/perl -w

use strict;
use warnings;
no warnings 'uninitialized';
use File::Path qw(rmtree mkpath);
use File::Find qw(find);
use File::Basename qw(basename dirname);
use Time::Local;
use Carp qw(confess);
use Storable qw(nstore retrieve);

my $debug=0;
my $diff=$ENV{BKCVS_DIFF}||60; # Zeitraum für "gleichzeitige" Änderungen im CVS

sub Usage() {
	print STDERR <<END;
Usage: $0 CVSName ProjektName

Environment: CVS_REPOSITORY BK_REPOSITORY DISPLAY
END
	exit 1;
}

Usage unless @ARGV == 2;
Usage unless $ENV{BK_REPOSITORY};
Usage unless $ENV{CVS_REPOSITORY};
$ENV{BK_LICENSE}="ACCEPTED";
select(STDERR); $|=1; select(STDOUT);

use Shell qw(); ## bk cvs
system("xterm -e true");
if($?) {
	print STDERR "No X connection?\n\n";
	Usage;
}

sub init_bk();
my $rhost="un.known";
$rhost=$1 if $ENV{CVS_REPOSITORY} =~ /\@(?:cvs\.)?([^\:]+)\:/;

my $cn = shift @ARGV;
my $pn = shift @ARGV;
$pn =~ s#[/:]#_#g;
my %excl;
foreach my $arg(@ARGV) {
	$excl{$arg}++;
}

my @DT; my @AU; my $mdate;

my $dtf;
if(-f "/usr/lib/datefudge.so") {
	$dtf = "/usr/lib";
} elsif(-f "/home/smurf/datefudge/datefudge.so") {
	$dtf = "/home/smurf/datefudge";
} else {
	die "No DateFudge";
}

sub dateset($;$) {
	my($dt,$au) = @_;
	@DT=();
	@AU=();

	@DT = ("LD_PRELOAD=$dtf/datefudge.so","DATEFUDGE=".(time-$dt-($$%(1+$diff)))) if $dt;
	@AU = ("LOGNAME=$au","USER=$au","BK_USER=$au","BK_HOST=$rhost") if $au;
}

sub dupsi($$) {
	my($ncp,$check)=@_;
	# This will tell us if we have any dups anywhere in the tree.
	die "Main Bang in ".`pwd` if $check and not $ncp and system("bk -r check -acp");

	my %dups;
	if($check) {
		open(DUP,"bk -r prs -hr1.0.. -nd:KEY: |");
		while(<DUP>) {
			chomp;
			die "Dup!" if $dups{$_}++;
		}
		close(DUP);
		if(-d "RESYNC") {
			%dups = ();
			die "Resync Bang in ".`pwd` if system("bk -r check -cR");
			open(DUP,"cd RESYNC; bk -r prs -hr1.0.. -nd:KEY: |");
			while(<DUP>) {
				chomp;
				die "Dup!" if $dups{$_}++;
			}
			close(DUP);
		}
	}
}

my $seq = 0;

sub bk {
	my @cmd = @_;
	my $check = (not defined $cmd[0] or ($cmd[0] ne "sfiles" and $cmd[0] ne "prs" and $cmd[0] ne "get" and $cmd[0] ne "new" and $cmd[0] ne "rm" and $cmd[0] ne "setup" and $cmd[0] ne "prs"));
	my $ncp = (defined $cmd[0] and $cmd[0] eq "-r" and $cmd[1] eq "ci");
	my $undo = (defined $cmd[0] and $cmd[0] eq "undo");

	$check=0 unless $debug;
	# print STDERR "@cmd\n" unless $cmd[0] eq "get" or $cmd[0] eq "prs";

	#die "ChangeSet files are not nice\n" if -f "ChangeSet";
	unlink("ChangeSet");
	dupsi($ncp,$check);
	if(defined $cmd[0]) {
		print STDERR ">>> bk @cmd\n" if $check;
		# print C "bk @cmd\n";
		unshift(@cmd,"env",@DT,@AU,"bk");
	} else {
		shift(@cmd);
		print STDERR ">>> @cmd\n" if $check;
		# print C "@cmd\n";
	}
	# close(C);
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
	unlink("ChangeSet");
	if(-f "kunde/domain/SCCS/s.record" and -d "kunde/domain/record") {
		rename("kunde/domain/record","kunde/domain/recordd");
		system("env @AU @DT bk edit kunde/domain/record");
		system("env @AU @DT bk rm kunde/domain/record");
		rename("kunde/domain/recordd","kunde/domain/record");
	}
	#die "*** CHGF in".`pwd`."    @cmd\n" if -f "ChangeSet";
	if($undo and system("bk -r check -ag")) {
		system("bk -r check -ag | env @AU @DT bk gone -");
		system("env @AU @DT bk citool");
	}
	dupsi($ncp,$check);
	wantarray ? @res : join(" ",@res);
}

sub cvs {
	my @comp = ();
	if(defined $ENV{BKCVS_COMP}) {
		push(@comp,$ENV{BKCVS_COMP}) if $ENV{BKCVS_COMP} ne "";
	} else {
		push(@comp,"-z3");
	}
	unshift(@_,"cvs",@comp,"-d",$ENV{CVS_REPOSITORY});
	print STDERR ">>> @_\n" if $debug;
	open(FP,"-|") or do {
		chdir("..");
		exec @_;
		#exec "strace","-v","-s3000","-o","/var/tmp/prcs","-F","-f",@_;
		exit(99);
	};
	my @res;
	while(<FP>) {
		chop;
		push(@res,$_);
	}
	close(FP);
	wantarray ? @res : join(" ",@res);
}

sub bkfiles($) {
	my($f) = @_;
	grep {
		(m#/Attic/# or
		 m#^Attic/# or
		 m#^\.cvsignore$# or
		 m#/\.cvsignore$# or
		 m#/CVS/# or
		 m#^CVS/# or
		 m#^CVSROOT/# or
		 m#/CVSROOT/#)
		? undef
		: ( chmod((0600|0777&((stat $_)[2])),$_) or 1 );
	} bk(sfiles=>"-U$f");
}

sub pdate($) {
	my($d) = @_;
#	2001/03/21 09:08:43
	return undef unless m#(\d{2,4})/(\d\d)/(\d\d)\s(\d\d):(\d\d)#;
	my $y=$1; $y-=1900 if $y>1900;
	my $date = timelocal(0,$5,$4,$3,$2-1,$y);
	$mdate = $date if not $mdate or $mdate > $date;
	$date;
}

my %symdate;
my $cset;
my $dt_done;

my %known;
sub add_date($;$$$$) {
	my($wann,$fn,$rev,$autor,$cmt)=@_;
	return if defined $fn and $known{$fn}{$rev}++;

	sub acmp($$) {
		my($a,$b)=@_;
		return 0 if not defined $a;
		return 0 if not defined $b;
		$a cmp $b;
	}

	my $i;
	my $cs;
	cset:
	{
		my($min,$max);
		$min=0;$max=@$cset;$i=0;

		# vor dem Anfang?
		while($min<$max) {
			$i=int(($min+$max)/2);
			$cs = $cset->[$i];
			# A vor Anfang
			# C gleichzeitig
			# E nach Ende
			#
			if($cs->{wann} > $wann) { # A: weitersuchen
				$max=$i;
				next;
			} elsif($cs->{wann} < $wann) { # E: weitersuchen
				$min=$i+1;
				next;
			}
			# ansonsten: Treffer.
			last cset;
		}
		# nix gefunden
		$cs={"wann"=>$wann};
		splice(@$cset,$max,0,$cs);
	}
	if(defined $fn) {
		$autor="?" unless defined $autor;
		$cs->{autor}={} unless ref $cs->{autor};
		$cs->{autor}{$autor}={} unless ref $cs->{autor}{$autor};
		$cs = $cs->{autor}{$autor};
	
		$cs->{$fn}{cmt} = $cmt;
		$cs->{$fn}{rev} = $rev;
	} else {
		$cs->{sym} = [] unless defined $cs->{sym};
		return $cs->{sym};
	}
}

# Bearbeite den Log-Eintrag EINER Datei
sub proc1($$$$$$) {
	my($fn,$dt,$rev,$cmt,$autor,$syms) = @_;

	add_date($dt,$fn,$rev,$autor,$cmt);
	foreach my $sym(@$syms) {
		$symdate{$sym}=$dt if not defined $symdate{$sym} or $symdate{$sym}<$dt;
	}
}
sub proc(@) {
	my $state=0;
	my $fn;
	my $rev;
	my $dt;
	my $autor;
	my $cmt;
	my %syms;
	foreach my $x(@_) {
		if($state == 0 and $x =~ s/^Working file:\s+(\S+)\s*$/$1/) {
			$fn = $x;
			$state=1;
			print STDERR " "x70,"\r  $fn\r";
			next;
		}
		if($state == 1 and $x =~ /^symbolic names:/) {
			$state=2;
			next;
		}
		if($state == 2) {
			if($x =~ /^\s+(\S+)\:\s*(\S+)\s*$/) {
				$syms{$2}=[] unless defined $syms{$2};
				push(@{$syms{$2}},$1);
				next;
			} else {
				$state=3;
			}
		}
		if($state >= 2 and $x =~ /^\-+\s*$/) {
			$state=4;
			proc1($fn,$dt,$rev,$cmt,$autor,$syms{$rev}) if $dt;
			$dt=0; $cmt="";
			next;
		}
		if($state == 4 and $x =~ /^revision\s+(\d+\.\d+)\s*$/) {
			$rev=$1;
			$state=5;
			next;
		}
		if($state == 5 and $x =~ /^date:\s+(\d+)\/(\d+)\/(\d+)\s+(\d+)\:(\d+)\:(\d+)\s*\;\s+author\:\s+(\S+)\;/) {
			$autor = $7;
			my($y,$m,$d,$hh,$mm,$ss)=($1,$2,$3,$4,$5,$6);
			$y-=1900 if $y>=1900; $m--;
			$dt=timelocal($ss,$mm,$hh,$d,$m,$y);
			die "Datum: $x" unless $dt;
			$state = 6;
			next;
		}
		if($state==6) {
			next if $x =~ /^branches\:\s+/;
			$cmt .= "$x\n";
			next;
		}
	}
	proc1($fn,$dt,$rev,$cmt,$autor,$syms{$rev}) if $dt; $dt=0;
}

my $tmpcv = "/var/cache/cvs/$cn";

if(-f "$tmpcv.data") {
	print STDERR "Reading stored CVS log\n";
	$cset = retrieve("$tmpcv.data");
} else {
	$cset=[];
	print STDERR "Processing CVS log\n";
	for my $mr(1..9) {
		rmtree($tmpcv);
		
		print STDERR "Fetch CVS files $mr...\n";
		chdir("/var/cache/cvs/bk");
		cvs("get","-r$mr.1",$cn);
		chdir($tmpcv);
		print STDERR "processing $mr...\n";
		my @buf = ();
		open(LOG,"cvs log |");
		while(<LOG>) {
			chomp;
			if($_ =~ /^=+\s*$/) {
				proc(@buf);
				@buf=();
			} else {
				push(@buf,$_) if @buf or /^RCS file:/;
			}
		}
		proc(@buf) if @buf;
		close(LOG);
	}
	rmtree($tmpcv);
	foreach my $sym(keys %symdate) {
		push(@{add_date($symdate{$sym})},$sym);
	}
	nstore($cset,"$tmpcv.data");
}
chdir("/");

dateset($cset->[0]{wann});

my $tmppn="/var/cache/cvs/bk/$cn";
unless(-d "$tmppn/BitKeeper") {
	system("bk clone -q $ENV{BK_REPOSITORY}/$pn $tmppn");

	if($?) {
		print STDERR "Creating new Bitkeeper repository...\n";
		my $tmpcf = "/tmp/cf.$$";
		open(CF,">$tmpcf");
		print CF <<END;
description: $pn

logging:    changesets\@openlogging.org
security:   none
contact:    Matthias Urlichs
email:		smurf\@noris.de
Company:    noris network AG
Street:     Kilianstraße 142
City:       Nürnberg
Postal:     90491
Country:    Germany

checkout:get
END
		close CF;
		bk("setup", '-f', -c => $tmpcf, $tmppn);
		unlink $tmpcf;
		chdir($tmppn);
		bk("edit","BitKeeper/etc/logging_ok");
		open(OK,">>BitKeeper/etc/logging_ok");
		print OK $ENV{USER}."\@".`hostname`; ## includes LF
		close(OK);
		bk("new"=>"BitKeeper/etc/logging_ok");
		bk('-r', ci => '-qG', "-yLogging_OK");
		system("bk sfiles -pC | env @DT @AU bk cset -q -yLogging_OK");
		bk("parent","$ENV{BK_REPOSITORY}/$pn");
		bk("clone",".","$ENV{BK_REPOSITORY}/$pn");
	}
#	find({wanted=>sub{
#		return unless $_ eq "SCCS";
#		$File::Find::path="." unless defined $File::Find::path;
#		mkpath($File::Find::path,0,0755);
#		rename("SCCS",$tmpcv."/".$File::Find::path."/SCCS");
#		$File::Find::prune=1;
#	}},".");
}
chdir($tmppn);

sub cleanout() {
	unlink bkfiles("x");
	bk("-r","unlock","-f");
	bk("-r","clean","-q");
}

# Finde den letzten Import
{
	cleanout();
	unlink bkfiles("g");
	open(REV,"bk prs -anh -r+ -d ':COMMENTS:\n' ChangeSet |");
	while(<REV>) {
		chomp;
		if(/^C CVS\:\s*(\d+)-(\d+)-(\d+)\s+(\d+)\:(\d+)\:(\d+)\s*$/) {
			my ($y,$m,$d,$hh,$mm,$ss)=($1,$2,$3,$4,$5,$6);
			$y -= 1900 if $y >= 1900; $m--;
			my $dt = timelocal($ss,$mm,$hh,$d,$m,$y);
			$dt_done = $dt if $dt_done < $dt;
		}
	}
	close(REV);
}


sub scmt($;$) {
	my($adt,$scmt)=@_;

	foreach my $f(values %$adt) {
		my $cmt = $f->{cmt};
		next unless defined $cmt;
		if(not defined $scmt) {
			$scmt=$cmt;
		} else {
			$scmt="" if $scmt ne $cmt;
		}
	}
	$scmt;
}

sub process($$$$) {
	my($autor,$wann,$adt,$len)=@_;
	my $scmt = scmt($adt);

	my($ss,$mm,$hh,$d,$m,$y)=localtime($wann);
	$m++; $y+=1900; ## zweistellig wenn <2000
	my $cvsdate = sprintf "%04d-%02d-%02d %02d:%02d:%02d",$y,$m,$d,$hh,$mm,$ss;
	print STDERR " Processing $len: $cvsdate                        \r";
	dateset($wann,$autor);

	# system("(bk sfiles -gU; bk sfiles -x) | p.bk.filter | xargs -0r p.bk.mangler");
	# Map: Revisionsnummer->Dateiname

	my @gone;
	{
		my %rev;
		foreach my $f(keys %$adt) {
			my $rev = $adt->{$f}{rev};
			push(@{$rev{$rev}}, $f);
			if($ENV{CVS_REPOSITORY} =~ /\:pserver\:/) {
				do {
					$f = dirname($f);
					mkpath("$f/CVS",1,0755);
				} while($f ne ".");
			} else {
				$f = dirname($f);
				rmdir("$f/CVS");
			}
		}
		foreach my $rev(keys %rev) {
			my @f = @{$rev{$rev}};
			print STDERR "  Processing $len: $cvsdate $rev ".(0+@f)."       \r";
			while(@f) {
				my $i = undef;
				$i=50 if @f>60;
				my @ff = splice(@f,0,$i||(1+@f));
				bk("get","-egq", @ff) if $rev !~ /^\d+\.1$/;
				unlink(@ff);
				cvs("get","-r",$rev, map { "$cn/$_" } @ff);
			}
			push(@gone, grep {
					-e dirname($_)."/SCCS/s.".basename($_) and ! -e $_ }
				@{$rev{$rev}});
		}
	}

#	foreach my $f(keys %{$inf->{rev}}) {
#		mkpath(dirname($f),0,0755);
#		bk("get","-eg",$f);
#		cvs("get","-d",dirname($f),"-r",$inf->{rev}{$f},"$cn/$f");
#	}
#
#	my $redo;
#	foreach my $f(@files) {
#		$redo++ if $f =~/^[CM]\s/;
#	}
#	cvs("update","-d","-D",$cvsdate) if $redo;
#
	my @new=();
	foreach my $n (grep { if(-l $_) { unlink $_; undef; } else { 1; } } bkfiles("x")) {
		if($adt->{$n}{rev} =~ /^\d+\.1$/) {
			push(@new,$n);
			next;
		}
		print "Checking if '$n' is a resurrected file...\n";
		rename($n,"x.$$");
		system("env",@DT,@AU,"bk","unrm","$n");
		if(-f $n) {
			bk("get","-egq",$n);
		} else {
			push(@new,$n);
		}
		rename("x.$$",$n);
	}

	if(@new and @gone) {
		use IO::File;
		# bk(get=>"-qeg",@gone); ## schon erledigt
		# print STDERR ">>> bk -qeg @gone\n";
		# print $rename $d->{major}.".".$d->{minor}."\n";
		my $tmf="/tmp/bren.$$";
		open(RN,"|env @AU @DT bk renametool -p > $tmf");
		foreach my $f(sort { $a cmp $b } @gone) { print RN "$f\n"; }
		print RN "\n";
		foreach my $f(sort { $a cmp $b } @new) { print RN "$f\n"; }
		close(RN);
		# print $rename "\n";
		confess "No rename" if $? or not -s $tmf;

		my $cmds="";
		my $T = IO::File->new($tmf,"r");
		while(<$T>) {
			$cmds .= $_;
		}
		$T->close();
		unlink($tmf);

		nstore($cset,"$tmpcv.data");
	
		@new=(); @gone=();
		my $ocmt=""; my @onew;
		foreach my $line(split(/\n/,$cmds)) {
			if($line =~ /^bk rm (.+)$/) {
				push(@gone,$1);
			} elsif($line =~ /^bk new (.+)$/) {
				push(@new,$1);
			} elsif($line =~ /^bk mv (.+) (.+)$/) {
				my $cmt1=$adt->{$1}{cmt};
				my $cmt2=$adt->{$2}{cmt};
				if(defined $cmt1 and $cmt1 ne "") {
					$cmt1.=$cmt2 if defined $cmt2 and $cmt2 ne "" and $cmt1 ne $cmt2;
				} else {
					$cmt1=$cmt2;
				}
				$cmt1="CVS: $cvsdate" if defined $scmt and $cmt1 eq $scmt;
				my $n=$2;
				rename($n,"x.$$");
				bk("mv",$1,$n);
				bk("get","-geq",$n);
				rename("x.$$",$n);

				if($cmt1 ne $ocmt) {
					bk(ci => '-qG', "-y$ocmt", @onew) if @onew;
					@onew=();
					$ocmt=$cmt1;
				}
				push(@onew,$n);
			}
		}
		bk(ci => '-qG', "-y$ocmt", @onew) if @onew;
		# bk(undef,"echo after renametool");
	}
	if(@new) {
		my $ocmt=""; my @onew=();
		foreach my $new(@new) {
			my $cmt = $adt->{$new}{cmt};
			$cmt = "CVS: $cvsdate" if $cmt eq "" or (defined $scmt and $cmt eq $scmt);
			if($cmt ne $ocmt) {
				bk(delta => '-i', "-y$ocmt", "-q", @onew) if @onew;
				@onew=();
				$ocmt=$cmt;
			}
			push(@onew,$new);
		}
		bk(delta => '-i', "-y$ocmt", "-q", @onew) if @onew;
	}
	if(@gone) {
		bk(rm => @gone);
	}

#	die "ENDE ".`pwd`."env @DT @AU bk -r ci -qG -yFoo\n";
	my $ocmt=""; my @onew=();
	foreach my $f(bkfiles("cg")) {
		my $cmt = $adt->{$f}{cmt};
		$cmt = "CVS: $cvsdate" if $cmt eq "" or (defined $scmt and $cmt eq $scmt);

		if($cmt ne $ocmt) {
			bk(ci => '-qG', "-y$ocmt", @onew) if @onew;
			@onew=();
			$ocmt=$cmt;
		}
		push(@onew,$f);
	}
	bk(ci => '-qG', "-y$ocmt", @onew) if @onew;

	$scmt = "CVS: $cvsdate".((defined $scmt) ? "\n$scmt" : "");
	# $scmt =~ s/\'/\"/g;
	open(FP,"|-") or do {
		exec("env", @DT,@AU, "bk", "cset", "-q", "-y$scmt");
		exit(99);
	};
	open(P,"bk sfiles -pC |");
	print FP $_ while(<P>);
	close(P); close(FP);

	# unlink(bkfiles("g"));
#	bk("-r","unget");
#	bk("-r","unedit");
#	bk("-r","unlock");
}

my %last;
my $x;
$DB::single=1;
while(@$cset) {
	$x = $cset->[0];
	next if $x->{wann} <= $dt_done;
	
	foreach my $autor(keys %{$x->{autor}}) {
		next if defined $last{$autor} and $last{$autor} >= $x->{wann};

		my %adt;
		my %adf;

		my $scmt;
		my $ldiff=$x->{wann};

		# Wir suchen nun Blöcke, die nur von einem Autor stammen,
		# entweder denselben Kommentar haben oder ausreichend eng
		# zusammen sind, und nicht durch Änderungen anderer Autoren oder
		# durch Symbole unterbrochen sind.
		my $i=0;
		sk_add: while($i < @$cset) {
			my $y=$cset->[$i];
			my $f=$y->{autor}{$autor};

			# Änderung dieses Autors ?
			last sk_add unless $f;

			# Doppelte Änderung?
			foreach my $fn(keys %$f) {
				last sk_add if $adf{$fn}++;
			}

			# anderer Kommentar?
			$scmt = scmt($f,$scmt);

			if (not defined $scmt or $scmt eq "") {
				last sk_add if $y->{wann} - $ldiff > $diff;
			} else {
				last sk_add if $y->{wann} - $ldiff > 10*$diff;
			}


			# JETZT aber: Sammle Änderungen.
			foreach my $fn(keys %$f) {
				$adt{$fn}=$f->{$fn};
			}
			$last{$autor}=$ldiff=$y->{wann};
			

			# Abbruch, wenn Symbol
			last sk_add if $y->{sym};

			# Abbruch, wenn Änderung anderer Autoren reinkommt.
			foreach my $a(keys %{$y->{autor}}) {
				last sk_add if $a ne $autor and (not defined $last{$a} or $last{$a} < $y->{wann});
	}
		} continue {
			$i++;
		}
		process($autor,$ldiff,\%adt,0+@$cset);
	}

	if(defined $x->{sym}) {
		foreach my $sym(@{$x->{sym}}) {
			bk("cset","-r+","-S$sym");
		}
	}
} continue {
	shift @$cset;
}
bk("push","-q") unless $ENV{BKCVS_NOPUSH};
print STDERR "OK                                                 \n";
unlink("$tmpcv.data");
