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
# in time (for purposes of tagging the whole tree). This results in some
# confusion when the oiginal CVS people import part of somebody else's
# CVS subtree into their own, but that can't be helped.
#
# Importing tagged sub-branches works, by properly walking along the
# tree. Note that because of the problem mentioned before, if the tagged
# branch-off point is too late you must manually undo the "wrong" part
# of your CVS tree(s).
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

my $debug=$ENV{BK_VERBOSE}||0;
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
my $target = {};
my %tpre; # previous version name
my %cutoff; # date where the vendor version branch ends
   # The vendor branch is an "interesting" idea. Basically, it must be
   # handled like the real thing until a version 1.2 shows up.

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
my $time = time();

sub dateset($;$) {
	my($dt,$au) = @_;
	@DT=();
	@AU=();

	@AU = ("LOGNAME=$au","USER=$au","BK_USER=$au","BK_HOST=$rhost") if $au;
    ## TODO: set the check-in date
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
	wantarray ? @res : join(" ",@res);
}

package CVS;

sub new {
	my($what,$repo,$subdir) = @_;
	$what=ref($what) if ref($what);

	my $self = {};
	$self->{'buffer'} = "";
	bless($self,$what);

	$repo =~ s#/+$##;
	if($repo =~ s/^:pserver:(?:(.*?)(?::(.*?))?@)?(.*?)(?::\(\d+\))?//) {
		my($user,$pass,$serv,$port) = ($1,$2,$3,$4);
		$user="anonymous" unless defined $user;
		$port=2401 unless $port;
		my $rr = ":pserver:$user\@$serv:$port/$repo";

		unless($pass) {
			open(H,$ENV{'HOME'}."/.cvspass") and do {
				while(<H>) {
					s/^\/\d+\s+//;
					my ($w,$p) = split;
					if($w eq $rr) {
						$pass = $p;
						last;
					}
				}
			};
		}
		$pass="A" unless $pass;

		use IO::Socket;
		my $s = IO::Socket::INET->new(PeerHost => $serv, PeerPort => $port);
		die "Socket to $serv: $!\n" unless defined $s;
		$s->write("BEGIN AUTH REQUEST\n$repo\n$user\n$pass\nEND AUTH REQUEST\n") or die "Write to $serv: $!\n";
		$s->flush();

		my $rep = <$s>;

		if($rep ne "I LOVE YOU\n") {
			$rep="<unknown>" unless $rep;
			die "AuthReply: $rep\n";
		}
		$self->{'socketo'} = $s;
		$self->{'socketi'} = $s;
	} else { # local
		use IO::Pipe;
		my $pr = IO::Pipe->new();
		my $pw = IO::Pipe->new();
		my $pid = fork();
		die "Fork: $!\n" unless defined $pid;
		unless($pid) {
			$pr->writer();
			$pw->reader();
			use POSIX qw(dup2);
			dup2($pw->fileno(),0);
			dup2($pr->fileno(),1);
			$pr->close();
			$pw->close();
			exec("cvs","server");
		}
		$pw->writer();
		$pr->reader();
		$self->{'socketo'} = $pw;
		$self->{'socketi'} = $pr;
	}
	$self->{'socketo'}->write("Root $repo\n");
	#Valid-responses ok error Valid-requests Checked-in New-entry Checksum Copy-file Updated Created Update-existing Merged Patched Rcs-diff Mode Mod-time Removed Remove-entry Set-static-directory Clear-static-directory Set-sticky Clear-sticky Template Clear-template Notified Module-expansion Wrapper-rcsOption M Mbinary E F MT\nvalid-requests
	$self->{'socketo'}->write("Valid-responses ok error Valid-requests Mode Mod-time M Mbinary E F Checked-in Updated Merged Removed\n");

	$self->{'socketo'}->write("valid-requests\n");
	$self->{'socketo'}->flush();

	my $rep=$self->readline();
	if($rep !~ s/^Valid-requests\s*//) {
		$rep="<unknown>" unless $rep;
		die "validReply: $rep\n";
	}
	$rep=$self->readline();
	die "validReply: $rep\n" if $rep ne "ok\n";

	$self->{'ok'} = $rep;
	$self->{'socketo'}->write("UseUnchanged\n") if $rep =~ /\bUseUnchanged\b/;
	$self->{'repo'} = $repo;
	$self->{'subdir'} = $subdir;
	$self->{'lines'} = undef;

	return $self;
}

