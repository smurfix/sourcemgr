#!/bin/sh

usage() {
cat >&2 <<END
Usage: $(basename $0)  -- Hole aus Archiv, baue, installiere, wirf weg.
       [ -i (install) ]
       [ -v release ]
       [ -g (sources are to go to /usr/src, checkout if necessary) ]
       [ -n (do not delete after install) ]
       [ was ]

Ohne -l-Option: Gehe nach /usr/src/dest-directory, checke aus, baue.
Mit: Verwende lokales Verzeichnis, .

Normalerweise werden automatisch ausgecheckte Sourcen nach erfolgreicher
Installation auch wieder automatisch gelöscht, _ohne_ irgendwas
einzuchecken. Abhilfe: (a) selber einchecken, (b) Datei "AUTOREMOVE"
löschen, (c) -n-Option beim Installieren verwenden. Methode (a) ist
eindeutig vorzuziehen!

Beim Installieren wird automagisch "sudo" aufgerufen.
Das Paßwort ist folglich das eigene.
END
exit 1
}

dir=
vers=noris
doinstall=
islocal=y
nodelete=
compile=compile
install=install

   set -- $(getopt "v:hignd:" $*)
   if test $? != 0
   then
	   usage
   fi
   for i
   do
	   case "$i"
	   in
		   -h)
		       usage ;;
		   -d)
			   shift; dir="$1"; shift;;
		   -v)
			   shift; vers="$1"; shift;;
			-n)
				shift; nodelete=y ;;
			-g)
				shift; islocal= ;;
			-i)
				shift; doinstall=y ;;
			--)
				shift; break;;
	   esac
   done

if test -n "$2"; then usage; fi
if test -z "$*" -a -z "$dir" ; then
	dir=$(/bin/pwd|sed -ne 's/^.*[\./]src\///p')
	if test -z "$dir"; then usage; fi
fi
if test -n "$*" -a -n "$dir"; then usage; fi
if test -n "$*" ; then dir="$*"; fi
if test -z "$dir"; then
	if test -z "$islocal"; then usage; fi
	dir=NIX
fi

export PRCS_REPOSITORY=/archiv/src/prcs PRCS_LOGQUERY=1
what=$(echo $dir | sed -e 's/\//_/g' -e 's/_*$//')
desc=$(echo $dir | sed -e 's/\//:/g' -e 's/:*$//')
dir=$(echo $desc | sed -e 's/:/\//g')

if test -z "$doinstall" -a "$(whoami)" = "root" ; then
    echo "Bitte NICHT als Root!"
    exit 1
fi

set -e

if test -z "$islocal" ; then
	cd /usr/src
	if test -n "$doinstall" -a ! -d "$dir" ; then
		echo "$desc: erst auschecken und bauen!"
		exit 1
	fi
	if test -f "/usr/src/STATUS/checkout/$desc" ; then
		# set -- $(grep "^$desc[	 ]" STATUS/checkout/$desc)
		set -- $(cat /usr/src/STATUS/checkout/$desc)
		what=$1
		compile=$2
		install=$3
		if test -n "$4" ; then what="$4" ; fi
		what=$(echo $what | sed -e 's/[:\/]/_/g' -e 's/_*$//')
	fi
	if test ! -d $PRCS_REPOSITORY/$what ; then
		echo "$desc: kein PRCS-Archiv gefunden!"
		exit 1
	fi
	if test -f "STATUS/work/$desc" ; then
		echo -n "$desc: In Arbeit: "
		head -1 STATUS/work/$desc 
		echo "$desc: 'redo $dir', wenn Abbruch."
		exit 1
	fi
	if test -f "STATUS/legacy/$desc" ; then
		echo "$desc: Altes Programm, wird nicht angefaßt."
		exit 1
	fi
#	if test -f "STATUS/to-install/$desc" -a -z "$doinstall" ; then
#		echo "$desc: Muß installiert werden."
#		exit 0
#	fi
	echo $(hostname) $$ > STATUS/work/$desc
	if test -f "STATUS/fail/$desc" ; then
		cat STATUS/fail/$desc >> STATUS/work/$desc 
		echo '# RESTART' $(hostname) $$ >> STATUS/work/$desc
		rm -f STATUS/fail/$desc
	fi
	if test -f "STATUS/to-install/$desc" ; then
		cat STATUS/to-install/$desc >> STATUS/work/$desc 
		echo '# RESTART' $(hostname) $$ >> STATUS/work/$desc
		rm -f STATUS/to-install/$desc
	fi
	if test -f "STATUS/done/$desc" ; then
		cat STATUS/done/$desc >> STATUS/work/$desc 
		echo '# RESTART' $(hostname) $$ >> STATUS/work/$desc
		rm -f STATUS/done/$desc
	fi

	mkfifo /tmp/ff.$$
	( set +x; while read a ; do echo "# $a" ; done < /tmp/ff.$$ | tee -a STATUS/work/$desc ) &
	sleep 1
	exec > /tmp/ff.$$ 2>&1
	rm /tmp/ff.$$

	if test -f "$dir/AUTOREMOVE" ; then
		if test -f "STATUS/keep/$desc" ; then
			echo "$desc: Ist der Inhalt eingecheckt?"
		else
			echo "$desc: Wird nach der Installation gelöscht!"
			echo "$desc: Ist der Inhalt eingecheckt???"
		fi
		cd $dir
	elif test -d "$dir" ; then
		if test -z "$doinstall" ; then
			echo "$desc: Existiert, ist der Inhalt aktuell???"
		fi
		cd $dir
	else
		mkdir -p $dir
		cd $dir
		prcs checkout -f -r$vers $what.prj
	    touch AUTOREMOVE
	fi
fi

bad=
if test -z "$doinstall" ; then # compile
	echo + make -f Makefile.Linux $compile
	make -f Makefile.Linux $compile || bad=y
else # install
	echo + make -f Makefile.Linux $install
	sudo env LD_PRELOAD=/usr/lib/log-install.so LOGFILE=/usr/src/STATUS/work/$desc \
	make -f Makefile.Linux $install || bad=y
fi

if test -z "$islocal" ; then
	cd /usr/src
	if test -n "$bad" ; then
		mv "STATUS/work/$desc" "STATUS/fail/$desc"
		echo "$desc: ### FEHLER ###"
		exit 1
	fi
    if test -z "$doinstall" ; then # compile
		mv "STATUS/work/$desc" "STATUS/to-install/$desc"
	else # install
		mv -f "STATUS/work/$desc" "STATUS/done/$desc"
		echo "$desc: Generiere STATUS/dist/$desc"
		rm -f "STATUS/fail/$desc"
		(
			(	gen.flist <STATUS/done/$desc
#				if test -f STATUS/out/$desc ; then cat STATUS/out/$desc ; fi
			)	| sort -u > STATUS/out/new.$desc 
			mv -f STATUS/out/new.$desc STATUS/out/$desc
			gen.distfile $dir
		) &
		if test -f "$dir/AUTOREMOVE" -a ! -f "STATUS/keep/$desc" ; then
			rm -rf "$dir"
		fi
	fi
else
	if test -n "$doinstall" ; then
		echo "$desc: Achtung: Die Dateien sind NICHT aufgezeichnet."
	fi
fi

exit 0
