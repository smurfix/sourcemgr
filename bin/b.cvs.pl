#!/usr/bin/perl -w

use strict;
use warnings;
no warnings 'uninitialized';
use File::Path qw(rmtree mkpath);
use File::Find qw(find);
use File::Basename qw(basename dirname);
use Time::Local;
use IO::File;
use Carp qw(confess);
use Storable qw(nstore retrieve);

my $debug=0;
my $diff=30; # Zeitraum für "gleichzeitige" Änderungen im CVS

sub Usage() {
	print STDERR <<END;
Usage: $0 CVSName ProjektName

Environment: CVS_REPOSITORY BK_REPOSITORY
END
	exit 1;
}

Usage unless @ARGV == 2;
Usage unless $ENV{BK_REPOSITORY};
Usage unless $ENV{CVS_REPOSITORY};
$ENV{BK_LICENSE}="ACCEPTED";
select(STDERR); $|=1; select(STDOUT);

use Shell qw(); ## bk cvs

sub init_bk();

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
	@AU = ("LOGNAME=$au","USER=$au","BK_USER=$au","BK_HOST=un.known") if $au;
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
	unshift(@_,"cvs","-z3","-d",$ENV{CVS_REPOSITORY});
	print STDERR ">>> @_\n";
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

sub atta($$) {
	my($i,$j)=@_; # copy $j into $i
	my($fi,$fj);
	$fi->{ende}=$fj->{ende} if defined $fj->{ende};

	# Kommentare, pro Datei
	$fi=$i->{cmt};
	$fj=$j->{cmt};
	unless($fi) {
		$i->{cmt}=$fj;
	} elsif($fj) {
		foreach my $f(keys %$fj) {
			$fi->{$f} .= $fj->{$f};
		}
	}

	# Ein nichtexistierender Eintrag wird auf den anderen gesetzt.
	# Ein undef-Eintrag hat Vorrang (es gibt bereits einenn Konflikt).
	# Ungleiche Einträge resultieren in undef.
	unless(exists $fi->{scmt}) {
		$fi->{scmt} = $fj->{scmt} if exists $fj->{scmt};
	} elsif(exists $fj->{scmt} and defined $fi->{scmt} and (not defined $fj->{scmt} or $fi->{scmt} ne $fj->{scmt})) {
		$fi->{scmt}=undef;
	}
	unless(exists $fi->{autor}) {
		$fi->{autor} = $fj->{autor} if exists $fj->{autor};
	} elsif(exists $fj->{autor} and defined $fi->{autor} and (not defined $fj->{autor} or $fi->{autor} ne $fj->{autor})) {
		$fi->{autor}=undef;
	}

	# Symbol-Liste für diese Revision.
	$fi=$i->{sym};
	$fj=$j->{sym};
	unless($fi) {
		$i->{sym}=$fj;
	} elsif($fj) {
		push(@$fi,@$fj);
	}

	# Revisionsnummern. Die letzte hat Vorrang.
	$fi=$i->{rev};
	$fj=$j->{rev};
	unless($fi) {
		$i->{rev}=$fj;
	} elsif($fj) {
		foreach my $f(keys %$fj) {
			$fi->{$f}=$fj->{$f};
		}
	}


}
sub csdiff($$$$) {
	my($i,$fn,$autor,$cmt)=@_;
	my $df = $diff;
	my $fi = $cset->[$i];
	if(defined $fn and exists $fi->{autor}) {
		unless(defined $fi->{autor}) { # Konflikt
			$df /= 2;
		} elsif($fi->{autor} eq $autor) { # OK
			$df *= 2;
		}
	}
	if(defined $cmt and exists $fi->{scmt}) {
		unless(defined $fi->{scmt}) { # Konflikt
			$df /= 5;
		} elsif($fi->{scmt} eq $cmt) { # OK
			$df *= 5;
		}
	}
	$df /= 2 if defined $fn and defined $fi->{cmt}{$fn};
	$df;
}
sub add_date($;$$$$) {
	chomp;

	my($wann,$fn,$rev,$autor,$cmt)=@_;
	my $i;
	cset:
	{
		my($min,$max);
		$min=-1;$max=@$cset;$i=0;

		# vor dem Anfang?
		while($min<$max-1) {
			$i=int(($min+$max)/2);
			last if $i==$min;
			last if $i==$max;
			# fünf Bereiche:
			# A vor Anfang-Spielraum
			# B vor Anfang
			# C irgendwo zwischen Anfang und Ende
			# D nach Ende
			# E nach Ende+Spielraum
			#
			if($cset->[$i]{start}-csdiff($i,$fn,$autor,$cmt) > $wann) { # A: weitersuchen
				$max=$i; $i--;
				next;
			} elsif($cset->[$i]{start} > $wann) { # B: verlängern
				if($i>0 and $cset->[$i-1]{ende}+$diff >= $wann) {
					atta($cset->[$i-1],$cset->[$i]);
					splice(@$cset,$i,1);
					$i--;
				} else {
					$cset->[$i]{start} = $wann;
				}
				last cset;
			} elsif($cset->[$i]{ende}+csdiff($i,$fn,$autor,$cmt) < $wann) { # E: weitersuchen
				$min=$i;
				next;
			} elsif($cset->[$i]{ende} < $wann) { # D: Verlängern
				if($i < @$cset-1 and $cset->[$i+1]{start}-$diff <= $wann) {
					atta($cset->[$i],$cset->[$i+1]);
					splice(@$cset,$i+1,1);
				} else {
					$cset->[$i]{ende} = $wann;
				}
			}
			# ansonsten sind wir im Bereich => OK.
			last cset;
		} continue {
			$i++;
		}
		# nix gefunden
		splice(@$cset,$i,0,{"start"=>$wann,"ende"=>$wann});
	}
	my $cs = $cset->[$i];
	if(defined $cs->{autor}) {
		$cs->{autor} = undef if $cs->{autor} ne $autor;
	} elsif(not exists $cs->{autor}) {
		$cs->{autor} = $autor;
	}
	if(defined $cs->{scmt}) {
		$cs->{scmt} = undef if $cs->{scmt} ne $cmt;
	} elsif(not exists $cs->{scmt}) {
		$cs->{scmt} = $cmt;
	}
	if(defined $fn) {
		$cs->{cmt}{$fn} .= $cmt;
		$cs->{rev}{$fn} = $rev;
	}

	$cs;
}

