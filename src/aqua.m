/* File: aqua.m
 *
 * This file is part of XSCHEM,
 * a schematic capture and Spice/Vhdl/Verilog netlisting tool for circuit
 * simulation.
 * Copyright (C) 2026 Thomas Ferreira de Lima
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

/* Display layer of the native macOS build (XSCHEM_AQUA), used with Aqua Tk instead of an
 * X server. xschem keeps calling Xlib, which Tk emulates on macOS as it does on Windows.
 *
 * - Points: xschem works in points (window size, pointer coordinates, line widths) as on
 *   any other platform. A pixmap made by aqua_create_pixmap() is a Tk pixmap of 'scale'
 *   pixels per point (the window backing scale, 2 on Retina) whose CoreGraphics context
 *   carries a matching scale transform, so Tk's Xlib emulation draws at device resolution.
 * - Cairo shares the pixels: a Tk pixmap is a CGBitmapContext in cairo's ARGB32 layout, and
 *   each registered pixmap has a cairo image surface on the same memory (device scale =
 *   'scale'). The memory is reference counted, so a surface never outlives it.
 * - Front buffers: Aqua Tk shows drawing on a window only while AppKit redraws that window,
 *   and xschem draws on its window at any time. The macros in aqua.h redirect every Xlib
 *   call aimed at a window to the window's front buffer, a registered pixmap.
 * - Present: aqua_present() asks AppKit to redraw the window and, from inside that redraw,
 *   draws the front buffer into it. It runs on Expose events and, through aqua_flush(),
 *   at the end of every outermost xschem command (xschem_and_present() in xinit.c).
 *
 * Objective-C, compiled without -std=c89 so the system headers can be used. Tcl and Tk are
 * called through their stubs tables, because libtk 8.6 does not export
 * Tk_MacOSXGetCGContextForDrawable() and Tk_MacOSXGetNSWindowForDrawable(); aqua_init() sets
 * them up; the functions that draw or present run after it (aqua_nesting() and xserver_ok()
 * do not need it). This file does not include xschem.h:
 * its bookkeeping structures use calloc() and free(). */

#include "../config.h"
#define USE_TCL_STUBS
#define USE_TK_STUBS
#import <Cocoa/Cocoa.h>
#include <tcl.h>
#include <tk.h>
/* Private Tk header, installed with Tk: no public call returns the clip of a GC.
 * Used for TkpClipMask (what gc->clip_mask points to in Tk's Xlib emulation) and
 * TkClipBox(), see clip_to_gc() */
#include <tkInt.h>
#include <tkMacOSX.h>
#include <cairo.h>
#define AQUA_NO_REDIRECT
#include "aqua.h"

/* A pixmap made by aqua_create_pixmap() */
typedef struct AquaPix {
  Pixmap pixmap;
  CGContextRef cg;       /* one reference held by this entry */
  cairo_surface_t *sfc;  /* the surface holds its own reference to cg */
  double scale;          /* pixels per point */
  int width, height;     /* points */
  struct AquaPix *next;
} AquaPix;

/* The front buffer of a window */
typedef struct AquaFront {
  Window win;
  Tk_Window tkwin;
  AquaPix *pix;
  int dirty;             /* drawn on since last presented */
  int pending;           /* draw_front() queued */
  struct AquaFront *next;
} AquaFront;

/* Tk method that marks part of a view for the next redraw (Tk 8.6.10 and later) */
@interface NSView (XschemAquaTk)
- (void) addTkDirtyRect: (NSRect) rect;
@end

static Display *aqua_display = NULL;
static int *aqua_debug = NULL;
static double aqua_forced_scale = 0.0;
static AquaPix *pix_list = NULL;
static AquaFront *front_list = NULL;
static AquaFront *front_hit = NULL;    /* last window found */
static Drawable front_miss = 0;        /* last drawable that is not a window with front buffer */
static const cairo_user_data_key_t cg_key;
static void draw_front(ClientData cd);

