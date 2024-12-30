
DESTDIR ?= /

install:
	mkdir -p $(DESTDIR)/usr/bin
	install bin/* $(DESTDIR)/usr/bin
	:
	mkdir -p $(DESTDIR)/usr/sbin
	install sbin/* $(DESTDIR)/usr/sbin
	:
	mkdir -p $(DESTDIR)/usr/lib/git-core
	for f in git/* ; do \
                test -f $$f && install -m 755 $$f $(DESTDIR)/usr/lib/git-core/;\
        done
	:
	mkdir -p $(DESTDIR)/usr/share/sourcemgr
	cp -a share/* $(DESTDIR)/usr/share/sourcemgr

