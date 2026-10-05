/* spike-only helper: lets the app capture its own windows (no Screen Recording permission needed) */
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
  if (objc != 2) { Tcl_WrongNumArgs(interp, 1, objv, "prefix"); return TCL_ERROR; }
  NSString *prefix = [NSString stringWithUTF8String:Tcl_GetString(objv[1])];
  GrabFn grab = (GrabFn)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
  Tcl_Obj *res = Tcl_NewListObj(0, NULL);
  int i = 0;
  for (NSWindow *w in [NSApp windows]) {
    if (![w isVisible]) continue;
    NSString *path = [NSString stringWithFormat:@"%@_%d.png", prefix, i++];
    const char *how = "windowserver";
    CGImageRef img = grab ? grab(CGRectNull, 1u << 3, (uint32_t)[w windowNumber], (1u << 0) | (1u << 4)) : NULL;
    int ok = 0;
    if (img) { ok = writePNG(img, path); CGImageRelease(img); }
    if (!ok) {
      NSView *v = [w contentView];
      NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:[v bounds]];
      [v cacheDisplayInRect:[v bounds] toBitmapImageRep:rep];
      ok = [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
      how = "view-cache";
    }
    Tcl_ListObjAppendElement(interp, res, Tcl_ObjPrintf("%s:%s:%s:%s", [[w title] UTF8String], how, ok ? "ok" : "FAILED", [path UTF8String]));
  }
  Tcl_SetObjResult(interp, res);
  return TCL_OK;
}

int Grab_Init(Tcl_Interp *interp) {
  Tcl_CreateObjCommand(interp, "grabwin", GrabCmd, NULL, NULL);
  return TCL_OK;
}
