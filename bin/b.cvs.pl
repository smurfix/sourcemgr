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

### Test Revisionsmatching
#my %target=("x"=>"2.2.0.4");
#my $trev="test";
#sub rev_ok($$);
#foreach my $i(qw(1.1 1.2 1.3 1.4  2.0 2.1 2.2 2.2.4.1 2.2.4.2 2.2.4.3)) {
#	die "RevProb $i\n" unless rev_ok("x",$i);
#}
#foreach my $i(qw(1.2.3.4 2.3 2.3.4.5 2.2.3.1 2.2.5.1 2.2.4.1.4.4 3.1)) {
#	die "RevProb $i\n" if rev_ok("x",$i);
#}

my $debug=0;
my $diff=$ENV{BKCVS_DIFF}||60; # Zeitraum für "gleichzeitige" Änderungen im CVS
my $shells=$ENV{BKCVS_SHELLS}||0;

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
my $trev = $ENV{BK_TARGET_REV};
$trev="" unless defined $trev;
my %target;
my %tpre; # Vorlaeufer-Versionsname
my %cutoff; # Datum, ab dem Vendor-Versionen nicht mehr aktiv sind

$pn =~ s#[/:]#_#g;
my %excl;
foreach my $arg(@ARGV) {
	$excl{$arg}++;
}

my $cne=$cn;
if($cn eq ".") {
	$cn=$pn; $cn =~ s#.*_##; $cn =~ s#\-.*##;
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
		chomp;
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
	my $do_cd=1;
	unless(defined $_[0]) {
		shift(@_);
		$do_cd=0;
	}
	unshift(@_,"cvs",@comp,"-d",$ENV{CVS_REPOSITORY});
	print STDERR ">>> @_\n" if $debug;
	open(FP,"-|") or do {
		#chdir("..") if $do_cd;
		exec @_;
		#exec "strace","-v","-s3000","-o","/var/tmp/prcs","-F","-f",@_;
		exit(99);
	};
	my @res;
	while(<FP>) {
		chomp;
		push(@res,$_);
	}
	close(FP);
	die "CVS error: $?\n" if $?;
	wantarray ? @res : join(" ",@res);
}

