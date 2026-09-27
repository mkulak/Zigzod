// The implementations live in Zig (src/common.zig). This file only adapts
// the C++ API used by the rest of the engine (std::string, std::vector).
#include "common.h"

namespace COMMON
{

void create_folder(char *foldername) { zod_create_folder(foldername); }
double current_time() { return zod_current_time(); }
void uni_pause(int m_sec) { zod_uni_pause(m_sec); }

void split(char *dest, char *message, char split, int *initial, int d_size, int m_size)
{
	zod_split(dest, message, split, initial, d_size, m_size);
}

void clean_newline(char *message, int size) { zod_clean_newline(message, size); }
void lcase(char *message, int m_size) { zod_lcase(message, m_size); }

void lcase(string &message)
{
	if(!message.empty()) zod_lcase(&message[0], static_cast<int>(message.size()));
}

void print_dump(char *message, int size, char *name) { zod_print_dump(message, size, name); }

bool points_within_distance(int x1, int y1, int x2, int y2, int distance)
{
	return zod_points_within_distance(x1, y1, x2, y2, distance);
}

bool points_within_area(int px, int py, int ax, int ay, int aw, int ah)
{
	return zod_points_within_area(px, py, ax, ay, aw, ah);
}

bool good_user_char(int c) { return zod_good_user_char(c); }
bool good_user_string(const char *message) { return zod_good_user_string(message); }
void printd_reg(char *message) { zod_printd_reg(message); }

string data_to_hex_string(unsigned char *data, int size)
{
	if(size <= 0) return string();
	string output(static_cast<size_t>(size) * 2 + 1, '\0');
	zod_data_to_hex(data, size, &output[0]);
	output.resize(static_cast<size_t>(size) * 2);
	return output;
}

bool file_can_be_written(char *filename) { return zod_file_can_be_written(filename); }

static void add_to_filelist(void *ctx, const char *name)
{
	static_cast<vector<string>*>(ctx)->push_back(name);
}

vector<string> directory_filelist(string foldername)
{
	vector<string> filelist;
	zod_directory_filelist(foldername.c_str(), add_to_filelist, &filelist);
	return filelist;
}

void parse_filelist(vector<string> &filelist, string extension)
{
	for(vector<string>::iterator i=filelist.begin(); i!=filelist.end();)
	{
		if(zod_has_extension(i->c_str(), extension.c_str()))
			++i;
		else
			i = filelist.erase(i);
	}
}

bool sort_string_func (const string &a, const string &b)
{
	return strcmp(a.c_str(), b.c_str()) < 0;
}

};
