#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "arg.h"
#include "db.h"
#include "libs.h"
#include "log.h"
#include "dep.h"
#include "tmpasm_scconfig.h"

#define version "2.0.1"

int find_sul_libjpeg(const char *name, int logdepth, int fatal)
{
        const char *test_c =
                NL "#include <stdio.h>"
                NL "#include <stdlib.h>"
                NL "#include <jpeglib.h>"
                NL ""
                NL "int main()"
                NL "{"
                NL "     struct jpeg_compress_struct cinfo;"
                NL "     struct jpeg_error_mgr jerr;"
                NL "     jerr.error_exit = NULL;"
                NL "     cinfo.err = jpeg_std_error(&jerr);"
                NL "     jpeg_create_compress(&cinfo);"
                NL "     jpeg_destroy_compress(&cinfo);"
                NL "     if(jerr.error_exit)"
                NL "         puts(\"OK\");"
                NL "     return 0;"
                NL "}"
                NL;

        const char *node = "libs/sul/libjpeg";

        if (require("cc/cc", logdepth, fatal))
                return 1;

        report("Checking for libjpeg... ");

        if (try_icl_pkg_config(logdepth, node, test_c, NULL, "libjpeg", NULL))
                return 0;

        if (try_icl(logdepth, node, test_c, NULL, NULL, "-ljpeg"))
                return 0;

        return try_fail(logdepth, node);
}

/* --aqua: native macOS build against Aqua Tk, all libraries from Homebrew */

/* install prefix of a Homebrew formula; NULL if it lacks file 'probe' */
static char *aqua_brew_prefix(const char *formula, const char *probe)
{
        char *cmd, *out = NULL, *nl, *prefix, *path;

        cmd = str_concat("", "HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 brew --prefix ", formula, NULL);
        if ((run_shell(1, cmd, &out) == 0) && (out != NULL) && (*out == '/')) {
                nl = strchr(out, '\n');
                if (nl != NULL)
                        *nl = '\0';
                prefix = strclone(out);
        }
        else
                prefix = str_concat("", "/opt/homebrew/opt/", formula, NULL);
        free(cmd);
        free(out);

        path = str_concat("/", prefix, probe, NULL);
        if (!is_file(path)) {
                free(prefix);
                prefix = NULL;
        }
        free(path);
        return prefix;
}

/* value of NAME='value' in a tclConfig.sh / tkConfig.sh; "" if absent */
static char *aqua_cfgvar(const char *file, const char *name)
{
        char *buf, *s, *e, *res;
        size_t len = strlen(name);

        buf = load_file(file);
        if (buf == NULL)
                return strclone("");
        for(s = buf; s != NULL; s = strchr(s, '\n')) {
                if (*s == '\n')
                        s++;
                if ((strncmp(s, name, len) == 0) && (s[len] == '=') && (s[len+1] == '\'')) {
                        s += len + 2;
                        e = strchr(s, '\'');
                        if (e != NULL)
                                *e = '\0';
                        res = strclone(s);
                        free(buf);
                        return res;
                }
        }
        free(buf);
        return strclone("");
}

static int aqua_icl(const char *node, const char *test_c, const char *cflags, const char *ldflags)
{
        report("Checking for %s... ", node);
        if (try_icl(1, node, test_c, NULL, cflags, ldflags))
                return 0;
        report("not usable\n");
        report("\nERROR: --aqua: %s does not compile or run with\n  %s %s\nDetails in scconfig/config.log\n", node, cflags, ldflags);
        return 1;
}

/* Fill the tcl, tk, cairo, libjpeg, xpm nodes so that the generic detectors
   are skipped (no X11, no pkg-config); set /local/xschem/bison and objcflags */