static void dbg_aqua(int level, const char *fmt, ...)
{
  va_list ap;
  if(!aqua_debug || *aqua_debug < level) return;
  va_start(ap, fmt);
  vfprintf(stderr, fmt, ap);
  va_end(ap);
}

/* 1 if the process can open windows. This is the Aqua counterpart of the DISPLAY test of
 * the X11 build: there is no window server session in an ssh login, a launch daemon or a
 * sandbox without window server access, and xschem then starts without GUI. */
int xserver_ok(void)
{
  CFDictionaryRef session = CGSessionCopyCurrentDictionary(); /* NULL: no GUI session */
  if(!session) return 0;
  CFRelease(session);
  return 1;
}

void aqua_init(Tcl_Interp *interp, Display *display, int *debug_level)
{
  const char *s;
  aqua_display = display;
  aqua_debug = debug_level;
  if(!Tcl_InitStubs(interp, TCL_VERSION, 0) || !Tk_InitStubs(interp, TK_VERSION, 0)) {
    fprintf(stderr, "aqua_init(): can not initialize Tcl/Tk stubs: %s\n", Tcl_GetStringResult(interp));
    exit(1);
  }
  /* XSCHEM_AQUA_SCALE=n draws every window at n pixels per point, whatever its display.
   * For testing: 1 shows on a Retina display what a non-Retina display gets, and a value
   * that differs from the display exercises the backing scale change code. */
  s = getenv("XSCHEM_AQUA_SCALE");
  if(s) aqua_forced_scale = atof(s);
}

/* A process started from a shell is not launched as an application by Launch Services, so
 * macOS leaves it inactive and its window behind the terminal. Bring it to the front once at
 * startup, as a Finder launch does. The cooperative -[NSApplication activate] of macOS 14 is
 * ignored in that case; -activateIgnoringOtherApps: still works (macOS 26). */
void aqua_activate(void)
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  [NSApp activateIgnoringOtherApps:YES];
#pragma clang diagnostic pop
}

/* pixels per point of the display a window is on */
static double window_scale(Window win)
{
  NSWindow *w;
  double s;
  if(aqua_forced_scale > 0.0) return aqua_forced_scale;
  w = win ? (NSWindow *)Tk_MacOSXGetNSWindowForDrawable(win) : nil;
  s = w ? [w backingScaleFactor] : [[NSScreen mainScreen] backingScaleFactor];
  return s >= 1.0 ? s : 1.0;
}

/* ---------------------------------------------------------------- pixmaps */

static AquaPix *find_pix(Drawable d)
{
  AquaPix *p;
  for(p = pix_list; p; p = p->next) if(p->pixmap == d) return p;
  return NULL;
}

static void release_cg(void *cg)
{
  CGContextRelease((CGContextRef)cg);
}

/* cairo surface on the memory of a bitmap context, keeping the context alive */
static cairo_surface_t *bitmap_surface(CGContextRef cg, double scale)
{
  cairo_surface_t *sfc = cairo_image_surface_create_for_data(
      (unsigned char *)CGBitmapContextGetData(cg), CAIRO_FORMAT_ARGB32,
      (int)CGBitmapContextGetWidth(cg), (int)CGBitmapContextGetHeight(cg),
      (int)CGBitmapContextGetBytesPerRow(cg));
  cairo_surface_set_device_scale(sfc, scale, scale);
  CGContextRetain(cg);
  cairo_surface_set_user_data(sfc, &cg_key, cg, release_cg);
  return sfc;
}

