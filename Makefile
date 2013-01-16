
GENCFILE=code.c

INSTALLDIR=/usr/local
INSTALLLIB=$(INSTALLDIR)/lib

CLANGINCLUDE=/usr/include/clang/3.1/include

INCLUDE=/usr/include/lua5.1
LIBS=-lc -llua5.1
LUA=lua5.1

CFLAGS=-O2 -fpic

SONAME=stat.so
LIBNAME=$(SONAME)

$(LIBNAME):     code.o
		$(CC) -shared -Wl,-soname,$(SONAME) -o $(LIBNAME) code.o $(LIBS)

code.o:     	$(GENCFILE)
		$(CC) $(CFLAGS) -I$(INCLUDE) -c $(GENCFILE) -o code.o

code.c:		parse.lua stat.c
		C_INCLUDE_PATH=$(CLANGINCLUDE) $(LUA) parse.lua stat.c

all:            $(LIBNAME)

default:        all

test:		test.lua $(LIBNAME)
		$(LUA) test.lua

clean:          
		rm -f *~ *.o $(LIBNAME) $(GENCFILE)

install:        $(LIBNAME)
		install -d $(INSTALLLIB)
		install $(LIBNAME) $(INSTALLLIB)
		ldconfig $(INSTALLLIB)