sub readline {
	my($self) = @_;
	return $self->{'socketi'}->getline();
#	return undef unless defined $self->{'buffer'};
#	while(1) {
#		if($self->{'buffer'} =~ s/^(.*?\n)//) {
#			return $1;
#		}
#		my $buf;
#		my $len = $self->{'socketi'}->read($buf);
#		die "Server: $!" if not defined $len or $len<0;
#		if($len == 0) {
#			$self->{'buffer'}=undef;
#			return undef; # EOF
#		}
#		$self->{'buffer'} .= $buf;
#	}
}

sub rlog {
	my($self) = @_;
	$self->{'socketo'}->write("Argument --\n");
	$self->{'socketo'}->write("Argument $self->{'subdir'}\n");
	$self->{'socketo'}->write("rlog\n");
	$self->{'socketo'}->flush();
	$self->{'lines'} = 0;
	print STDERR "C: rlog\n";
}

sub file {
	my($self,$fn,$rev) = @_;
	$self->{'socketo'}->write("Global_option -n\n");
	$self->{'socketo'}->write("Argument -n\n");
	$self->{'socketo'}->write("Argument -p\n");
	$self->{'socketo'}->write("Argument -N\n");
	$self->{'socketo'}->write("Argument -ko\n");
	$self->{'socketo'}->write("Argument -r\n");
	$self->{'socketo'}->write("Argument $rev\n");
	$self->{'socketo'}->write("Argument --\n");
	$self->{'socketo'}->write("Argument $self->{'subdir'}/$fn\n");
	$self->{'socketo'}->write("Directory .\n");
	$self->{'socketo'}->write("$self->{'repo'}\n");
	$self->{'socketo'}->write("Sticky T1.1\n");
	$self->{'socketo'}->write("co\n");
	$self->{'socketo'}->flush();
	$self->{'lines'} = 0;
}

sub line {
	my($self) = @_;
	die "Not in lines" unless defined $self->{'lines'};

	my $line;
	while(defined($line = $self->readline())) {
		#chomp $line;
		if($line =~ s/^M //) {
			$self->{'lines'}++;
			return $line;
		} elsif($line =~ /^Mbinary\b/) {
			my $cnt;
			die "EOF from server" unless defined ($cnt = $self->readline());
			chomp $cnt;
			die "Duh: Mbinary $cnt" if $cnt !~ /^\d+$/ or $cnt<1;
			$line="";
			while($cnt) {
				my $buf;
				my $num = $self->{'socketi'}->read($buf,$cnt);
				die "S: Mbinary $cnt: $num: $!\n" if not defined $num or $num<=0;
				$line .= $buf;
				$cnt -= $num;
			}
			$self->{'lines'}++;
			return $line;
		} else {
			chomp $line;
			if($line eq "ok") {
				print STDERR "S: ok ($self->{'lines'})\n";
				$self->{'lines'} = undef;
				return undef;
			} elsif($line =~ s/^E //) {
				print STDERR "S: $line\n";
			} else {
				die "Unknown: $line\n";
			}
		}
	}
	die "EOF from server\n";
}

package main;

my $cvs = CVS->new($ENV{CVS_REPOSITORY},$cne);

## my $cvs=CVS->new(":pserver:anonymous\@cvs.sourceforge.net:/cvsroot/ivtv","ivtv");
## my $line;
##
## $cvs->file("ivtv/README","1.1");
## open(F,">/tmp/itr.1.1");
## while(defined($line=$cvs->line())) { print F $line; }
## close(F);
##
## $cvs->file("ivtv/README","1.2");
## open(F,">/tmp/itr.1.2");
## while(defined($line=$cvs->line())) { print F $line; }
## close(F);
## exit(0);
##__END__

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