static int find_aqua(void)
{
        const char *test_tk =
                NL "#include <stdio.h>"
                NL "#include <tk.h>"
                NL "int main() {"
                NL "     if (Tk_GetNumMainWindows() == 0)"
                NL "         puts(\"OK\");"
                NL "     return 0;"
                NL "}"
                NL;
        const char *test_cairo =
                NL "#include <stdio.h>"
                NL "#include <cairo.h>"
                NL "int main() {"
                NL "     if (cairo_image_surface_create(CAIRO_FORMAT_RGB24, 100, 100) != NULL)"
                NL "         puts(\"OK\");"
                NL "     return 0;"
                NL "}"
                NL;
        const char *test_jpeg =
                NL "#include <stdio.h>"
                NL "#include <jpeglib.h>"
                NL "int main() {"
                NL "     struct jpeg_error_mgr jerr;"
                NL "     if (jpeg_std_error(&jerr) != NULL)"
                NL "         puts(\"OK\");"
                NL "     return 0;"
                NL "}"
                NL;
        char *tk, *cairo, *jpeg, *bison, *missing, *tmp, *inc, *lib, *test_ldflags;
        char *tclcfg, *tkcfg, *tcl_lib, *tcl_stub, *tcl_major, *tk_lib, *tk_stub;
        char *tcl_cflags, *tcl_ldflags, *tk_cflags, *tk_ldflags, *cairo_cflags, *cairo_ldflags, *jpeg_cflags, *jpeg_ldflags;
        const char *opt;
        int err = 0;

        report("Native macOS (Aqua) build: locating Homebrew packages\n");
        if (get("/local/xschem/aqua-tk") != NULL) {
                tk = str_concat("", get("/local/xschem/aqua-tk"), "/lib/tkConfig.sh", NULL);
                if (!is_file(tk)) {
                        report("\nERROR: --aqua-tk: %s not found\n", tk);
                        free(tk);
                        return 1;
                }
                free(tk);
                tk = strclone(get("/local/xschem/aqua-tk"));
        }
        else
                tk = aqua_brew_prefix("tcl-tk@8", "lib/tkConfig.sh");
        cairo = aqua_brew_prefix("cairo", "include/cairo/cairo.h");
        jpeg = aqua_brew_prefix("jpeg-turbo", "include/jpeglib.h");
        bison = aqua_brew_prefix("bison", "bin/bison");

        missing = strclone("");
        if (tk == NULL)    { tmp = str_concat(" ", missing, "tcl-tk@8", NULL);   free(missing); missing = tmp; }
        if (cairo == NULL) { tmp = str_concat(" ", missing, "cairo", NULL);      free(missing); missing = tmp; }
        if (jpeg == NULL)  { tmp = str_concat(" ", missing, "jpeg-turbo", NULL); free(missing); missing = tmp; }
        if (bison == NULL) { tmp = str_concat(" ", missing, "bison", NULL);      free(missing); missing = tmp; }
        if (*missing != '\0') {
                report("\nERROR: --aqua needs Homebrew packages that are not installed. Install them with:\n\n  brew install%s\n\n", missing);
                return 1;
        }
        free(missing);
        report(" tcl/tk:     %s\n cairo:      %s\n jpeg-turbo: %s\n bison:      %s/bin/bison\n", tk, cairo, jpeg, bison);

        /* Tcl/Tk: library names from tclConfig.sh/tkConfig.sh (Tk 8.6: -ltk8.6, Tk 9: -ltcl9tk9.1);
           aqua.m calls Tk_MacOSX* through the stubs tables, so the stub libraries are linked too */
        tclcfg = str_concat("", tk, "/lib/tclConfig.sh", NULL);
        tkcfg = str_concat("", tk, "/lib/tkConfig.sh", NULL);
        tcl_lib = aqua_cfgvar(tclcfg, "TCL_LIB_FLAG");
        tcl_stub = aqua_cfgvar(tclcfg, "TCL_STUB_LIB_FLAG");
        tcl_major = aqua_cfgvar(tclcfg, "TCL_MAJOR_VERSION");
        tk_lib = aqua_cfgvar(tkcfg, "TK_LIB_FLAG");
        tk_stub = aqua_cfgvar(tkcfg, "TK_STUB_LIB_FLAG");
        inc = str_concat("", tk, "/include/tcl-tk/tk.h", NULL);
        if (is_file(inc)) {
                free(inc);
                inc = str_concat("", tk, "/include/tcl-tk", NULL);
        }
        else {
                free(inc);
                inc = str_concat("", tk, "/include", NULL);
        }
        lib = str_concat("", tk, "/lib", NULL);
        /* tcl.h of Tcl 9 uses 'inline', not a C89 keyword */
        tcl_cflags = str_concat("", "-I", inc, (atoi(tcl_major) >= 9) ? " -Dinline=__inline__" : "", NULL);
        tcl_ldflags = str_concat("", "-L", lib, " ", tcl_lib, " ", tcl_stub, NULL);
        tk_cflags = strclone("-DXSCHEM_AQUA -DMAC_OSX_TK");
        tk_ldflags = str_concat(" ", tk_lib, tk_stub, "-framework Cocoa", NULL);
        tmp = str_concat(" ", tcl_cflags, tk_cflags, NULL);
        test_ldflags = str_concat(" ", tcl_ldflags, tk_ldflags, NULL);
        if (aqua_icl("libs/script/tk", test_tk, tmp, test_ldflags) != 0)
                return 1;
        free(tmp);
        free(test_ldflags);
        /* the test stored tcl+tk flags in libs/script/tk; split them so each lib is linked once */
        put("libs/script/tcl/presents", strue);
        put("libs/script/tcl/includes", "");
        put("libs/script/tcl/cflags", tcl_cflags);
        put("libs/script/tcl/ldflags", tcl_ldflags);
        put("libs/script/tk/includes", "");
        put("libs/script/tk/cflags", tk_cflags);
        put("libs/script/tk/ldflags", tk_ldflags);

        cairo_cflags = str_concat("", "-I", cairo, "/include/cairo", NULL);
        cairo_ldflags = str_concat("", "-L", cairo, "/lib -lcairo", NULL);
        err |= aqua_icl("libs/gui/cairo", test_cairo, cairo_cflags, cairo_ldflags);
        jpeg_cflags = str_concat("", "-I", jpeg, "/include", NULL);
        jpeg_ldflags = str_concat("", "-L", jpeg, "/lib -ljpeg", NULL);
        err |= aqua_icl("libs/sul/libjpeg", test_jpeg, jpeg_cflags, jpeg_ldflags);
        if (err)
                return 1;

        /* no Xpm: icon.c is not used on Aqua */
        put("libs/gui/xpm/presents", sfalse);
        put("libs/gui/xpm/includes", "");
        put("libs/gui/xpm/cflags", "");
        put("libs/gui/xpm/ldflags", "");

        tmp = str_concat("", bison, "/bin/bison", NULL);
        put("/local/xschem/bison", tmp);
        free(tmp);

        /* aqua.m is Objective-C: own flags, without -std=c89 -pedantic */
        if (istrue(get("/local/xschem/debug")))
                opt = "-g -O0";
        else if (istrue(get("/local/xschem/symbols")))
                opt = "-O2 -g";
        else
                opt = "-O2";
        tmp = str_concat(" ", opt, "-Wall -fno-objc-arc", jpeg_cflags, cairo_cflags, tk_cflags, tcl_cflags, NULL);
        put("/local/xschem/objcflags", tmp);
        free(tmp);
        return 0;
}


