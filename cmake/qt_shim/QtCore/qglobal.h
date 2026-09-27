// Minimal stand-in for <QtCore/qglobal.h>.
// The engine libraries only use Qt for a handful of platform/export macros,
// so the CMake build provides them here instead of requiring a Qt install.
#ifndef ZOD_QT_SHIM_QGLOBAL_H
#define ZOD_QT_SHIM_QGLOBAL_H

#if defined(_WIN32)
#  define Q_OS_WIN
#  define Q_DECL_EXPORT __declspec(dllexport)
#  define Q_DECL_IMPORT __declspec(dllimport)
#else
#  define Q_OS_UNIX
#  if defined(__APPLE__)
#    define Q_OS_DARWIN
#    define Q_OS_MACOS
#    define Q_OS_MAC
#  elif defined(__linux__)
#    define Q_OS_LINUX
#  endif
#  define Q_DECL_EXPORT __attribute__((visibility("default")))
#  define Q_DECL_IMPORT __attribute__((visibility("default")))
#endif

// Convenience typedefs that real <QtCore/qglobal.h> provides. glibc happens to
// define most of them too, but macOS does not (e.g. "ulong").
#ifdef __cplusplus
typedef unsigned char  uchar;
typedef unsigned short ushort;
typedef unsigned int   uint;
typedef unsigned long  ulong;
#endif

#endif // ZOD_QT_SHIM_QGLOBAL_H
