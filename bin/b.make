#!/bin/bash
 
set -e
trap 'test -n "$superset" && kill $SUPERPID; usage; exit 1' 0

usage() {
cat >&2 <<END
Usage: $(basename $0)  -- Hole aus Archiv, baue, installiere, wirf weg.
       [ -i (install) ]  [ -I (build-und-install) ]
       [ -v release ]    [ -s Subtarget, d.h. compile_XX ] 
       [ -g (Sources sind in /usr/src, Checkout wenn nötig) ]
       [ -l (Sources sind im aktuellen Verzeichnis) ]
       [ -n (Sourcen nach Installation nicht löschen) ]
       [ -N (laß in Ruhe wenn bereits fertig) ]
       [ was ]

Mit -g-Option: Gehe nach /usr/src/dest-directory, checke aus, baue.
Mit -l-Option: Verwende lokales Verzeichnis. Default: -l.

Normalerweise werden automatisch ausgecheckte Sourcen nach erfolgreicher
Installation auch wieder automatisch gelöscht, _ohne_ irgendwas
einzuchecken. Abhilfe: (a) selber einchecken, (b) Datei "AUTOREMOVE"
löschen, (c) -n-Option beim Installieren verwenden. Methode (a) ist
eindeutig vorzuziehen!

Beim Installieren wird automagisch "sudo" aufgerufen.
Das Paßwort ist folglich das eigene.

"Was" kann eine Datei in STATUS/hosts oder STATUS/packages sein, dann wird
genau das darin Aufgeführte neu gebaut.
END
}

dir=
defvers=noris
vers=
doinstall=
islocal=y
nodelete=
compile=compile
install=install
submode=
recargs=
skipdone=
freinst=
ARCH=Linux
if test -f /mach ; then ARCH=Mac; fi

   eval set -- "$(getopt "v:hignd:s:IlNf" "$@")"
   if test $? != 0
   then
	   exit 1
   fi
   for i
   do
	   case "$i"
	   in
		   -h)
		       exit 1 ;;
		   -d)
			   shift; recargs="$recargs -d $1"; dir="$1"; shift;;
		   -v)
			   shift; recargs="$recargs -v $1"; vers="$1"; shift;;
		   -s)
			   shift; recargs="$recargs -s $1"; submode="_$1";
			                                    subtarget="-$1"; shift;;
			-f)
				shift; recargs="$recargs -f"; freinst=y ;;
			-n)
				shift; recargs="$recargs -n"; nodelete=y ;;
			-N)
				shift; recargs="$recargs -N"; skipdone=y ;;
			-l)
				shift; recargs="$recargs -l"; islocal=y ;;
			-g)
				shift; recargs="$recargs -g"; islocal= ;;
			-i)
				shift; recargs="$recargs -i"; doinstall=y ;;
			-I)
				shift; doinstall=b ;;
			--)
				shift; break;;
	   esac
   done

superset=
dv=
test -z "$vers" || dv="-$vers"
#if test -n "$doinstall" -a -z "$SUPERPID"; then
#	sudo echo "sudo-Test OK"
#	(
#	    TTY=$(tty)
#		while true ; do sudo touch /var/run/sudo/$USER.$TTY; done
#	) &
#	export SUPERPID=$!
#	superset=y
#fi

if test -z "$dir$dv" ; then
	b.name -n "$*" > /tmp/bn.$$
	read dir overs < /tmp/bn.$$
	rm -f /tmp/bn.$$

    if test -f "/usr/src/STATUS/packages/$dir$dv" ; then
		trap 'test -n "$superset" && kill $SUPERPID' 0
		if test "$doinstall" = "b" ; then recargs="$recargs -I"; fi
		while read x y ; do
			if test -n "$y" ; then y="-s $y"; fi
			echo + b.make $recargs $y $x
			b.make -N $recargs $y $x
		done < /usr/src/STATUS/packages/$dir$dv
	    exit 0
    fi
    if test -f "/usr/src/STATUS/hosts/$dir$dv" ; then
		trap 'test -n "$superset" && kill $SUPERPID' 0
		if test "$doinstall" = "b" ; then recargs="$recargs -I"; fi
		while read x y ; do
			if test -n "$y" ; then y="-s $y"; fi
			echo + b.make $recargs $y $x
			b.make -N $recargs $y $x
		done < /usr/src/STATUS/hosts/$dir$dv
	    exit 0
    fi
	recargs="$recargs $*"
else
	test -z "$*"
fi

trap 'test -n "$superset" && kill $SUPERPID' 0