static void help(void)
{
        printf("./configure: configure xschem.\n");
        printf("\n");
        printf("Usage: ./configure [options]\n");
        printf("\n");
        printf("xschem-specific options:\n");
        printf(" --prefix=path             change installation prefix from /usr/local to path\n");
        printf(" --debug                   build full debug version (-g -O0)\n");
        printf(" --profile                 build profiling version if available (-pg)\n");
        printf(" --symbols                 include symbols (add -g, but no -O0)\n");
        printf(" --user-conf-dir           change the user conf dir (e.g. ~/.xschem)\n");
        printf(" --user-lib-path           set the user library path\n");
        printf(" --sys-lib-path            set the system library path\n");
        printf(" --xschem-lib-path         overrides the final list of library search paths\n");
        printf(" /arg/tk-version=8.x       force detecting a specific version of tcl/tk\n");
        printf(" --aqua                    macOS: native build on Aqua Tk (no X11), libraries from\n");
        printf("                           Homebrew: brew install tcl-tk@8 cairo jpeg-turbo bison\n");
        printf(" --aqua-tk=path            macOS: Tcl/Tk prefix (with lib/tkConfig.sh) instead of\n");
        printf("                           Homebrew tcl-tk@8; implies --aqua\n");

        printf("\n");
        help_default_args(stdout, "");
}