my %symdate; # actual date - latest
my %dead_sym; # symbols found on non-included branches
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
		my $csf = $cs->{autor}{$autor};
	
		$csf->{$fn}{cmt} = $cmt;
		$csf->{$fn}{rev} = $rev;
		$csf->{$fn}{gone} = 1 if $gone;
	} else {
		$cs->{sym} = [] unless defined $cs->{sym};
	}
	return $cs;
}

sub date_sym($$$$) {
	my($fn,$sym,$dt,$edt) = @_;
	return if $dt >= $edt;
	$symdate{$sym}=[] unless exists $symdate{$sym};
	my $s = $symdate{$sym};

	my($min,$max,$i,$cs);

	cend: {
		$min=0;$max=@$s;$i=0;

		# vor dem Anfang?
		while($min<$max) {
			$i=int(($min+$max)/2);
			$cs = $s->[$i];

			if($cs->[0] > $edt) {
				$max=$i;
				next;
			} elsif($cs->[0] < $edt) {
				$min=$i+1;
				next;
			}
			# ansonsten: Treffer.
			last cend;
		}
		# nix gefunden
		if($max>0) {
			my $sm=$s->[$max-1][1];
#			my $sa=[ @{$s->[$max-1][2]} ];
			$cs=[$edt,$sm];
		} else {
			$cs=[$edt,0];
		}
		splice(@$s,$max,0,$cs);
	}

	cstart: {
		$min=0;$max=@$s;$i=0;

		# vor dem Anfang?
		while($min<$max) {
			$i=int(($min+$max)/2);
			$cs = $s->[$i];
			
			if($cs->[0] > $dt) {
				$max=$i;
				next;
			} elsif($cs->[0] < $dt) {
				$min=$i+1;
				next;
			}
			# ansonsten: Treffer.
			$max=$i;
			last cstart;
		}
		# nix gefunden
		if($max>0) {
			my $sm=$s->[$max-1][1];
#			my $sa=[ @{$s->[$max-1][2]} ];
			$cs=[$dt,$sm];
		} else {
			$cs=[$dt,0];
		}
		splice(@$s,$max,0,$cs);
	}

	while($s->[$max][0] < $edt) {
		$s->[$max][1] ++;
#		push(@{$s->[$max][2]},$fn);
		$max ++;
	}
}

sub reduce_sym() {
	foreach my $sym(keys %symdate) {
		next if $dead_sym{$sym};
		my $acnt=-1;
		my $adate;
		my %fl;
		my %fa;
		my $fa;
		my $fs;
		foreach my $s(@{$symdate{$sym}}) {
#			my($ss,$mm,$hh,$d,$m,$y)=localtime($s->[0]);
#			$m++; $y+=1900; ## zweistellig wenn <2000
#			my $dat = sprintf "%04d-%02d-%02d %02d:%02d:%02d",$y,$m,$d,$hh,$mm,$ss;
#			$fa=""; $fs=""; %fa=();
#			foreach my $f(@{$s->[2]}) {
#				$fa{$f}=1;
#				next if exists $fl{$f};
#				$fa.=" $f";
#				$fl{$f}=1;
#			}
#			foreach my $f(keys %fl) {
#				next if exists $fa{$f};
#				$fs.=" $f";
#				delete $fl{$f};
#			}
#			print "$sym: $dat: $s->[1]";
#			print " +$fa" if $fa; print " -$fs" if $fs;
#			print "\n";

			if($acnt <= $s->[1]) { # use the latest
				$adate = $s->[0];
				$acnt = $s->[1];
			}
		}
#		foreach my $s(@{$symdate{$sym}}) {
#			next if $acnt != $s->[1];
#			my($ss,$mm,$hh,$d,$m,$y)=localtime($s->[0]);
#			$m++; $y+=1900; ## zweistellig wenn <2000
#			my $dat = sprintf "%04d-%02d-%02d %02d:%02d:%02d",$y,$m,$d,$hh,$mm,$ss;
#			print "$sym: $dat: @{$s->[2]}\n";
#		}

		push(@{add_date($adate)->{sym}},$sym);

#		my($ss,$mm,$hh,$d,$m,$y)=localtime($adate);
#		$m++; $y+=1900; ## zweistellig wenn <2000
#		my $dat = sprintf "%04d-%02d-%02d %02d:%02d:%02d",$y,$m,$d,$hh,$mm,$ss;
#		print "$sym: $dat\n";
	}
	%symdate=();
}

