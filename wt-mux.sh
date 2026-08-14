#!/usr/bin/env bash
# wt-mux.sh - terminal multiplexer abstraction shared by the wt* worktree tools.
#
# Meant to be sourced, not executed:
#   . "$(dirname "$(command -v wt)")/wt-mux.sh"
#
# Backends: tmux and cmux (https://cmux.com). tmux behaviour is unchanged from
# before this library existed; cmux is the added backend.
#
# ─── Vocabulary ───────────────────────────────────────────────────────────────
# The API speaks tmux's language, because that is what the wt* tools were
# written against. cmux's topology maps onto it like so:
#
#   this library   tmux              cmux
#   ------------   ----              ----
#   "window"       window            workspace
#   "pane"         pane              pane (a container of surfaces/tabs)
#
# Panes are addressed by LABEL — agent | root | logs — never by number, because
# tmux numbers panes from 1 while cmux numbers them from 0. In tmux the label is
# the pane title (`select-pane -T`); in cmux it is the surface/tab title
# (`rename-tab`). Either way, resolution goes through mux_pane_target.
#
# ─── Backend detection ────────────────────────────────────────────────────────
# $TMUX wins whenever it is set, so running tmux inside cmux keeps working
# exactly as it did. cmux is detected via $CMUX_WORKSPACE_ID. Outside both,
# mux_kind is "none" and the tools fall back to starting a tmux session, which
# is what they always did.
#
# ─── API ──────────────────────────────────────────────────────────────────────
#   mux_kind                       -> tmux | cmux | none
#   mux_require KIND...            -> die unless the backend is one of KIND
#   mux_window_names               -> one window name per line
#   mux_current_window             -> name of the window the caller is in
#   mux_has_window NAME            -> exit 0 if a window named NAME exists
#   mux_new_window NAME DIR [L3]   -> build the 3-pane layout (L3 default: logs)
#   mux_select_window NAME
#   mux_attach NAME                -> attach, when built outside a multiplexer
#   mux_kill_window NAME
#   mux_kill_other_panes           -> close every pane except the caller's
#   mux_send NAME LABEL TEXT       -> type TEXT then Enter into a pane
#   mux_send_key NAME LABEL KEY    -> send a bare key (e.g. C-c)
#   mux_capture NAME LABEL         -> print a pane's visible text
#   mux_current_path               -> cwd of the caller's pane
#   mux_agent_start NAME           -> run `claude` in the agent pane
#   mux_agent_prompt NAME PROMPT   -> run `claude` in plan mode with PROMPT
#
# The 3-pane layout every tool shares:
#   ┌──────────┬──────────┐
#   │  agent   │   root   │
#   ├──────────┴──────────┤
#   │        logs         │   (30% tall)
#   └─────────────────────┘

# Silence cmux's "X is now an alias for Y" migration notices, which would
# otherwise contaminate every command substitution in here.
export CMUX_QUIET=1

# ── backend detection ────────────────────────────────────────────────────────

# Resolved once, lazily, so sourcing this file stays cheap.
_MUX_KIND=""

mux_kind() {
  if [ -z "$_MUX_KIND" ]; then
    if [ -n "${TMUX:-}" ]; then
      _MUX_KIND="tmux"
    elif [ -n "${CMUX_WORKSPACE_ID:-}" ] && [ -n "$(_cmux_bin)" ]; then
      _MUX_KIND="cmux"
    else
      _MUX_KIND="none"
    fi
  fi
  printf '%s' "$_MUX_KIND"
}

mux_require() {
  local kind want
  kind=$(mux_kind)
  for want in "$@"; do
    [ "$kind" = "$want" ] && return 0
  done
  echo "Error: this command requires $* (current: $kind)" >&2
  return 1
}

# ── cmux plumbing ────────────────────────────────────────────────────────────

# cmux ships its CLI inside the app bundle. Inside a cmux terminal the bundle's
# bin/ is already on PATH, but $CMUX_BUNDLED_CLI_PATH is the authoritative
# pointer, so prefer it.
_cmux_bin() {
  if [ -n "${CMUX_BUNDLED_CLI_PATH:-}" ] && [ -x "${CMUX_BUNDLED_CLI_PATH}" ]; then
    printf '%s' "$CMUX_BUNDLED_CLI_PATH"
  else
    command -v cmux 2>/dev/null || true
  fi
}

