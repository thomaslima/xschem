/* File: aqua.h
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

/* Display layer of the native macOS build (Aqua Tk, no X server), implemented in aqua.m,
 * which describes the model. Included by xschem.h when XSCHEM_AQUA is defined; C89. */

#ifndef AQUA_H
#define AQUA_H

#if HAS_CAIRO != 1
#error "the Aqua build needs cairo"
#endif

extern void aqua_init(Tcl_Interp *interp, Display *display, int *debug_level);

/* pixmaps */
extern Pixmap aqua_create_pixmap(Window win, int width, int height, int depth, int native);
extern void aqua_free_pixmap(Pixmap pixmap);
extern cairo_surface_t *aqua_pixmap_surface(Pixmap pixmap);
extern int aqua_scale_mismatch(Window win, Pixmap pixmap);

/* front buffers */
extern void aqua_front_sync(Window win);
extern Drawable aqua_drawable(Drawable d);

/* Xlib calls redirected by the macros below */
extern int aqua_copy_area(Display *display, Drawable src, Drawable dst, GC gc, int src_x, int src_y,
                          unsigned int width, unsigned int height, int dest_x, int dest_y);
extern int aqua_fill_rectangle(Display *display, Drawable d, GC gc, int x, int y, unsigned int width,
                               unsigned int height);
extern int aqua_fill_rectangles(Display *display, Drawable d, GC gc, XRectangle *r, int n);
extern int aqua_fill_polygon(Display *display, Drawable d, GC gc, XPoint *p, int n, int shape, int mode);
extern int aqua_fill_arc(Display *display, Drawable d, GC gc, int x, int y, unsigned int width,
                         unsigned int height, int angle1, int angle2);

/* present */
extern void aqua_present(Window win);
extern int aqua_nesting(int delta);
extern void aqua_flush(void);
extern void aqua_activate(void);

extern cairo_font_face_t *aqua_toy_font_face(const char *family, cairo_font_slant_t slant,
                                             cairo_font_weight_t weight);

/* Xlib calls missing in the Aqua Tk emulation layer */
extern int XSetTile(Display *d, GC gc, Pixmap p);
#if TK_MAJOR_VERSION < 9
extern int XDrawRectangles(Display *d, Drawable w, GC gc, XRectangle *r, int n);
extern int XDrawArcs(Display *d, Drawable w, GC gc, XArc *a, int n);
extern int XFillArcs(Display *d, Drawable w, GC gc, XArc *a, int n);
#endif

#ifndef AQUA_NO_REDIRECT
/* Xlib drawing calls aimed at a window are redirected to its front buffer.
 * Pixmap drawables are passed through unchanged. */
#define XDrawLine(d, w, gc, x1, y1, x2, y2) (XDrawLine)(d, aqua_drawable(w), gc, x1, y1, x2, y2)
#define XDrawLines(d, w, gc, p, n, m) (XDrawLines)(d, aqua_drawable(w), gc, p, n, m)
#define XDrawSegments(d, w, gc, s, n) (XDrawSegments)(d, aqua_drawable(w), gc, s, n)
#define XDrawPoints(d, w, gc, p, n, m) (XDrawPoints)(d, aqua_drawable(w), gc, p, n, m)
#define XDrawRectangle(d, w, gc, x, y, wd, ht) (XDrawRectangle)(d, aqua_drawable(w), gc, x, y, wd, ht)
#define XDrawArc(d, w, gc, x, y, wd, ht, a1, a2) (XDrawArc)(d, aqua_drawable(w), gc, x, y, wd, ht, a1, a2)
/* Aqua Tk hands the line width to CoreGraphics, which draws nothing for a width of 0
 * (in X11 the thinnest line, one pixel wide): xschem uses it for the crosshair, the
 * snap cursor and the grid points */
#define XSetLineAttributes(d, gc, w, s, c, j) (XSetLineAttributes)(d, gc, (w) ? (w) : 1, s, c, j)
/* fills also draw the stipple of a FillStippled GC */
#define XFillArc(d, w, gc, x, y, wd, ht, a1, a2) aqua_fill_arc(d, w, gc, x, y, wd, ht, a1, a2)
#define XFillRectangle(d, w, gc, x, y, wd, ht) aqua_fill_rectangle(d, w, gc, x, y, wd, ht)
#define XFillRectangles(d, w, gc, r, n) aqua_fill_rectangles(d, w, gc, r, n)
#define XFillPolygon(d, w, gc, p, n, s, m) aqua_fill_polygon(d, w, gc, p, n, s, m)
/* Tk's XCopyArea() addresses the source in pixels and so can not copy scaled pixmaps */
#define XCopyArea(d, s, w, gc, sx, sy, wd, ht, dx, dy) aqua_copy_area(d, s, w, gc, sx, sy, wd, ht, dx, dy)
/* generic font family names in lower case, see aqua_toy_font_face() */
#define cairo_toy_font_face_create(f, s, w) aqua_toy_font_face(f, s, w)
#if TK_MAJOR_VERSION >= 9
#define XDrawRectangles(d, w, gc, r, n) (XDrawRectangles)(d, aqua_drawable(w), gc, r, n)
#define XDrawArcs(d, w, gc, a, n) (XDrawArcs)(d, aqua_drawable(w), gc, a, n)
#define XFillArcs(d, w, gc, a, n) (XFillArcs)(d, aqua_drawable(w), gc, a, n)
#endif
#endif /* AQUA_NO_REDIRECT */

#endif /* AQUA_H */