sub rev_ok($$) {
	my($fn,$rev)=@_;
# Target: 2.2.0.4
# OK: 1.1 1.1.1.1 1.1.1.2 1.2 1.3 1.4  2.0 2.1 2.2 2.2.4.1 2.2.0.4 2.2.4.2 2.2.4.3
# !OK: 1.2.3.4 2.3 2.3.4.5 2.2.3.1 2.2.5.1 2.2.4.1.4.4 2.3 3.1 

# ASSUMPTION: mainline+vendor is checked in completely before we even think
#             about importing "normal" branches.
# Vendor branch cut-off dates (1.1.1.2, 1.2, 1.1.1.3 => ignore the latter)
# are checked via %cutoff.

	my $tr = $target->{$fn};
	return 1 if defined $tr and $rev eq $tr;
	my @f = split(/\./,$rev);

	return (0+@f == 2 or (0+@f==4 and $f[0]==1 and $f[1]==1 and $f[2]==1))
		if $trev eq "" or not $tr; # baseline + vendor branch

	return 0 unless defined $tr;
	die "Target: $tr  File: $fn\n" unless $tr =~ s/\.0\.(\d+)$/.$1/;

	my @t = split(/\./,$tr);

	my $rt = shift @t;
	my $rf = shift @f;
	if($rt != $rf) { # Special for 1.9 => 2.0: use baseline
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

### Test Revision Matching
#$target->{"/hurzli"}="2.2.0.4";
#foreach my $r(qw(1.1 1.2 1.3 1.4  2.0 2.1 2.2 2.2.0.4 2.2.4.1 2.2.4.2 2.2.4.3)) {
#	die "RevP1: $r\n" unless rev_ok("/hurzli",$r);
#}
#foreach my $r(qw(1.2.3.4 2.3 2.3.4.5 2.2.3.1 2.2.5.1 2.2.0.2 2.2.4.1.4.4 2.3 3.1)) {
#	die "RevP2: $r\n" if rev_ok("/hurzli",$r);
#}
#exit(0);


# Process one CVS log entry
sub proc1($$$$$$) {
	my($fn,$dt,$rev,$cmt,$autor,$gone) = @_;

	return if 
		 $fn =~ m#^CVS/# or
		 $fn =~ m#/CVS/# or
		 $fn =~ m#^CVSROOT/# or
		 $fn =~ m#/CVSROOT/# or
		 0;
	return add_date($dt,$fn,$rev,$autor,$cmt,$gone)
		if $rev ne "1.1" or not $gone;
}

sub proc(@) {
	my $state=0;
	my $fn;
	my $rev;
	my $dt;
	my $autor;
	my $cmt;
	my $pre;
	my $gone;

	my %entry;
	my %syms;
	my $re = "$cvs->{'repo'}/$cvs->{'subdir'}";

	# It is helpful to have the output of "cvs log FILE" handy if you
	# want to understand the next bits.
	foreach my $x(@_) {
		if($state == 0 and $x =~ s/^Working file:\s+(\S+)\s*$/$1/) {
			$fn = $x;
			$state=1;
			# print STDERR "$CLR  $fn\r" if $verbose;
			next;
		}
		if($state == 0 and $x =~ s/^RCS file:\s+(\S+),v\s*$/$1/) {
			$fn = $x;
			die "Unknown name: $fn\n" unless $fn =~ s/^\Q$re\E\///;
			$fn =~ s#/Attic/#/#;
			$fn =~ s#^Attic/##;
			$state=1;
			# print STDERR "$CLR  $fn\r" if $verbose;
			next;
		}
		if($state == 1 and $x =~ /^symbolic names:/) {
			$state=2;
			next;
		}
		if($state == 2) {
#symbolic names:
#    v0_9_1: 1.3
			if($x =~ /^\s+(\S+)\:\s*(\S+)\s*$/) { # Branches
				my $dsym=$1;
				my $drev=$2;

				$target->{$fn}=$drev if defined $trev and $dsym eq $trev;
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
			$entry{$rev} = proc1($fn,$dt,$rev,$cmt,$autor,$gone) if $dt;
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
			$state=6;
			next;
		} elsif($state == 5 and $x =~ /^date:\s+(\d+)-(\d+)-(\d+)\s+(\d+)\:(\d+)\:(\d+)\s*[+-]\d{4}\s*\;\s+author\:\s+(\S+)\;\s+state\:\s+(\S+)\;/) {
			$gone=1 if lc($8) eq "dead";
			$autor = $7;
			my($y,$m,$d,$hh,$mm,$ss)=($1,$2,$3,$4,$5,$6);
			$y-=1900 if $y>=1900; $m--;
			$dt=timelocal($ss,$mm,$hh,$d,$m,$y);
			die "Datum: $x" unless $dt;
			$cutoff{$fn}=$dt if $rev eq "1.2";
			$state=6;
			next;
		}
		if($state == 6) {
			next if $x =~ /^branches\:\s+/;
			$cmt .= "$x\n";
			next;
		}
	}
	$entry{$rev} = proc1($fn,$dt,$rev,$cmt,$autor,$gone) if $dt;

	while(my($rev,$syms)=each %syms) {
		foreach my $sym(@$syms) {
			unless(rev_ok($fn,$rev)) {
#				print STDERR "Ouch $sym|$rev|$target->{$fn}|$fn\n";
				$dead_sym{$sym}++;
				next;
			}
			my $nxdate = $time;
			if($entry{$rev.".1.1"}) {
				$nxdate = $entry{$rev.".1.1"}{wann}
					if $nxdate > $entry{$rev.".1.1"}{wann};
			}
			my $enum=2;
			my $skip=0;
			my $drev;
			while($skip<5) {
				$drev=$rev.".$enum.1";
				if($entry{$drev}) {
					$nxdate = $entry{$drev}{wann}
						if $nxdate > $entry{$drev}{wann} and ($sym =~ /^Branch:/ or rev_ok($fn,$drev));
				} else {
					$skip += 1;
				}
				$enum++;
			}
			$drev = $rev; $drev =~ s/(\d+)$/1+$1/e;
			if($entry{$drev}) {
				$nxdate = $entry{$drev}{wann}
					if $nxdate > $entry{$drev}{wann} and rev_ok($fn,$drev);
			}
			my $dt = $entry{$rev};
			next unless $dt;
			$dt = $dt->{wann};
			next unless $dt;
			date_sym($fn,$sym,$dt,$nxdate);
		}
	}
}

my $tmpcv = "/var/cache/cvs";
my $tmppn="/var/cache/cvs/bk/$pn";

#if(-f "$tmppn.data") {
#	print STDERR "$pn: Reading stored CVS log\n";
#	$cset = retrieve("$tmppn.data");
#	($cset,$target) = @$cset;
#
#	foreach my $x (@$cset) {
#		my $ff=$x->{files};
#		foreach my $f (keys %$ff) {
#			$cutoff{$f}=$x->{wann}
#				if $ff->{$f}{rev} eq "1.2";
#		}
#	}
#} else {
	$cset=[];
	print STDERR "$CLR $pn: Processing CVS log\r" if $verbose;
	my $mr=1;
	my @buf = ();
	my $line;

	$cvs->rlog();
	while(defined($line = $cvs->line())) {
		chomp $line;
		if($line =~ /^=+\s*$/) {
			proc(@buf);
			@buf=();
		} else {
			push(@buf,$line) if @buf or $line =~ /^RCS file:/;
		}
	}
	proc(@buf) if @buf;

	reduce_sym();
	nstore([$cset,$target],"$tmppn.data");
#}
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
unlink("BitKeeper/etc/SCCS/x.lmark");
system("bk prs -anhd:KEY: -r+ ChangeSet | tail -1 > BitKeeper/etc/SCCS/x.lmark");

sub cleanout() {
	unlink bkfiles("x");
	bk("-r","clean","-q");
	bk("-r","unedit");
	bk("-r","unlock","-f");
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
					foreach my $f(@ff) {
						my $line;
						$cvs->file($f,$rev);
						open(F,">$f") or die "No file: $f: $!\n";
						while(defined($line=$cvs->line())) {
							print F $line or die "Write: $f: $!\n";
						}
						close(F) or die "Write: $f: $!\n";
						#cvs((($ENV{CVS_REPOSITORY} =~ m#:/#) ? "-q" : "-Q"),"update","-A","-r",$rev, @ff);
					}
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

	foreach my $pre(keys %tpre) {
		die "Kein Vorläufer-Branch '$pre' für '$trev' gefunden\n"
			unless bk("prs","-hd:I:", "-r$pre","ChangeSet");
	}
	my $b_rev=bk("prs","-hd:I:", "-rBranch:$trev","ChangeSet");
	my $b_top=bk("prs","-hd:I:", "-r+","ChangeSet");
	unless($b_rev) {
		warn "No start revision for branch '$trev' found!\n" unless $b_rev;
	} else {
		bk("undo","-sfqa$b_rev");
		unlink("BitKeeper/etc/SCCS/x.lmark");
		system("bk prs -anhd:KEY: -r+ ChangeSet | tail -1 > BitKeeper/etc/SCCS/x.lmark");
	}

	bk("tag","-r+",$trev) if $b_rev ne $b_top;
	bk("clone",".","$ENV{BK_REPOSITORY}/$pn");
	bk("parent","$ENV{BK_REPOSITORY}/$pn");
} elsif($trev ne "") { # tag should exist
	warn "Tag '$trev' doesn't exists!\n" unless bk("prs","-hd:I:", "-r$trev","ChangeSet");
}

my %last;
my $x;
my $done=0;
my $ddone=0;

while(@$cset) {
	$x = $cset->[0];
	if(defined $x->{sym}) {
		my($ss,$mm,$hh,$d,$m,$y)=localtime($x->{wann});
		$m++; $y+=1900; ## zweistellig wenn <2000
		my $cvsdate = sprintf "%04d-%02d-%02d %02d:%02d:%02d",$y,$m,$d,$hh,$mm,$ss;
		foreach my $s(@{$x->{sym}}) {
			print "$s $cvsdate     \n";
		}
	}
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

			# A file was changed already -> this belongs in a new changeset
			my $nf = 0;
			foreach my $fn(keys %$f) {
				next unless rev_ok($fn,$f->{$fn}{rev});
				$nf++;
				last sk_add if $adf{$fn}++;
			}

			# skip if there are no files to be done here.
			# If there are tags here, however ...
			last sk_add if $y->{sym} and not $nf;
			next sk_add unless $nf;

			# Different author -> different changeset
			last sk_add unless $f;

			# comments are the same? If so, increase grace time
			$scmt = scmt($f,$scmt);
			if (not defined $scmt or $scmt eq "") {
				last sk_add if $y->{wann} - $ldiff > $diff;
			} else {
				last sk_add if $y->{wann} - $ldiff > 10*$diff;
			}

			# NOW, finally, collect changes.
			foreach my $fn(keys %$f) {
				next unless rev_ok($fn,$f->{$fn}{rev});
				$adt{$fn}=$f->{$fn}
					if $f->{$fn}{rev} !~ /^1\.1\.1\.\d+$/
						or not defined $cutoff{$fn}
						or $y->{wann} < $cutoff{$fn};
			}
			$last{$autor}=$ldiff=$y->{wann};
			
			# If there are tags here, we need a changeset
			last sk_add if $y->{sym};

			# We also need one if there are other authors
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
	unlink("BitKeeper/etc/SCCS/x.lmark");
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