/* native: 1 = pixmap for the window at its backing scale, 0 = one pixel per point */
Pixmap aqua_create_pixmap(Window win, int width, int height, int depth, int native)
{
  double scale = native ? window_scale(win) : 1.0;
  Pixmap pixmap;
  CGContextRef cg;
  AquaPix *p;

  if(width < 1) width = 1;
  if(height < 1) height = 1;
  pixmap = Tk_GetPixmap(aqua_display, win, (int)ceil(width * scale), (int)ceil(height * scale), depth);
  cg = (CGContextRef)Tk_MacOSXGetCGContextForDrawable(pixmap);
  /* A Tk pixmap is premultiplied ARGB32 in host byte order: cairo's CAIRO_FORMAT_ARGB32 */
  if(!cg || !CGBitmapContextGetData(cg) || CGBitmapContextGetBitsPerPixel(cg) != 32) {
    fprintf(stderr, "aqua_create_pixmap(): no 32 bit bitmap for pixmap\n");
    return pixmap;
  }
  /* Tk's Xlib emulation takes the pixmap height from the clip bounding box in user space,
   * so its flip to X coordinates works unchanged on top of this transform */
  CGContextScaleCTM(cg, scale, scale);
  p = (AquaPix *)calloc(1, sizeof(AquaPix));
  p->pixmap = pixmap;
  p->cg = CGContextRetain(cg);
  p->sfc = bitmap_surface(cg, scale);
  p->scale = scale;
  p->width = width;
  p->height = height;
  p->next = pix_list;
  pix_list = p;
  dbg_aqua(1, "aqua_create_pixmap(): %dx%d points, scale %g\n", width, height, scale);
  return pixmap;
}

void aqua_free_pixmap(Pixmap pixmap)
{
  AquaPix **pp, *p;
  if(!pixmap) return;
  for(pp = &pix_list; *pp; pp = &(*pp)->next) {
    if((*pp)->pixmap == pixmap) {
      p = *pp;
      *pp = p->next;
      cairo_surface_destroy(p->sfc); /* bitmap stays alive while other surfaces use it */
      CGContextRelease(p->cg);
      free(p);
      break;
    }
  }
  if(front_miss == pixmap) front_miss = 0;
  Tk_FreePixmap(aqua_display, pixmap);
}

/* New reference to the cairo surface on the pixmap memory; cairo_surface_destroy() it.
 * It keeps the memory alive (not the pixmap) if the pixmap is freed first.
 * A drawable not registered here means that aqua_create_pixmap() failed, or that a window
 * got no front buffer. The callers do not expect a failure (on X11 a cairo surface can be
 * made on any drawable), so they get a scratch surface: xschem keeps running, its cairo
 * drawing (text, images) is lost. */
cairo_surface_t *aqua_pixmap_surface(Pixmap pixmap)
{
  AquaPix *p = find_pix(pixmap);
  if(p) return cairo_surface_reference(p->sfc);
  fprintf(stderr, "aqua_pixmap_surface(): unknown pixmap, cairo drawing will not be visible\n");
  return cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1);
}

/* 1 if the pixmap was not made at the backing scale of the window */
int aqua_scale_mismatch(Window win, Pixmap pixmap)
{
  AquaPix *p = find_pix(pixmap);
  return p && fabs(p->scale - window_scale(win)) > 0.01;
}

/* ------------------------------------------------------------ front buffers */

static AquaFront *find_front(Drawable d)
{
  AquaFront *f;
  if(front_hit && front_hit->win == d) return front_hit;
  if(d == front_miss) return NULL;
  for(f = front_list; f; f = f->next) if(f->win == d) return front_hit = f;
  front_miss = d;
  return NULL;
}

/* window destroyed: free its front buffer, its id may be reused by any drawable */
static void front_event(ClientData cd, XEvent *ev)
{
  AquaFront **pp, *f = (AquaFront *)cd;
  if(ev->type != DestroyNotify) return;
  for(pp = &front_list; *pp; pp = &(*pp)->next) {
    if(*pp == f) {
      *pp = f->next;
      break;
    }
  }
  front_hit = NULL;
  front_miss = 0;
  dbg_aqua(1, "aqua: window %s destroyed, front buffer freed\n", Tk_PathName(f->tkwin));
  if(f->pending) Tcl_CancelIdleCall(draw_front, f);
  if(f->pix) aqua_free_pixmap(f->pix->pixmap);
  Tk_DeleteEventHandler(f->tkwin, StructureNotifyMask, front_event, f);
  free(f);
}