/* Runs when a custom command line argument is found
   returns true if no further argument processing should be done */
int hook_custom_arg(const char *key, const char *value)
{
        if (strcmp(key, "prefix") == 0) {
                report("Setting prefix to '%s'\n", value);
                put("/local/xschem/prefix", strclone(value));
                return 1;
        }
        if (strcmp(key, "debug") == 0) {
                put("/local/xschem/debug", strue);
                return 1;
        }
        if (strcmp(key, "profile") == 0) {
                put("/local/xschem/profile", strue);
                return 1;
        }
        if (strcmp(key, "symbols") == 0) {
                put("/local/xschem/symbols", strue);
                return 1;
        }
        if (strcmp(key, "user-conf-dir") == 0) {
                put("/local/xschem/user-conf-dir", value);
                return 1;
        }
        if (strcmp(key, "user-lib-path") == 0) {
                put("/local/xschem/user-lib-path", value);
                return 1;
        }
        if (strcmp(key, "sys-lib-path") == 0) {
                put("/local/xschem/sys-lib-path", value);
                return 1;
        }
        if (strcmp(key, "xschem-lib-path") == 0) {
                put("/local/xschem/xschem-lib-path", value);
                return 1;
        }
        if (strcmp(key, "aqua") == 0) {
                put("/local/xschem/aqua", strue);
                return 1;
        }
        if (strcmp(key, "aqua-tk") == 0) {
                put("/local/xschem/aqua", strue);
                put("/local/xschem/aqua-tk", value);
                return 1;
        }
        if (strcmp(key, "help") == 0) {
                help();
                exit(0);
        }

        return 0;
}


/* Runs before anything else */
int hook_preinit()
{
        return 0;
}

/* Runs after initialization */
int hook_postinit()
{
        /* libjpeg detection */
        dep_add("libs/sul/libjpeg/*",     find_sul_libjpeg);

        db_mkdir("/local");
        db_mkdir("/local/xschem");

        /* DEFAULTS */
        put("/local/xschem/prefix", "/usr/local");
        put("/local/xschem/debug", sfalse);
        put("/local/xschem/profile", sfalse);
        put("/local/xschem/symbols", sfalse);
        put("/local/xschem/user-conf-dir", "~/.xschem");
        put("/local/xschem/aqua", sfalse);
        put("/local/xschem/bison", "bison");

        return 0;
}

