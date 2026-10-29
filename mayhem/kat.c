/* Known-answer probe for libass: parse an in-memory ASS script and render a vector drawing,
 * printing parsed fields and rendered-bitmap facts that mayhem/test.sh compares to fixed values.
 * Drawings need no font, so the output does not depend on installed fonts. */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdarg.h>
#include "ass.h"
#include "ass_types.h"

static void quiet_cb(int level, const char *fmt, va_list va, void *data) {}

static const char script[] =
    "[Script Info]\n"
    "ScriptType: v4.00+\n"
    "PlayResX: 854\n"
    "PlayResY: 480\n"
    "\n"
    "[V4+ Styles]\n"
    "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n"
    "Style: Default,sans-serif,40,&H000000FF,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,5,0,0,0,1\n"
    "Style: Second,DejaVu Sans,24,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,-1,0,0,0,100,100,0,0,1,0,0,2,0,0,0,1\n"
    "\n"
    "[Events]\n"
    "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
    "Dialogue: 0,0:00:01.00,0:00:03.50,Default,,0,0,0,,{\\an7\\pos(100,100)\\p1}m 0 0 l 200 0 200 100 0 100{\\p0}\n"
    "Dialogue: 2,0:00:10.00,0:00:12.00,Second,actor,5,6,7,,Plain text, with comma\n";

int main(void)
{
    ASS_Library *lib = ass_library_init();
    if (!lib) return 3;
    ass_set_message_cb(lib, quiet_cb, NULL);

    ASS_Track *tr = ass_read_memory(lib, (char *)script, sizeof(script) - 1, NULL);
    if (!tr) { puts("parse failed"); return 3; }

    printf("n_styles=%d n_events=%d res=%dx%d\n", tr->n_styles, tr->n_events, tr->PlayResX, tr->PlayResY);
    for (int i = 0; i < tr->n_styles; i++)
        printf("style[%d]=%s font=%s size=%g primary=%08X bold=%d align=%d\n", i, tr->styles[i].Name,
               tr->styles[i].FontName, tr->styles[i].FontSize,
               (unsigned)tr->styles[i].PrimaryColour, tr->styles[i].Bold, tr->styles[i].Alignment);
    for (int i = 0; i < tr->n_events; i++)
        printf("event[%d] start=%lld dur=%lld layer=%d style=%d margins=%d,%d,%d name=%s text=%s\n", i,
               (long long)tr->events[i].Start, (long long)tr->events[i].Duration, tr->events[i].Layer,
               tr->events[i].Style, tr->events[i].MarginL, tr->events[i].MarginR, tr->events[i].MarginV,
               tr->events[i].Name ? tr->events[i].Name : "", tr->events[i].Text);

    ASS_Renderer *r = ass_renderer_init(lib);
    if (!r) return 3;
    ass_set_fonts(r, NULL, "sans-serif", ASS_FONTPROVIDER_AUTODETECT, NULL, 1);
    ass_set_frame_size(r, 854, 480);
    ass_set_storage_size(r, 854, 480);

    const long long times[] = { 500, 2000, 5000 };
    for (int t = 0; t < 3; t++) {
        int change = -1;
        int n = 0;
        ASS_Image *img = ass_render_frame(r, tr, times[t], &change);
        printf("t=%lld change=%d\n", times[t], change);
        for (; img; img = img->next, n++) {
            long full = 0, nonzero = 0;
            for (int y = 0; y < img->h; y++)
                for (int x = 0; x < img->w; x++) {
                    unsigned char v = img->bitmap[y * img->stride + x];
                    full += v == 255;
                    nonzero += v != 0;
                }
            printf("  image[%d] type=%d pos=%d,%d size=%dx%d color=%08X mostly_covered=%d tight=%d\n", n,
                   (int)img->type, img->dst_x, img->dst_y, img->w, img->h, (unsigned)img->color,
                   full >= 19000, nonzero <= 21000);
        }
        printf("  images=%d\n", n);
    }

    ass_free_track(tr);
    ass_renderer_done(r);
    ass_library_done(lib);
    return 0;
}
