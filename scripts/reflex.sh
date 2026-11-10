#!/bin/sh
# reflex: take a session to another machine. Reflex's move button and @boat
# use these steps; so does the reflex skill, which an agent follows to build
# your template the first time.
#
#   reflex machine new [--template | --from SNAPSHOT] [--type T] [--name N]
#   reflex machine rm NAME          reflex machine ls
#   reflex machine extend NAME SECONDS | state NAME | resume NAME
#                                   its sandbox's lifetime, state, restart
#   reflex where MACHINE PATH       the path there (~/x here is ~/x there,
#                                   /tmp/x is /tmp/x)
#   (MACHINE "." is this Mac; --from SRC reads from another machine, so a
#   move can go from anywhere to anywhere, through this Mac)
#   reflex sync MACHINE [DIR] [--include PATH]... [--from SRC]
#                                   the project's files (git's view: tracked
#                                   and untracked but not ignored, plus .git),
#                                   and any ignored PATH you name
#   reflex copy MACHINE PATH... [--from SRC]
#                                   files or folders as they are (Downloads,
#                                   notes, data): each to the same path there
#   reflex creds MACHINE [--claude] [--any]
#   reflex session MACHINE KIND SESSION CWD [--from SRC]
#                                   again: only what's new since the last time
#   reflex snapshot MACHINE --manifest FILE
#   reflex template [--json]        exit 0 current, 1 stale, 2 none
#   reflex move self --to MACHINE [PATH...]
#                                   asks Reflex to move this session, and what
#                                   its work needs; you approve it in the app
#   reflex list PATH [--from SRC]   what's in a folder there
#   reflex bring MACHINE PATH... [--from SRC]
#                                   repositories (sync) and anything else (copy)
#   reflex home fetch PATH... | home ls PATH | home machines
#                                   from a session Reflex moved: ask the Reflex
#                                   that moved it, over herdr-core's line
#   reflex bus listen MACHINE | bus reply MACHINE ID   (Reflex's side)
#   reflex id                       this machine's Reflex id
#   reflex skill install [--on MACHINE]
#   reflex install                  link this script as ~/.local/bin/reflex
#
# Machines are herdr-core's (`hc machine ls`); `machine new` makes a boat.dev
# sandbox and adds it as a temporary one. Nothing here prints a secret.
set -eu