/* Runs after all arguments are read and parsed */
int hook_postarg()
{

        if (get("/local/xschem/user-lib-path") == NULL) {
                put("/local/xschem/user-lib-path", get("/local/xschem/user-conf-dir"));
                append("/local/xschem/user-lib-path", "/xschem_library");
        }

        if (get("/local/xschem/sys-lib-path") == NULL) {
                put("/local/xschem/sys-lib-path", get("/local/xschem/prefix"));
                append("/local/xschem/sys-lib-path", "/");
                append("/local/xschem/sys-lib-path", "share/xschem/xschem_library/devices");
        }

        if (get("/local/xschem/xschem-lib-path") == NULL) {
                put("/local/xschem/xschem-lib-path", "\\\n    \"");
                append("/local/xschem/xschem-lib-path", get("/local/xschem/user-lib-path"));
                append("/local/xschem/xschem-lib-path", "\",\\\n    ");

                append("/local/xschem/xschem-lib-path", "\"");
                append("/local/xschem/xschem-lib-path", get("/local/xschem/sys-lib-path"));
                append("/local/xschem/xschem-lib-path", "\",\\\n    ");

                append("/local/xschem/xschem-lib-path", "\"");
                append("/local/xschem/xschem-lib-path", get("/local/xschem/prefix"));
                append("/local/xschem/xschem-lib-path", "/");
                append("/local/xschem/xschem-lib-path", "share/doc/xschem/examples");
                append("/local/xschem/xschem-lib-path", "\",\\\n    ");

                append("/local/xschem/xschem-lib-path", "\"");
                append("/local/xschem/xschem-lib-path", get("/local/xschem/prefix"));
                append("/local/xschem/xschem-lib-path", "/");
                append("/local/xschem/xschem-lib-path", "share/doc/xschem/ngspice");
                append("/local/xschem/xschem-lib-path", "\",\\\n    ");

                append("/local/xschem/xschem-lib-path", "\"");
                append("/local/xschem/xschem-lib-path", get("/local/xschem/prefix"));
                append("/local/xschem/xschem-lib-path", "/");
                append("/local/xschem/xschem-lib-path", "share/doc/xschem/ngspice_verilog_cosim");
                append("/local/xschem/xschem-lib-path", "\",\\\n    ");

                append("/local/xschem/xschem-lib-path", "\"");
                append("/local/xschem/xschem-lib-path", get("/local/xschem/prefix"));
                append("/local/xschem/xschem-lib-path", "/");
                append("/local/xschem/xschem-lib-path", "share/doc/xschem/logic");
                append("/local/xschem/xschem-lib-path", "\",\\\n    ");

                append("/local/xschem/xschem-lib-path", "\"");
                append("/local/xschem/xschem-lib-path", get("/local/xschem/prefix"));
                append("/local/xschem/xschem-lib-path", "/");
                append("/local/xschem/xschem-lib-path", "share/doc/xschem/xschem_simulator");
                append("/local/xschem/xschem-lib-path", "\",\\\n    ");

                append("/local/xschem/xschem-lib-path", "\"");
                append("/local/xschem/xschem-lib-path", get("/local/xschem/prefix"));
                append("/local/xschem/xschem-lib-path", "/");
                append("/local/xschem/xschem-lib-path", "share/doc/xschem/generators");
                append("/local/xschem/xschem-lib-path", "\",\\\n    ");

                append("/local/xschem/xschem-lib-path", "\"");
                append("/local/xschem/xschem-lib-path", get("/local/xschem/prefix"));
                append("/local/xschem/xschem-lib-path", "/");
                append("/local/xschem/xschem-lib-path", "share/doc/xschem/inst_sch_select");
                append("/local/xschem/xschem-lib-path", "\",\\\n    ");

                append("/local/xschem/xschem-lib-path", "\"");
                append("/local/xschem/xschem-lib-path", get("/local/xschem/prefix"));
                append("/local/xschem/xschem-lib-path", "/");
                append("/local/xschem/xschem-lib-path", "share/doc/xschem/binto7seg");
                append("/local/xschem/xschem-lib-path", "\",\\\n    ");

                append("/local/xschem/xschem-lib-path", "\"");
                append("/local/xschem/xschem-lib-path", get("/local/xschem/prefix"));
                append("/local/xschem/xschem-lib-path", "/");
                append("/local/xschem/xschem-lib-path", "share/doc/xschem/pcb");
                append("/local/xschem/xschem-lib-path", "\",\\\n    ");

                append("/local/xschem/xschem-lib-path", "\"");
                append("/local/xschem/xschem-lib-path", get("/local/xschem/prefix"));
                append("/local/xschem/xschem-lib-path", "/");
                append("/local/xschem/xschem-lib-path", "share/doc/xschem/rom8k");
                append("/local/xschem/xschem-lib-path", "\",\\\n    ");

                append("/local/xschem/xschem-lib-path", "\"");
                append("/local/xschem/xschem-lib-path", get("/local/xschem/prefix"));
                append("/local/xschem/xschem-lib-path", "/");
                append("/local/xschem/xschem-lib-path", "share/doc/xschem/analyses");
                append("/local/xschem/xschem-lib-path", "\",\\\n    ");

                append("/local/xschem/xschem-lib-path", "NULL");

        }
        return 0;
}

