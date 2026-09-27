/*
 SDL_rotozoom - rotozoomer (from SDL_gfx)
 LGPL (c) A. Schiffler

 Implemented in Zig: src/sdl_rotozoom.zig (same license).
*/

#ifndef SDL_rotozoom_h
#define SDL_rotozoom_h

#include "SDL/SDL.h"

#ifdef __cplusplus
extern "C" {
#endif

#define SMOOTHING_OFF		0
#define SMOOTHING_ON		1

/*
 rotozoomSurface()
 Rotates and zooms a 32bit or 8bit 'src' surface to a newly created surface.
 'angle' is the rotation in degrees, 'zoom' a scaling factor (negative
 flips). If 'smooth' is 1 then a 32bit result is anti-aliased. Surfaces that
 are not 8bit or 32bit are converted to 32bit RGBA on the fly.
*/
SDL_Surface *rotozoomSurface(SDL_Surface *src, double angle, double zoom, int smooth);
SDL_Surface *rotozoomSurfaceXY(SDL_Surface *src, double angle, double zoomx, double zoomy, int smooth);

/* Size of the surface rotozoomSurface() / a plain zoom would create. */
void rotozoomSurfaceSize(int width, int height, double angle, double zoom, int *dstwidth, int *dstheight);
void rotozoomSurfaceSizeXY(int width, int height, double angle, double zoomx, double zoomy, int *dstwidth, int *dstheight);
void zoomSurfaceSize(int width, int height, double zoomx, double zoomy, int *dstwidth, int *dstheight);

#ifdef __cplusplus
}
#endif

#endif /* SDL_rotozoom_h */