if test -z "$doinstall" -a "$(whoami)" = "root" ; then
    echo "Bitte NICHT als Root!"
    exit 1
fi

desc=$(echo $dir | sed -e 's/[_\/]/:/g' -e 's/:*$//')
what=$(echo $desc | sed -e 's/:/_/g' -e 's/_*$//')

set -e

if test -z "$islocal" ; then
	cd /usr/src
	if test -n "$skipdone" -a -s "STATUS/done/$desc$submode" ; then
		echo "$desc$submode: Done."
		exit 0
	fi
	if test -n "$doinstall" -a -s "STATUS/done/$desc$submode" ; then
		echo "$desc$submode: Bereits installiert, wiederhole..."
		mv "STATUS/done/$desc$submode" "STATUS/to-install/$desc$submode"
	fi
	if test -n "$doinstall" -a -s "STATUS/fail/$desc$submode" -a -n "$freinst"; then
		echo "$desc$submode: Installationsfehler? wiederhole..."
		mv "STATUS/fail/$desc$submode" "STATUS/to-install/$desc$submode"
	fi
	if test "$doinstall" = "y" -a ! -d "$dir$dv" ; then
		echo "$desc$submode: erst auschecken und bauen!"
		exit 1
	fi
	if test "$doinstall" = "y" -a ! -f "STATUS/to-install/$desc$submode" ; then
		echo "$desc$submode: Noch nicht gebaut!"
		exit 1
	fi
	if test -f "/usr/src/STATUS/checkout/$desc" ; then
		# set -- $(grep "^$desc[	 ]" STATUS/checkout/$desc)
		set -- $(cat /usr/src/STATUS/checkout/$desc)
		what=$1
		compile=$2
		install=$3
		what=$(echo $what | sed -e 's/:/_/g'  -e 's/\//_/g' -e 's/_*$//')
		if test -n "$4" ; then
			defvers="$4"
		fi
	fi
	if test -f "STATUS/work/$desc$submode" ; then
		read host pid < STATUS/work/$desc$submode
		if ! test "$host" = "$(hostname)" || kill -0 $pid >/dev/null 2>&1 ; then
			echo -n "$desc$submode: In Arbeit: "
			head -1 STATUS/work/$desc$submode 
			echo "$desc$submode: 'redo $dir$dv', wenn Abbruch."
			exit 1
		fi
	fi
	if test -f "STATUS/legacy/$desc" ; then
		echo "$desc$submode: Altes Programm, wird nicht angefaßt."
		exit 1
	fi
#	if test -f "STATUS/to-install/$desc$submode" -a -z "$doinstall" ; then
#		echo "$desc$submode: Muß installiert werden."
#		exit 0
#	fi
	if test -f STATUS/work/$desc$submode ; then
		mv -f STATUS/work/$desc$submode STATUS/work/$desc$submode.new
	fi
	echo $(hostname) $$ > STATUS/work/$desc$submode

	if test -s "STATUS/fail/$desc$submode" ; then
		echo '# RESTART (fail)'
		echo '# RESTART (fail)' >> STATUS/work/$desc$submode
		sed -e '/^#-#/d' -e 's/^/#-/' < STATUS/fail/$desc$submode >> STATUS/work/$desc$submode 
		echo '# RESTART (fail)' $(hostname) $$ >> STATUS/work/$desc$submode
		rm -f STATUS/fail/$desc$submode
	fi
	if test -s "STATUS/to-install/$desc$submode" ; then
		echo '# RESTART (to-install)'
		echo '# RESTART (to-install)' >> STATUS/work/$desc$submode
		sed -e '/^#-#/d' -e 's/^/#-/' < STATUS/to-install/$desc$submode >> STATUS/work/$desc$submode 
		echo '# RESTART (to-install)' $(hostname) $$ >> STATUS/work/$desc$submode
		rm -f STATUS/to-install/$desc$submode
	fi
	if test -s "STATUS/done/$desc$submode" ; then
		echo '# RESTART (done)'
		echo '# RESTART (done)' >> STATUS/work/$desc$submode
		sed -e '/^#-#/d' -e 's/^/#-/' < STATUS/done/$desc$submode >> STATUS/work/$desc$submode 
		echo '# RESTART (done)' $(hostname) $$ >> STATUS/work/$desc$submode
		rm -f STATUS/done/$desc$submode
	fi
	if test -s STATUS/work/$desc$submode.new ; then
		echo '# RESTART (Abbruch)'
		echo '# RESTART (Abbruch)' >> STATUS/work/$desc$submode
		sed -e '/^#-#/d' -e 's/^/#-/' < STATUS/work/$desc$submode.new >> STATUS/work/$desc$submode 
		echo '# RESTART (Abbruch)' $(hostname) $$ >> STATUS/work/$desc$submode
		rm -f STATUS/work/$desc$submode.new
	fi

	if test -d "$dir$dv" ; then
		cd "$dir$dv"
		if test -z "$doinstall" ; then
			bk pull
		fi
	else
		b.get -d "$dir" -v "$vers" "$dir$dv"
		cd "$dir$dv"
	fi