/* Runs when things should be detected for the compilation host system (commands
   that will be executed on host and will produce files to be used on host) */
int hook_detect_host()
{
        return 0;
}

static void disable_xcb(void)
{
        put("libs/gui/xcb/presents", "");
        put("libs/gui/xcb/includes", "");
        put("libs/gui/xcb/cflags", "");
        put("libs/gui/xcb/ldflags", "");
        put("libs/gui/xcb_render/presents", "");
        put("libs/gui/xcb_render/includes", "");
        put("libs/gui/xcb_render/cflags", "");
        put("libs/gui/xcb_render/ldflags", "");
        put("libs/gui/xgetxcbconnection/presents", "");
        put("libs/gui/xgetxcbconnection/includes", "");
        put("libs/gui/xgetxcbconnection/cflags", "");
        put("libs/gui/xgetxcbconnection/ldflags", "");
}

/* Runs when things should be detected for the host->target system (commands
   that will be executed on host but will produce files to be used on target) */
int hook_detect_target()
{
        require("cc/fpic",  0, 0);

        { /* need to set debug flags here to make sure libs are detected with the modified cflags; -ansi matters in what #defines we need for some #includes */
                const char *tmp, *fpic, *debug;
                fpic = get("/target/cc/fpic");
                if (fpic == NULL) fpic = "";
                debug = get("/arg/debug");
                if (debug == NULL) debug = "";
                tmp = str_concat(" ", fpic, debug, NULL);
                put("/local/global_cflags", tmp);

                /* for --debug mode, use -ansi -pedantic for all detection */
                if (istrue(get("/local/xschem/debug"))) {
                        append("cc/cflags", " -g -O0 -Wconversion -Wno-sign-conversion");
                        if (require("cc/argstd/Wall",  0, 0) == 0) {
                                append("cc/cflags", " ");
                                append("cc/cflags", get("cc/argstd/Wall"));
                        }

                        if (require("cc/argstd/std_c89",  0, 0) == 0) {
                               append("cc/cflags", " ");
                               append("cc/cflags", get("cc/argstd/std_c89"));
                        }

                        if (require("cc/argstd/pedantic",  0, 0) == 0) {
                                append("cc/cflags", " ");
                                append("cc/cflags", get("cc/argstd/pedantic"));
                        }
                }
                else {
                        append("cc/cflags", " -O2");
                        if (istrue(get("/local/xschem/symbols")))
                                append("cc/cflags", " -g");
                }

                if (istrue(get("/local/xschem/profile"))) {
                        if (require("cc/argstd/pg",  0, 0) == 0) {
                                append("cc/cflags", " ");
                                append("cc/cflags", get("cc/argstd/pg"));
                                append("cc/ldflags", " ");
                                append("cc/ldflags", get("cc/argstd/pg"));
                        }
                        /* no-pie no more needed it seems */
                        /*
                        if (require("cc/argstd/no-pie",  0, 0) == 0) {
                                append("cc/cflags", " ");
                                append("cc/cflags", get("cc/argstd/no-pie"));
                        }
                        */
                }
        }

        if (require("libs/io/popen/*",  0, 0) != 0) {
                if (require("libs/proc/fork/*",  0, 0) == 0) /* pipe is used together with fork, both needed */
                        require("libs/io/pipe/*",  0, 0);
        }

        require("libs/io/dup2/*",  0, 0); /* Stefan: query dup2() availability */
        require("parsgen/flex/presents",  0, 1);
        require("parsgen/bison/presents",  0, 1);
        if (istrue(get("/local/xschem/aqua")) && (find_aqua() != 0)) /* presets the libs required below */
                exit(1);
        require("libs/script/tk/*",  0, 1); /* this will also bring libs/script/tcl/* */
        require("fstools/awk",  0, 1);
        require("libs/gui/xpm/*",  0, 1);
        require("libs/gui/cairo/*",  0, 0);
        /* require("libs/tty/readline/*",  0, 0); */
        require("libs/sul/libjpeg/*",  0, 0);
        /* require("libs/types/stdint/*",  0, 0); */
        require("sys/types/size/4_u_int", 0, 1);
        require("sys/types/size/4_s_int", 0, 1);

        if (istrue(get("/local/xschem/aqua")) || (require("libs/gui/cairo-xcb/*",  0, 0) != 0)) {
                put("libs/gui/xcb/presents", sfalse);
        }
        else if (require("libs/gui/xcb/*",  0, 0) == 0) {
                /* if xcb is used, the code requires these: */
                require("libs/gui/xgetxcbconnection/*", 0, 0);
                if (!istrue(get("libs/gui/xgetxcbconnection/presents"))) {
                        report("Disabling xcb because xgetxcbconnection is not found...\n");
                        disable_xcb();
                }
                else {
                        require("libs/gui/xcb_render/*", 0, 0);
                        if (!istrue(get("libs/gui/xcb_render/presents"))) {
                                report("Disabling xcb because xcb_render is not found...\n");
                                disable_xcb();
                        }
                }
        }

        return 0;
}

