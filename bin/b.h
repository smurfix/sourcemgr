#!/bin/bash

cat <<'END'
b.cache     copy external BK archive into local cache
b.cvs       mirror CVS => BK
b.exists    check whether a BK archive exists
b.get       checks out BK archive
b.import    import local file tree into BK archive
b.make      run make / make install from BK archive
b.merge     merge updates from BK archive
b.name      returns the local BK archive's name
b.new       create new BK archive
b.pfp       (helper program to import Perforce (for Perl))
b.put       send updates to BK archive
b.rev       return current revision numbers
b.rpm       build RPM archive
b.rpmenv    return RPM environment variables
b.rpmget    get BK archive for RPM processing
b.upversion install as BitKeeper/triggers/pre-commit.upversion
            to auto-increment a version number in file 'rpm.version'
b.version   get version number of the current directory
END
