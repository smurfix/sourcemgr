#!/bin/bash

cat <<'END'
b.cache     copy external BK archive into local cache
b.cvs       incrementally mirror CVS => BK
b.deb       debian-izes a repository
b.debuild   builds Debian source / binary package
b.exists    check whether a BK archive exists
b.get       checks out BK archive
b.import    import local file tree into BK archive
b.merge     merge updates from BK archive
b.name      returns the local BK archive's name
b.new       create new BK archive
b.pfp       helper program to import Perforce (used for Perl)
b.pull      "bk pull" from multiple parents
b.put       send updates to BK archive
b.rcs       incrementally mirror RCS => BK
b.rev       return current revision numbers
b.rpm       build RPM archive
b.rpmenv    return RPM environment variables
b.rpmget    get BK archive for RPM processing
b.upversion install as BitKeeper/triggers/pre-commit.upversion
            to auto-increment a version number in file 'rpm.version'
b.version   get version number of the current directory
b.uplog     auto-generate debian/changelog
b.upversion auto-update version number file, or debian/changelog
b.version   find version (from number file's check-in comments)
END