/* create the front buffer of a window, or remake it at the window size and scale */
void aqua_front_sync(Window win)
{
  AquaFront *f = find_front(win);
  Tk_Window tkwin;
  int w, h;
  double scale;
  Pixmap pixmap;

  if(!f) {
    tkwin = Tk_IdToWindow(aqua_display, win);
    if(!tkwin) return;
    f = (AquaFront *)calloc(1, sizeof(AquaFront));
    f->win = win;
    f->tkwin = tkwin;
    f->next = front_list;
    front_list = f;
    front_hit = NULL;
    front_miss = 0;
    Tk_CreateEventHandler(tkwin, StructureNotifyMask, front_event, f);
    dbg_aqua(1, "aqua: front buffer for window %s\n", Tk_PathName(tkwin));
  }
  w = Tk_Width(f->tkwin);
  h = Tk_Height(f->tkwin);
  if(w < 1) w = 1;
  if(h < 1) h = 1;
  scale = window_scale(win);
  if(!f->pix || f->pix->width != w || f->pix->height != h || f->pix->scale != scale) {
    if(f->pix) aqua_free_pixmap(f->pix->pixmap);
    pixmap = aqua_create_pixmap(win, w, h, Tk_Depth(f->tkwin), 1);
    f->pix = find_pix(pixmap);
    if(!f->pix) Tk_FreePixmap(aqua_display, pixmap);
  }
}

/* drawable to use for Xlib drawing: front buffer if d is a window, d itself if a pixmap */
Drawable aqua_drawable(Drawable d)
{
  AquaFront *f = find_front(d);
  if(!f || !f->pix) return d;
  f->dirty = 1;
  return f->pix->pixmap;
}

/* ------------------------------------------------------- Xlib drawing calls */

/* clip cr to the clip rectangle of gc (xschem sets one rectangle at most) */
static void clip_to_gc(cairo_t *cr, GC gc)
{
  XRectangle r;
  if(!gc || !gc->clip_mask || ((TkpClipMask *)gc->clip_mask)->type != TKP_CLIP_REGION) return;
  TkClipBox(((TkpClipMask *)gc->clip_mask)->value.region, &r);
  cairo_rectangle(cr, r.x + gc->clip_x_origin, r.y + gc->clip_y_origin, r.width, r.height);
  cairo_clip(cr);
}

/* XCopyArea() of Tk addresses the source in pixels, so it can not copy scaled pixmaps.
 * Copy between registered pixmaps with cairo, honouring the GC clip rectangle */
int aqua_copy_area(Display *display, Drawable src, Drawable dst, GC gc, int src_x, int src_y,
                   unsigned int width, unsigned int height, int dest_x, int dest_y)
{
  Drawable s = aqua_drawable(src), d = aqua_drawable(dst);
  AquaPix *ps = find_pix(s), *pd = find_pix(d);
  cairo_t *cr;

  if(!ps || !pd) return XCopyArea(display, s, d, gc, src_x, src_y, width, height, dest_x, dest_y);
  cr = cairo_create(pd->sfc);
  clip_to_gc(cr, gc);
  cairo_rectangle(cr, dest_x, dest_y, width, height);
  cairo_clip(cr);
  cairo_set_source_surface(cr, ps->sfc, dest_x - src_x, dest_y - src_y);
  cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
  cairo_paint(cr);
  cairo_destroy(cr);
  return Success;
}

