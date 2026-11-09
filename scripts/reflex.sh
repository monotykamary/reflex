#!/bin/sh
# reflex: take a session to another machine. Reflex's move button and @boat
# use these steps; so does the reflex skill, which an agent follows to build
# your template the first time.
#
#   reflex machine new [--template | --from SNAPSHOT] [--type T] [--name N]
#   reflex machine rm NAME          reflex machine ls
#   reflex where MACHINE PATH       the path there (~/x here is ~/x there)
#   reflex sync MACHINE [DIR]       the project's files (git's view: tracked
#                                   and untracked but not ignored, plus .git)
#   reflex creds MACHINE [--claude] [--any]
#   reflex session MACHINE KIND SESSION CWD
#   reflex snapshot MACHINE --manifest FILE
#   reflex template [--json]        exit 0 current, 1 stale, 2 none
#   reflex move self --to MACHINE   asks Reflex; you approve it in the app
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

# Run a shell line there, stdin passed through, its exit code back.
# (Helpers keep to their own _names: sh has no locals.)
rsh() { hc exec --on "$1" -i --timeout 600 -- sh -c "$2" < "${3:-/dev/null}"; }
rsh_in() { hc exec --on "$1" -i --timeout 600 -- sh -c "$2"; }

remote_home() {
  _h=$(rsh "$1" 'printf %s "$HOME"') || die "can't reach $1 (hc machine ls)"
  [ -n "$_h" ] || die "$1 has no \$HOME"
  printf '%s' "$_h"
}

