#ifndef FLUTTER_PLUGIN_FFMPEG_KIT_FLUTTER_PLUGIN_H_
#define FLUTTER_PLUGIN_FFMPEG_KIT_FLUTTER_PLUGIN_H_

/*
 * The file name and the symbol below both use the "f_fmpeg_" prefix on purpose.
 * The Flutter tool snake-cases the pubspec pluginClass (FFmpegKitFlutterPlugin)
 * to derive both, and its conversion inserts a separator before every capital
 * after the first, yielding f_fmpeg_kit_flutter_plugin. generated_plugin_
 * registrant.cc includes this exact path and calls this exact symbol, so
 * "fixing" the spelling to ffmpeg_* breaks the link.
 */

#include <flutter_linux/flutter_linux.h>

G_BEGIN_DECLS

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __attribute__((visibility("default")))
#else
#define FLUTTER_PLUGIN_EXPORT
#endif

typedef struct _FFmpegKitFlutterPlugin FFmpegKitFlutterPlugin;
typedef struct {
  GObjectClass parent_class;
} FFmpegKitFlutterPluginClass;

FLUTTER_PLUGIN_EXPORT GType f_fmpeg_kit_flutter_plugin_get_type();

FLUTTER_PLUGIN_EXPORT void f_fmpeg_kit_flutter_plugin_register_with_registrar(
    FlPluginRegistrar* registrar);

G_END_DECLS

#endif  // FLUTTER_PLUGIN_FFMPEG_KIT_FLUTTER_PLUGIN_H_