/* Aqua Tk fills with a FillStippled GC as if it were FillSolid, so the stippled layers of
 * xschem would cover everything below them. These fills are done with cairo instead: the
 * caller adds the shape to the path returned by stipple_begin() (NULL: not a stippled GC
 * or not a pixmap of ours, let Tk fill), stipple_end() paints the GC foreground through
 * the stipple bitmap, tiled from the drawable origin with one bit per point. */
static cairo_t *stipple_begin(Drawable d, GC gc)
{
  AquaPix *p;
  cairo_t *cr;
  if(gc->fill_style != FillStippled || !gc->stipple || !(p = find_pix(d))) return NULL;
  cr = cairo_create(p->sfc);
  clip_to_gc(cr, gc);
  cairo_set_fill_rule(cr, gc->fill_rule == EvenOddRule ? CAIRO_FILL_RULE_EVEN_ODD : CAIRO_FILL_RULE_WINDING);
  return cr;
}

static int stipple_end(cairo_t *cr, GC gc)
{
  /* a depth 1 Tk pixmap is an 8 bit alpha only bitmap: cairo's CAIRO_FORMAT_A8 */
  CGContextRef cg = (CGContextRef)Tk_MacOSXGetCGContextForDrawable(gc->stipple);
  cairo_surface_t *bits = cairo_image_surface_create_for_data(
      (unsigned char *)CGBitmapContextGetData(cg), CAIRO_FORMAT_A8, (int)CGBitmapContextGetWidth(cg),
      (int)CGBitmapContextGetHeight(cg), (int)CGBitmapContextGetBytesPerRow(cg));
  cairo_pattern_t *mask = cairo_pattern_create_for_surface(bits);

  cairo_pattern_set_extend(mask, CAIRO_EXTEND_REPEAT);
  cairo_pattern_set_filter(mask, CAIRO_FILTER_NEAREST);
  cairo_clip(cr);
  /* Aqua Tk pixel values of rgb colours are 0xRRGGBB */
  cairo_set_source_rgb(cr, ((gc->foreground >> 16) & 0xff) / 255.0,
      ((gc->foreground >> 8) & 0xff) / 255.0, (gc->foreground & 0xff) / 255.0);
  cairo_mask(cr, mask);
  cairo_pattern_destroy(mask);
  cairo_surface_destroy(bits);
  cairo_destroy(cr);
  return Success;
}

int aqua_fill_rectangles(Display *display, Drawable d, GC gc, XRectangle *r, int n)
{
  cairo_t *cr = stipple_begin(d = aqua_drawable(d), gc);
  int i;
  if(!cr) return XFillRectangles(display, d, gc, r, n);
  for(i = 0; i < n; ++i) cairo_rectangle(cr, r[i].x, r[i].y, r[i].width, r[i].height);
  return stipple_end(cr, gc);
}

int aqua_fill_rectangle(Display *display, Drawable d, GC gc, int x, int y, unsigned int width,
                        unsigned int height)
{
  XRectangle r;
  r.x = x;
  r.y = y;
  r.width = width;
  r.height = height;
  return aqua_fill_rectangles(display, d, gc, &r, 1);
}

/* xschem only uses CoordModeOrigin */
int aqua_fill_polygon(Display *display, Drawable d, GC gc, XPoint *p, int n, int shape, int mode)
{
  cairo_t *cr = stipple_begin(d = aqua_drawable(d), gc);
  int i;
  if(!cr) return XFillPolygon(display, d, gc, p, n, shape, mode);
  for(i = 0; i < n; ++i) cairo_line_to(cr, p[i].x, p[i].y);
  return stipple_end(cr, gc);
}