_cmux() {
  local bin
  bin=$(_cmux_bin)
  if [ -z "$bin" ]; then
    echo "Error: cmux CLI not found" >&2
    return 1
  fi
  "$bin" "$@"
}

_mux_need_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  echo "Error: jq is required for cmux support (brew install jq)" >&2
  return 1
}

# Resolve a window name to a cmux workspace ref.
#
# Prefers an exact custom_title match. mux_new_window always passes --name, so
# workspaces it creates carry a custom title, which cmux will NOT overwrite with
# an agent-generated one — that is what keeps name lookups stable. The
# displayed-title match is a fallback for workspaces created outside these
# tools.
_cmux_ws_ref() {
  local name="$1"
  _mux_need_jq || return 1
  _cmux workspace list --json 2>/dev/null | jq -r --arg n "$name" '
    ( [ .workspaces[] | select((.custom_title // "") == $n) ]
    + [ .workspaces[] | select((.title        // "") == $n) ]
    ) | first | .ref // empty
  '
}

# Caller context. `cmux current-workspace` reports the SELECTED workspace, which
# is not necessarily the one the calling shell lives in; `identify` reports the
# caller. The wt* tools always mean "the workspace I am running in".
_cmux_caller() {
  local field="$1"
  _mux_need_jq || return 1
  _cmux identify --json 2>/dev/null | jq -r --arg f "$field" '.caller[$f] // empty'
}

# Print "<pane_ref> <surface_ref> <surface_title>" per surface of a workspace,
# in layout order.
_cmux_surfaces() {
  local ws_ref="$1"
  _mux_need_jq || return 1
  _cmux tree --json 2>/dev/null | jq -r --arg w "$ws_ref" '
    .windows[].workspaces[] | select(.ref == $w)
    | .panes[] as $p | $p.surfaces[]
    | "\($p.ref) \(.ref) \(.title // "")"
  '
}

# Resolve a pane LABEL to a cmux surface ref, by surface title. Falls back to
# position in layout order (agent first, then root, then the third pane) for
# workspaces whose tabs were never labelled.
_cmux_surface_ref() {
  local ws_ref="$1" label="$2" ref
  ref=$(_cmux_surfaces "$ws_ref" | awk -v l="$label" '$3 == l {print $2; exit}')
  if [ -z "$ref" ]; then
    local idx
    case "$label" in
      agent) idx=1 ;;
      root)  idx=2 ;;
      *)     idx=3 ;;
    esac
    ref=$(_cmux_surfaces "$ws_ref" | awk -v n="$idx" 'NR == n {print $2; exit}')
  fi
  printf '%s' "$ref"
}

# ── windows ──────────────────────────────────────────────────────────────────

mux_window_names() {
  case "$(mux_kind)" in
    tmux) tmux list-windows -F '#W' 2>/dev/null || true ;;
    cmux)
      _mux_need_jq || return 1
      _cmux workspace list --json 2>/dev/null |
        jq -r '.workspaces[] | (.custom_title // .title // "")' | sed '/^$/d'
      ;;
  esac
}

mux_current_window() {
  case "$(mux_kind)" in
    tmux) tmux display-message -p '#W' 2>/dev/null || true ;;
    cmux)
      local ws_ref
      ws_ref=$(_cmux_caller workspace_ref) || return 1
      [ -z "$ws_ref" ] && return 0
      _cmux workspace list --json 2>/dev/null | jq -r --arg w "$ws_ref" '
        .workspaces[] | select(.ref == $w) | (.custom_title // .title // "")
      '
      ;;
  esac
}

mux_has_window() {
  local name="$1"
  case "$(mux_kind)" in
    tmux) tmux list-windows -F '#W' 2>/dev/null | grep -qx "$name" ;;
    cmux) [ -n "$(_cmux_ws_ref "$name")" ] ;;
    *)    return 1 ;;
  esac
}

mux_select_window() {
  local name="$1"
  case "$(mux_kind)" in
    tmux) tmux select-window -t "$name" ;;
    cmux)
      local ref
      ref=$(_cmux_ws_ref "$name")
      [ -z "$ref" ] && { echo "Error: no cmux workspace named $name" >&2; return 1; }
      _cmux workspace select --workspace "$ref" >/dev/null
      ;;
  esac
}

