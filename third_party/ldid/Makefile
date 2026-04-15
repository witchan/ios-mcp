ifneq (,$(wildcard .git))
VERSION  ?= $(shell git describe --tags)
else
VERSION  ?= 2.1.5-procursus7
endif

CC       ?= cc
CXX      ?= c++
INSTALL  ?= install
LN       ?= ln

CXXFLAGS ?= -O2 -pipe
LDFLAGS  ?=

PREFIX   ?= /usr/local

BINDIR   ?= $(PREFIX)/bin
MANDIR   ?= $(PREFIX)/share/man

SRC      := ldid.cpp
LIBS     ?=

LIBPLIST_INCLUDES  ?= $(shell pkg-config --cflags libplist-2.0)
LIBPLIST_LIBS      ?= $(shell pkg-config --libs libplist-2.0)

ifeq ($(shell uname -s),FreeBSD)
LIBCRYPTO_INCLUDES ?= -I/usr/include
LIBCRYPTO_LIBS     ?= -L/usr/lib -lcrypto
else
LIBCRYPTO_INCLUDES ?= $(shell pkg-config --cflags libcrypto)
LIBCRYPTO_LIBS     ?= $(shell pkg-config --libs libcrypto)
endif

ifeq ($(SMARTCARD),1)
CPPFLAGS += -DSMARTCARD
endif

MANPAGE_LANGS := zh_TW zh_CN

EXT ?=

all: ldid$(EXT)

%.cpp.o: %.cpp
	$(CXX) -c -std=c++11 $(CXXFLAGS) $(LIBCRYPTO_INCLUDES) $(LIBPLIST_INCLUDES) $(CPPFLAGS) -I. -DLDID_VERSION=\"$(VERSION)\" $< -o $@

ldid$(EXT): $(SRC:%=%.o)
	$(CXX) -o $@ $^ $(LDFLAGS) $(LIBCRYPTO_LIBS) $(LIBPLIST_LIBS) $(LIBS)

install: all
	$(INSTALL) -d $(DESTDIR)$(BINDIR)/
	$(INSTALL) -m755 ldid $(DESTDIR)$(BINDIR)/ldid
	$(LN) -sf ldid $(DESTDIR)$(BINDIR)/ldid2
	$(INSTALL) -d $(DESTDIR)$(MANDIR)/man1/
	$(INSTALL) -m644 docs/ldid.1 $(DESTDIR)$(MANDIR)/man1/ldid.1
	for lang in $(MANPAGE_LANGS); do \
		$(INSTALL) -d $(DESTDIR)$(MANDIR)/$$lang/man1/; \
		$(INSTALL) -m644 docs/ldid.$$lang.1 $(DESTDIR)$(MANDIR)/$$lang/man1/ldid.1; \
	done

clean:
	rm -rf ldid$(EXT) *.o

.PHONY: all clean install
