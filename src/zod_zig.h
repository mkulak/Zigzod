// C declarations of the functions implemented in Zig (src/*.zig).
// Include this from C++ code; keep it in sync with the Zig `export fn`s.
#ifndef ZOD_ZIG_H
#define ZOD_ZIG_H

#ifdef __cplusplus
extern "C" {
#endif

// ---- common.zig -----------------------------------------------------------
double zod_current_time(void);
void zod_uni_pause(int m_sec);
void zod_split(char *dest, const char *message, char split, int *initial, int d_size, int m_size);
void zod_clean_newline(char *message, int size);
void zod_lcase(char *message, int m_size);
bool zod_good_user_char(int c);
bool zod_good_user_string(const char *message);
void zod_data_to_hex(const unsigned char *data, int size, char *out);
bool zod_has_extension(const char *name, const char *ext);
bool zod_points_within_distance(int x1, int y1, int x2, int y2, int distance);
bool zod_points_within_area(int px, int py, int ax, int ay, int aw, int ah);
void zod_create_folder(const char *foldername);
bool zod_file_can_be_written(const char *filename);
typedef void (*zod_file_callback)(void *ctx, const char *name);
void zod_directory_filelist(const char *foldername, zod_file_callback callback, void *ctx);
void zod_print_dump(const char *message, int size, const char *name);
void zod_printd_reg(const char *message);

// ---- ztime.zig ------------------------------------------------------------
struct ZTime;
void zod_ztime_init(struct ZTime *t);
void zod_ztime_update(struct ZTime *t);
void zod_ztime_pause(struct ZTime *t);
void zod_ztime_resume(struct ZTime *t);
void zod_ztime_set_game_speed(struct ZTime *t, double new_speed);

#ifdef __cplusplus
}
#endif

#endif // ZOD_ZIG_H