DATA=${REFLEX_DATA:-"$HOME/Library/Application Support/Reflex"}
DIR="$DATA/boat"
TEMPLATE=${REFLEX_TEMPLATE:-reflex-template}
HERE=$(cd "$(dirname "$0")" && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/reflex.XXXXXX")
trap 'rm -rf "$T"' EXIT

die() { echo "reflex: $*" >&2; exit 1; }
say() { echo "$*" >&2; }
q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# A JSON value at a key path, read with the perl every Mac has.
jget() {
  perl -MJSON::PP -0777 -e '
    my $v = eval { JSON::PP->new->decode(<STDIN>) } // exit 1;
    for my $k (@ARGV) { $v = ref $v eq "HASH" ? $v->{$k} : ref $v eq "ARRAY" ? $v->[$k] : undef; }
    exit 1 unless defined $v;
    print ref $v ? JSON::PP->new->canonical->encode($v) : $v;' "$@"
}

# Machines
# --------

record() { echo "$DIR/machines/$1"; }
boat_id() { [ -f "$(record "$1")" ] && sed -n 1p "$(record "$1")"; }
ours() { [ -f "$(record "$1")" ]; }

# Run a shell line there, stdin passed through, its exit code back. "."
# is this Mac. (Helpers keep to their own _names: sh has no locals.)
rsh() { if [ "$1" = . ]; then (cd "$HOME" && sh -c "$2") < "${3:-/dev/null}"; else hc exec --on "$1" -i --timeout 600 -- sh -c "$2" < "${3:-/dev/null}"; fi; }
rsh_in() { if [ "$1" = . ]; then (cd "$HOME" && sh -c "$2"); else hc exec --on "$1" -i --timeout 600 -- sh -c "$2"; fi; }

# Where files come from: this Mac, or SRC (--from), read through herdr-core.
SRC=.
S_HOME=$HOME
from_src() { # from_src SRC: what follows reads from SRC
  SRC=$1
  if [ "$SRC" = . ]; then S_HOME=$HOME; else S_HOME=$(remote_home "$SRC"); fi
}
# What a shell line prints on SRC, into a local file: gzipped there, read
# back in pieces (hc gives back at most 8 MB at a time).
pull() { # pull SRC LINE OUT
  if [ "$1" = . ]; then (cd "$HOME" && sh -c "$2") > "$3"; return; fi
  _pt=$(rsh "$1" "t=\$(mktemp -d \"\${TMPDIR:-/tmp}/reflex.XXXXXX\") && { $2 ; } | gzip -c > \"\$t/all.gz\" && cd \"\$t\" && split -b 7000000 all.gz p. && rm all.gz && printf %s \"\$t\"") || die "can't read from $1"
  : > "$T/pull.gz"
  for _pp in $(rsh "$1" "ls $(q "$_pt")"); do
    rsh "$1" "cat $(q "$_pt/$_pp")" >> "$T/pull.gz" || die "reading from $1 failed"
  done
  rsh "$1" "rm -rf $(q "$_pt")" >/dev/null
  gunzip -c "$T/pull.gz" > "$3"
  rm -f "$T/pull.gz"
}
# tar's flags for where it runs: macOS's would add ._ files and xattrs.
TARF='$(tar --version 2>/dev/null | grep -q bsdtar && echo --no-mac-metadata --no-xattrs)'

remote_home() {
  [ "$1" = . ] && { printf '%s' "$HOME"; return; }
  _h=$(rsh "$1" 'printf %s "$HOME"') || die "can't reach $1 (hc machine ls)"
  [ -n "$_h" ] || die "$1 has no \$HOME"
  printf '%s' "$_h"
}

# ~/x where it is (this Mac, or SRC) is ~/x there, and a temporary folder
# (a worktree in /tmp, say) is the same one there; nothing else outside
# your home moves.
where() {
  case $2 in
    "$S_HOME") remote_home "$1" ;;
    "$S_HOME"/*) printf '%s%s' "$(remote_home "$1")" "${2#"$S_HOME"}" ;;
    /private/tmp/*) printf '/tmp/%s' "${2#/private/tmp/}" ;;
    /tmp/*) printf '%s' "$2" ;;
    *) die "$2 is outside your home folder: only folders under ~ (and /tmp) move" ;;
  esac
}

# The same mapping inside files that name paths (a worktree's .git): a
# perl program (sed -i differs between macOS and Linux).
repath() { # repath MACHINE
  printf 's#\\Q%s/\\E#%s/#g; s#/private/tmp/#/tmp/#g' "$S_HOME" "$(remote_home "$1")"
}

connected() {
  [ "$1" = . ] && return 0
  hc machine ls --json 2>/dev/null | perl -MJSON::PP -0777 -e '
    my $j = JSON::PP->new->decode(<STDIN>);
    for (@{$j->{machines}}) { exit 0 if $_->{name} eq $ARGV[0] && $_->{state} eq "connected" } exit 1' "$1"
}

machine_new() {
  # An hour: Reflex renews it while an agent there works, so the hour
  # starts when the machine goes idle (and when Reflex isn't watching).
  from="" type="" name="" ttl=3600
  while [ $# -gt 0 ]; do
    case $1 in
      --template) from=$(template_field snapshot) || die "no template yet: build one with the reflex skill"; shift ;;
      --from) from=$2; shift 2 ;;
      --type) type=$2; shift 2 ;;
      --name) name=$2; shift 2 ;;
      --ttl) ttl=$2; shift 2 ;;
      *) die "machine new: unknown $1" ;;
    esac
  done
  command -v boat >/dev/null || die "the boat CLI isn't installed (https://docs.boat.dev/cli-reference)"
  mkdir -p "$DIR/machines"
  say "Starting a boat sandbox${from:+ from $from}..."
  out=$(boat new --json --no-update ${from:+--from "$from"} ${type:+--type "$type"} ${ttl:+--ttl "$ttl"} \
    --name "${name:-reflex}" 2>&1) || die "boat new failed: $(printf '%s' "$out" | tail -n 3)"
  id=$(printf '%s' "$out" | grep -o '"id":"bx_[A-Za-z0-9]*"' | tail -n 1 | cut -d'"' -f4)
  [ -n "$id" ] || die "boat new gave no sandbox id: $(printf '%s' "$out" | tail -n 3)"
  name=${name:-boat-${id#bx_}}
  printf '%s\n%s\n' "$id" "${from:-}" > "$(record "$name")"
  say "Adding $id to herdr-core as $name..."
  # (A sandbox just ready can take a while to answer ssh.)
  a=0
  until r=$(hc machine add --via "boat ssh $id" --name "$name" --temp --install --json 2>&1); do
    a=$((a + 1))
    if [ $a -ge 4 ]; then
      say "hc machine add failed: $r"
      hc machine rm "$name" >/dev/null 2>&1 || true
      boat delete --yes "$id" >/dev/null 2>&1 || true
      rm -f "$(record "$name")"
      exit 1
    fi
    say "$id isn't answering ssh yet; again in 5 s"
    sleep 5
  done
  i=0
  until connected "$name"; do
    i=$((i + 1))
    [ $i -lt 90 ] || die "$name didn't connect (hc machine ls)"
    sleep 1
  done
  # This version of the skill (a template keeps the one it was built with).
  skill install --on "$name" >/dev/null 2>&1 || say "the reflex skill isn't on $name: reflex skill install --on $name"
  echo "$name"
}

machine_rm() {
  name=$1
  ours "$name" || die "$name isn't a machine Reflex made: remove it with hc machine rm"
  id=$(boat_id "$name")
  hc machine rm "$name" >/dev/null 2>&1 || true
  boat delete --yes --no-update "$id" >/dev/null 2>&1 || say "boat delete $id failed: delete it with boat delete"
  rm -f "$(record "$name")"
  rm -rf "$DIR/sent/$name"
  echo "removed $name ($id)"
}

# Its boat sandbox: how long it stays up, its state, and back up again.
machine_extend() { # machine_extend NAME SECONDS
  ours "$1" || die "$1 isn't a machine Reflex made"
  boat extend "$(boat_id "$1")" --ttl "$2" --json --no-update >/dev/null 2>&1 || die "boat extend $(boat_id "$1") failed"
}
machine_state() { # machine_state NAME: boat's word for it (running, idle, stopped...)
  ours "$1" || die "$1 isn't a machine Reflex made"
  boat info "$(boat_id "$1")" --json --no-update 2>/dev/null | jget sandbox state || die "boat info $(boat_id "$1") failed"
  echo
}
machine_resume() { # machine_resume NAME: running and connected again
  ours "$1" || die "$1 isn't a machine Reflex made"
  say "Resuming $(boat_id "$1")..."
  boat resume "$(boat_id "$1")" --ttl 3600 --json --no-update >/dev/null 2>&1 || die "boat resume $(boat_id "$1") failed"
  i=0
  until connected "$1"; do
    i=$((i + 1))
    [ $i -lt 120 ] || die "$1 is running again but herdr-core hasn't reconnected (hc machine ls)"
    sleep 1
  done
  echo "$1"
}

machine_ls() {
  [ -d "$DIR/machines" ] || return 0
  for f in "$DIR/machines"/*; do
    [ -f "$f" ] || continue
    printf '%s\t%s\t%s\n' "$(basename "$f")" "$(sed -n 1p "$f")" "$(sed -n 2p "$f")"
  done
}

# Files
# -----

sync() {
  m=$1; shift
  d="" includes="" missing=0
  while [ $# -gt 0 ]; do
    case $1 in
      --include) [ $# -ge 2 ] || die "sync: --include needs a path"; includes="$includes
$2"; shift 2 ;;
      --if-missing) missing=1; shift ;;
      --from) [ $# -ge 2 ] || die "sync: --from needs a machine"; from_src "$2"; shift 2 ;;
      -*) die "sync: unknown $1" ;;
      *) d=$1; shift ;;
    esac
  done
  if [ "$SRC" = . ]; then
    d=$(cd "${d:-$PWD}" && pwd -P)
    top=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$d")
  else
    [ -n "$d" ] || die "sync --from $SRC: name the folder there"
    # ~/x (or this Mac's home) is ~/x there.
    case $d in ("~") d=$S_HOME ;; ("~/"*) d="$S_HOME/${d#"~/"}" ;; ("$HOME") d=$S_HOME ;; ("$HOME"/*) d="$S_HOME/${d#"$HOME"/}" ;; esac
    top=$(rsh "$SRC" "cd $(q "$d") && { git rev-parse --show-toplevel 2>/dev/null || pwd -P; }") || die "no folder $d on $SRC"
  fi
  dest=$(where "$m" "$top")
  if [ $missing = 1 ] && rsh "$m" "[ -d $(q "$dest") ]" >/dev/null; then echo "$dest"; return 0; fi
  say "Copying $SRC:$top to $m:$dest..."
  # Ignored files you named: relative to the project, or a path in it.
  extra=$(printf '%s\n' "$includes" | while IFS= read -r i; do
    [ -n "$i" ] || continue
    case $i in ("$top"/*) printf '%s\n' "${i#"$top"/}" ;; (/*) die "sync: $i isn't in $top" ;; (*) printf '%s\n' "$i" ;; esac
  done) || exit 1
  if [ "$SRC" = . ] && [ -n "$extra" ]; then
    printf '%s\n' "$extra" | while IFS= read -r i; do [ -e "$top/$i" ] || die "sync: no $i in $top"; done || exit 1
  fi
  # The project as git sees it (tracked, untracked, .git), and those.
  inc=$(printf '%s\n' "$extra" | while IFS= read -r i; do [ -z "$i" ] || printf "printf '%%s\\\\0' %s; " "$(q "$i")"; done)
  pull "$SRC" "cd $(q "$top") && export COPYFILE_DISABLE=1 && if git rev-parse --git-dir >/dev/null 2>&1; then { git ls-files -co --exclude-standard -z; printf '.git\\0'; $inc } | tar $TARF --null -T - -cf - 2>/dev/null; else tar $TARF --exclude node_modules --exclude .DS_Store -cf - . 2>/dev/null; fi" "$T/tree.tar"
  unpack "$m" "$T/tree.tar" "$dest"
  fixgit "$m" "$dest"
  echo "$dest"
}

# Git names folders by path in a few small files: a worktree's .git, the
# repository's list of its worktrees, a submodule's alternates (where its
# objects are) and remotes, in the project and any repository inside it.
# Those paths there.
fixgit() { # fixgit MACHINE DEST
  rsh "$1" "cd $(q "$2") || exit 0
    find . -name node_modules -prune -o -name .git -print | while IFS= read -r g; do
      if [ -f \"\$g\" ]; then echo \"\$g\"
      else find \"\$g\" \\( -name gitdir -o -name alternates -o -name config -o -name commondir \\) -type f -size -64k; fi
    done |
      while IFS= read -r f; do grep -qE $(q "$S_HOME/|/private/tmp/") \"\$f\" && perl -pi -e $(q "$(repath "$1")") \"\$f\"; done; true" >/dev/null
}

# Anything, as it is: each file or folder to the same path there.
copy() {
  m=$1; shift
  paths=""
  while [ $# -gt 0 ]; do
    case $1 in
      --from) [ $# -ge 2 ] || die "copy: --from needs a machine"; from_src "$2"; shift 2 ;;
      *) paths="$paths
$1"; shift ;;
    esac
  done
  [ -n "$paths" ] || die "copy MACHINE PATH... [--from SRC]"
  printf '%s\n' "$paths" | while IFS= read -r p; do
    [ -n "$p" ] || continue
    case $p in ("~") p=$S_HOME ;; ("~/"*) p="$S_HOME/${p#"~/"}" ;; esac
    [ "$SRC" = . ] || case $p in ("$HOME") p=$S_HOME ;; ("$HOME"/*) p="$S_HOME/${p#"$HOME"/}" ;; esac
    if [ "$SRC" = . ]; then
      [ -e "$p" ] || die "copy: no $p"
      a=$(cd "$(dirname "$p")" && pwd -P)/$(basename "$p")
    else
      a=$(rsh "$SRC" "[ -e $(q "$p") ] && cd \"\$(dirname $(q "$p"))\" && printf '%s/%s' \"\$(pwd -P)\" \"\$(basename $(q "$p"))\"") || die "copy: no $p on $SRC"
    fi
    dest=$(where "$m" "$a")
    say "Copying $SRC:$a to $m:$dest..."
    pull "$SRC" "cd \"\$(dirname $(q "$a"))\" && COPYFILE_DISABLE=1 tar $TARF --exclude .DS_Store -cf - \"\$(basename $(q "$a"))\"" "$T/copy.tar"
    unpack "$m" "$T/copy.tar" "$(dirname "$dest")"
    echo "$dest"
  done
}

# A local file to a new temp file there, gzipped; its path there. In
# pieces: hc takes at most 8 MB on stdin.
send() {
  gzip -c "$2" > "$T/send.gz"
  _sr=$(rsh "$1" 'mktemp "${TMPDIR:-/tmp}/reflex.XXXXXX"') || die "can't reach $1"
  rm -f "$T"/piece.*
  split -b 7000000 "$T/send.gz" "$T/piece."
  for _c in "$T"/piece.*; do
    [ -f "$_c" ] || continue
    rsh "$1" "cat >> $(q "$_sr")" "$_c" >/dev/null || die "copying to $1 failed"
  done
  rm -f "$T"/piece.* "$T/send.gz"
  printf '%s' "$_sr"
}

put() { # put MACHINE LOCAL REL: the file as ~/REL there, readable only by you
  _pr=$(send "$1" "$2")
  rsh "$1" "umask 077; mkdir -p \"\$HOME\"/$(q "$(dirname "$3")") && gunzip -c $(q "$_pr") > \"\$HOME\"/$(q "$3"); s=\$?; rm -f $(q "$_pr"); exit \$s" >/dev/null
}

# A tarball made here, unpacked in DEST there.
unpack() { # unpack MACHINE TARBALL DEST
  _ur=$(send "$1" "$2")
  # (GNU tar's warnings about macOS headers aside; macOS's tar has no such flag.)
  rsh "$1" "mkdir -p $(q "$3") && w=\$(tar --version 2>/dev/null | grep -q GNU && echo --warning=no-unknown-keyword); gunzip -c $(q "$_ur") | { tar \$w -xf - -C $(q "$3") 2>/dev/null || true; }; rm -f $(q "$_ur")" >/dev/null
}

creds() {
  m=$1; shift
  claude=0 any=0
  for a in "$@"; do
    case $a in --claude) claude=1 ;; --any) any=1 ;; *) die "creds: unknown $a" ;; esac
  done
  ours "$m" || [ $any = 1 ] || die "$m isn't a machine Reflex made: pass --any once the user says to copy their logins there"
  rh=$(remote_home "$m")
  copied=""
  # The harnesses' logins, and the files the template's manifest calls
  # secret (an extension's key file): never in the template, copied to each.
  extra=$(template_field manifest secrets 2>/dev/null | perl -MJSON::PP -0777 -ne 'print join "\n", @{decode_json($_)}' 2>/dev/null || true)
  for rel in .pi/agent/auth.json .codex/auth.json .mcporter/credentials.json $(printf '%s\n' "$extra" | sed -n 's#^~/##p'); do
    if [ -f "$HOME/$rel" ]; then
      put "$m" "$HOME/$rel" "$rel"
    elif [ -d "$HOME/$rel" ]; then   # a folder: as it is, yours alone there
      COPYFILE_DISABLE=1 tar -C "$(dirname "$HOME/$rel")" --no-mac-metadata --no-xattrs -cf "$T/secret.tar" "$(basename "$rel")"
      _sd="$rh/$(dirname "$rel")"
      _sr=$(send "$m" "$T/secret.tar")
      rsh "$m" "umask 077; mkdir -p $(q "$_sd") && gunzip -c $(q "$_sr") | tar -xf - -C $(q "$_sd"); s=\$?; rm -f $(q "$_sr"); exit \$s" >/dev/null || die "copying ~/$rel to $m failed"
    else
      continue
    fi
    copied="$copied $rel"
  done
  # boat's own login, the account's (the sandbox's token sees only that
  # sandbox): supercomputer and boat there reach your images and machines.
  # The sandbox's token stays beside it.
  bc="$HOME/Library/Application Support/ascii/boat/config.json"
  if [ -f "$bc" ] && ours "$m"; then
    rsh "$m" 'c="$HOME/.config/ascii/boat"; [ -f "$c/config.json" ] && [ ! -f "$c/sandbox.json" ] && cp -p "$c/config.json" "$c/sandbox.json"; true' >/dev/null
    put "$m" "$bc" .config/ascii/boat/config.json
    copied="$copied .config/ascii/boat/config.json"
  fi
  # Claude accounts kept with cswap (claude-swap): installed there, the
  # accounts imported (export file readable only by you, gone after), and
  # claude there takes cswap's account rather than boat's injected login.
  if command -v cswap >/dev/null 2>&1 && ours "$m"; then
    # (The account active here, active there too.)
    _ca=$(cswap status --json 2>/dev/null | jget active number 2>/dev/null || true)
    if (umask 077; cswap export "$T/cswap.json" >/dev/null 2>&1); then
      put "$m" "$T/cswap.json" .reflex/cswap.json
      rm -f "$T/cswap.json"
      rsh "$m" 'export PATH="$HOME/.local/bin:$PATH"
        command -v cswap >/dev/null || uv tool install claude-swap >/dev/null 2>&1 || { rm -f "$HOME/.reflex/cswap.json"; exit 4; }
        cswap import "$HOME/.reflex/cswap.json" </dev/null >/dev/null 2>&1; s=$?
        [ -n "'"$_ca"'" ] && cswap switch '"$_ca"' </dev/null >/dev/null 2>&1
        rm -f "$HOME/.reflex/cswap.json"
        line="[ -f \"\$HOME/.reflex/cswap\" ] && unset CLAUDE_CODE_OAUTH_TOKEN"
        for f in .bashrc .profile .zshrc; do [ -f "$HOME/$f" ] || [ $f = .profile ] || continue; grep -qF "$line" "$HOME/$f" 2>/dev/null || printf "%s\n" "$line" >> "$HOME/$f"; done
        : > "$HOME/.reflex/cswap"
        exit $s' >/dev/null || say "cswap's accounts didn't import on $m"
      copied="$copied cswap"
    fi
  fi
  # mcporter's servers name their commands by path: ~ here is ~ there.
  if [ -f "$HOME/.mcporter/mcporter.json" ]; then
    sed "s#$HOME/#$rh/#g" "$HOME/.mcporter/mcporter.json" > "$T/mcporter.json"
    put "$m" "$T/mcporter.json" .mcporter/mcporter.json
    copied="$copied .mcporter/mcporter.json"
  fi
  if [ $claude = 1 ]; then
    tmp="$T/claude.json"
    if security find-generic-password -s "Claude Code-credentials" -w > "$tmp" 2>/dev/null; then
      put "$m" "$tmp" .claude/.credentials.json
      copied="$copied .claude/.credentials.json"
    else
      say "Claude's login isn't readable from the Keychain: claude there uses boat's"
    fi
  fi
  # A machine with your logins never becomes a template.
  printf '%s\n' $copied | rsh_in "$m" 'mkdir -p "$HOME/.reflex" && cat > "$HOME/.reflex/creds"'
  echo "copied:${copied:- nothing}"
}

# Sessions
# --------

claude_dir() { printf '%s' "$1" | sed -e 's#[/.]#-#g'; }
pi_dir() { printf -- '--%s--' "$(printf '%s' "$1" | sed -e 's#^/##' -e 's#/#-#g')"; }

# Only the cwd fields: a transcript's text is left alone (Claude signs its
# thinking, and a changed byte there fails the resume).
# Every cwd under ~ (the agent may have worked in other folders too).
recwd() { OLD=$1 NEW=$2 perl -pe 's/"cwd":"\Q$ENV{OLD}\E(?=["\/])/"cwd":"$ENV{NEW}/g'; }

# What a session sent to a machine already: Reflex copies a session while
# the agent is still where it is (which can take minutes) and again once
# it's closed, when only what it wrote since goes.
sent() { printf '%s/sent/%s/%s' "$DIR" "$1" "$(printf '%s' "$SRC:$2" | tr '/' '_')"; }

# Perl on SRC (every Mac and Linux has it).
src_perl() { # src_perl SCRIPT ARGS...
  _sp=$1; shift
  if [ "$SRC" = . ]; then perl -e "$_sp" "$@"; else
    _sa=""; for _x in "$@"; do _sa="$_sa $(q "$_x")"; done
    rsh "$SRC" "perl -e $(q "$_sp")$_sa"
  fi
}
# Where the last whole line of FILE ends, in bytes.
line_end() {
  src_perl 'open F, "<", $ARGV[0] or die; my $s = -s F; my $b = $s < 65536 ? $s : 65536;
    seek F, $s - $b, 0; read F, my $t, $b; my $i = rindex($t, "\n"); print $i < 0 ? 0 : $s - $b + $i + 1' "$1"
}
# The 4 KB of FILE before OFFSET, hashed: the part sent is unchanged.
before() {
  src_perl 'use Digest::SHA qw(sha256_hex); open F, "<", $ARGV[0] or die; my $o = $ARGV[1]; my $b = $o < 4096 ? $o : 4096;
    seek F, $o - $b, 0; read F, my $t, $b; print sha256_hex($t)' "$1" "$2"
}
# LEN bytes of FILE from FROM (0-based), into OUT here.
src_range() { # src_range FILE FROM LEN OUT
  pull "$SRC" "tail -c +$(($2 + 1)) $(q "$1") | head -c $3" "$4"
}

# A transcript (it only grows) as ~/REL there, cwd fields mapped: whole the
# first time, then the lines added since.
send_log() { # send_log MACHINE FILE REL
  _ls=$(sent "$1" "$3")
  _le=$(line_end "$2")
  _lf=0 _lz=0
  if [ -f "$_ls" ]; then
    _lo=$(sed -n 1p "$_ls")
    [ "$_lo" -le "$_le" ] && [ "$(before "$2" "$_lo")" = "$(sed -n 2p "$_ls")" ] && _lf=$_lo _lz=$(sed -n 3p "$_ls")
  fi
  _lh=$(remote_home "$1")
  if [ "$_lf" -gt 0 ]; then
    src_range "$2" "$_lf" "$((_le - _lf))" "$T/raw"
    recwd "$S_HOME" "$_lh" < "$T/raw" > "$T/log"
    _ln=$(wc -c < "$T/log" | tr -d ' ')
    _lr=$(send "$1" "$T/log")
    # Only onto the copy as it was left: one gone or written to there since
    # (the session went on there) gets the whole of it, below.
    if rsh "$1" "f=\"\$HOME\"/$(q "$3"); [ -f \"\$f\" ] && [ \"\$(wc -c < \"\$f\")\" -eq $_lz ] || { rm -f $(q "$_lr"); exit 3; }; gunzip -c $(q "$_lr") >> \"\$f\"; s=\$?; rm -f $(q "$_lr"); exit \$s" >/dev/null; then
      _lz=$((_lz + _ln))
    else
      _lf=0
    fi
  fi
  if [ "$_lf" = 0 ]; then
    src_range "$2" 0 "$_le" "$T/raw"
    recwd "$S_HOME" "$_lh" < "$T/raw" > "$T/log"
    _lz=$(wc -c < "$T/log" | tr -d ' ')
    put "$1" "$T/log" "$3"
  fi
  rm -f "$T/raw" "$T/log"
  mkdir -p "$(dirname "$_ls")"
  printf '%s\n%s\n%s\n' "$_le" "$(before "$2" "$_le")" "$_lz" > "$_ls"
}

# A folder (PARENT/NAME, on SRC) into DEST there: whole the first time, then
# the files changed since (a minute's overlap: a few go twice, none missed).
send_dir() { # send_dir MACHINE PARENT NAME DEST
  rsh "$SRC" "[ -d $(q "$2/$3") ]" >/dev/null 2>&1 || return 0
  _ds=$(sent "$1" "$2/$3")
  _dn=$(date +%s)   # before the copy: what changes during it goes next time
  if [ -f "$_ds" ]; then
    _dm=$(( ($_dn - $(sed -n 1p "$_ds")) / 60 + 2 ))
    _dl="find $(q "$3") -type f -mmin -$_dm -print0"
  else
    _dl="printf '%s\\0' $(q "$3")"
  fi
  pull "$SRC" "cd $(q "$2") && n=\$($_dl | tr -cd '\\0' | wc -c) && [ \$n -gt 0 ] && $_dl | COPYFILE_DISABLE=1 tar $TARF --null -T - -cf - || true" "$T/dir.tar"
  [ -s "$T/dir.tar" ] && unpack "$1" "$T/dir.tar" "$4"
  rm -f "$T/dir.tar"
  mkdir -p "$(dirname "$_ds")"
  echo "$_dn" > "$_ds"
}

# The Reflex a session's machine answers to (reflex home), and where its
# files came from, as that Reflex names it.
mark_home() { # mark_home MACHINE
  printf '{"home":"%s","origin":"%s"}\n' "$(self_id)" "$SRC" | rsh_in "$1" 'mkdir -p "$HOME/.reflex" && cat > "$HOME/.reflex/home"'
}

session() {
  m=$1 kind=$2 id=$3 cwd=$4
  shift 4
  while [ $# -gt 0 ]; do
    case $1 in --from) from_src "$2"; shift 2 ;; *) die "session: unknown $1" ;; esac
  done
  rcwd=$(where "$m" "$cwd")
  rsh "$m" "mkdir -p $(q "$rcwd")" >/dev/null
  case $kind in
    claude)
      f="$S_HOME/.claude/projects/$(claude_dir "$cwd")/$id.jsonl"
      rsh "$SRC" "[ -f $(q "$f") ]" >/dev/null 2>&1 || die "no claude session $id for $cwd on $SRC"
      rel=".claude/projects/$(claude_dir "$rcwd")"
      send_log "$m" "$f" "$rel/$id.jsonl"
      # Its subagents' transcripts and saved tool output, and Claude's
      # memory for the project.
      send_dir "$m" "$(dirname "$f")" "$id" "$(remote_home "$m")/$rel"
      send_dir "$m" "$(dirname "$f")" memory "$(remote_home "$m")/$rel"
      # Trusted there as it is here: no folder-trust question on resume.
      rsh "$m" "command -v node >/dev/null && node -e '
        const fs = require(\"fs\"), p = process.env.HOME + \"/.claude.json\";
        let j = {}; try { j = JSON.parse(fs.readFileSync(p, \"utf8\")) } catch {}
        j.projects = j.projects || {}; const d = process.argv[1];
        j.projects[d] = Object.assign(j.projects[d] || {}, { hasTrustDialogAccepted: true });
        j.hasCompletedOnboarding = true;
        fs.writeFileSync(p, JSON.stringify(j, null, 2));' $(q "$rcwd") || true" >/dev/null
      out=$id
      ;;
    pi)
      case $id in
        /*) f=$id ;;
        *) f=$(rsh "$SRC" "ls -t $(q "$S_HOME/.pi/agent/sessions/$(pi_dir "$cwd")")/*$(q "$id")*.jsonl 2>/dev/null | head -n 1") || f="" ;;
      esac
      [ -n "$f" ] && rsh "$SRC" "[ -f $(q "$f") ]" >/dev/null 2>&1 || die "no pi session $id for $cwd on $SRC"
      rel=".pi/agent/sessions/$(pi_dir "$rcwd")/$(basename "$f")"
      send_log "$m" "$f" "$rel"
      # A path names the file there; an id is the same id.
      case $id in /*) out="$(remote_home "$m")/$rel" ;; *) out=$id ;; esac
      ;;
    codex)
      f=$(rsh "$SRC" "find \"\$HOME/.codex/sessions\" -name $(q "*$id*.jsonl") 2>/dev/null | head -n 1") || f=""
      [ -n "$f" ] || die "no codex session $id on $SRC"
      rel=".codex/sessions/${f#"$S_HOME/.codex/sessions/"}"
      send_log "$m" "$f" "$rel"
      out=$id
      ;;
    *) die "Reflex can't move a $kind session (claude, pi and codex only)" ;;
  esac
  [ "$m" = . ] || mark_home "$m"
  printf '%s\t%s\n' "$rcwd" "$out"
}

# The template
# ------------

template_field() {
  [ -f "$DIR/template.json" ] || return 1
  jget "$@" < "$DIR/template.json"
}

hashes() { # the inputs' hashes, as JSON
  perl -MJSON::PP -MDigest::SHA=sha256_hex -e '
    my %h; for my $p (@ARGV) { (my $f = $p) =~ s/^~/$ENV{HOME}/;
      if (open my $fh, "<", $f) { local $/; binmode $fh; $h{$p} = sha256_hex(<$fh>) } else { $h{$p} = "" } }
    print JSON::PP->new->canonical->encode(\%h)' "$@"
}

snapshot() {
  m=$1 manifest=""
  [ "${2:-}" = --manifest ] && manifest=${3:-}
  [ -n "$manifest" ] && [ -f "$manifest" ] || die "snapshot: --manifest FILE (what you installed, the checks, the inputs)"
  ours "$m" || die "$m isn't a boat machine Reflex made"
  jget inputs < "$manifest" >/dev/null || die "the manifest has no \"inputs\" (the files here the setup was built from)"
  if rsh "$m" 'test -e "$HOME/.reflex/creds"' >/dev/null 2>&1; then
    die "$m has your logins on it (reflex creds): build the template on a machine without them"
  fi
  id=$(boat_id "$m")
  # shellcheck disable=SC2046
  h=$(hashes $(jget inputs < "$manifest" | perl -MJSON::PP -0777 -e 'print join "\n", @{decode_json(<STDIN>)}'))
  out=$(perl -MJSON::PP -0777 -e '
    my $m = JSON::PP->new->decode(do { local $/; open my $f, "<", $ARGV[0] or die; <$f> });
    print JSON::PP->new->canonical->pretty->encode({ snapshot => $ARGV[1], sandbox => $ARGV[2],
      at => $ARGV[3], hashes => JSON::PP->new->decode($ARGV[4]), manifest => $m })' \
    "$manifest" "$TEMPLATE" "$id" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$h")
  printf '%s\n' "$out" | rsh_in "$m" 'mkdir -p "$HOME/.reflex" && cat > "$HOME/.reflex/template.json"'
  say "Saving $id as $TEMPLATE..."
  boat snapshot --no-update "$id" "$TEMPLATE" >&2 || die "boat snapshot failed"
  mkdir -p "$DIR"
  printf '%s\n' "$out" > "$DIR/template.json"
  echo "$TEMPLATE"
}

template() {
  [ -f "$DIR/template.json" ] || { [ "${1:-}" = --json ] && echo '{"state":"none"}' || echo "no template"; exit 2; }
  perl -MJSON::PP -MDigest::SHA=sha256_hex -0777 -e '
    my $t = JSON::PP->new->decode(do { local $/; open my $f, "<", $ARGV[0] or die; <$f> });
    my @changed;
    for my $p (sort keys %{$t->{hashes}}) { (my $f = $p) =~ s/^~/$ENV{HOME}/;
      my $now = ""; if (open my $fh, "<", $f) { local $/; binmode $fh; $now = sha256_hex(<$fh>) }
      push @changed, $p if $now ne $t->{hashes}{$p} }
    my $state = @changed ? "stale" : "current";
    if ($ARGV[1] eq "--json") {
      print JSON::PP->new->canonical->encode({ state => $state, snapshot => $t->{snapshot}, at => $t->{at}, changed => \@changed }), "\n";
    } else {
      print "$t->{snapshot}: $state (built $t->{at})\n"; print "  changed: $_\n" for @changed;
    }
    exit(@changed ? 1 : 0)' "$DIR/template.json" "${1:-}"
}

# Moving, and the line home
# ------------------------
#
# A session asks the Reflex that moved it (or, unanswered, any Reflex
# watching this machine) through a mailbox: ~/.reflex/bus/out/ID.json,
# answered in ~/.reflex/bus/in/ID.json. Reflex keeps a `bus listen` running
# on each machine over herdr-core's ssh line, so a request reaches it at
# once, from a sandbox behind NAT too.

BUS='$HOME/.reflex/bus'

self_id() {
  _f="$HOME/.reflex/id"
  if [ ! -s "$_f" ]; then
    mkdir -p "$HOME/.reflex"
    printf '%s-%s\n' "$(hostname -s 2>/dev/null || hostname)" "$(od -An -N4 -tx4 /dev/urandom | tr -d ' \n')" > "$_f"
  fi
  cat "$_f"
}

# Post a request (JSON from perl's args), wait for its answer, print it.
ask_home() { # ask_home OP WAIT_SECONDS KEY=VALUE... [-- LIST...]
  _op=$1 _wait=$2; shift 2
  _id="$(date +%s)-$$"
  mkdir -p "$HOME/.reflex/bus/out" "$HOME/.reflex/bus/in"
  perl -MJSON::PP -e '
    my %r = (op => shift, id => shift, pane => $ENV{HC_TERMINAL_ID} // "", cwd => $ENV{PWD} // "", at => time);
    my $h = eval { local $/; open my $f, "<", "$ENV{HOME}/.reflex/home" or die; JSON::PP->new->decode(<$f>) } // {};
    $r{home} = $h->{home} // ""; $r{origin} = $h->{origin} // "";
    my @list; my $l = 0;
    for (@ARGV) { if ($_ eq "--") { $l = 1; next } if ($l) { push @list, $_ } else { my ($k, $v) = split /=/, $_, 2; $r{$k} = $v } }
    $r{paths} = \@list if $l;
    print JSON::PP->new->canonical->encode(\%r), "\n"' "$_op" "$_id" "$@" > "$HOME/.reflex/bus/out/$_id.json.tmp"
  mv "$HOME/.reflex/bus/out/$_id.json.tmp" "$HOME/.reflex/bus/out/$_id.json"
  [ "$_wait" -gt 0 ] || { echo "$_id"; return 0; }
  _n=0
  until [ -f "$HOME/.reflex/bus/in/$_id.json" ]; do
    _n=$((_n + 1))
    if [ $_n -gt "$_wait" ]; then
      rm -f "$HOME/.reflex/bus/out/$_id.json"
      die "no Reflex answered in $_wait s (is the Mac that moved this session awake, with Reflex running?)"
    fi
    sleep 1
  done
  _a="$HOME/.reflex/bus/in/$_id.json"
  jget message < "$_a" 2>/dev/null && echo
  jget output < "$_a" 2>/dev/null && echo || true
  _ok=$(jget ok < "$_a" 2>/dev/null || echo 0)
  rm -f "$_a"
  [ "$_ok" = 1 ]
}

home() {
  _hp=""
  case ${1:-} in
    fetch)
      shift; [ $# -gt 0 ] || die "home fetch PATH..."
      # Paths as they are where the files are: ~ for its home.
      _n=$#
      for p in "$@"; do
        case $p in "$HOME"/*) p="~/${p#"$HOME"/}" ;; esac
        set -- "$@" "$p"
      done
      shift "$_n"
      say "Asking Reflex for $*... (the user approves it there)"
      ask_home fetch 1800 -- "$@" ;;
    ls)
      shift; p=${1:-~}
      case $p in "$HOME"/*) p="~/${p#"$HOME"/}" ;; esac
      ask_home ls 600 -- "$p" ;;
    machines) ask_home machines 60 ;;
    *) die "home fetch PATH... | home ls PATH | home machines" ;;
  esac
}

# The agent says where, and what its work needs besides this project
# (other repositories, files, folders): Reflex copies them from wherever
# this machine is, through itself, then moves the session.
move() {
  [ "${1:-}" = self ] || die "move self --to MACHINE [PATH...]"
  [ "${2:-}" = --to ] && [ -n "${3:-}" ] || die "move self --to MACHINE [PATH...]"
  [ -n "${HC_TERMINAL_ID:-}" ] || die "not in a herdr-core terminal (no HC_TERMINAL_ID): Reflex can't tell which session to move"
  to=$3; shift 3
  _n=$#
  for p in "$@"; do
    [ -e "$p" ] || die "no $p here"
    p=$(cd "$(dirname "$p")" && pwd -P)/$(basename "$p")
    set -- "$@" "$p"
  done
  shift "$_n"
  # (Reflex says at once whether it knows the machine.)
  ask_home move 60 to="$to" -- "$@"
}

# What an agent said its work needs: a repository as git sees it (sync),
# anything else as it is (copy), each to the same path there.
bring() { # bring MACHINE PATH... [--from SRC]
  m=$1; shift
  _bf=. _bl=""
  while [ $# -gt 0 ]; do
    case $1 in --from) _bf=$2; shift 2 ;; *) _bl="$_bl
$1"; shift ;; esac
  done
  printf '%s\n' "$_bl" | while IFS= read -r p; do
    [ -n "$p" ] || continue
    if rsh "$_bf" "[ -e $(q "$p")/.git ]" >/dev/null 2>&1; then
      ( sync "$m" "$p" --from "$_bf" )
    else
      ( copy "$m" "$p" --from "$_bf" )
    fi
  done
}

# What's in a folder (or a file's details), where it is.
list() { # list PATH [--from SRC]
  p=${1:-~}; shift || true
  [ "${1:-}" = --from ] && from_src "$2"
  case $p in ("~") p=$S_HOME ;; ("~/"*) p="$S_HOME/${p#"~/"}" ;; esac
  rsh "$SRC" "ls -lAh $(q "$p")"
}

# Reflex's side: wait (up to SECONDS) for requests on MACHINE, take them and
# print each as a JSON line. Its own, or any nobody took in 20 s.
bus_listen() { # bus_listen MACHINE [SECONDS]
  rsh "$1" "d=$BUS; mkdir -p \"\$d/out\" \"\$d/in\" \"\$d/taken\"; me=$(q "$(self_id)"); i=0
    age() { echo \$(( \$(date +%s) - \$(stat -c %Y \"\$1\" 2>/dev/null || stat -f %m \"\$1\") )); }
    # (Taken by a Reflex that went away before answering: again.)
    for f in \"\$d\"/taken/*.json; do [ -f \"\$f\" ] && [ ! -f \"\$d/in/\$(basename \"\$f\")\" ] && [ \$(age \"\$f\") -gt 1800 ] && mv \"\$f\" \"\$d/out/\"; done
    while [ \$i -lt ${2:-240} ]; do
      got=''
      for f in \"\$d\"/out/*.json; do
        [ -f \"\$f\" ] || continue
        if grep -q \"\\\"home\\\":\\\"\$me\\\"\" \"\$f\" || grep -q '\"home\":\"\"' \"\$f\" || [ \$(age \"\$f\") -gt 20 ]; then
          n=\$(basename \"\$f\")
          mv \"\$f\" \"\$d/taken/\$n\" 2>/dev/null && { cat \"\$d/taken/\$n\"; got=1; }
        fi
      done
      [ -n \"\$got\" ] && exit 0
      sleep 1; i=\$((i + 1))
    done; exit 0"
}

# The answer to request ID (JSON, as an argument or on stdin), where it was asked.
bus_reply() { # bus_reply MACHINE ID [JSON]
  if [ $# -ge 3 ]; then printf '%s\n' "$3" | bus_reply "$1" "$2"; return; fi
  rsh_in "$1" "d=$BUS; mkdir -p \"\$d/in\" && cat > \"\$d/in/$2.json.tmp\" && mv \"\$d/in/$2.json.tmp\" \"\$d/in/$2.json\" && rm -f \"\$d/taken/$2.json\""
}

bus() {
  case ${1:-} in
    listen) shift; bus_listen "$@" ;;
    reply) shift; bus_reply "$@" ;;
    *) die "bus listen MACHINE [SECONDS] | bus reply MACHINE ID" ;;
  esac
}

# Setup
# -----

skill_src() {
  for s in "$HERE/../skills/reflex/SKILL.md" "$HERE/../integrations/skills/reflex/SKILL.md"; do
    [ -f "$s" ] && { printf '%s' "$s"; return; }
  done
  die "the reflex skill isn't next to this script"
}

skill() {
  [ "${1:-}" = install ] || die "skill install [--on MACHINE]"
  src=$(skill_src)
  if [ "${2:-}" = --on ]; then
    m=$3
    for d in .claude/skills/reflex .codex/skills/reflex .pi/agent/skills/reflex; do
      put "$m" "$src" "$d/SKILL.md"
    done
    # And this command, for `reflex home` there.
    put "$m" "$HERE/$(basename "$0")" .local/bin/reflex
    rsh "$m" 'chmod 755 "$HOME/.local/bin/reflex"' >/dev/null
    echo "installed the reflex skill and command on $m"
    return
  fi
  for h in .claude .codex .pi/agent; do
    [ -d "$HOME/$h" ] || continue
    mkdir -p "$HOME/$h/skills/reflex"
    cp "$src" "$HOME/$h/skills/reflex/SKILL.md"
    echo "installed ~/$h/skills/reflex/SKILL.md"
  done
}

install() {
  mkdir -p "$HOME/.local/bin"
  ln -sf "$HERE/$(basename "$0")" "$HOME/.local/bin/reflex"
  echo "linked ~/.local/bin/reflex"
}

cmd=${1:-}
[ $# -gt 0 ] && shift
case $cmd in
  machine)
    sub=${1:-}; [ $# -gt 0 ] && shift
    case $sub in
      new) machine_new "$@" ;; rm) machine_rm "$@" ;; ls) machine_ls ;;
      extend) machine_extend "$@" ;; state) machine_state "$@" ;; resume) machine_resume "$@" ;;
      *) die "machine new|rm|ls|extend|state|resume" ;;
    esac ;;
  where) where "$@"; echo ;;
  sync) sync "$@" ;;
  fixgit) fixgit "$1" "$(where "$1" "$(cd "${2:-$PWD}" && pwd -P)")" ;;
  copy) copy "$@" ;;
  list) list "$@" ;;
  bring) bring "$@" ;;
  creds) creds "$@" ;;
  session) session "$@" ;;
  snapshot) snapshot "$@" ;;
  template) template "$@" ;;
  move) move "$@" ;;
  home) home "$@" ;;
  bus) bus "$@" ;;
  id) self_id ;;
  skill) skill "$@" ;;
  install) install ;;
  ""|-h|--help|help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" ;;
  *) die "unknown command $cmd (reflex --help)" ;;
esac