# ~/x here is ~/x there; nothing outside your home moves.
where() {
  case $2 in
    "$HOME") remote_home "$1" ;;
    "$HOME"/*) printf '%s%s' "$(remote_home "$1")" "${2#"$HOME"}" ;;
    *) die "$2 is outside your home folder: only folders under ~ move" ;;
  esac
}

connected() {
  hc machine ls --json 2>/dev/null | perl -MJSON::PP -0777 -e '
    my $j = JSON::PP->new->decode(<STDIN>);
    for (@{$j->{machines}}) { exit 0 if $_->{name} eq $ARGV[0] && $_->{state} eq "connected" } exit 1' "$1"
}

machine_new() {
  from="" type="" name="" ttl=""
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
  if ! r=$(hc machine add --via "boat ssh $id" --name "$name" --temp --install --json 2>&1); then
    say "hc machine add failed: $r"
    boat delete --yes "$id" >/dev/null 2>&1 || true
    rm -f "$(record "$name")"
    exit 1
  fi
  i=0
  until connected "$name"; do
    i=$((i + 1))
    [ $i -lt 90 ] || die "$name didn't connect (hc machine ls)"
    sleep 1
  done
  echo "$name"
}

machine_rm() {
  name=$1
  ours "$name" || die "$name isn't a machine Reflex made: remove it with hc machine rm"
  id=$(boat_id "$name")
  hc machine rm "$name" >/dev/null 2>&1 || true
  boat delete --yes --no-update "$id" >/dev/null 2>&1 || say "boat delete $id failed: delete it with boat delete"
  rm -f "$(record "$name")"
  echo "removed $name ($id)"
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
  m=$1 d=${2:-$PWD}
  d=$(cd "$d" && pwd -P)
  top=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$d")
  dest=$(where "$m" "$top")
  say "Copying $top to $m:$dest..."
  # macOS's tar would add ._ files and xattrs Linux warns about.
  export COPYFILE_DISABLE=1
  if git -C "$top" rev-parse --git-dir >/dev/null 2>&1; then
    { git -C "$top" ls-files -co --exclude-standard -z; printf '.git\0'; } \
      | tar -C "$top" --no-mac-metadata --no-xattrs --null -T - -cf "$T/tree.tar" 2>/dev/null
  else
    tar -C "$top" --no-mac-metadata --no-xattrs --exclude node_modules --exclude .DS_Store -cf "$T/tree.tar" . 2>/dev/null
  fi
  unpack "$m" "$T/tree.tar" "$dest"
  echo "$dest"
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
  rsh "$1" "mkdir -p $(q "$3") && gunzip -c $(q "$_ur") | { tar --warning=no-unknown-keyword -xf - -C $(q "$3") 2>/dev/null || true; }; rm -f $(q "$_ur")" >/dev/null
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
    [ -f "$HOME/$rel" ] || continue
    put "$m" "$HOME/$rel" "$rel"
    copied="$copied $rel"
  done
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

session() {
  m=$1 kind=$2 id=$3 cwd=$4
  rcwd=$(where "$m" "$cwd")
  rsh "$m" "mkdir -p $(q "$rcwd")" >/dev/null
  tmp="$T/session.jsonl"
  case $kind in
    claude)
      f="$HOME/.claude/projects/$(claude_dir "$cwd")/$id.jsonl"
      [ -f "$f" ] || die "no claude session $id for $cwd"
      rel=".claude/projects/$(claude_dir "$rcwd")"
      recwd "$HOME" "$(remote_home "$m")" < "$f" > "$tmp"
      put "$m" "$tmp" "$rel/$id.jsonl"
      # Its subagents' transcripts, when it has any.
      if [ -d "${f%.jsonl}" ]; then
        COPYFILE_DISABLE=1 tar -C "$(dirname "$f")" --no-mac-metadata --no-xattrs -cf "$T/sub.tar" "$id"
        unpack "$m" "$T/sub.tar" "$(remote_home "$m")/$rel"
      fi
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
      if [ -f "$id" ]; then f=$id; else
        f=$(ls -t "$HOME/.pi/agent/sessions/$(pi_dir "$cwd")"/*"$id"*.jsonl 2>/dev/null | head -n 1)
      fi
      [ -n "$f" ] && [ -f "$f" ] || die "no pi session $id for $cwd"
      rel=".pi/agent/sessions/$(pi_dir "$rcwd")/$(basename "$f")"
      recwd "$HOME" "$(remote_home "$m")" < "$f" > "$tmp"
      put "$m" "$tmp" "$rel"
      # A path names the file there; an id is the same id.
      if [ -f "$id" ]; then out="$(remote_home "$m")/$rel"; else out=$id; fi
      ;;
    codex)
      f=$(find "$HOME/.codex/sessions" -name "*$id*.jsonl" 2>/dev/null | head -n 1)
      [ -n "$f" ] || die "no codex session $id"
      rel=".codex/sessions/${f#"$HOME/.codex/sessions/"}"
      recwd "$HOME" "$(remote_home "$m")" < "$f" > "$tmp"
      put "$m" "$tmp" "$rel"
      out=$id
      ;;
    *) die "Reflex can't move a $kind session (claude, pi and codex only)" ;;
  esac
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

# Moving
# ------

move() {
  [ "${1:-}" = self ] || die "move self --to MACHINE"
  [ "${2:-}" = --to ] && [ -n "${3:-}" ] || die "move self --to MACHINE"
  to=$3
  pane=${HC_TERMINAL_ID:-}
  [ -n "$pane" ] || die "not in a herdr-core terminal (no HC_TERMINAL_ID): Reflex can't tell which session to move"
  connected "$to" || die "$to isn't connected (hc machine ls)"
  mkdir -p "$DIR/requests"
  f="$DIR/requests/$(date +%s)-$pane.json"
  printf '{"pane":"%s","to":"%s","cwd":"%s","made":%s}\n' "$pane" "$to" "$PWD" "$(ours "$to" && echo true || echo false)" > "$f.tmp"
  mv "$f.tmp" "$f"
  echo "Asked Reflex to move this session to $to. The user approves it in Reflex; it moves once this turn ends, so end your turn now."
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
    echo "installed the reflex skill on $m"
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
    case $sub in new) machine_new "$@" ;; rm) machine_rm "$@" ;; ls) machine_ls ;; *) die "machine new|rm|ls" ;; esac ;;
  where) where "$@"; echo ;;
  sync) sync "$@" ;;
  creds) creds "$@" ;;
  session) session "$@" ;;
  snapshot) snapshot "$@" ;;
  template) template "$@" ;;
  move) move "$@" ;;
  skill) skill "$@" ;;
  install) install ;;
  ""|-h|--help|help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command $cmd (reflex --help)" ;;
esac
