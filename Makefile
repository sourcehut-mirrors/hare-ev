.POSIX:
.SUFFIXES:
HARE=hare
HAREFLAGS=
HAREDOC=haredoc

DESTDIR=
PREFIX=/usr/local
SRCDIR=$(PREFIX)/src
HARESRCDIR=$(SRCDIR)/hare
THIRDPARTYDIR=$(HARESRCDIR)/third-party

all:

check:
	$(HARE) test

docs:
	mkdir -p docs/ev docs/ev/dial docs/ev/dns
	$(HAREDOC) -Fhtml ev > docs/ev/index.html
	$(HAREDOC) -Fhtml ev::dial > docs/ev/dial/index.html
	$(HAREDOC) -Fhtml ev::dns > docs/ev/dns/index.html

clean:
	rm -rf docs

install:
	mkdir -p $(DESTDIR)$(THIRDPARTYDIR)/ev/+linux
	mkdir -p $(DESTDIR)$(THIRDPARTYDIR)/ev/dial
	mkdir -p $(DESTDIR)$(THIRDPARTYDIR)/ev/dns
	install -m644 ev/+linux/*.ha $(DESTDIR)$(THIRDPARTYDIR)/ev/+linux
	install -m644 ev/dial/*.ha $(DESTDIR)$(THIRDPARTYDIR)/ev/dial
	install -m644 ev/dns/*.ha $(DESTDIR)$(THIRDPARTYDIR)/ev/dns

uninstall:
	rm -rf $(DESTDIR)$(THIRDPARTYDIR)/ev

.PHONY: all docs clean check install uninstall
