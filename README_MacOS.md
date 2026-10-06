# Build instructions for macOS (native Aqua build)
The native build draws through Tk's macOS (Aqua) backend. It needs neither XQuartz nor an
X11 library, and all libraries come from Homebrew.

## Prerequisites
Install the Xcode command line tools (`xcode-select --install`) and Homebrew (https://brew.sh),
then the required packages:

```
brew install tcl-tk@8 cairo jpeg-turbo bison
```

Tcl/Tk 8.6 (`tcl-tk@8`) is required. Homebrew's `bison` is needed because the bison shipped
with macOS (2.3) is too old; it does not have to be on `PATH`.

## xschem compilation

```
git clone https://github.com/StefanSchippers/xschem.git
cd xschem
./configure --aqua
make
```

`--aqua` locates the Homebrew packages with `brew --prefix` (or under `/opt/homebrew/opt` when
`brew` is not on `PATH`) and skips the X11, Xpm and xcb detection, so libraries from MacPorts or
XQuartz are not used even when they are installed. If a package is missing, configure stops and
prints the `brew install` command for it. It can be combined with the other configure options,
for example `--debug` or `--prefix`. To build against a different Tcl/Tk installation, give its
prefix (the directory that holds `lib/tclConfig.sh` and `lib/tkConfig.sh`):

```
./configure --aqua-tk=/path/to/tcl-tk
```

xschem can be run from the source tree without installing it:

```
cd src
./xschem
```

To install it, set the prefix at configure time (default `/usr/local`):

```
./configure --aqua --prefix=/Users/$(whoami)/xschem-macos
make
make install
```

## Application bundle
`XSchemMac/make_app.sh` packages the built `src/xschem` into a self-contained `Xschem.app`
intended to run on other Macs without Homebrew (verified so far only on the build machine, with
a scrubbed environment):

```
XSchemMac/make_app.sh            # -> XSchemMac/build/Xschem.app
```

See [XSchemMac/README.md](XSchemMac/README.md) for the bundle layout, signing and how to
give the app to someone else.

---

# X11 build with XQuartz
The instructions below build xschem as an X11 application that runs under XQuartz. Run
`./configure` without `--aqua` for this build.

---

# Build instructions for MacOS 'Catalina'
Install the latest XQuartz from XQuartz.org.
Install the latest tcl, tk and cairo from MacPorts. 

## xschem compilation
Let's use a recent xschem repository and install it on ~/xschem-macos  

```
git clone https://github.com/StefanSchippers/xschem.git  
cd xschem  
## set prefix to the base directory where xschem and his support files will be installed
## default if unspecified is /usr/local
./configure --prefix=/Users/$(whoami)/xschem-macos
```

Finally, we compile and install the application.  

```
make
make install
```

The application will be placed in `/Users/$(whoami)/xschem-macos/bin` and can be started with
`./xschem` in that folder.

---

# Build Instructions for MacOS 'Big Sur'
In order to compile xschem properly on MacOS, we always need to reference the X libraries from XQuartz
and change some compilation variables. The following dependencies are required:
- XQuartz: https://www.xquartz.org/releases/XQuartz-2.7.11.html
- Tcl: https://prdownloads.sourceforge.net/tcl/tcl8.6.10-src.tar.gz
- Tk: https://prdownloads.sourceforge.net/tcl/tk8.6.10-src.tar.gz  

The first step is to install XQuartz and then compile Tcl and Tk. Nothing special on compiling these two, but
we need to specify the X libraries from XQuartz when compiling Tk. Let's use the path
/usr/local/opt/tcl-tk as destination folder.
## Tcl compilation
Extract the Tcl sources and then go to the unix folder:

NOTE: ensure the install directory (/usr/local/opt/tcl-tk) is not already used by official MacOS libraries, if this is the case use another location. This applies for Tk build as well.

```
cd <extracted-folder>/unix
./configure --prefix=/usr/local/opt/tcl-tk  
make
make install
```

## Tk compilation
Same procedure as Tcl, but we need to specificy the Tcl and X libraries paths. XQuartz is installed on
/opt/X11 , so we do:  

NOTE: before running 'make' inspect the Makefile and ensure the LIB_RUNTIME_DIR is set as follows. Make the correction if not:
```
LIB_RUNTIME_DIR         = $(libdir)
```

```
cd <extracted-folder>/unix
./configure --prefix=/usr/local/opt/tcl-tk \
--with-tcl=/usr/local/opt/tcl-tk/lib --with-x \
--x-includes=/opt/X11/include --x-libraries=/opt/X11/lib  
make
make install  
```

## xschem compilation
Besides referencing the X libraries, we need to also point to the Tcl/Tk installation path. Let's use a recent
xschem repository and install it on ~/xschem-macos (adapt this to your username):  

```
git clone https://github.com/StefanSchippers/xschem.git  
cd xschem  
## set prefix to the base directory where xschem and his support files will be installed
## default if unspecified is /usr/local
./configure --prefix=/Users/$(whoami)/xschem-macos
```

Before building the application, we need to adjust `Makefile.conf` because the current configure
script doesn't support custom flags. So we need to replace the CFLAGS and LDFLAGS variables in that file
as below:  

```
CFLAGS=-I/opt/X11/include -I/opt/X11/include/cairo \
-I/usr/local/opt/tcl-tk/include -O2
LDFLAGS=-L/opt/X11/lib -L/usr/local/opt/tcl-tk/lib -lm -lcairo \
-lX11 -lXrender -lxcb -lxcb-render -lX11-xcb -lXpm -ltcl8.6 -ltk8.6
```

Finally, we compile and install the application.  

```
make
make install
```

The application will be placed in `/Users/$(whoami)/xschem-macos/bin` and can be started with
`./xschem` in that folder.
