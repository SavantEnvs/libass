// Matroska-style libass harness: feeds ass_process_chunk() one event per input line, with event
// pruning enabled (ass_configure_prune), and renders frames, which prunes (ass_render_frame ->
// ass_prune_events). This is how a demuxer/player drives libass; upstream's fuzz.c only reads
// whole files and never reaches the ReadOrder bookkeeping.
#include <stdarg.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "ass.h"

#define MAX_CHUNKS 64

static const char header[] =
    "[Script Info]\n"
    "ScriptType: v4.00+\n"
    "PlayResX: 384\n"
    "PlayResY: 288\n"
    "\n"
    "[V4+ Styles]\n"
    "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, "
    "Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, "
    "Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n"
    "Style: Default,DejaVu Sans,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,2,2,10,10,10,1\n"
    "\n"
    "[Events]\n"
    "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n";

static void msg_callback(int level, const char *fmt, va_list va, void *data)
{
}

int LLVMFuzzerInitialize(int *argc, char ***argv)
{
#ifdef ASSFUZZ_FONTCONFIG_SYSROOT
#define STR_(x) #x
#define STR(x) STR_(x)
    setenv("FONTCONFIG_SYSROOT", STR(ASSFUZZ_FONTCONFIG_SYSROOT), 1);
#endif
    return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    ASS_Library *library = ass_library_init();
    if (!library)
        abort();
    ass_set_message_cb(library, msg_callback, NULL);

    ASS_Renderer *renderer = ass_renderer_init(library);
    if (!renderer)
        abort();
    ass_set_fonts(renderer, NULL, "sans-serif", ASS_FONTPROVIDER_AUTODETECT, NULL, 1);
    ass_set_frame_size(renderer, 384, 288);
    ass_set_storage_size(renderer, 384, 288);

    ASS_Track *track = ass_new_track(library);
    if (!track)
        abort();
    ass_process_codec_private(track, header, sizeof(header) - 1);
    ass_configure_prune(track, 0);

    int change;
    size_t pos = 0;
    int n = 0;
    while (pos < size && n < MAX_CHUNKS) {
        const uint8_t *nl = memchr(data + pos, '\n', size - pos);
        size_t len = nl ? (size_t)(nl - (data + pos)) : size - pos;
        if (len) {
            ass_process_chunk(track, (const char *)data + pos, (int)len, n * 100LL, 50);
            // every third chunk, render shortly after the previous one: prunes the older events
            if (n % 3 == 2)
                ass_render_frame(renderer, track, (n - 1) * 100LL + 20, &change);
            n++;
        }
        pos += len + 1;
    }
    // past every event: prunes whatever is left
    ass_render_frame(renderer, track, n * 100LL + 1000, &change);

    ass_free_track(track);
    ass_renderer_done(renderer);
    ass_library_done(library);
    return 0;
}