/* Runs when things should be detected for the runtime system  (commands
   that will be executed only on the target, never on host) */
int hook_detect_runtime()
{
        return 0;
}

static const char *isok(int retval, int *accumulator)
{
        *accumulator |= retval;
        return (retval == 0) ? "ok" : "ERROR";
}

/* Runs after detection hooks, should generate the output (Makefiles, etc.) */
int hook_generate()
{
        int generr = 0;

        printf("\n--- Generating build and config files\n");
        printf("config.h:              %s\n", isok(tmpasm("..", "config.h.in", "config.h"), &generr));
        printf("Makefile.conf:         %s\n", isok(tmpasm("..", "Makefile.conf.in", "Makefile.conf"), &generr));
        printf("doc/manpages/xschem.1: %s\n", isok(tmpasm("../doc/manpages", "xschem.1.in", "xschem.1"), &generr));
        printf("src/Makefile:          %s\n", isok(tmpasm("../src", "Makefile.in", "Makefile"), &generr));

        if (!generr) {
                printf("\n\n");
                printf("=====================\n");
                printf("Configuration summary\n");
                printf("=====================\n");

                printf("\nCompilation:\n");
                printf(" CC:        %s\n", get("/target/cc/cc"));
                printf(" debug:     %s\n", istrue(get("/local/xschem/debug")) ? "yes" : "no");
                printf(" profiling: %s\n", istrue(get("/local/xschem/profile")) ? "yes" : "no");
                if (istrue(get("/local/xschem/aqua")))
                        printf(" aqua:      yes (native macOS, no X11)\n");

                printf("\nPaths:\n");
                printf(" prefix:        %s\n", get("/local/xschem/prefix"));
                printf(" user-conf-dir: %s\n", get("/local/xschem/user-conf-dir"));
                printf(" user-lib-path: %s\n", get("/local/xschem/user-lib-path"));
                printf(" sys-lib-path:  %s\n", get("/local/xschem/sys-lib-path"));

                printf("\nLibs & features:\n");
                /*
                 * printf(" stdint:    %s\n", istrue(get("/target/libs/types/stdint/presents")) ? "yes" : "no");
                 */
                printf(" tcl:       %s\n", get("/target/libs/script/tcl/ldflags"));
                printf(" tk:        %s\n", get("/target/libs/script/tk/ldflags"));
                printf(" cairo:     %s\n", istrue(get("/target/libs/gui/cairo/presents")) ? "yes" : "no");
                /* printf(" readline:  %s\n", istrue(get("/target/libs/tty/readline/presents")) ? "yes" : "no"); */
                printf(" libjpeg:   %s\n", istrue(get("/target/libs/sul/libjpeg/presents")) ? "yes" : "no");
                printf(" xcb:       %s\n", istrue(get("/target/libs/gui/xcb/presents")) ? "yes" : "no");

                printf("\nConfiguration complete, ready to compile.\n\n");
        }

        return 0;
}

/* Runs before everything is uninitialized */
void hook_preuninit()
{
}

/* Runs at the very end, when everything is already uninitialized */
void hook_postuninit()
{
}

