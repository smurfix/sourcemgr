#!/usr/bin/perl -w

#
# This is the core of CVS import. The basics of operation is,
# roughly, as follows:
# - Do separate CVS imports for the whole to-be-imported tree,
#   versions N.1, N.1.1.1 and N.1.2.1, for successive N starting at 1
#   until there are no more files. There's no known other way to get the
#   names of all files, including deleted ones.
# - Do "cvs log" on each import. Sort by date.
# - Figure out where to start and what to import, based on stored
#   changeset comments and tags.
# - Aggregate, based on timestamp difference between check-ins, equality
#   of check-in comment, and author.
# - Pop up renametool (if warranted) to reproduce file/directory renames.
# - Generate changesets. Tag them with whatever CVS was tagged.
# - Auto-push every 100 changes (or whatever) in case something goes
#   seriously wrong.
# - Optionally tag the final changeset and push it.
# 
# This tool supports importing CVS branches, though this is not well
# tested. It obviously supports incremental uploads.
#
# It does NOT support any kind of operation which does not involve
# the first steps of creating an empty BK repository and starting with
# the very earliest CVS check-ins.
#
# CVS doesn't have changeset-wide tags; this tool implements the
# workaround of collecting all of them and remembering which were latest
# in time. This results in some confusion when the oiginal CVS people
# import part of somebody else's CVS subtree into their own, but that
# can't be helped.
# 
# This tool is copyright (C) Matthias Urlichs.
# It is released under the Gnu Public License, version 2.
#

use strict;
use warnings;
no warnings 'uninitialized';
use File::Path qw(rmtree mkpath);
use File::Find qw(find);
use File::Basename qw(basename dirname);
use Time::Local;
use Carp qw(confess);
use Storable qw(nstore retrieve);
use File::ShLock;

my $ENDFILE = "/var/run/b.cvs.stop";
my $verbose = $ENV{"BK_VERBOSE"};

my $CLR="\r".(" "x79)."\r";
my $lock;
if($ENV{BKCVS_LOCK}) {
	nl: while(1) {
		my $i = 0;
		while($i++ < $ENV{BKCVS_LOCK}) {
			last nl if ref ($lock = new File::ShLock("b.cvs.$i"));
		}
	} continue { sleep 15; }
}

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
$ENV{BK_LOGGING_OK}="YES";
select(STDERR); $|=1; select(STDOUT);

use Shell qw(); ## bk cvs
system("xhost >/dev/null 2>&1");
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
my %tpre; # previous version name
my %cutoff; # date where the vendor version branch ends
   # The vendor branch is an "interesting" idea. Basically, it must be
   # handled like the real thing until a version 1.2 shows up. 1.1.1.x
   # versions after that are supposed to be merged onto the trunk.
   # This is incidentally the reason why I need to scan revisions 1.1,
   # 1.1.1.1 _and_ 1.1.2.1.

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

sub dateset($;$) {
	my($dt,$au) = @_;
	@DT=();
	@AU=();

	@AU = ("LOGNAME=$au","USER=$au","BK_USER=$au","BK_HOST=$rhost") if $au;
    ## TODO: set the check-in date
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
	my $rep=0;
	while(1) {
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
		unless ($? and not $ENV{BKCVS_IGNORE_ERROR}) {
			return wantarray ? @res : join(" ",@res);
		}
		if($rep++<1000) {
			print STDERR "$CLR CVS $?\r";
			if($rep < 15) {
				sleep($rep)
			} else {
				sleep(15)
			}
		} else {
			die " CVS error: $?\n";
		}
	}
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
sub add_date($;$$$$$) {
	my($wann,$fn,$rev,$autor,$cmt,$gone)=@_;
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
		$cs->{$fn}{gone} = 1 if $gone;
	} else {
		$cs->{sym} = [] unless defined $cs->{sym};
		return $cs->{sym};
	}
}