mux_kill_window() {
  local name="$1"
  case "$(mux_kind)" in
    tmux)
      # Address by window id, so a rename mid-flight cannot retarget the kill.
      local id
      id=$(tmux list-windows -F '#{window_name} #{window_id}' |
        awk -v n="$name" '$1 == n {print $2; exit}')
      [ -n "$id" ] && tmux kill-window -t "$id"
      ;;
    cmux)
      local ref
      ref=$(_cmux_ws_ref "$name")
      [ -n "$ref" ] && _cmux workspace close --workspace "$ref" >/dev/null
      ;;
  esac
  return 0
}

# Close every pane except the caller's, to stop processes running in the
# worktree before it is deleted. The caller's pane survives because the script
# invoking this is running in it.
mux_kill_other_panes() {
  case "$(mux_kind)" in
    tmux) tmux kill-pane -a 2>/dev/null || true ;;
    cmux)
      local ws_ref caller_pane
      ws_ref=$(_cmux_caller workspace_ref) || return 0
      caller_pane=$(_cmux_caller pane_ref) || return 0
      [ -z "$ws_ref" ] && return 0
      # cmux has no close-pane; a pane disappears once its last surface closes.
      _cmux_surfaces "$ws_ref" | while read -r pane surface _; do
        [ "$pane" = "$caller_pane" ] && continue
        _cmux close-surface --workspace "$ws_ref" --surface "$surface" >/dev/null 2>&1 || true
      done
      ;;
  esac
  return 0
}

# ── layout ───────────────────────────────────────────────────────────────────

# The nested cmux layout matching the shared 3-pane arrangement. Only "terminal"
# and "browser" surfaces are accepted here; a per-surface "title" is silently
# ignored, which is why mux_new_window labels the tabs in a second pass.
_CMUX_LAYOUT='{"direction":"vertical","split":0.7,"children":[
  {"direction":"horizontal","split":0.5,"children":[
    {"pane":{"surfaces":[{"type":"terminal"}]}},
    {"pane":{"surfaces":[{"type":"terminal"}]}}
  ]},
  {"pane":{"surfaces":[{"type":"terminal"}]}}
]}'

mux_new_window() {
  local name="$1" dir="$2" third="${3:-logs}"

  case "$(mux_kind)" in
    none)
      # No multiplexer: start a tmux session, as these tools always have.
      # Built detached so callers can populate panes before mux_attach blocks.
      tmux new-session -d -s "$name" -n "$name" -c "$dir" \; \
        select-pane -T "agent" \; \
        split-window -h -c "$dir" \; \
        select-pane -T "root" \; \
        select-pane -t 1 \; \
        split-window -v -f -c "$dir" -l 30% \; \
        select-pane -T "$third" \; \
        select-pane -t 1
      ;;
    tmux)
      tmux new-window -n "$name" -c "$dir"
      tmux select-pane -T "agent"
      tmux split-window -h -c "$dir"
      tmux select-pane -T "root"
      tmux select-pane -t 1
      tmux split-window -v -f -c "$dir" -l 30%
      tmux select-pane -T "$third"
      tmux select-pane -t 1
      ;;
    cmux)
      local ref
      ref=$(_cmux new-workspace --name "$name" --cwd "$dir" \
        --layout "$_CMUX_LAYOUT" --focus true 2>/dev/null | awk '{print $NF}')
      if [ -z "$ref" ]; then
        echo "Error: failed to create cmux workspace $name" >&2
        return 1
      fi
      # Label the tabs so panes can be addressed by name from here on. Resolve
      # refs rather than indices, since indices shift as surfaces come and go.
      local surfaces label i=0
      surfaces=$(_cmux_surfaces "$ref" | awk '{print $2}')
      while IFS= read -r surface; do
        [ -z "$surface" ] && continue
        case "$i" in
          0) label="agent" ;;
          1) label="root" ;;
          *) label="$third" ;;
        esac
        _cmux rename-tab --workspace "$ref" --surface "$surface" "$label" >/dev/null
        i=$((i + 1))
      done <<< "$surfaces"
      ;;
  esac
}

# Attach to a window built outside any multiplexer. Blocks until detach. A no-op
# under tmux and cmux, where the window is already on screen.
mux_attach() {
  local name="$1"
  [ "$(mux_kind)" = "none" ] || return 0
  tmux attach -t "$name"
}

# ── pane I/O ─────────────────────────────────────────────────────────────────