/* pie slice (the GC default arc mode), angles in 1/64 degree counterclockwise */
int aqua_fill_arc(Display *display, Drawable d, GC gc, int x, int y, unsigned int width,
                  unsigned int height, int angle1, int angle2)
{
  cairo_t *cr = stipple_begin(d = aqua_drawable(d), gc);
  double a1 = -angle1 * M_PI / (180 * 64), a2 = -(angle1 + angle2) * M_PI / (180 * 64);
  if(!cr) return XFillArc(display, d, gc, x, y, width, height, angle1, angle2);
  if(!width || !height) {
    cairo_destroy(cr);
    return Success;
  }
  cairo_save(cr);
  cairo_translate(cr, x + width / 2.0, y + height / 2.0);
  cairo_scale(cr, width / 2.0, height / 2.0);
  cairo_move_to(cr, 0, 0);
  if(angle2 > 0) cairo_arc_negative(cr, 0, 0, 1, a1, a2);
  else cairo_arc(cr, 0, 0, 1, a1, a2);
  cairo_restore(cr);
  return stipple_end(cr, gc);
}

/* ------------------------------------------------------------------ present */

/* rectangle of a window in the content view of its NSWindow, AppKit coordinates */
static NSView *window_rect(AquaFront *f, NSRect *rect)
{
  NSWindow *w = (NSWindow *)Tk_MacOSXGetNSWindowForDrawable(f->win);
  NSView *view;
  Tk_Window t;
  int x = 0, y = 0;

  if(!w || !(view = [w contentView])) return nil;
  for(t = f->tkwin; t && !Tk_IsTopLevel(t); t = Tk_Parent(t)) {
    x += Tk_X(t) + Tk_Changes(t)->border_width;
    y += Tk_Y(t) + Tk_Changes(t)->border_width;
  }
  *rect = NSMakeRect(x, [view bounds].size.height - y - f->pix->height, f->pix->width, f->pix->height);
  return view;
}

/* idle callback of aqua_present(): draw the front buffer into the window */
static void draw_front(ClientData cd)
{
  AquaFront *f = (AquaFront *)cd;
  NSView *view;
  NSRect r;
  CGContextRef cg;
  CGRect clip, src, dst;
  CGImageRef img, sub;
  double s;

  f->pending = 0;
  if(!f->pix || !(view = window_rect(f, &r))) return;
  if(view != [NSView focusView]) { /* not run by drawRect: after all */
    aqua_present(f->win);
    return;
  }
  cg = [[NSGraphicsContext currentContext] CGContext];
  if(!cg) return;
  f->dirty = 0;
  clip = CGRectIntersection(CGContextGetClipBoundingBox(cg), NSRectToCGRect(r));
  if(CGRectIsEmpty(clip)) return;
  /* part of the front buffer to draw, in pixels from its top left corner */
  s = f->pix->scale;
  src = CGRectIntegral(CGRectMake((clip.origin.x - r.origin.x) * s,
          (r.origin.y + r.size.height - clip.origin.y - clip.size.height) * s,
          clip.size.width * s, clip.size.height * s));
  src = CGRectIntersection(src, CGRectMake(0, 0, CGBitmapContextGetWidth(f->pix->cg),
          CGBitmapContextGetHeight(f->pix->cg)));
  if(CGRectIsEmpty(src)) return;
  dst = CGRectMake(r.origin.x + src.origin.x / s,
          r.origin.y + r.size.height - (src.origin.y + src.size.height) / s,
          src.size.width / s, src.size.height / s);
  img = CGBitmapContextCreateImage(f->pix->cg);
  sub = img ? CGImageCreateWithImageInRect(img, src) : NULL;
  if(sub) {
    CGContextSaveGState(cg);
    CGContextClipToRect(cg, clip);
    CGContextSetInterpolationQuality(cg,
        fabs(s - [[view window] backingScaleFactor]) < 0.01 ? kCGInterpolationNone : kCGInterpolationDefault);
    CGContextDrawImage(cg, dst, sub);
    CGContextRestoreGState(cg);
  }
  CGImageRelease(sub);
  CGImageRelease(img);
  dbg_aqua(2, "draw_front(): %gx%g at %g,%g\n", dst.size.width, dst.size.height, dst.origin.x, dst.origin.y);
}

