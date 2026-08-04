#!/bin/bash
input=$(cat)

# ANSI colors (dim-friendly: standard foreground colors)
RESET="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"
CYAN="\033[36m"
YELLOW="\033[33m"
GREEN="\033[32m"
RED="\033[31m"
MAGENTA="\033[35m"
BLUE="\033[34m"
WHITE="\033[37m"

SEP="${DIM}  ${RESET}"

# --- Model ---
model=$(echo "$input" | jq -r '.model.display_name // "unknown"')
model_str="${CYAN}🤖 ${model}${RESET}"

# --- Context progress bar ---
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
if [ -n "$used" ]; then
  used_int=$(printf "%.0f" "$used")
  bar_filled=$(( used_int / 10 ))
  bar_empty=$(( 10 - bar_filled ))
  filled_str=""
  empty_str=""
  for i in $(seq 1 $bar_filled); do filled_str="${filled_str}#"; done
  for i in $(seq 1 $bar_empty); do empty_str="${empty_str}-"; done
  if [ "$used_int" -ge 80 ]; then
    bar_color="${RED}"
  elif [ "$used_int" -ge 50 ]; then
    bar_color="${YELLOW}"
  else
    bar_color="${GREEN}"
  fi
  context_str="🧠 ${DIM}[${RESET}${bar_color}${filled_str}${RESET}${DIM}${empty_str}]${RESET} ${bar_color}${used_int}%${RESET}"
else
  context_str="🧠 ${DIM}[----------] --%${RESET}"
fi

# --- Cost ---
raw_cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
if [ -n "$raw_cost" ]; then
  cost=$(awk "BEGIN { printf \"\$%.3f\", $raw_cost }")
  cost_str="${MAGENTA}💰 ${cost}${RESET}"
else
  cost_str=""
fi

# --- Session duration ---
transcript=$(echo "$input" | jq -r '.transcript_path // empty')
duration_str=""
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  # GNU stat (Linux) first, falling back to BSD stat (macOS)
  birth=$(stat -c %Y "$transcript" 2>/dev/null || stat -f "%SB" -t "%s" "$transcript" 2>/dev/null)
  if [ -n "$birth" ]; then
    now=$(date +%s)
    elapsed=$(( now - birth ))
    hours=$(( elapsed / 3600 ))
    mins=$(( (elapsed % 3600) / 60 ))
    if [ "$hours" -gt 0 ]; then
      duration_str="${YELLOW}⏱ ${hours}h${mins}m${RESET}"
    else
      duration_str="${YELLOW}⏱ ${mins}m${RESET}"
    fi
  fi
fi

# --- Path ---
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
projects_prefix="$HOME/projects/"
if [[ "$cwd" == "$projects_prefix"* ]]; then
  display_path="~/projects/${cwd#$projects_prefix}"
elif [[ "$cwd" == "$HOME/"* ]]; then
  display_path="~/${cwd#$HOME/}"
else
  display_path="$cwd"
fi
path_str="${BLUE}📁 ${display_path}${RESET}"

# --- Git branch ---
git_branch=""
if [ -n "$cwd" ] && [ -d "$cwd" ]; then
  git_branch=$(git -C "$cwd" --git-dir="$cwd/.git" symbolic-ref --short HEAD 2>/dev/null \
    || git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
fi

# --- Assemble ---
line="${model_str}${SEP}${context_str}"
[ -n "$cost_str" ] && line="${line}${SEP}${cost_str}"
[ -n "$duration_str" ] && line="${line}${SEP}${duration_str}"
line="${line}${SEP}${path_str}"
[ -n "$git_branch" ] && line="${line}${SEP}${WHITE}🌿 ${git_branch}${RESET}"

printf "%b" "$line"
