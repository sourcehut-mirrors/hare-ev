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
	mkdir -p docs/ev
	$(HAREDOC) -Fhtml ev > docs/ev/index.html

clean:
	rm -rf docs

install:
	mkdir -p $(DESTDIR)$(THIRDPARTYDIR)/ev/+linux
	install -m644 ev/+linux/*.ha $(DESTDIR)$(THIRDPARTYDIR)/ev/+linux

uninstall:
	rm -rf $(DESTDIR)$(THIRDPARTYDIR)/ev

.PHONY: all docs clean check install uninstall