sub bkfiles($) {
	my($f) = @_;
	grep {
		(m#/Attic/# or
		 m#^Attic/# or
		 m#^\.cvsignore$# or
		 m#/\.cvsignore$# or
		 m#\.prj$# or
		 m#^core$# or
		 m#/SCCS/x\.# or
		 m#^CVS/# or
		 m#/CVS/# or
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

sub rev_ok($$) {
	my($fn,$rev)=@_;
# Target: 2.2.0.4
# OK: 1.1 1.2 1.3 1.4  2.0 2.1 2.2 2.2.4.1 2.2.4.2 2.2.4.3
# !OK: 1.2.3.4 2.3 2.3.4.5 2.2.3.1 2.2.5.1 2.2.4.1.4.4 3.1 

	my @f = split(/\./,$rev);
	return (0+@f == 2 or (0+@f==4 and $f[0]==1 and $f[1]==1 and $f[2]==1))
		if $trev eq ""; # baseline / vendor branch

	my $tr = $target{$fn};
	return 0 unless defined $tr;
	die "Target: $tr  File: $fn\n" unless $tr =~ s/\.0\.(\d+)$/.$1/;

	my @t = split(/\./,$tr);

	my $rt = shift @t;
	my $rf = shift @f;
	if($rt != $rf) { # Special für 1.9 => 2.0: nimm die Baseline
		return 0 if 0+@f > 2;  # !OK: 1.2.3.4
		return ($rt > $rf); # OK: 1.?  !OK: 3.1
	}

	while(@t) {
		$rt = shift @t;
		$rf = shift @f;

		return ($rt > $rf and @f == 0)
			if $rt != $rf;
	}
	return 0+@f == 1;
}

# Bearbeite den Log-Eintrag EINER Datei
sub proc1($$$$$$) {
	my($fn,$dt,$rev,$cmt,$autor,$syms) = @_;
	return unless rev_ok($fn,$rev);

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
	my $pre;
	my $skip;
	foreach my $x(@_) {
		if($state == 0 and $x =~ s/^Working file:\s+(\S+)\s*$/$1/) {
			$fn = $x;
			$state=1;
			# print STDERR " "x70,"\r  $fn\r";
			next;
		}
		if($state == 1 and $x =~ /^symbolic names:/) {
			$state=2;
			next;
		}
		if($state == 2) {
			if($x =~ /^\s+(\S+)\:\s*(\S+)\s*$/) { # Branches
				my $dsym=$1;
				my $drev=$2;

				$target{$fn}=$drev if defined $trev and $dsym eq $trev;
				$syms{$drev}=[] unless defined $syms{$drev};
				push(@{$syms{$drev}},$dsym);

				if($trev eq $dsym) {
					$drev =~ s/\.0\.\d+$//; # 1.2.3.4

					push(@{$syms{$drev}},$trev); 
					$pre = $drev  # 1.2.0.3
						if $drev =~ s/\.(\d+)\.\d+$/.0.$1/;
				} elsif($drev =~ s/\.0\.\d+$//) {
					push(@{$syms{$drev}},"Branch:".$dsym);
				}
				next;
			} else {
				if($pre and $pre ne "1.1.0.1") { # vendor branch
					die "Kein Vor-Symbol '$pre' in '$fn'\n" unless $syms{$pre};
					$tpre{$syms{$pre}[0]}++;
				}
				$state=3;
			}
		}
		if($state >= 2 and $x =~ /^\-+\s*$/) {
			$state=4;
			proc1($fn,$dt,$rev,$cmt,$autor,$syms{$rev}) if $dt and not $skip;
			$dt=0; $cmt=""; $skip=0;
			next;
		}
		if($state == 4 and $x =~ /^revision\s+([\d\.]+)(?:$|\s+)/) {
			$rev=$1;
			$state=5;
			next;
		}
		if($state == 5 and $x =~ /^date:\s+(\d+)\/(\d+)\/(\d+)\s+(\d+)\:(\d+)\:(\d+)\s*\;\s+author\:\s+(\S+)\;\s+state\:\s+(\S+)\;/) {
			$skip=$1 if lc($8) eq "dead";
			$autor = $7;
			my($y,$m,$d,$hh,$mm,$ss)=($1,$2,$3,$4,$5,$6);
			$y-=1900 if $y>=1900; $m--;
			$dt=timelocal($ss,$mm,$hh,$d,$m,$y);
			die "Datum: $x" unless $dt;
			$cutoff{$fn}=$dt if $rev eq "1.2";
			$state = 6;
			next;
		}
		if($state==6) {
			next if $x =~ /^branches\:\s+/;
			$cmt .= "$x\n";
			next;
		}
	}
	proc1($fn,$dt,$rev,$cmt,$autor,$syms{$rev}) if $dt and not $skip; $dt=0;
}

my $tmpcv = "/var/cache/cvs";
my $tmppn="/var/cache/cvs/bk/$pn";

if(-f "$tmppn.data") {
	print STDERR "$pn: Reading stored CVS log\n";
	$cset = retrieve("$tmppn.data");

	foreach my $x (@$cset) {
		if($x->{sym}) {
			foreach my $s(@{$x->{sym}}) {
				$symdate{$s}=$x->{wann};
			}
		}
		my $ff=$x->{files};
		foreach my $f (keys %$ff) {
			$cutoff{$f}=$x->{wann}
				if $ff->{$f}{rev} eq "1.2";
		}
	}
} else {
	$cset=[];
	print STDERR "$pn: Processing CVS log     |\r";
	my $mr=1;
	while(1) {
		my $done=0;
		foreach my $x (qw(1 1.2.1)) {
			mkpath("$tmpcv/$mr.$x",1,0755);
			
			print STDERR "$pn: Fetch CVS files $mr.$x     |\r";
			chdir("$tmpcv/$mr.$x") or die "no dir $tmpcv/$mr.$x";
			if(-d $cn) {
				chdir($cn) or die "no chdir $cn: $!";
				cvs(undef,"update","-d","-r$mr.$x");
			} else {
				if($cne eq ".") {
					mkdir($cn);
					chdir($cn);
				}
				cvs(undef,"get","-r$mr.$x",$cne);
				chdir($cne) or last;  # no-op when $cne eq "."
			}
			print STDERR "$pn: processing $mr.$x       |\r";
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

			opendir(D,".");
			my $dn;
			while(defined($dn=readdir(D))) {
				next if $dn eq "." or $dn eq "..";
				next if $dn eq "CVS" or $dn eq "CVSROOT";
				$done++;
				last;
			}
			closedir(D);
		}
		last unless $done;
	} continue {
		$mr++;
	}
	foreach my $sym(keys %symdate) {
		push(@{add_date($symdate{$sym})},$sym);
	}
	nstore($cset,"$tmppn.data");
}
chdir("/");

dateset($cset->[0]{wann});

unless(-d "$tmppn/BitKeeper") {
	system("bk clone -q $ENV{BK_REPOSITORY}/$pn $tmppn");

	if($?) {
		print STDERR "$pn: Creating new Bitkeeper repository...\n";
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
	open(REV,"bk prs -anh -d ':COMMENTS:\n' ChangeSet |");
	while(<REV>) {
		chomp;
		if(/^C CVS\:\s*(\d+)-(\d+)-(\d+)(?:\s+(\d+)\:(\d+)\:(\d+))?\s*$/) {
			my ($y,$m,$d,$hh,$mm,$ss)=($1,$2,$3,$4,$5,$6);
			$y -= 1900 if $y >= 1900; $m--;
			my $dt = timelocal($ss+0,$mm+0,$hh+0,$d,$m,$y);
			$dt_done = $dt if $dt_done < $dt;
			last;
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
	print STDERR " $pn: Processing $len: $cvsdate      |\r";
	dateset($wann,$autor);

	# system("(bk sfiles -gU; bk sfiles -x) | p.bk.filter | xargs -0r p.bk.mangler");
	# Map: Revisionsnummer->Dateiname

	my @gone;
	{
		my %rev;
		foreach my $f(keys %$adt) {
			my $rev = $adt->{$f}{rev};
			push(@{$rev{$rev}}, $f);
			dirs: while(1) {
				$f = dirname($f);
				last dirs if -d "$f/CVS";
				mkpath("$f/CVS",0,0755);
				open(R,">$f/CVS/Repository");
				if($f eq ".") {
					print R "$cne\n";
				} else {
					print R "$cne/$f\n";
				}
				close(R);
				open(R,">$f/CVS/Root");
				print R $ENV{CVS_REPOSITORY},"\n";
				close(R);
				open(R,">$f/CVS/Entries");
				close(R);
			}
		}
		my $cnt=0;
		my $rcnt=0+keys %rev;
		foreach my $rev(keys %rev) {
			my %d;
			my @f = @{$rev{$rev}};
			unlink(@f);
			while(@f) {
				print STDERR " $pn: Processing $len: $cvsdate $cnt ".(0+@f)." $rcnt  |\r";
				my @ff;
				if(@f > 30) {
					@ff = splice(@f,0,25);
				} else {
					@ff = @f; @f = ();
				}
				$cnt += @ff;
				#cvs("get","-A","-d",$d,"-r",$rev, map { ($d eq ".") ? "$cne/$_" : "$cne/$d/$_" } @f);
				my @lf = grep { -f $_ } map { dirname($_)."/SCCS/s.".basename($_) } @ff;
				bk("get","-egq", @lf) if @lf;
				cvs("-q","update","-A","-r",$rev, @ff);
				utime($wann,$wann,@ff);
			}
			push(@gone, grep {
					-e dirname($_)."/SCCS/s.".basename($_) and ! -e $_ }
				@{$rev{$rev}});
		} continue {
			--$rcnt;
		}
	}

	my @new=();
	foreach my $n (grep { if(-l $_) { unlink $_; undef; } else { 1; } } bkfiles("x")) {
		if($adt->{$n}{rev} eq "1.1" or $ENV{BKCVS_NORENAME}) {
			push(@new,$n);
			next;
		}
		print STDERR "$pn: Checking if '$n' is a resurrected file...\n";
		rename($n,"x.$$");

		open(FP,"|-") or do {
			exec("env",@DT,@AU,"bk","unrm","$n");
			exit(99);
		};
		print FP "y\n";
		close(FP);

		if(-f $n or not $?) {
			unlink($n);
			bk("get","-egq",$n);
		} else {
			push(@new,$n);
		}
		rename("x.$$",$n);
	}

	if(@new and @gone and not $ENV{BKCVS_NORENAME}) {
		use IO::File;
		# bk(get=>"-qeg",@gone); ## schon erledigt
		# print STDERR ">>> bk -qeg @gone\n";
		# print $rename $d->{major}.".".$d->{minor}."\n";
		my $tmf="/tmp/bren.$$";
		if($shells) {
			print <<END;
Do your actions.
OLD: @gone
NEW: @new
echo "bk mv/new/rm FILENAME(s)" > $tmf
exit.

END
			system($ENV{SHELL} || "/bin/sh","-i");
			$shells--;
		} else {
			print STDERR " $pn: *** rename ***\r";
			open(RN,"|env @AU @DT bk renametool -p > $tmf");
			foreach my $f(sort { $a cmp $b } @gone) { print RN "$f\n"; }
			print RN "\n";
			foreach my $f(sort { $a cmp $b } @new) { print RN "$f\n"; }
			close(RN);
			# print $rename "\n";
			confess "No rename" if $? or not -s $tmf;
		}

		my $cmds="";
		my $T = IO::File->new($tmf,"r");
		while(<$T>) {
			$cmds .= $_;
		}
		$T->close();
		unlink($tmf);

		@new=(); @gone=();
		my $ocmt=""; my @onew;
		foreach my $line(split(/\n/,$cmds)) {
			if($line =~ /^bk rm (.+)$/) {
				push(@gone,$1);
			} elsif($line =~ /^bk new (.+)$/) {
				push(@new,$1);
			} elsif($line =~ /^bk mv (.+) (.+)$/) {
				my $o=$1;
				my $n=$2;
				my $cmt1=$adt->{$o}{cmt};
				my $cmt2=$adt->{$n}{cmt};
				if(defined $cmt1 and $cmt1 ne "") {
					$cmt1.=$cmt2 if defined $cmt2 and $cmt2 ne "" and $cmt1 ne $cmt2;
				} else {
					$cmt1=$cmt2;
				}
				$cmt1="" if defined $scmt and $cmt1 eq $scmt;
				rename($n,"x.$$");
				bk("mv",$o,$n);
				bk("get","-geq",$n);
				rename("x.$$",$n);

				if($cmt1 ne $ocmt) {
					$ocmt =~ s/\001//g;
					bk(ci => '-qG', "-y$ocmt", @onew) if @onew;
					@onew=();
					$ocmt="CVS: ".$adt->{$o}{rev}." => ".$adt->{$n}{rev}."\n".$cmt1;
				}
				push(@onew,$n);
			}
		}
		$ocmt =~ s/\001//g;
		bk(ci => '-qG', "-y$ocmt", @onew) if @onew;
		# bk(undef,"echo after renametool");
	}
	if(@new) {
		my $ocmt=""; my @onew=();
		foreach my $new(@new) {
			my $cmt = $adt->{$new}{cmt};
			$cmt = "" if $cmt eq "" or (defined $scmt and $cmt eq $scmt);
			$cmt="CVS: ".$adt->{$new}{rev}."\n".$cmt;
			if($cmt ne $ocmt) {
				$ocmt =~ s/\001//g;
				bk(delta => '-i', "-y$ocmt", "-q", @onew) if @onew;
				@onew=();
				$ocmt=$cmt;
			}
			push(@onew,$new);
		}
		$ocmt =~ s/\001//g;
		bk(delta => '-i', "-y$ocmt", "-q", @onew) if @onew;
	}
	if(@gone) {
		bk(rm => @gone);
	}

#	die "ENDE ".`pwd`."env @DT @AU bk -r ci -qG -yFoo\n";
	my $ocmt=""; my @onew=();
	foreach my $f(bkfiles("cg")) {
		my $cmt = $adt->{$f}{cmt};
		$cmt = "" if $cmt eq "" or (defined $scmt and $cmt eq $scmt);
		$cmt="CVS: ".$adt->{$f}{rev}."\n".$cmt;

		if($cmt ne $ocmt) {
			$ocmt =~ s/\001//g;
			bk(ci => '-qG', "-y$ocmt", @onew) if @onew;
			@onew=();
			$ocmt=$cmt;
		}
		push(@onew,$f);
	}
	$ocmt =~ s/\001//g;
	bk(ci => '-qG', "-y$ocmt", @onew) if @onew;

	$scmt = "CVS: $cvsdate".((defined $scmt) ? "\n$scmt" : "");
	# $scmt =~ s/\'/\"/g;
	open(FP,"|-") or do {
		$scmt =~ s/\001//g;
		exec("env", @DT,@AU, "bk", "cset", "-q","-y$scmt");
		exit(99);
	};
	open(P,"bk sfiles -pC |");
	print FP $_ while(<P>);
	close(P); close(FP);
	my $tip=bk("prs","-ahn","-r+","-d:I:");
	print STDERR "$pn: $cvsdate  $tip     |\n";


	# unlink(bkfiles("g"));
#	bk("-r","unget");
#	bk("-r","unedit");
#	bk("-r","unlock");
}

if($trev ne "" and $ENV{BK_TARGET_NEW}) { # tag must not exist
	# Rollback bis hinter das Zieldatum
	$DB::single=1;
	die "Tag '$trev' exists" if bk("prs","-hd:I:", "-r$trev","ChangeSet");

	$dt_done=$symdate{$trev};
	die "kein Datum für '$trev'\n" unless $dt_done;
	foreach my $pre(keys %tpre) {
		die "Kein Vorläufer-Branch '$pre' für '$trev' gefunden\n"
			unless bk("prs","-hd:I:", "-r$pre","ChangeSet");
	}
	my $b_rev=bk("prs","-hd:I:", "-rBranch:$trev","ChangeSet");
	die "Keine Revisionsnummer für '$trev' gefunden.\n" unless $b_rev;
	bk("undo","-sfqa$b_rev");

	bk("tag",$trev);
} elsif($trev ne "") { # tag must exist
	die "Tag '$trev' doesn't exists" unless bk("prs","-hd:I:", "-r$trev","ChangeSet");
}

my %last;
my $x;
my $done=0;
my $ddone=0;
$DB::single=1; $DB::single=1 if 0;

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
				$adt{$fn}=$f->{$fn}
					if $f->{$fn}{rev} !~ /^1\.1\.1\.\d+$/
						or $y->{wann} < $cutoff{$fn};
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
		$done++;
	}

	if(defined $x->{sym}) {
		foreach my $sym(@{$x->{sym}}) {
			bk("tag","-r+",$sym);
			$done++;
		}
	}
} continue {
	shift @$cset;
	if($ENV{BKCVS_PUSH} and $done >= $ENV{BKCVS_PUSH}) {
		$ddone += $done;
		print STDERR "$pn: Push $ddone     |\r";
		bk("push","-q");
		$done=0;
	}
}
if($ENV{BKCVS_PUSH}) {
	print STDERR "$pn: Push LAST        |\r";
	bk("push","-q");
}
print STDERR "$pn: OK     |\n";
unlink("$tmppn.data");
