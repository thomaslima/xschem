/* test-only helper, never installed or bundled: lets the app capture its own windows (no Screen Recording permission needed)
 *   grabwin prefix ?nominal?
 * Writes prefix_N.png for each visible window, at the native (backing store) resolution,
 * or at one pixel per point with 'nominal'. Returns title:method:status:path:WxH entries. */
#import <Cocoa/Cocoa.h>
#import <ImageIO/ImageIO.h>
#include <dlfcn.h>
#include <tcl.h>

typedef CGImageRef (*GrabFn)(CGRect, uint32_t, uint32_t, uint32_t);

static int writePNG(CGImageRef img, NSString *path) {
  NSURL *url = [NSURL fileURLWithPath:path];
  CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
  if (!d) return 0;
  CGImageDestinationAddImage(d, img, NULL);
  int ok = CGImageDestinationFinalize(d);
  CFRelease(d);
  return ok;
}

static int GrabCmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
  if (objc != 2 && objc != 3) { Tcl_WrongNumArgs(interp, 1, objv, "prefix ?nominal?"); return TCL_ERROR; }
  int nominal = objc == 3 && !strcmp(Tcl_GetString(objv[2]), "nominal");
  NSString *prefix = [NSString stringWithUTF8String:Tcl_GetString(objv[1])];
  GrabFn grab = (GrabFn)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
  Tcl_Obj *res = Tcl_NewListObj(0, NULL);
  int i = 0;
  for (NSWindow *w in [NSApp windows]) {
    if (![w isVisible]) continue;
    NSString *path = [NSString stringWithFormat:@"%@_%d.png", prefix, i++];
    const char *how = "windowserver";
    /* kCGWindowListOptionIncludingWindow, kCGWindowImageBoundsIgnoreFraming,
     * kCGWindowImageNominalResolution */
    CGImageRef img = grab ? grab(CGRectNull, 1u << 3, (uint32_t)[w windowNumber],
                                 (1u << 0) | (nominal ? (1u << 4) : 0)) : NULL;
    int ok = 0;
    size_t pw = 0, ph = 0;
    if (img) { pw = CGImageGetWidth(img); ph = CGImageGetHeight(img); ok = writePNG(img, path); CGImageRelease(img); }
    if (!ok) {
      NSView *v = [w contentView];
      NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:[v bounds]];
      [v cacheDisplayInRect:[v bounds] toBitmapImageRep:rep];
      pw = [rep pixelsWide]; ph = [rep pixelsHigh];
      ok = [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
      how = "view-cache";
    }
    Tcl_ListObjAppendElement(interp, res, Tcl_ObjPrintf("%s:%s:%s:%s:%lux%lu", [[w title] UTF8String], how,
                             ok ? "ok" : "FAILED", [path UTF8String], (unsigned long)pw, (unsigned long)ph));
  }
  Tcl_SetObjResult(interp, res);
  return TCL_OK;
}

int Grab_Init(Tcl_Interp *interp) {
  Tcl_CreateObjCommand(interp, "grabwin", GrabCmd, NULL, NULL);
  return TCL_OK;
}