# Bearbeite den Log-Eintrag EINER Datei
sub proc1($$$$$$) {
	my($fn,$dt,$rev,$cmt,$autor,$syms) = @_;
	my $dtx = add_date($dt,$fn,$rev,$autor,$cmt);
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
	print STDERR "Processing CVS log\n";
	if(-d "$tmpcv") {
		chdir("$tmpcv");
	} else {
		print STDERR "Need to fetch the CVS files...\n";
		chdir("/var/cache/cvs/bk");
		cvs("get",$cn);
		chdir($tmpcv);
		print STDERR "processing...\n";
	}
	$cset=[];
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
	foreach my $sym(keys %symdate) {
		push(@{add_date($symdate{$sym})->{sym}},$sym);
	}
	nstore($cset,"$tmpcv.data");
}
chdir("/");

dateset($cset->[0]{start});

my $tmppn="/var/cache/cvs/bk/$cn";
unless(-d "$tmppn/BitKeeper") {
	system("bk clone -q $ENV{BK_REPOSITORY}/$pn $tmppn");

	if($?) {
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
	unlink bkfiles("g");
	unlink bkfiles("x");
	bk("-r","unedit");
	bk("-r","unlock");
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


sub process($$) {
	my($dt,$inf) = @_;
	my($ss,$mm,$hh,$d,$m,$y)=localtime($dt);
	$m++; $y+=1900; ## zweistellig wenn <2000
	dateset($dt,$inf->{autor});
	my $cvsdate = sprintf "%04d-%02d-%02d %02d:%02d:%02d",$y,$m,$d,$hh,$mm,$ss;
	print STDERR "Processing: $cvsdate\n";

	# system("(bk sfiles -gU; bk sfiles -x) | p.bk.filter | xargs -0r p.bk.mangler");
	# Map: Revisionsnummer->Dateiname

	my @gone;
	{
		my %rev;
		foreach my $f(keys %{$inf->{rev}}) {
			my $rev = $inf->{rev}{$f};
			push(@{$rev{$rev}}, $f);
		}
		foreach my $rev(keys %rev) {
			my @f = @{$rev{$rev}};
			while(@f) {
				my $i = undef;
				$i=50 if @f>60;
				my @ff = splice(@f,0,$i||(1+@f));
				bk("get","-eg", @ff);
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
	my @new = grep { if(-l $_) { unlink $_; undef; } else { 1; } } bkfiles("x");

	if(@new and @gone) {
		$DB::single=1;
		my $cmds = $inf->{rename};

		unless($cmds) {
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
			my $T = IO::File->new($tmf,"r");
			while(<$T>) {
				$cmds .= $_;
			}
			$T->close();
			unlink($tmf);

			$inf->{rename}=$cmds;
			nstore($cset,"$tmpcv.data");
		}
		@new=(); @gone=();
		my $ocmt=""; my @onew;
		foreach my $line(split(/\n/,$cmds)) {
			if($line =~ /^bk rm (.+)$/) {
				push(@gone,$1);
			} elsif($line =~ /^bk new (.+)$/) {
				push(@new,$1);
			} elsif($line =~ /^bk mv (.+) (.+)$/) {
				my $cmt1=$inf->{cmt}{$1};
				my $cmt2=$inf->{cmt}{$2};
				if(defined $cmt1 and $cmt1 ne "") {
					$cmt1.=$cmt2 if defined $cmt2 and $cmt2 ne "" and $cmt1 ne $cmt2;
				} else {
					$cmt1=$cmt2;
				}
				$cmt1="CVS: $cvsdate" if defined $inf->{scmt} and $cmt1 eq $inf->{scmt};
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
			my $cmt = (defined $inf->{scmt}) ? "CVS: $cvsdate" : $inf->{cmt}{$new};
			$cmt = "CVS: $cvsdate" if not defined $cmt or $cmt eq "";
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
		my $cmt = (defined $inf->{scmt}) ? "CVS: $cvsdate" : $inf->{cmt}{$f};
		$cmt = "CVS: $cvsdate" if not defined $cmt or $cmt eq "";
		if($cmt ne $ocmt) {
			bk(ci => '-qG', "-y$ocmt", @onew) if @onew;
			@onew=();
			$ocmt=$cmt;
		}
		push(@onew,$f);
	}
	bk(ci => '-qG', "-y$ocmt", @onew) if @onew;

	my $scmt = "CVS: $cvsdate".((defined $inf->{scmt}) ? "\n".$inf->{scmt} : "");
	$scmt =~ s/\'/\"/g;
	bk(undef,"bk sfiles -pC | env @DT @AU bk cset -q -y'$scmt'");
	foreach my $sym(@{$inf->{sym}}) {
		bk("cset","-r+","-S$sym");
	}

	# unlink(bkfiles("g"));
	bk("-r","unedit");
	bk("-r","unlock");
}

my $sum;
my $last;
my $step;
foreach my $x(@$cset) {
	if($last) {
		my $idate = int(($last->{ende}+$x->{start})/2);
		if($idate > $dt_done) {
			$DB::single=1 if $sum;
			# process($sum->{ende},$sum) if $sum;
			$sum=undef;
			process($idate,$last);
		} else {
			$sum={} unless ref $sum;
			atta($sum,$last);
		}
	}
	$last = $x;
	bk("push") unless $setpp++%10;
}
process($last->{ende}+30,$last) if $last;