# Print the backend-specific target for a pane, for callers that need to talk to
# the backend directly.
mux_pane_target() {
  local name="$1" label="$2"
  case "$(mux_kind)" in
    tmux)
      # tmux panes are 1-indexed in the order the layout creates them.
      local idx
      case "$label" in
        agent) idx=1 ;;
        root)  idx=2 ;;
        *)     idx=3 ;;
      esac
      printf '%s.%s' "$name" "$idx"
      ;;
    cmux)
      local ref
      ref=$(_cmux_ws_ref "$name")
      [ -z "$ref" ] && return 1
      printf '%s' "$(_cmux_surface_ref "$ref" "$label")"
      ;;
  esac
}

mux_send() {
  local name="$1" label="$2" text="$3"
  case "$(mux_kind)" in
    tmux|none)
      tmux send-keys -t "$(mux_pane_target "$name" "$label")" "$text" Enter
      ;;
    cmux)
      local ref surface
      ref=$(_cmux_ws_ref "$name")
      [ -z "$ref" ] && { echo "Error: no cmux workspace named $name" >&2; return 1; }
      surface=$(_cmux_surface_ref "$ref" "$label")
      [ -z "$surface" ] && { echo "Error: no $label pane in $name" >&2; return 1; }
      # Send the text and the newline separately: `cmux send` expands \n and \r
      # in its argument, so a payload containing a literal backslash-n would
      # otherwise submit early.
      _cmux send --workspace "$ref" --surface "$surface" -- "$text" >/dev/null
      _cmux send-key --workspace "$ref" --surface "$surface" Enter >/dev/null
      ;;
  esac
}

mux_send_key() {
  local name="$1" label="$2" key="$3"
  case "$(mux_kind)" in
    tmux|none)
      tmux send-keys -t "$(mux_pane_target "$name" "$label")" "$key"
      ;;
    cmux)
      local ref surface
      ref=$(_cmux_ws_ref "$name")
      [ -z "$ref" ] && return 1
      surface=$(_cmux_surface_ref "$ref" "$label")
      [ -z "$surface" ] && return 1
      _cmux send-key --workspace "$ref" --surface "$surface" "$key" >/dev/null
      ;;
  esac
}

mux_capture() {
  local name="$1" label="$2"
  case "$(mux_kind)" in
    tmux|none)
      tmux capture-pane -t "$(mux_pane_target "$name" "$label")" -p 2>/dev/null || true
      ;;
    cmux)
      local ref surface
      ref=$(_cmux_ws_ref "$name")
      [ -z "$ref" ] && return 0
      surface=$(_cmux_surface_ref "$ref" "$label")
      [ -z "$surface" ] && return 0
      _cmux read-screen --workspace "$ref" --surface "$surface" 2>/dev/null || true
      ;;
  esac
}

mux_current_path() {
  case "$(mux_kind)" in
    tmux) tmux display-message -p '#{pane_current_path}' ;;
    # $PWD tracks cd the same way tmux's #{pane_current_path} does, whereas a
    # cmux workspace's current_directory is where it was created. Prefer $PWD.
    *) printf '%s' "$PWD" ;;
  esac
}

# ── agent pane ───────────────────────────────────────────────────────────────

# The agent pane is a plain terminal running the `claude` CLI, on every backend.
#
# cmux can host a native agent-session surface instead
# (`new-surface --type agent-session --provider claude`), and an earlier version
# of this library used one. It is deliberately NOT used: the surface renders
# empty, `surface.send_text`/`surface.send_key` both reject it with "Surface is
# not a terminal", and the only delivery path — `workspace.prompt_submit` —
# merely pre-fills the input box without ever submitting it, so a prompt sits
# there forever and the workspace lane stays "todo". Running the CLI in a
# terminal keeps the agent pane working and keeps real `--permission-mode plan`
# available, which the native surface exposes no switch for.
#
# Set WT_NO_AGENT=1 to leave the agent pane as a bare shell.

# Start a plain `claude` session in the agent pane.
mux_agent_start() {
  local name="$1" dir="${2:-}"
  [ -n "${WT_NO_AGENT:-}" ] && return 0
  mux_send "$name" agent "claude"
}

# Start `claude` in the agent pane in plan mode, seeded with a prompt.
mux_agent_prompt() {
  local name="$1" prompt="$2"
  [ -z "$prompt" ] && return 0
  [ -n "${WT_NO_AGENT:-}" ] && return 0

  local escaped
  escaped=$(printf '%s' "$prompt" | sed "s/'/'\\\\''/g")
  mux_send "$name" agent "claude --permission-mode plan -p '${escaped}'"
}
