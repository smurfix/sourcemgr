#!/usr/bin/perl -w

use strict;
use warnings;
no warnings 'uninitialized';
use File::Path qw(rmtree);
use Time::Local;
use IO::File;
use Carp qw(confess);

my $debug=0;

sub Usage() {
	print STDERR <<END;
Usage: $0 ProjektName

Environment: PRCS_REPOSITORY BK_REPOSITORY
END
	exit 1;
}

Usage unless @ARGV;
Usage unless $ENV{BK_REPOSITORY};
Usage unless $ENV{PRCS_REPOSITORY};
$ENV{BK_LICENSE}="ACCEPTED";
$ENV{CLOCK_DRIFT}="1";
select(STDERR); $|=1; select(STDOUT);

use Shell qw(); ## bk prcs

sub process($);
sub init_bk();

my $pn = shift @ARGV;
$pn =~ s#[/:]#_#g;
my %excl;
foreach my $arg(@ARGV) {
	$excl{$arg}++;
}

my $bk = $ENV{BK_REPOSITORY}."/prcs/$pn";
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

	@DT = ("LD_PRELOAD=$dtf/datefudge.so","DATEFUDGE=".(time-$dt)) if $dt;
	@AU = ("LOGNAME=$au","USER=$au") if $au;
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
	open(C,">>$bk.cmd");
	if(defined $cmd[0]) {
		print STDERR ">>> bk @cmd\n" if $check;
		print C "bk @cmd\n";
		unshift(@cmd,"env",@DT,@AU,"bk");
	} else {
		shift(@cmd);
		print STDERR ">>> @cmd\n" if $check;
		print C "@cmd\n";
	}
	close(C);
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

