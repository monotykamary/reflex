#!/bin/sh
# reflex: take a session to another machine. Reflex's move button and @boat
# use these steps; so does the reflex skill, which an agent follows to build
# your template the first time.
#
#   reflex machine new [--template | --from SNAPSHOT] [--type T] [--name N]
#   reflex machine rm NAME          reflex machine ls
#   reflex machine extend NAME SECONDS | state NAME | resume NAME
#   reflex mesh sync                every machine here, in your other Macs' too
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
#   reflex template [--json|--keep] exit 0 current, 1 changed, 2 none
#                                   (--keep: what's here now is current)
#   reflex move self --to MACHINE [PATH...]
#                                   asks Reflex to move this session, and what
#                                   its work needs; you approve it in the app
#   reflex list PATH [--from SRC]   what's in a folder there
#   reflex run-at [--from SRC] [--cwd DIR] [--timeout S] -- COMMAND
#   reflex bring MACHINE PATH... [--from SRC]
#                                   repositories (sync) and anything else (copy)
#   reflex home fetch PATH... | home ls PATH | home machines
#   reflex home run [--cwd DIR] [--timeout S] COMMAND
#   reflex on NAME fetch|ls|run ...  the same, on another machine (home --on NAME)
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

# (boat's installer, and Reflex giving a Mac your login, put it here.)
[ -d "$HOME/.ascii/bin" ] && case ":$PATH:" in *":$HOME/.ascii/bin:"*) ;; *) PATH="$PATH:$HOME/.ascii/bin" ;; esac
DATA=${REFLEX_DATA:-"$HOME/Library/Application Support/Reflex"}
DIR="$DATA/boat"
TEMPLATE=${REFLEX_TEMPLATE:-reflex-template}
# (Where this script really is: ~/.local/bin/reflex is a link to it.)
_self=$0
while [ -L "$_self" ]; do
  _l=$(readlink "$_self")
  case $_l in /*) _self=$_l ;; *) _self=$(dirname "$_self")/$_l ;; esac
done
HERE=$(cd "$(dirname "$_self")" && pwd -P)
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
# How herdr-core here reaches a machine (its --via command).
target_of() { # target_of NAME
  hc machine ls --json 2>/dev/null | NAME=$1 perl -MJSON::PP -0777 -ne '
    for (@{ JSON::PP->new->decode($_)->{machines} // [] }) { if ($_->{name} eq $ENV{NAME}) { print $_->{target} // ""; exit 0 } }
    exit 1'
}
# A boat sandbox this Mac looks after: one it made, or one another Mac shared
# (so it stays up, and comes back, with that Mac off). Its boat id.
sandbox_id() { # sandbox_id NAME
  if ours "$1"; then boat_id "$1"; return; fi
  [ -f "$DIR/shared/$1" ] || return 1
  _st=$(target_of "$1") || return 1
  printf '%s' "$_st" | perl -ne 'print $1 if /boat ssh (bx_\w+)/' | grep . || return 1
}

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
  # (Your other Macs see its sessions too.)
  ( mesh_sync ) >/dev/null 2>&1 || true
  echo "$name"
}

machine_rm() {
  name=$1
  ours "$name" || die "$name isn't a machine Reflex made: remove it with hc machine rm"
  id=$(boat_id "$name")
  hc machine rm "$name" >/dev/null 2>&1 || true
  ( machine_unshare "$name" ) >/dev/null 2>&1 || true
  boat delete --yes --no-update "$id" >/dev/null 2>&1 || say "boat delete $id failed: delete it with boat delete"
  rm -f "$(record "$name")"
  rm -rf "$DIR/sent/$name"
  echo "removed $name ($id)"
}

# Its boat sandbox: how long it stays up, its state, and back up again.
machine_extend() { # machine_extend NAME SECONDS
  _id=$(sandbox_id "$1") || die "$1 isn't a boat sandbox Reflex made or was shared"
  boat extend "$_id" --ttl "$2" --json --no-update >/dev/null 2>&1 || die "boat extend $_id failed"
}
machine_state() { # machine_state NAME: boat's word for it (running, idle, stopped...)
  _id=$(sandbox_id "$1") || die "$1 isn't a boat sandbox Reflex made or was shared"
  boat info "$_id" --json --no-update 2>/dev/null | jget sandbox state || die "boat info $_id failed"
  echo
}
machine_resume() { # machine_resume NAME [--type T]: running (at that size) and connected again
  _id=$(sandbox_id "$1") || die "$1 isn't a boat sandbox Reflex made or was shared"
  _rt=""; [ "${2:-}" = --type ] && _rt=${3:-}
  # (Added again the way it was reached, should its herdr-core be a new one.)
  _via=$(target_of "$1" 2>/dev/null || true); [ -n "$_via" ] || _via="boat ssh $_id"
  # (Already running, after all: nothing to resume.)
  _st=$(machine_state "$1" 2>/dev/null || true)
  if [ "$_st" = stopping ]; then
    say "$_id is still saving; waiting for it to stop..."
    i=0
    while [ "$(machine_state "$1" 2>/dev/null || true)" = stopping ]; do
      i=$((i + 1)); [ $i -lt 120 ] || die "$_id is still stopping after 6 minutes"
      sleep 3
    done
    _st=stopped
  fi
  case $_st in
    running|idle|ready|busy) ;;
    *)
      say "Resuming $_id${_rt:+ as $_rt}..."
      boat resume "$_id" --ttl 3600 ${_rt:+--type "$_rt"} --json --no-update >/dev/null 2>&1 || die "boat resume $_id failed"
      ;;
  esac
  i=0
  until connected "$1"; do
    i=$((i + 1))
    # On a different machine size its herdr-core is a new one, which hc
    # won't take for the old: added again, same name.
    if [ $i = 20 ] && hc machine ls --json 2>/dev/null | grep -q "different core answers"; then
      say "$1 came back with a new herdr-core: adding it again"
      hc machine rm "$1" >/dev/null 2>&1 || true
      hc machine add --via "$_via" --name "$1" --temp --install --json >/dev/null 2>&1 || die "hc machine add $1 failed"
    fi
    [ $i -lt 180 ] || die "$1 is running again but herdr-core hasn't reconnected (hc machine ls)"
    sleep 1
  done
  # (Another size is another herdr-core there: your other Macs again too.)
  [ -n "$_rt" ] && { ( mesh_sync ) >/dev/null 2>&1 || true; }
  echo "$1"
}

# Your other Macs with Reflex (herdr-core's machines that stay, connected).
peers() {
  hc machine ls --json 2>/dev/null | perl -MJSON::PP -0777 -e '
    my $j = JSON::PP->new->decode(<STDIN>);
    for (@{$j->{machines}}) { print "$_->{name}\n" if $_->{state} eq "connected" && !$_->{temporary} }'
}
SHARED='$HOME/Library/Application Support/Reflex/boat/shared'
BOAT_LOGIN="$HOME/Library/Application Support/ascii/boat/config.json"

# The boat CLI on PEER when it's logged in there (its path), else nothing.
peer_boat() { # peer_boat PEER
  rsh "$1" 'b=$(PATH="$HOME/.ascii/bin:$HOME/.local/bin:/opt/homebrew/bin:$PATH" command -v boat) && PATH="$(dirname "$b"):$PATH" boat status --check --no-update >/dev/null 2>&1 && printf %s "$b"' 2>/dev/null || true
}

# Your boat login (and the CLI, if it's missing) on another of your Macs
# that has none: it reaches your sandboxes itself, and keeps them up and
# resumes them while this Mac is off. A login of its own is left alone.
give_boat() { # give_boat PEER BOAT
  [ -f "$BOAT_LOGIN" ] || return 1
  rsh "$1" '[ ! -f "$HOME/Library/Application Support/ascii/boat/config.json" ]' >/dev/null 2>&1 || return 1
  if ! rsh "$1" 'PATH="$HOME/.ascii/bin:$HOME/.local/bin:/opt/homebrew/bin:$PATH" command -v boat' >/dev/null 2>&1; then
    put "$1" "$2" .ascii/bin/boat && rsh "$1" 'chmod 700 "$HOME/.ascii/bin/boat"' >/dev/null 2>&1 || return 1
  fi
  put "$1" "$BOAT_LOGIN" "Library/Application Support/ascii/boat/config.json" || return 1
  say "$1 has your boat login now"
}

# The mesh: every machine this Mac's herdr-core reaches, in each other Mac's
# too (each Reflex shares its own, so they all converge). A boat sandbox
# goes through that Mac's own boat login when it has one; anything else is
# relayed through this Mac, the shell line quoted so all of it runs there.
# One that stopped connecting there (a sandbox resumed at another size is a
# new herdr-core) is added again; one this Mac no longer has goes.
mesh_sync() {
  _me=$(scutil --get LocalHostName 2>/dev/null || hostname -s)
  _boat=$(command -v boat 2>/dev/null || true)
  hc machine ls --json > "$T/mine.json" 2>/dev/null || die "herdr-core isn't answering"
  for p in $(peers); do
    rsh "$p" "[ -d \"\$HOME/Library/Application Support/Reflex\" ]" >/dev/null 2>&1 || continue
    rsh "$p" 'export PATH="$HOME/.local/bin:$PATH"; hc machine ls --json' > "$T/theirs.json" 2>/dev/null || continue
    _from=$(rsh "$p" "cd \"$SHARED\" 2>/dev/null && grep -lx $(q "$_me") * 2>/dev/null; true" 2>/dev/null || true)
    _pb=$(peer_boat "$p")
    if [ -z "$_pb" ] && [ -n "$_boat" ] && boat status --check --no-update >/dev/null 2>&1; then
      give_boat "$p" "$_boat" && _pb=$(peer_boat "$p")
    fi
    ME="$_me" PEER="$p" PB="$_pb" BOAT="$_boat" FROM="$_from" perl -MJSON::PP -e '
      sub load { local $/; open my $f, "<", shift or return []; JSON::PP->new->decode(<$f>)->{machines} // [] }
      my @mine = @{ load($ARGV[0]) }; my @theirs = @{ load($ARGV[1]) };
      my %from = map { $_ => 1 } grep { length } split /\n/, $ENV{FROM};
      my ($peer) = grep { $_->{name} eq $ENV{PEER} } @mine;
      my ($back) = grep { lc($_->{host} // "") eq lc($ENV{ME}) && !$_->{temporary} } @theirs;
      my %theirs = map { $_->{name} => $_ } @theirs;
      my %hosts = map { (lc($_->{host} // "") => 1) } grep { $_->{state} eq "connected" } @theirs;
      my %mine = map { $_->{name} => 1 } @mine;
      for my $m (@mine) {
        next unless $m->{state} eq "connected";
        next if $m->{name} eq $ENV{PEER} || lc($m->{host} // "") eq lc($peer->{host} // "-");
        # (Shared with this Mac by another: that one shares it.)
        next if -e "$ENV{HOME}/Library/Application Support/Reflex/boat/shared/$m->{name}";
        my $t = $theirs{$m->{name}};
        my ($id) = ($m->{target} // "") =~ /^\S*boat ssh (bx_\w+)$/;
        # A sandbox it reaches through this Mac, now that it has a boat
        # login: directly (it stays reachable with this Mac off).
        my $redo = $t && $id && length $ENV{PB} && $from{$m->{name}} && ($t->{target} // "") =~ /\srelay$/;
        unless ($redo) {
          # Reached there already, short-lived and not yet marked: its Reflex
          # shows it once marked shared.
          if ($t && $t->{state} eq "connected" && $m->{temporary} && !$from{$m->{name}}) { print "mark\t$m->{name}\n"; next }
          next if $t && ($t->{state} eq "connected" || !$from{$m->{name}});
          next if !$t && $hosts{lc($m->{host} // "")};
        }
        my $via;
        if ($id) {
          if (length $ENV{PB}) { $via = "$ENV{PB} ssh $id" }
          elsif ($back && length $ENV{BOAT}) { $via = qq{sh -c '"'"'exec ssh -T -o BatchMode=yes $back->{name} $ENV{BOAT} ssh $id "\$(printf %q "\$1")"'"'"' relay} }
        } elsif ($back && !$m->{via}) {
          $via = qq{sh -c '"'"'exec ssh -T -o BatchMode=yes $back->{name} "ssh -T -o BatchMode=yes $m->{target} \$(printf %q "\$(printf %q "\$1")")"'"'"' relay};
        }
        next unless $via;
        print join("\t", "add", $m->{name}, $via, $m->{temporary} ? "--temp" : ""), "\n";
      }
      for my $n (sort keys %from) { print "drop\t$n\n" unless $mine{$n} }
    ' "$T/mine.json" "$T/theirs.json" > "$T/plan"
    while IFS="$(printf '\t')" read -r _do _n _via _temp; do
      case $_do in
        add)
          rsh "$p" "export PATH=\"\$HOME/.local/bin:\$PATH\"; hc machine rm $(q "$_n") >/dev/null 2>&1; hc machine add --via $(q "$_via") --name $(q "$_n") $_temp --install --json >/dev/null 2>&1 && mkdir -p \"$SHARED\" && echo $(q "$_me") > \"$SHARED/\"$(q "$_n")" >/dev/null 2>&1 \
            && say "$p reaches $_n now" || say "couldn't share $_n with $p" ;;
        mark)
          rsh "$p" "mkdir -p \"$SHARED\" && echo $(q "$_me") > \"$SHARED/\"$(q "$_n")" >/dev/null 2>&1 && say "$p shows $_n now" || true ;;
        drop)
          rsh "$p" "export PATH=\"\$HOME/.local/bin:\$PATH\"; hc machine rm $(q "$_n") >/dev/null 2>&1; rm -f \"$SHARED/\"$(q "$_n")" >/dev/null 2>&1 \
            && say "$p no longer has $_n" || true ;;
      esac
    done < "$T/plan"
  done
}

# A machine gone from here (removed): gone from the Macs it was shared with.
machine_unshare() { # machine_unshare NAME
  _me=$(scutil --get LocalHostName 2>/dev/null || hostname -s)
  for p in $(peers); do
    rsh "$p" "export PATH=\"\$HOME/.local/bin:\$PATH\"; [ \"\$(cat \"$SHARED/\"$(q "$1") 2>/dev/null)\" = $(q "$_me") ] || exit 0; hc machine rm $(q "$1") >/dev/null 2>&1; rm -f \"$SHARED/\"$(q "$1")" >/dev/null 2>&1 || true
  done
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

# What a template input amounts to, hashed. A JSON file without what changes
# by itself (the model last picked, changelog and last-used markers, a
# device id, anything about tokens, logins or sessions); anything else as
# it is. (Version 2 of this; templates built before get a fresh baseline.)
DIGEST='
  use JSON::PP; use Digest::SHA qw(sha256_hex);
  my $volatile = qr/(token|secret|auth|login|session|device|changelog|^last|updated|^recent|history|^default(model|provider|thinking))/i;
  sub strip { my $v = shift;
    if (ref $v eq "HASH") { return { map { ($_ => strip($v->{$_})) } grep { $_ !~ $volatile } keys %$v } }
    if (ref $v eq "ARRAY") { return [ map { strip($_) } @$v ] }
    return $v }
  sub digest { my $p = shift; (my $f = $p) =~ s/^~/$ENV{HOME}/;
    open my $fh, "<", $f or return ""; local $/; binmode $fh; my $raw = <$fh>;
    if ($f =~ /\.json$/) { my $j = eval { JSON::PP->new->decode($raw) };
      return "j:" . sha256_hex(JSON::PP->new->canonical->encode(strip($j))) if ref $j eq "HASH" }
    return sha256_hex($raw) }'

hashes() { # the inputs' hashes, as JSON
  perl -e "$DIGEST"'
    my %h; $h{$_} = digest($_) for @ARGV;
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
      at => $ARGV[3], hashes => JSON::PP->new->decode($ARGV[4]), manifest => $m, hashing => 2 })' \
    "$manifest" "$TEMPLATE" "$id" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$h")
  printf '%s\n' "$out" | rsh_in "$m" 'mkdir -p "$HOME/.reflex" && cat > "$HOME/.reflex/template.json"'
  say "Saving $id as $TEMPLATE..."
  boat snapshot --no-update "$id" "$TEMPLATE" >&2 || die "boat snapshot failed"
  mkdir -p "$DIR"
  printf '%s\n' "$out" > "$DIR/template.json"
  echo "$TEMPLATE"
}

# `--keep`: what's here now is what the template stands for (a change that
# doesn't matter to it).
template() {
  [ -f "$DIR/template.json" ] || { [ "${1:-}" = --json ] && echo '{"state":"none"}' || echo "no template"; exit 2; }
  perl -e "$DIGEST"'
    my ($file, $arg) = @ARGV;
    my $t = JSON::PP->new->decode(do { local $/; open my $f, "<", $file or die; <$f> });
    my $keep = $arg eq "--keep";
    # Built before digests ignored what changes by itself: this is its baseline.
    $keep = 1 unless ($t->{hashing} // 1) >= 2;
    my @changed;
    for my $p (sort keys %{$t->{hashes}}) {
      my $now = digest($p);
      if ($keep) { $t->{hashes}{$p} = $now } elsif ($now ne $t->{hashes}{$p}) { push @changed, $p } }
    if ($keep) {
      $t->{hashing} = 2;
      open my $o, ">", "$file.tmp" or die; print $o JSON::PP->new->canonical->pretty->encode($t); close $o; rename "$file.tmp", $file;
    }
    my $state = @changed ? "stale" : "current";
    if ($arg eq "--json") {
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
  export REFLEX_WAIT=$_wait
  _id="$(date +%s)-$$"
  mkdir -p "$HOME/.reflex/bus/out" "$HOME/.reflex/bus/in"
  perl -MJSON::PP -e '
    my %r = (op => shift, id => shift, pane => $ENV{HC_TERMINAL_ID} // "", cwd => $ENV{PWD} // "", at => time);
    $r{until} = time + $ENV{REFLEX_WAIT};
    my $h = eval { local $/; open my $f, "<", "$ENV{HOME}/.reflex/home" or die; JSON::PP->new->decode(<$f>) } // {};
    $r{home} = $h->{home} // ""; $r{origin} = $h->{origin} // "";
    my @list; my $l = 0;
    for (@ARGV) { if ($_ eq "--") { $l = 1; next } if ($l) { push @list, $_ } else { my ($k, $v) = split /=/, $_, 2; $r{$k} = $v } }
    $r{paths} = \@list if $l;
    print JSON::PP->new->canonical->encode(\%r), "\n"' "$_op" "$_id" "$@" > "$HOME/.reflex/bus/out/$_id.json.tmp"
  # A heartbeat while this waits: Reflex drops a request whose asker is gone
  # (stopped, interrupted), and an asker that stops takes its request along.
  mkdir -p "$HOME/.reflex/bus/alive"
  : > "$HOME/.reflex/bus/alive/$_id"
  trap 'rm -f "$HOME/.reflex/bus/out/'"$_id"'.json" "$HOME/.reflex/bus/alive/'"$_id"'" "$HOME/.reflex/bus/in/'"$_id"'.json"; rm -rf "$T"' EXIT
  trap 'exit 130' INT TERM HUP
  mv "$HOME/.reflex/bus/out/$_id.json.tmp" "$HOME/.reflex/bus/out/$_id.json"
  [ "$_wait" -gt 0 ] || { echo "$_id"; return 0; }
  _n=0
  until [ -f "$HOME/.reflex/bus/in/$_id.json" ]; do
    touch "$HOME/.reflex/bus/alive/$_id"
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
  # (A command's own exit code, when one ran.)
  _code=$(jget code < "$_a" 2>/dev/null || true)
  rm -f "$_a"
  [ -n "$_code" ] && return "$_code"
  [ "$_ok" = 1 ]
}

home() {
  # (--on NAME: that machine instead of the one this session came from, as
  # the answering Reflex names it; "here" is the Mac it runs on.)
  _on=""
  if [ "${1:-}" = --on ]; then [ $# -ge 2 ] || die "home --on NAME ..."; _on=$2; shift 2; fi
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
      ask_home fetch 1800 on="$_on" -- "$@" ;;
    ls)
      shift; p=${1:-~}
      case $p in "$HOME"/*) p="~/${p#"$HOME"/}" ;; esac
      ask_home ls 600 on="$_on" -- "$p" ;;
    machines) ask_home machines 60 ;;
    run)
      # A shell line on the Mac this session came from (the user allows each
      # one there): its output and exit code come back.
      shift; _rc=$PWD _rt=120
      while [ $# -gt 0 ]; do
        case $1 in
          --cwd) _rc=$2; shift 2 ;;
          --timeout) _rt=$2; shift 2 ;;
          --) shift; break ;;
          *) break ;;
        esac
      done
      [ $# -gt 0 ] || die "home run [--cwd DIR] [--timeout SECONDS] COMMAND..."
      case $_rc in "$HOME") _rc="~" ;; "$HOME"/*) _rc="~/${_rc#"$HOME"/}" ;; esac
      say "Asking Reflex to run that... (the user allows it there)"
      ask_home run $((1800 + _rt)) on="$_on" command="$*" dir="$_rc" timeout="$_rt" ;;
    *) die "home [--on NAME] fetch PATH... | ls PATH | run COMMAND | machines" ;;
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

# A shell line on SRC (a login shell, in DIR when it's there), its output
# (stdout and stderr) and exit code; ended after SECONDS.
run_at() { # run_at [--from SRC] [--cwd DIR] [--timeout SECONDS] -- COMMAND
  _wd="~" _wt=120
  while [ $# -gt 0 ]; do
    case $1 in
      --from) from_src "$2"; shift 2 ;;
      --cwd) _wd=$2; shift 2 ;;
      --timeout) _wt=$2; shift 2 ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  case $_wd in ("~") _wd=$S_HOME ;; ("~/"*) _wd="$S_HOME/${_wd#"~/"}" ;; esac
  _wl="cd $(q "$_wd") 2>/dev/null || cd; $*"
  if [ "$SRC" = . ]; then
    perl -e 'alarm shift; exec @ARGV' "$_wt" sh -lc "$_wl" 2>&1
  else
    [ "$_wt" -le 600 ] || _wt=600
    hc exec --on "$SRC" --timeout "$_wt" -- sh -lc "$_wl" 2>&1
  fi
}

# What's in a folder (or a file's details), where it is.
list() { # list PATH [--from SRC]
  p=${1:-~}; shift || true
  [ "${1:-}" = --from ] && from_src "$2"
  case $p in ("~") p=$S_HOME ;; ("~/"*) p="$S_HOME/${p#"~/"}" ;; esac
  rsh "$SRC" "ls -lAh $(q "$p")"
}

# Reflex's side: wait (up to SECONDS) for requests on MACHINE and print
# each as a JSON line, leaving it there: Reflex claims one (bus claim) before
# it answers, so a listener whose Reflex quit takes nothing with it. Its own, one that names no Reflex (the
# machine's own Reflex first: others wait 5 s), or any nobody took in 20 s.
bus_listen() { # bus_listen MACHINE [SECONDS]
  _wait=5; [ "$1" = . ] && _wait=0
  rsh "$1" "d=$BUS; mkdir -p \"\$d/out\" \"\$d/in\" \"\$d/taken\"; me=$(q "$(self_id)"); i=0
    age() { echo \$(( \$(date +%s) - \$(stat -c %Y \"\$1\" 2>/dev/null || stat -f %m \"\$1\") )); }
    # (Taken by a Reflex that went away before answering: again.)
    for f in \"\$d\"/taken/*.json; do [ -f \"\$f\" ] && [ ! -f \"\$d/in/\$(basename \"\$f\")\" ] && [ \$(age \"\$f\") -gt 1800 ] && mv \"\$f\" \"\$d/out/\"; done
    # Answers nobody read (the asker had gone) and stale claims: away.
    for f in \"\$d\"/in/*.json \"\$d\"/in/.json; do [ -f \"\$f\" ] && [ \$(age \"\$f\") -gt 600 ] && rm -f \"\$f\"; done
    for f in \"\$d\"/taken/*.json; do [ -f \"\$f\" ] && [ \$(age \"\$f\") -gt 86400 ] && rm -f \"\$f\"; done
    mkdir -p \"\$d/alive\"
    while [ \$i -lt ${2:-240} ]; do
      got=''
      for f in \"\$d\"/out/*.json; do
        [ -f \"\$f\" ] || continue
        # Its asker gone (no heartbeat for 15 s; none at all from an older
        # reflex, past 30 minutes): nobody to answer.
        n=\$(basename \"\$f\" .json); a=\"\$d/alive/\$n\"
        if { [ -f \"\$a\" ] && [ \$(age \"\$a\") -gt 15 ]; } || { [ ! -f \"\$a\" ] && [ \$(age \"\$f\") -gt 1800 ]; }; then rm -f \"\$f\" \"\$a\"; continue; fi
        if grep -q \"\\\"home\\\":\\\"\$me\\\"\" \"\$f\" || { grep -q '\"home\":\"\"' \"\$f\" && [ \$(age \"\$f\") -ge $_wait ]; } || [ \$(age \"\$f\") -gt 20 ]; then
          cat \"\$f\" && got=1
        fi
      done
      [ -n \"\$got\" ] && exit 0
      sleep 1; i=\$((i + 1))
    done; exit 0"
}

# Whether the session that asked ID still waits (its heartbeat fresh).
bus_alive() { # bus_alive MACHINE ID
  rsh "$1" "a=$BUS/alive/$2; [ -f \"\$a\" ] && [ \$(( \$(date +%s) - \$(stat -c %Y \"\$a\" 2>/dev/null || stat -f %m \"\$a\") )) -le 15 ]" >/dev/null
}

# Request ID is this Reflex's to answer (exit 1: another took it).
bus_claim() { # bus_claim MACHINE ID
  rsh "$1" "d=$BUS; mkdir -p \"\$d/taken\" && mv \"\$d/out/$2.json\" \"\$d/taken/$2.json\" 2>/dev/null" >/dev/null
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
    claim) shift; bus_claim "$@" ;;
    alive) shift; bus_alive "$@" ;;
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
      unshare) machine_unshare "$@" ;;
      extend) machine_extend "$@" ;; state) machine_state "$@" ;; resume) machine_resume "$@" ;;
      *) die "machine new|rm|ls|extend|state|resume" ;;
    esac ;;
  where) where "$@"; echo ;;
  sync) sync "$@" ;;
  fixgit) fixgit "$1" "$(where "$1" "$(cd "${2:-$PWD}" && pwd -P)")" ;;
  copy) copy "$@" ;;
  list) list "$@" ;;
  bring) bring "$@" ;;
  run-at) run_at "$@" ;;
  creds) creds "$@" ;;
  session) session "$@" ;;
  snapshot) snapshot "$@" ;;
  template) template "$@" ;;
  move) move "$@" ;;
  home) home "$@" ;;
  on) [ $# -ge 2 ] || die "on NAME fetch PATH... | ls PATH | run COMMAND"; _n=$1; shift; home --on "$_n" "$@" ;;
  bus) bus "$@" ;;
  id) self_id ;;
  skill) skill "$@" ;;
  mesh) [ "${1:-}" = sync ] || die "mesh sync"; mesh_sync ;;
  install) install ;;
  ""|-h|--help|help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" ;;
  *) die "unknown command $cmd (reflex --help)" ;;
esac
