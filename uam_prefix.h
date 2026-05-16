// UAM symbol-redirect macros — objcopy --prefix-symbols=__uam_ renamed all
// symbols in libuam.a to avoid collision with RA's bundled mesa GLSL compiler.
// These must appear BEFORE the uam.h declarations so they expand too.
#ifdef __cplusplus
extern "C" {
#endif
#define uam_init __uam_uam_init
#define uam_deinit __uam_uam_deinit
#define uam_compileDksh __uam_uam_compileDksh
#ifdef __cplusplus
}
#endif