sub prcs {
	unshift(@_,"prcs");
	print STDERR ">>> @_\n";
	open(FP,"-|") or do {
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
	my @new = grep {
		($_ eq "$pn.backup" or
		 $_ eq ".$pn.prcs_aux" or
		 $_ eq "$pn.prj" or
		 m#/SCCS/#)
		? undef
		: ( chmod((0600|0777&((stat $_)[2])),$_) or 1 );
	} bk(sfiles=>"-U$f");
	@new;
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

my @node;
my %node;
sub proc($) {
	local($_)=shift;
	return unless length $_ > 3;
	my $d = {};
	if(/PRCS parent indices:\s+([\d\s\:]+?)\s*$/) {
		$d->{parent} = [ split(/(?:\:|\s+)/,$1) ];
	}
	my $major = $d->{major} = $1 if /PRCS major version:\s+(\S+)/;
	my $minor = $d->{minor} = $1 if /PRCS minor version:\s+(\S+)/;
	print STDERR "  $major.$minor  \r";
	$d->{date} = pdate($1) if /date:\s+([^;]+)/;
	$d->{author} = $1 if /author:\s+([^;]+)/;
	$node{$major}[$minor] = $d;
	unshift(@node,$d);
}

print STDERR "Processing project file\n";

open(LOG,"rlog $ENV{PRCS_REPOSITORY}/$pn/$pn.prj,v |");

while(<LOG>) {
	last if /^-{10,}\s*$/;
}

my $buf = "";
while(<LOG>) {
	proc($buf),last if /^={10,}\ss*$/;
	proc($buf),$buf="" if /^-{10,}\ss*$/;
	$buf .= $_;
}
close(LOG);

my $id = 0; ## Parent Index

print STDERR "Scanning nodes\n";
foreach my $d(@node) { ## walk through nodes
	$d->{id} = $id;
	if($d->{parent}) {
	    foreach my $p(@{$d->{parent}}) { ## add child indices
			my $dd = $node[$p];
			$dd->{child} = {} unless $dd->{child};
			$dd->{child}{$id}++;
	    }
	} else {
		confess "No parent at $id" if $id;
	}
} continue {
	$id++;
}

my $maxlod = 1;
sub bkdir($) {
	my($v)=@_;
	confess "Version: $v" unless $v =~ /(\d+)(?:\.|$)/;
#	if($1 == 1) {
#		$bk;
#	} else {
		$bk."_L".$1;
#	}
}
sub cdbk($;$) {
	# Switch to a LOD if present; else, die if second parameter is false.
	my($line,$ret)=@_;
	my $dir = bkdir($line);
	unless(chdir $dir) {
		print STDERR "DIR $line ???\n";
		return undef if $ret;
		confess "No dir: $dir";
	}
	open(CD,">>$bk.cmd");
	print CD "cd $dir\n";
	close(CD);
	print STDERR "DIR $line\n";
	die "$dir: Broken.\n" if -d "RESYNC";
	1;
}

sub is_tip($) {
	# Switch to this LOD. If it is a tip, return LOD nr, else undef.
 	my($this) = @_;
	$this =~ s/(\d+)/1/;
	my $tip = $1;
	cdbk($tip);
	my $rtip = bk("prs","-hMnd:I:","-r$tip","ChangeSet");
	$this eq $rtip ? $tip : undef;
}

sub set_lod($;$) {
	# Check if this LOD is a tip. If yet, switch to it; if not, branch off.
 	my($this,$do_copy) = @_;
	my $rthis = $this;
	my $tip = is_tip($this);
	print STDERR "LOD: $this";
	if($tip and not $do_copy) {
		print STDERR "\n";
		return $tip;
	}

	my $dir = bkdir(++$maxlod);
	print STDERR " => $maxlod\n";
	bk("lclone","."=>$dir);
	chdir($dir);
	open(CD,">>$bk.cmd");
	print CD "cd $dir\n";
	close(CD);
	$this =~ s/^\d+/1/;
	bk("undo","-qsf","-a"=>$this) unless $tip;
	$maxlod;
}
sub cleanout() {
	unlink bk("sfiles","-gU");
	unlink bk("sfiles","-x");
	bk("-r","unedit");
	bk("-r","unlock");
}

my $rename = new IO::File("$bk.log",O_RDWR|O_CREAT|O_APPEND);
seek($rename,0,0);
{
	local $/ = "";
	while(<$rename>) {
		my($what,$cmds) = split(/\n/,$_,2);
		die "Rev version bad: '$what'\n" unless $what =~ /(\S+)\.(\d+)$/;
		my($maj,$min)=($1,$2);
		$cmds =~ s/^bk mv (.+) (.+)$/mv -f $2 $1; bk get -qeg $1; bk mv $1 $2/mg;
		$node{$maj}[$min]{"rename"} = $cmds;
	}
}

dateset($mdate);
if(cdbk(1,1)) {
	my @tags;
	$maxlod=1;
	while(cdbk($maxlod,1)) {
		cleanout();
		$tags[$maxlod]=[];
		bk("-r","unlock");
		unlink bk("sfiles","-gU");
		open(REV,"bk prs -anh -d ':I: :SYMBOL:' ChangeSet |");
		while(<REV>) {
			chomp;
			my($r,$cmt) = split(/ /,$_,2);
			if($cmt =~ /^PRCS:\S+:(\S+)\.(\d+)$/) {
				my $d = $node{$1}[$2];
				my $rev = "$1.$2";
				confess "Version $1.$2 not found" unless $d;

				unless(defined $d->{"rename"}) {
					my $cmds = "";
					my @change = bk(rset => "-h","-r$r");
					foreach my $ch(@change) {
						my(undef,$pre,$prer,$post,$postr) = split(/\|/,$ch);
						if($prer eq "1.0") {
							$cmds .= "bk new $post\n";
						} elsif($pre ne $post) {
							if($post =~m#/deleted/#) {
								$cmds .= "bk rm $pre\n";
							} else {
								$cmds .= "bk mv $pre $post\n";
							}
						}
					}
					print $rename "$rev\n$cmds\n";
					$cmds =~ s/^bk mv (.+) (.+)$/mv -f $2 $1; bk get -qeg $1; bk mv $1 $2/mg;
					$d->{"rename"} = $cmds;
				}

				$r =~ s/\b1\./$maxlod./;
				print STDERR "  $r:$rev          \r";
				$d->{tags} = [] unless defined $d->{tags};
				push(@{$d->{tags}},$r);
				push(@{$tags[$maxlod]}, $d);
				$d->{tag} = $r if not defined $d->{tag};
			}
		}
	} continue {
		$maxlod++;
	}
	$maxlod--;

	my $removed;
	my $lx=$maxlod;
	needer: while($lx) {
		foreach my $d(@{$tags[$lx]}) {
			next unless defined $d and defined $d->{tags};
			$lx--, next needer if @{$d->{tags}} == 1;
		}
		print STDERR "*** DROP $lx (move $maxlod) ***\n";
#		foreach my $d(@node) {
#			next unless defined $d->{tag};
#			$d->{tags} = [ grep { $_ !~ /^$lx\./ } @{$d->{tags}} ];
#			$d->{tag} = $d->{tags}[0] if $d->{tag} =~ /^$lx\./;
#			confess "Bad tag!" unless $d->{tag};
#		}
		rmtree(bkdir($lx));
		if($lx == $maxlod) {
			$lx--;
		} else {
			rename(bkdir($maxlod),bkdir($lx));
			$tags[$lx] = $tags[$maxlod];
		}
		$tags[$maxlod--] = undef;
		$removed++;
	}
	die "Repeat that.\n" if $removed;

	cdbk(1);
} else {
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
	bk("setup", '-f', -c => $tmpcf, bkdir(1));
	unlink $tmpcf;
	cdbk(1);
	bk("edit","BitKeeper/etc/logging_ok");
	open(OK,">>BitKeeper/etc/logging_ok");
	print OK $ENV{USER}."\@".`hostname`; ## includes LF
	close(OK);
	bk("new"=>"BitKeeper/etc/logging_ok");
	bk('-r', ci => '-qG', "-yLogging_OK");
	system("bk sfiles -pC | env @DT @AU bk cset -q -yLogging_OK");
}

sub process($) {
	my($d) = @_;
	my @par = ();
	my $lod;
	my $plod;
	my $par;

	return if $d->{tag}; # done already
	return if $excl{$d->{major}}; # skip it
	print STDERR "Processing: ".$d->{major}.".".$d->{minor}."       \n";
	dateset($d->{date},$d->{author});

	if($d->{parent}) {
		@par = @{$d->{parent}};
	}
	if(@par and $node[$par[0]]{tag}) {
		# print STDERR "!!! Parent: @par\n";
		foreach my $p(@par) {
			confess "Parent $p without tag" unless $node[$p]{tag};
		}

		$par = shift @par;
		my $p = $node[$par];
		$plod = $p->{tag};

		$lod=set_lod($plod); # ,0+@par ## for safety

		bk("-r",clean=>"-q");

		my @dead = bk(sfiles => "-lgU");
		if(@dead) {
			print STDERR "??? Cleanup: @dead\n";
			bk(unedit => @dead);
			bk(unlock => @dead);
		}
	} else {
		$lod=1;
	}
	{
		my %pseen = ($par=>1);
		foreach my $p(@par) { ## Pseudo-Merge
			next if $pseen{$p}++;
			$p = $node[$p];

			my $cmx = $maxlod;
			my $branch = set_lod($p->{tag});

			cdbk($lod);
			bk("pull","-qR",bkdir($branch));
			system("env @AU @DT bk resolve -a -mp.bk.merge '-yFake-Merge from ".$p->{major}.".".$p->{minor}."'");
			die "The usual problem" if -d "RESYNC";
			system("env @AU @DT bk citool");

			if($cmx < $maxlod and $branch == $maxlod) { # not needed here
				rmtree(bkdir($maxlod));
				$maxlod = $cmx;
			}
			
			#bk("admin",'-M'.$node[$p]{tag},"ChangeSet");
			## my $dd = $node[$p];
			## my $dsym = "PRCS:$pn:".$dd->{major}.".".$dd->{minor};
			## bk("admin","-r$sym","-M$dsym");
		}
	}
	die "The usual problem" if -d "RESYNC";
	prcs(checkout => '-f', "-r".$d->{major}.".".$d->{minor}, "$pn.prj");
	prcs(checkout => '-f', "-r".$d->{major}.".".$d->{minor}, "$pn.prj") if $?;
	if($?) {
		cleanout();
		# Re-Link child nodes to skip this parent
		bk("lclone",bkdir($lod),bkdir($lod)."_X".$d->{id});
		warn "$pn: ".$d->{major}.".".$d->{minor}." not checkoutable, skipped\n";
		if($d->{child}) {
			my @cl = keys %{$d->{child}};
			foreach my $c(@cl) {
				my $ch = $node[$c];
				$ch->{parent} = [ grep { $_ != $d->{id} } @{$ch->{parent}} ];
				push(@{$ch->{parent}},@{$d->{parent}});
			}
		}
		return;
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
	system("(bk sfiles -gU; bk sfiles -x) | p.bk.filter | xargs -0r p.bk.mangler");
	bk(get => "-qeg",@cur) if @cur;

	if(@new and @gone) {
		my $cmds = $d->{"rename"};

		if($cmds) {
			# print STDERR "... from the rename log ...\n";
			open(SH,"|env @AU @DT sh -x");
			print SH $cmds;
			close(SH);
			# confess "No rename" if $?;
		} else {
			bk(get=>"-qeg",@gone);
			# print STDERR ">>> bk -qeg @gone\n";
			print $rename $d->{major}.".".$d->{minor}."\n";
			open(RN,"|env @AU @DT bk renametool >> $bk.log");
			foreach my $f(sort { $a cmp $b } @gone) { print RN "$f\n"; }
			print RN "\n";
			foreach my $f(sort { $a cmp $b } @new) { print RN "$f\n"; }
			close(RN);
			print $rename "\n";
			confess "No rename" if $?;
		}
		# bk(undef,"echo after renametool");
	} elsif(@new) {
		bk(new => '-G', "-q", "-yPRCS:$pn:".$d->{major}.".".$d->{minor}, @new);
	} elsif(@gone) {
		bk(rm => @gone);
	}
	open(PR,"$pn.prj") or confess "Proj file $pn: $!";
	my $cmt = undef;
	while(<PR>) {
		chop;
		next if not defined $cmt and not s/^\(Version-Log\s*"//;
		$cmt .= $_;
		last if $cmt =~ s/"\s*\)\s*\z//;
		$cmt .= "\n";
	}
	close(PR);
	# $cmt =~ s/\\/\\\\/g;
	confess "No Comment in V ".$d->{major}.".".$d->{minor} unless defined $cmt;

	my $sym = "PRCS:$pn:".$d->{major}.".".$d->{minor};

#	die "ENDE ".`pwd`."env @DT @AU bk -r ci -qG -yFoo\n";
	bk('-r', ci => '-qG', "-y$sym");

		### XXX TODO XXX set the correct date! XXX TODO XXX ###

	bk(undef,"bk sfiles -pC | env @DT @AU bk cset -q -y\"$cmt\n$sym\" -S$sym");

	$d->{tag} = bk("prs","-hMnd:I:","-r+","ChangeSet");

	$d->{tag} =~ s/\b1\./$lod./;

	unlink(bkfiles("g"));
	bk("-r","unlock");
}

foreach my $d(@node) {  ## walk through nodes
	process($d);
}