else
	cd $(bk root)
fi
test -f Makefile.$ARCH || bk -r get -q

bad=
if test -f Makefile.$ARCH ; then
	MF=Makefile.$ARCH
elif test -f ../Makefile.$ARCH.sub ; then
	MF=../Makefile.$ARCH.sub
elif test -f ../../Makefile.$ARCH.sub ; then
	MF=../../Makefile.$ARCH.sub
else
	echo No Makefile.$ARCH found >&2
	exit 1
fi

if test -z "$doinstall" -o "$doinstall" = "b" ; then # compile
	echo + make -f $MF $compile$subtarget
	make -f $MF $compile$subtarget || bad=y
	#env LANG=C-JIS make -f $MF $compile$subtarget || bad=y
fi
if test -n "$doinstall" -a -z "$bad" ; then
	echo + make -f $MF $install$subtarget
	#sudo env LD_PRELOAD=/usr/lib/log-install.so LOGFILE=/usr/src/STATUS/work/$desc$submode \
	#env LANG=C-JIS make -f $MF $install$subtarget || bad=y
	sudo env LD_PRELOAD=/usr/lib/log-install.so LOGFILE=/usr/src/STATUS/work/$desc$submode.p \
	make -f $MF $install$subtarget || bad=y
fi

if test -z "$islocal" ; then
	cd /usr/src
	exec  1>&5 2>&6
	sleep 1
	kill $reader 2>/dev/null || true
	kill $readere 2>/dev/null || true
	test ! -s /usr/src/STATUS/work/$desc$submode.p || cat /usr/src/STATUS/work/$desc$submode.p >> /usr/src/STATUS/work/$desc$submode && rm -f /usr/src/STATUS/work/$desc$submode.p
	test ! -s /usr/src/STATUS/work/$desc$submode.e || cat /usr/src/STATUS/work/$desc$submode.e >> /usr/src/STATUS/work/$desc$submode && rm -f /usr/src/STATUS/work/$desc$submode.e
	if test -n "$bad" ; then
		mv "STATUS/work/$desc$submode" "STATUS/fail/$desc$submode"
		if test -n "$doinstall" ; then touch "STATUS/done/$desc$submode"; fi
		echo "$desc$submode: ### FEHLER ###"
		rm -f /usr/src/$dir$dv/AUTOREMOVE
			## falls Fixes aus Versehen nicht eingecheckt werden
		exit 1
	fi
    if test -z "$doinstall" ; then # compile
		mv "STATUS/work/$desc$submode" "STATUS/to-install/$desc$submode"
	else # install
		mv -f "STATUS/work/$desc$submode" "STATUS/done/$desc$submode"
		echo "$desc$submode: Generiere STATUS/dist/$desc$submode"
		rm -f "STATUS/fail/$desc$submode"
		(
			gen.flist < STATUS/done/$desc$submode > STATUS/out/new.$desc$submode 
			comm -23 <( ( test ! -f STATUS/removed/$desc$submode || cat STATUS/removed/$desc$submode ; test ! -f STATUS/out/$desc$submode || cat STATUS/out/$desc$submode ) | sort -u) <(sort -u STATUS/out/new.$desc$submode) > STATUS/removed/new.$desc$submode
			mv -f STATUS/out/new.$desc$submode STATUS/out/$desc$submode
			mv STATUS/removed/new.$desc$submode STATUS/removed/$desc$submode 
			gen.distfile "$dir$dv"
		) &
		if test -f "$dir$dv/AUTOREMOVE" -a ! -f "STATUS/keep/$desc$submode" ; then
			cd "$dir$dv"
			if test -z "$nodelete" && bk superset ; then
				cd /tmp
				rm -rf "$dir$dv"
			else
				rm -rf "$dir$dv/AUTOREMOVE"
			fi
		fi
	fi
else
	if test -n "$doinstall" ; then
		echo "$desc$submode: Achtung: Die Dateien sind NICHT aufgezeichnet."
	fi
fi

exit 0
