#!/usr/bin/env bash
#
# delete-branches.sh — delete git branches you no longer use, locally or on a remote.
#
# Just run it and it walks you through everything:
#   1. type/paste the repository folder
#   2. choose local or remote branches
#   3. pick branches from a numbered list
#   4. review the preview and confirm

set -euo pipefail

PROTECTED_BRANCHES="main master develop HEAD"

bold=$'\033[1m'; red=$'\033[31m'; green=$'\033[32m'; yellow=$'\033[33m'; cyan=$'\033[36m'; dim=$'\033[2m'; reset=$'\033[0m'
if [[ ! -t 1 ]]; then bold=""; red=""; green=""; yellow=""; cyan=""; dim=""; reset=""; fi

die() { echo "${red}Error:${reset} $*" >&2; exit 1; }

[[ $# -eq 0 ]] || die "This script takes no arguments — just run it and answer the prompts."
[[ -t 0 ]] || die "This script is interactive; run it in a terminal."

# ---------- prompt helpers ----------

# choose_one <question> <default number> <option...>; prints the chosen number (1-based).
choose_one() {
  local question="$1" def="$2"; shift 2
  local i=1 opt answer
  echo "${bold}$question${reset}" >&2
  for opt in "$@"; do echo "  ${cyan}$i)${reset} $opt" >&2; i=$((i + 1)); done
  while true; do
    read -r -p "Choose [$def]: " answer
    answer="${answer:-$def}"
    if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= $# )); then
      echo "$answer"; return
    fi
    echo "  ${yellow}Enter a number from 1 to $#.${reset}" >&2
  done
}

ask_yes_no() {
  local answer
  read -r -p "$1 [y/N] " answer
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# Clean up a typed, pasted or drag-and-dropped path.
normalize_path() {
  local p="$1"
  p="${p#"${p%%[![:space:]]*}"}"   # leading whitespace
  p="${p%"${p##*[![:space:]]}"}"   # trailing whitespace
  p="${p%\"}"; p="${p#\"}"; p="${p%\'}"; p="${p#\'}"
  p="${p//\\ / }"                  # "My\ Folder" -> "My Folder"
  p="${p/#\~/$HOME}"
  echo "$p"
}

is_protected() {
  local p
  for p in $PROTECTED_BRANCHES "$default_branch"; do
    [[ -n "$p" && "$1" == "$p" ]] && return 0
  done
  return 1
}

echo "${bold}Delete git branches${reset} ${dim}(Ctrl+C to quit at any time)${reset}"
echo

# ---------- repository ----------

default_repo="$(git rev-parse --show-toplevel 2>/dev/null || true)"
while true; do
  if [[ -n "$default_repo" ]]; then
    read -r -e -p "${bold}Repository folder${reset} [$default_repo]: " input
    input="${input:-$default_repo}"
  else
    read -r -e -p "${bold}Repository folder${reset} (type or paste a path): " input
  fi
  input="$(normalize_path "$input")"
  [[ -n "$input" ]] || continue
  if [[ -d "$input" ]] && repo="$(git -C "$input" rev-parse --show-toplevel 2>/dev/null)"; then
    break
  fi
  echo "  ${yellow}Not a git repository: $input${reset}"
done
echo
g() { git -C "$repo" "$@"; }

# ---------- local or remote ----------

n="$(choose_one "Which branches do you want to delete?" 1 \
  "Local   ${dim}(branches on this computer)${reset}" \
  "Remote  ${dim}(branches on the server, e.g. GitHub)${reset}")"
[[ "$n" == 1 ]] && where="local" || where="remote"
echo

remote="origin"
if [[ "$where" == "remote" ]]; then
  remotes=()
  while IFS= read -r r; do [[ -n "$r" ]] && remotes+=("$r"); done < <(g remote)
  [[ ${#remotes[@]} -gt 0 ]] || die "This repository has no remotes."
  if [[ ${#remotes[@]} -eq 1 ]]; then
    remote="${remotes[0]}"
  else
    def=1
    for i in "${!remotes[@]}"; do [[ "${remotes[$i]}" == "origin" ]] && def=$((i + 1)); done
    n="$(choose_one "Which remote?" "$def" "${remotes[@]}")"
    remote="${remotes[$((n - 1))]}"
    echo
  fi
  echo "${dim}Fetching $remote (with prune)...${reset}"
  g fetch --prune --quiet "$remote" || die "Could not fetch from $remote"
fi

current_branch="$(g symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
default_branch="$(g symbolic-ref --quiet --short "refs/remotes/$remote/HEAD" 2>/dev/null | sed "s|^$remote/||" || true)"

# Full ref for a branch name in the chosen location.
ref_for() {
  if [[ "$where" == "remote" ]]; then echo "refs/remotes/$remote/$1"; else echo "refs/heads/$1"; fi
}

# Branch the merge check compares against.
base_ref=""
for candidate in "$default_branch" main master; do
  [[ -n "$candidate" ]] || continue
  if g show-ref --verify --quiet "$(ref_for "$candidate")"; then
    base_ref="$(ref_for "$candidate")"; break
  fi
done

echo "${bold}Repository:${reset} $repo"
echo "${bold}Where:${reset}      $where$([[ "$where" == "remote" ]] && echo " ($remote)")"
[[ -n "$base_ref" ]] && echo "${bold}Merge base:${reset} ${base_ref#refs/*/}"
echo

# ---------- pick branches ----------

if [[ "$where" == "remote" ]]; then
  refs="refs/remotes/$remote"; name_fmt="%(refname:lstrip=3)"
else
  refs="refs/heads"; name_fmt="%(refname:short)"
fi

cand=(); cand_status=(); cand_date=(); cand_subject=()
while IFS='|' read -r name date subject; do
  is_protected "$name" && continue
  [[ "$where" == "local" && "$name" == "$current_branch" ]] && continue
  status="unmerged"
  if [[ -n "$base_ref" ]] && g merge-base --is-ancestor "$(ref_for "$name")" "$base_ref" 2>/dev/null; then
    status="merged"
  fi
  cand+=("$name"); cand_status+=("$status"); cand_date+=("$date"); cand_subject+=("$subject")
done < <(g for-each-ref --sort=-committerdate "$refs" --format="$name_fmt|%(committerdate:relative)|%(subject)")

if [[ ${#cand[@]} -eq 0 ]]; then
  echo "No deletable $where branches (protected and checked-out branches are hidden)."
  exit 0
fi

# print_row <index> [number label]
print_row() {
  local i="$1" label="${2:-}" color="$green" subject="${cand_subject[$1]}"
  [[ "${cand_status[$i]}" == "unmerged" ]] && color="$red"
  [[ ${#subject} -gt 50 ]] && subject="${subject:0:47}..."
  printf "  ${cyan}%4s${reset}  %-40s ${color}%-10s${reset} %-16s ${dim}%s${reset}\n" \
    "$label" "${cand[$i]}" "${cand_status[$i]}" "${cand_date[$i]}" "$subject"
}

echo "${bold}Deletable $where branches${reset} ${dim}(newest first; protected/checked-out hidden)${reset}"
printf "${bold}  %4s  %-40s %-10s %-16s %s${reset}\n" "#" "BRANCH" "STATUS" "LAST COMMIT" "SUBJECT"
for i in "${!cand[@]}"; do print_row "$i" "$((i + 1)))"; done
echo
echo "Select by number: ${cyan}1 3 5${reset}, ranges ${cyan}2-6${reset}, ${cyan}merged${reset} (all merged ones), ${cyan}all${reset}, or ${cyan}q${reset} to quit."

total=${#cand[@]}
while true; do
  read -r -p "Branches to delete: " answer
  read -r -a toks <<< "${answer//,/ }"
  [[ ${#toks[@]} -gt 0 ]] || continue
  mark=(); valid=true
  for tok in "${toks[@]}"; do
    case "$tok" in
      q|Q|quit|exit) echo "Aborted."; exit 0 ;;
      all|a)    for ((i = 1; i <= total; i++)); do mark[i]=1; done ;;
      merged|m) for ((i = 1; i <= total; i++)); do [[ "${cand_status[i-1]}" == merged ]] && mark[i]=1; done ;;
      *)
        if [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
          lo="${BASH_REMATCH[1]}"; hi="${BASH_REMATCH[2]}"
        elif [[ "$tok" =~ ^[0-9]+$ ]]; then
          lo="$tok"; hi="$tok"
        else
          echo "  ${yellow}Don't understand '$tok'.${reset}"; valid=false; break
        fi
        if (( lo < 1 || hi > total || lo > hi )); then
          echo "  ${yellow}'$tok' is out of range (1-$total).${reset}"; valid=false; break
        fi
        for ((i = lo; i <= hi; i++)); do mark[i]=1; done
        ;;
    esac
  done
  $valid || continue
  selected=()
  for ((i = 1; i <= total; i++)); do
    [[ "${mark[i]:-}" == 1 ]] && selected+=($((i - 1)))
  done
  [[ ${#selected[@]} -gt 0 ]] && break
  echo "  ${yellow}Nothing selected.${reset}"
done
echo

# ---------- preview ----------

echo "${bold}Preview${reset}"
printf "${bold}  %4s  %-40s %-10s %-16s %s${reset}\n" "" "BRANCH" "STATUS" "LAST COMMIT" "SUBJECT"
unmerged=0
for i in "${selected[@]}"; do
  print_row "$i"
  [[ "${cand_status[$i]}" == unmerged ]] && unmerged=$((unmerged + 1))
done
echo

# Unmerged local branches need -D; ask instead of letting git refuse them.
force=false
if [[ "$where" == "local" ]] && (( unmerged > 0 )); then
  echo "${yellow}$unmerged selected branch(es) are not merged${reset} — their commits may be lost."
  if ask_yes_no "Force-delete the unmerged ones too?"; then
    force=true
  else
    kept=()
    for i in "${selected[@]}"; do [[ "${cand_status[$i]}" == merged ]] && kept+=("$i"); done
    if [[ ${#kept[@]} -eq 0 ]]; then echo "Nothing to delete."; exit 0; fi
    selected=("${kept[@]}")
    echo "${dim}Skipping unmerged branches.${reset}"
  fi
  echo
fi

target="local"; [[ "$where" == "remote" ]] && target="remote '$remote'"
ask_yes_no "Delete ${#selected[@]} branch(es) from $target?" || { echo "Aborted."; exit 1; }

# ---------- delete ----------

failed=0
for i in "${selected[@]}"; do
  b="${cand[$i]}"
  if [[ "$where" == "remote" ]]; then
    if g push --quiet "$remote" --delete "$b"; then
      echo "${green}Deleted${reset} $remote/$b"
    else
      echo "${red}Failed${reset}  $remote/$b"; failed=$((failed + 1))
    fi
  else
    flag="-d"; [[ "$force" == true ]] && flag="-D"
    if g branch "$flag" "$b" >/dev/null 2>&1; then
      echo "${green}Deleted${reset} $b"
    else
      echo "${red}Failed${reset}  $b"; failed=$((failed + 1))
    fi
  fi
done

[[ $failed -eq 0 ]] || exit 1
