
DESTDIR ?= /

install:
	install bin/* $(DESTDIR)/usr/bin
	install sbin/* $(DESTDIR)/usr/sbin
