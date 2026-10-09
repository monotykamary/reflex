// reflex host effects
// ===================
//
// The only foreign code in reflexd. Each effect runs its blocking part on a
// Bend IO helper thread (io_work) and hands one whole UTF-8 buffer back to the
// loop, so a multi-byte character is never split across reads.
//
//   Host.unix_call(path, line, max, timeout_ms)
//     One request/response over a Unix stream socket: connect, write `line`,
//     read until the first '\n' (excluded), EOF or `max` bytes.
//   Host.http_read(sock, max, timeout_ms)
//     One HTTP/1.1 request from an accepted socket: the head through
//     "\r\n\r\n" plus Content-Length body bytes, as one string.

#include <sys/un.h>
#include <poll.h>
#include <strings.h>

static u64 rx_now_ms(void) {
  return io_tick() / 1000000ull;
}

// Waits for `evts` on fd until the absolute deadline; 0 on ready, else errno.
static int rx_wait(int fd, short evts, u64 deadline) {
  for (;;) {
    u64 now = rx_now_ms();
    if (now >= deadline) {
      return ETIMEDOUT;
    }
    struct pollfd p = {fd, evts, 0};
    int n = poll(&p, 1, (int)(deadline - now));
    if (n > 0) {
      return 0;
    }
    if (n == 0) {
      return ETIMEDOUT;
    }
    if (errno != EINTR) {
      return errno;
    }
  }
}

static int rx_write_all(int fd, const char* p, u64 n, u64 deadline) {
  u64 off = 0;
  while (off < n) {
    ssize_t k = write(fd, p + off, n - off);
    if (k > 0) {
      off += (u64)k;
      continue;
    }
    if (k < 0 && (errno == EAGAIN || errno == EINTR)) {
      int err = rx_wait(fd, POLLOUT, deadline);
      if (err) {
        return err;
      }
      continue;
    }
    return k < 0 ? errno : EPIPE;
  }
  return 0;
}

// Unix call
// ---------
// w->text: socket path, w->data: request line (then the reply buffer),
// w->size: request length (then reply length), w->word: max reply bytes,
// w->time: absolute deadline in ms.

static void unix_call_call(IoWork* w) {
  char* req = w->data;
  u64   len = w->size;
  w->data   = NULL;
  w->size   = 0;
  struct sockaddr_un at;
  memset(&at, 0, sizeof(at));
  at.sun_family = AF_UNIX;
  if (strlen(w->text) >= sizeof(at.sun_path)) {
    w->code = ENAMETOOLONG;
    free(req);
    return;
  }
  strcpy(at.sun_path, w->text);
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) {
    w->code = (u32)errno;
    free(req);
    return;
  }
  fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
  int err = 0;
  if (connect(fd, (struct sockaddr*)&at, sizeof(at)) != 0) {
    err = errno;
    if (err == EINPROGRESS || err == EAGAIN) {
      err = rx_wait(fd, POLLOUT, w->time);
    }
  }
  if (!err) {
    err = rx_write_all(fd, req, len, w->time);
  }
  free(req);
  u64   cap = 65536, n = 0;
  char* buf = err ? NULL : malloc(cap + 1);
  while (!err) {
    if (n == cap) {
      if (cap >= w->word) {
        err = EFBIG;
        break;
      }
      cap = cap * 2 < w->word ? cap * 2 : w->word;
      buf = realloc(buf, cap + 1);
    }
    ssize_t k = read(fd, buf + n, cap - n);
    if (k > 0) {
      char* nl = memchr(buf + n, '\n', (size_t)k);
      if (nl) {
        n = (u64)(nl - buf);
        break;
      }
      n += (u64)k;
    } else if (k == 0) {
      break;
    } else if (errno == EAGAIN || errno == EINTR) {
      err = rx_wait(fd, POLLIN, w->time);
    } else {
      err = errno;
    }
  }
  close(fd);
  if (err) {
    free(buf);
    w->code = (u32)err;
    return;
  }
  w->data = buf;
  w->size = n;
}

static Term unix_call_pack(Env e, IoWork* w) {
  Term r = io_res(e, w, io_str(e, w->data ? w->data : "", w->size));
  free(w->data);
  free(w->text);
  return r;
}

