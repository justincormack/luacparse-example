/* note that this is only the correct struct stat for 64 bit architectures */

struct stat {
  unsigned long   st_dev;
  unsigned long   st_ino;
  unsigned long   st_nlink;
  unsigned int    st_mode;
  unsigned int    st_uid;
  unsigned int    st_gid;
  unsigned int    __pad0;
  unsigned long   st_rdev;
  long            st_size;
  long            st_blksize;
  long            st_blocks;
  unsigned long   st_atime;
  unsigned long   st_atime_nsec;
  unsigned long   st_mtime;
  unsigned long   st_mtime_nsec;
  unsigned long   st_ctime;
  unsigned long   st_ctime_nsec;
  long            __unused[3];
};

struct example {
  int x, y, z;
};

int stat(const char *path, struct stat *buf);
int lstat(const char *path, struct stat *buf);