/* Draw the front buffer into the window. This only works while AppKit redraws the view
 * (Tk handles an Expose event from drawRect:); otherwise ask for a redraw, which comes
 * back here as an Expose event. Before drawRect: returns Tk runs the idle callbacks,
 * where a frame paints its -background over the window (the preview pane of the file
 * dialog has one): draw from an idle callback too, queued after those. */
void aqua_present(Window win)
{
  AquaFront *f = find_front(win);
  NSView *view;
  NSRect r;

  if(!f || !f->pix || !(view = window_rect(f, &r))) return;
  if(view != [NSView focusView]) {
    if([view respondsToSelector: @selector(addTkDirtyRect:)]) [view addTkDirtyRect: r];
    else [view setNeedsDisplayInRect: r];
  } else if(!f->pending) {
    f->pending = 1;
    Tcl_DoWhenIdle(draw_front, f);
  }
}

/* nesting depth of xschem commands, which nest through Tcl callbacks: add delta, return it */
int aqua_nesting(int delta)
{
  static int depth = 0;
  depth += delta;
  return depth;
}

/* present all windows drawn on since they were last presented */
void aqua_flush(void)
{
  AquaFront *f;
  for(f = front_list; f; f = f->next) if(f->dirty) aqua_present(f->win);
}

/* -------------------------------------------------------------------- fonts */

/* cairo's toy font faces on macOS match the generic family names ("sans-serif",
 * "monospace", ...) in lower case only: "Sans-Serif" or "Monospace" give plain Helvetica,
 * with no bold or italic. Other family names are matched in any case. A slanted face is
 * looked up by its style name, which is Oblique for Helvetica and Courier (the generic
 * sans and mono fonts) and Italic for Times (serif). */
cairo_font_face_t *aqua_toy_font_face(const char *family, cairo_font_slant_t slant,
                                      cairo_font_weight_t weight)
{
  char name[256];
  int i;
  for(i = 0; family[i] && i < (int)sizeof(name) - 1; ++i) name[i] = (char)tolower((unsigned char)family[i]);
  name[i] = '\0';
  if(slant != CAIRO_FONT_SLANT_NORMAL) {
    if(!strcmp(name, "sans-serif") || !strcmp(name, "sans") || !strcmp(name, "monospace") || !strcmp(name, "mono"))
      slant = CAIRO_FONT_SLANT_OBLIQUE;
    else if(!strcmp(name, "serif")) slant = CAIRO_FONT_SLANT_ITALIC;
  }
  return cairo_toy_font_face_create(name, slant, weight);
}

/* ------------------------------------------------- missing Xlib emulation */

/* no tiled fills in Aqua Tk, xschem always runs with fix_broken_tiled_fill */
int XSetTile(Display *d, GC gc, Pixmap p)
{
  (void)d; (void)gc; (void)p;
  return 0;
}

#if TK_MAJOR_VERSION < 9
int XDrawRectangles(Display *d, Drawable w, GC gc, XRectangle *r, int n)
{
  int i;
  w = aqua_drawable(w);
  for(i = 0; i < n; ++i) XDrawRectangle(d, w, gc, r[i].x, r[i].y, r[i].width, r[i].height);
  return 0;
}

int XDrawArcs(Display *d, Drawable w, GC gc, XArc *a, int n)
{
  int i;
  w = aqua_drawable(w);
  for(i = 0; i < n; ++i) XDrawArc(d, w, gc, a[i].x, a[i].y, a[i].width, a[i].height, a[i].angle1, a[i].angle2);
  return 0;
}

int XFillArcs(Display *d, Drawable w, GC gc, XArc *a, int n)
{
  int i;
  w = aqua_drawable(w);
  for(i = 0; i < n; ++i) XFillArc(d, w, gc, a[i].x, a[i].y, a[i].width, a[i].height, a[i].angle1, a[i].angle2);
  return 0;
}
#endif
