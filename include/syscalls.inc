; ---- Linux x86-64 syscall numbers ----
%define SYS_read        0
%define SYS_write       1
%define SYS_close       3
%define SYS_mmap        9
%define SYS_socket      41
%define SYS_accept      43
%define SYS_bind        49
%define SYS_listen      50
%define SYS_setsockopt  54
%define SYS_exit        60

; ---- socket constants ----
%define AF_INET         2
%define SOCK_STREAM     1
%define SOL_SOCKET      1
%define SO_REUSEADDR    2
%define INADDR_ANY      0

; ---- mmap constants ----
%define PROT_RW         3            ; PROT_READ|PROT_WRITE
%define MAP_ANON_PRIV   0x22         ; MAP_PRIVATE|MAP_ANONYMOUS

; ---- tunables ----
%define PORT_DEFAULT    6379
%define ARENA_SIZE      (64*1024*1024)
%define READ_BUF_SIZE   16384
%define OUT_BUF_SIZE    65536
%define MAX_ARGS        128
%define NBUCKETS        1024
%define BUCKET_MASK     1023