Term host_unix_call_run(Env e, Term* f, IoWork* w) {
  u64 plen = 0;
  w->text = io_cstr(e, f[0], &plen);
  w->data = io_cstr(e, f[1], &w->size);
  w->word = (u32)f[2] ? (u32)f[2] : 1;
  w->time = rx_now_ms() + ((u32)f[3] ? (u32)f[3] : 1);
  w->code = 0;
  return io_work(w, unix_call_call, unix_call_pack);
}

#ifdef CID(Host.unix_call)
static void __attribute__((constructor)) host_unix_call_use(void) {
  io_eff(CID(Host.unix_call), host_unix_call_run);
}
#endif

// HTTP read
// ---------
// w->hand: socket, w->word: max bytes, w->time: absolute deadline (ms),
// w->data/w->size: the request read.

static u64 http_content_length(const char* head, u64 n) {
  const char* key = "\r\ncontent-length:";
  u64 klen = strlen(key);
  for (u64 i = 0; i + klen <= n; i += 1) {
    if (strncasecmp(head + i, key, klen) == 0) {
      u64 v = 0, j = i + klen;
      while (j < n && head[j] == ' ') {
        j += 1;
      }
      while (j < n && head[j] >= '0' && head[j] <= '9') {
        v = v * 10 + (u64)(head[j] - '0');
        j += 1;
      }
      return v;
    }
  }
  return 0;
}

static void http_read_call(IoWork* w) {
  int   fd  = (int)w->hand;
  u64   cap = 16384, n = 0, need = 0;
  char* buf = malloc(cap + 1);
  int   err = 0;
  bool  head = false;
  for (;;) {
    if (head && n >= need) {
      break;
    }
    if (n == cap) {
      if (cap >= w->word) {
        err = EFBIG;
        break;
      }
      cap = cap * 2 < w->word ? cap * 2 : w->word;
      buf = realloc(buf, cap + 1);
    }
    ssize_t k = recv(fd, buf + n, cap - n, 0);
    if (k > 0) {
      n += (u64)k;
      if (!head) {
        buf[n] = 0;
        char* end = strstr(buf, "\r\n\r\n");
        if (end) {
          head = true;
          u64 hlen = (u64)(end - buf) + 4;
          need = hlen + http_content_length(buf, hlen);
          if (need > w->word) {
            err = EFBIG;
            break;
          }
        }
      }
    } else if (k == 0) {
      break;
    } else if (errno == EAGAIN || errno == EINTR) {
      err = rx_wait(fd, POLLIN, w->time);
      if (err) {
        break;
      }
    } else {
      err = errno;
      break;
    }
  }
  if (err) {
    free(buf);
    w->data = NULL;
    w->size = 0;
    w->code = (u32)err;
    return;
  }
  w->data = buf;
  w->size = n;
}

static Term http_read_pack(Env e, IoWork* w) {
  Term r = io_res(e, w, io_str(e, w->data ? w->data : "", w->size));
  free(w->data);
  return io_tup(e, io_hand(w->hand), r);
}

Term host_http_read_run(Env e, Term* f, IoWork* w) {
  w->hand = (intptr_t)io_hand_v(f[0]);
  w->word = (u32)f[1] ? (u32)f[1] : 1;
  w->time = rx_now_ms() + ((u32)f[2] ? (u32)f[2] : 1);
  w->code = 0;
  w->data = NULL;
  return io_work(w, http_read_call, http_read_pack);
}

#ifdef CID(Host.http_read)
static void __attribute__((constructor)) host_http_read_use(void) {
  io_eff(CID(Host.http_read), host_http_read_run);
}
#endif

// Parent watch
// ------------
// Host.ppid(): the parent's pid, so reflexd can exit when the app that
// started it is gone (re-parented to launchd).

Term host_ppid_run(Env e, Term* f, IoWork* w) {
  return (Term)(u32)getppid();
}

#ifdef CID(Host.ppid)
static void __attribute__((constructor)) host_ppid_use(void) {
  io_eff(CID(Host.ppid), host_ppid_run);
}
#endif