sub rev_ok($$) {
	my($fn,$rev)=@_;
# Target: 2.2.0.4
# OK: 1.1 1.1.1.1 1.1.1.2 1.2 1.3 1.4  2.0 2.1 2.2 2.2.4.1 2.2.4.2 2.2.4.3
# !OK: 1.2.3.4 2.3 2.3.4.5 2.2.3.1 2.2.5.1 2.2.4.1.4.4 3.1 

# Vorsicht -- 1.1.1.* muss separat rausgefiltert werden, wenn es
# zeitlich nach 1.2 kommt.

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

# Process one CVS log entry
sub proc1($$$$$$$) {
	my($fn,$dt,$rev,$cmt,$autor,$syms,$gone) = @_;

	return if 
		 $fn =~ m#^CVS/# or
		 $fn =~ m#/CVS/# or
		 $fn =~ m#^CVSROOT/# or
		 $fn =~ m#/CVSROOT/# or
		 0;
	return unless rev_ok($fn,$rev);
	add_date($dt,$fn,$rev,$autor,$cmt,$gone);
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
	my $gone;
	# It is helpful to have the output of "cvs log FILE" handy if you
	# want to understand the next bits.
	foreach my $x(@_) {
		if($state == 0 and $x =~ s/^Working file:\s+(\S+)\s*$/$1/) {
			$fn = $x;
			$state=1;
			# print STDERR "$CLR  $fn\r" if $verbose;
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
			proc1($fn,$dt,$rev,$cmt,$autor,$syms{$rev},$gone) if $dt;
			$dt=0; $cmt=""; $gone=0;
			next;
		}
		if($state == 4 and $x =~ /^revision\s+([\d\.]+)(?:$|\s+)/) {
			$rev=$1;
			$state=5;
			next;
		}
		if($state == 5 and $x =~ /^date:\s+(\d+)\/(\d+)\/(\d+)\s+(\d+)\:(\d+)\:(\d+)\s*\;\s+author\:\s+(\S+)\;\s+state\:\s+(\S+)\;/) {
			$gone=1 if lc($8) eq "dead";
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
	proc1($fn,$dt,$rev,$cmt,$autor,$syms{$rev},$gone) if $dt;
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
	print STDERR "$CLR $pn: Processing CVS log\r" if $verbose;
	my $mr=1;
	while(1) {
		my $done=0;
		foreach my $x (qw(1 1.1.1 1.2.1)) {
			mkpath("$tmpcv/$mr.$x",1,0755);
			
			print STDERR "$CLR $pn: Fetch CVS files $mr.$x\r";
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

			print STDERR "$CLR $pn: processing $mr.$x\r";
			my $lines=`find . -name CVS -prune -o -type f -print | wc -l`;
			last unless (0+$lines);

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
contact:    $ENV{FULLNAME}
email:		$ENV{EMAIL}
Company:    -
Street:     -
City:       -
Postal:     -
Country:    -

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
		system("bk sfiles -pC | env @DT @AU bk commit -q -yLogging_OK -");
		bk("parent","$ENV{BK_REPOSITORY}/$pn");
		bk("clone",".","$ENV{BK_REPOSITORY}/$pn");
	}
}
chdir($tmppn);
system("bk prs -anhd:KEY: -r+ ChangeSet | tail -1 > BitKeeper/etc/SCCS/x.lmark");

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

sub wget($$) {
	my($url,$file) = @_;
	system("wget",$url,"-O",$file);
	die "CVS error: $?\n" if $? and not $ENV{BKCVS_IGNORE_ERROR};
}

sub process($$$$) {
	my($autor,$wann,$adt,$len)=@_;
	my $scmt = scmt($adt);

	my($ss,$mm,$hh,$d,$m,$y)=localtime($wann);
	$m++; $y+=1900; ## zweistellig wenn <2000
	my $cvsdate = sprintf "%04d-%02d-%02d %02d:%02d:%02d",$y,$m,$d,$hh,$mm,$ss;
	print STDERR "$CLR $pn: Proc $len: $cvsdate\r";
	dateset($wann,$autor);

	# system("(bk sfiles -gU; bk sfiles -x) | p.bk.filter | xargs -0r p.bk.mangler");
	# Map: Revisionsnummer->Dateiname

	my @gone;
	{
		my %rev;
		foreach my $f(keys %$adt) {
			my $rev = $adt->{$f}{rev};
			if(exists $adt->{$f}{gone}) {
				unlink($f);
				push(@gone,$f);
			} else {
				push(@{$rev{$rev}}, $f);
			}
		}
		my $cnt=0;
		my $rcnt=0+keys %rev;
		foreach my $rev(keys %rev) {
			my %d;
			my @f = @{$rev{$rev}};
			foreach my $fx(@f) {
				unlink($fx);
				my $f=$fx;
				dirs: while(1) {
					$f = dirname($f);
					last dirs if -d "$f/CVS";
					mkpath("$f/CVS",0,0755) or die "$f: $!\n";
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
			while(@f) {
				print STDERR "$CLR $pn: Proc $len: $cvsdate $cnt ".(0+@f)." $rcnt\r" if $verbose;
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
				if($ENV{BKCVS_WEB}) {
					foreach my $f(@ff) {
						wget ($ENV{BKCVS_WEB}.$f."?rev=".$rev."&content-type=text/plain", $f);
					}
				} else {
					cvs((($ENV{CVS_REPOSITORY} =~ m#:/#) ? "-q" : "-Q"),"update","-A","-r",$rev, @ff);
				}
				utime($wann,$wann,@ff);
			}
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
		print STDERR "$pn: Checking if '$n' is a resurrected file...\n" if $verbose;
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
		bk("get","-egq", @gone);
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
			print STDERR "$CLR $pn: *** rename ***\r" if $verbose;
			#open(RN,"|env @AU @DT bk renametool -p > $tmf");
			# private patch. Doesn't work any more. :-(
			open(RN,"|env @AU @DT bk renametool");
			foreach my $f(sort { $a cmp $b } @gone) { print RN "$f\n"; }
			print RN "\n";
			foreach my $f(sort { $a cmp $b } @new) { print RN "$f\n"; }
			close(RN);

			open(REN,"bk -r prs -r+ -ahnd':DPN: :GFILE' |");
			while(<REN>) {
				# Files are already named "to", but BK doesn't know that.
				my($from,$to)=split;
				next if $from eq $to;
				rename($to,"BitKeeper/tmp/_XFOO_");
				mkpath(dirname($from)."/SCCS/",1,0755);
				rename(dirname($to)."/SCCS/s.".basename($to),dirname($from)."/SCCS/s.".basename($from));
				bk("mv","$from",$to);
				bk("edit","-qeg",$to);
				rename("BitKeeper/tmp/_XFOO_",$to);
			}

#			print "Do renametool's work somehow";
#			system("/bin/sh");
#			# print $rename "\n";
#			confess "No rename" if $? or not -s $tmf;
		}
	} elsif(@new) {
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
	} elsif(@gone) {
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

	bk("clean","-q","ChangeSet");

	$scmt = "CVS: $cvsdate".((defined $scmt) ? "\n$scmt" : "");
	# $scmt =~ s/\'/\"/g;
	open(FP,"|-") or do {
		$scmt =~ s/\001//g;
		exec("env", @DT,@AU, "bk", "commit", "-q","-y$scmt", "-");
		exit(99);
	};
	open(P,"bk sfiles -pC |");
	print FP $_ while(<P>);
	close(P); close(FP);
	my $tip=bk("prs","-ahn","-r+","-d:I:","ChangeSet");
	print STDERR "$pn: $cvsdate  $tip     |\n" if $verbose;


	# unlink(bkfiles("g"));
#	bk("-r","unget");
#	bk("-r","unedit");
#	bk("-r","unlock");
}

if($trev ne "" and $ENV{BK_TARGET_NEW}) { # tag must not exist
	# Rollback beyond the target date
	die "Tag '$trev' exists" if bk("prs","-hd:I:", "-r$trev","ChangeSet");

	$dt_done=$symdate{$trev};
	die "no date for '$trev'\n" unless $dt_done;
	foreach my $pre(keys %tpre) {
		die "Kein Vorläufer-Branch '$pre' für '$trev' gefunden\n"
			unless bk("prs","-hd:I:", "-r$pre","ChangeSet");
	}
	my $b_rev=bk("prs","-hd:I:", "-rBranch:$trev","ChangeSet");
	die "No revision number for '$trev' found.\n" unless $b_rev;
	bk("undo","-sfqa$b_rev");
	system("bk prs -anhd:KEY: -r+ ChangeSet | tail -1 > BitKeeper/etc/SCCS/x.lmark");

	bk("tag",$trev);
	bk("clone",".","$ENV{BK_REPOSITORY}/$pn");
} elsif($trev ne "") { # tag must exist
	die "Tag '$trev' doesn't exists" unless bk("prs","-hd:I:", "-r$trev","ChangeSet");
}

my %last;
my $x;
my $done=0;
my $ddone=0;

while(@$cset) {
	$x = $cset->[0];
	next if $x->{wann} <= $dt_done;
	
	foreach my $autor(keys %{$x->{autor}}) {
		next if defined $last{$autor} and $last{$autor} >= $x->{wann};

		my %adt;
		my %adf;

		my $scmt;
		my $ldiff=$x->{wann};

		# Here we collate the next few changes. They need to be from the
		# same author, not touch files twice, either have the same
		# comment or are within a few minutes of each other.
		# A tag also marks the end of a changeset, obviously.
		my $i=0;
		sk_add: while($i < @$cset) {
			my $y=$cset->[$i];
			my $f=$y->{autor}{$autor};

			# Different author -> different changeset
			last sk_add unless $f;

			# A file was changed already -> belongs in new changeset
			foreach my $fn(keys %$f) {
				last sk_add if $adf{$fn}++;
			}

			# comments are the same? If so, increase grace time
			$scmt = scmt($f,$scmt);
			if (not defined $scmt or $scmt eq "") {
				last sk_add if $y->{wann} - $ldiff > $diff;
			} else {
				last sk_add if $y->{wann} - $ldiff > 10*$diff;
			}

			# NOW, finally, collect changes.
			foreach my $fn(keys %$f) {
				$adt{$fn}=$f->{$fn}
					if $f->{$fn}{rev} !~ /^1\.1\.1\.\d+$/
						or not defined $cutoff{$fn}
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
	system("bk prs -anhd:KEY: -r+ ChangeSet | tail -1 > BitKeeper/etc/SCCS/x.lmark");
} continue {
	shift @$cset;
	last if -f $ENDFILE;

	if($ENV{BKCVS_PUSH} and $done >= $ENV{BKCVS_PUSH}) {
		$ddone += $done;
		print STDERR "$CLR $pn: Push $ddone\r" if $verbose;
		bk("push","-q","-c1");
		$done=0;
	}
}
if ($ENV{BKCVS_TAG}) {
	my $do_tag=$ENV{BKCVS_TAG};
	foreach my $tag (bk('prs', '-r+', '-d$if(:TAG:){$each(:TAG:){:TAG:\\n}}', '-h', 'ChangeSet')) {
		if ($tag eq $do_tag) {
			$do_tag=undef;
			last;
		}
	}
	if($do_tag) {
		bk("tag","-r+",$do_tag);
	}
}
if($ENV{BKCVS_PUSH}) {
	print STDERR "$CLR $pn: Push LAST\r" if $verbose;
	bk("push","-c1");
}
exit 0 if -f $ENDFILE;
print STDERR "$pn: OK     |\n" if $verbose;
unlink("$tmppn.data");
unlink("/var/lock/bcvs-$pn");
exit 0;
