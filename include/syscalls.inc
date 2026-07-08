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
; Flush out_buf once it grows past this, leaving room for one more max reply.
; A single reply is bounded by READ_BUF_SIZE (payload lives in read_buf) plus a
; small framing budget (64), so this guarantees no write past OUT_BUF_SIZE.
%define OUT_FLUSH_HI    (OUT_BUF_SIZE - READ_BUF_SIZE - 64)
%define MAX_ARGS        128
%define NBUCKETS        1024
%define BUCKET_MASK     1023

; ---- milestone C: epoll / non-blocking ----
%define SYS_epoll_create1  291
%define SYS_epoll_ctl      233
%define SYS_epoll_wait     232
%define SYS_accept4        288
%define EPOLLIN            0x1
%define EPOLLOUT           0x4
%define EPOLLERR           0x8
%define EPOLLHUP           0x10
%define EPOLL_CTL_ADD      1
%define EPOLL_CTL_DEL      2
%define EPOLL_CTL_MOD      3
%define EAGAIN             11
%define EINTR              4
%define SOCK_NONBLOCK      0x800
%define MAX_CONNS          1024
%define CONN_BUF_SIZE      16384
%define CONN_BUF_SHIFT     14
%define CONN_STATE_SZ      32
%define CONN_STATE_SHIFT   5
%define MAX_EVENTS         256
%define EV_SIZE            12
%define ST_IN_USE          1
%define ST_WATCH_OUT       2
