#!/usr/bin/env bash
#
# delete-branches.sh — delete git branches you no longer use, locally or on a remote.
#
# Just run it with no arguments and it walks you through everything:
#   1. type/paste the repository folder
#   2. choose local or remote branches
#   3. pick branches from a numbered list
#   4. review the preview and confirm
#
# Options you pass are used as-is and not asked again.
#
# Usage:
#   delete-branches.sh                        # fully interactive
#   delete-branches.sh [options] [branch ...]
#
# Options:
#   -r, --repo <path>      Repository path (default: asks, or current folder)
#   -w, --where <where>    local | remote   (default: asks, or local)
#   -o, --remote <name>    Remote name when --where remote (default: asks, or origin)
#   -f, --force            Local only: delete even if not merged (git branch -D)
#   -n, --dry-run          Show the preview, delete nothing
#   -y, --yes              Skip the confirmation prompt (preview is still shown)
#   -h, --help             Show this help
#
# Examples:
#   delete-branches.sh
#   delete-branches.sh -r ~/code/myapp -w remote
#   delete-branches.sh -w remote feature/old bugfix/123

set -euo pipefail

PROTECTED_BRANCHES="main master develop HEAD"

repo=""
where=""
remote=""
force=false
dry_run=false
assume_yes=false
branches=()

bold=$'\033[1m'; red=$'\033[31m'; green=$'\033[32m'; yellow=$'\033[33m'; cyan=$'\033[36m'; dim=$'\033[2m'; reset=$'\033[0m'
if [[ ! -t 1 ]]; then bold=""; red=""; green=""; yellow=""; cyan=""; dim=""; reset=""; fi

usage() { sed -n '3,29p' "$0" | sed 's/^# \{0,1\}//'; }
die()   { echo "${red}Error:${reset} $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--repo)    [[ $# -ge 2 ]] || die "$1 needs a value"; repo="$2"; shift 2 ;;
    -w|--where)   [[ $# -ge 2 ]] || die "$1 needs a value"; where="$2"; shift 2 ;;
    -o|--remote)  [[ $# -ge 2 ]] || die "$1 needs a value"; remote="$2"; shift 2 ;;
    -f|--force)   force=true; shift ;;
    -n|--dry-run) dry_run=true; shift ;;
    -y|--yes)     assume_yes=true; shift ;;
    -h|--help)    usage; exit 0 ;;
    --)           shift; branches+=("$@"); break ;;
    -*)           die "Unknown option: $1 (see --help)" ;;
    *)            branches+=("$1"); shift ;;
  esac
done

interactive=false
[[ -t 0 ]] && interactive=true

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

ask_repo() {
  local default input top
  default="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  while true; do
    if [[ -n "$default" ]]; then
      read -r -e -p "${bold}Repository folder${reset} [$default]: " input
      input="${input:-$default}"
    else
      read -r -e -p "${bold}Repository folder${reset} (type or paste a path): " input
    fi
    input="$(normalize_path "$input")"
    [[ -n "$input" ]] || continue
    if [[ -d "$input" ]] && top="$(git -C "$input" rev-parse --show-toplevel 2>/dev/null)"; then
      repo="$top"; return
    fi
    echo "  ${yellow}Not a git repository: $input${reset}"
  done
}

is_protected() {
  local p
  for p in $PROTECTED_BRANCHES "$default_branch"; do
    [[ -n "$p" && "$1" == "$p" ]] && return 0
  done
  return 1
}

# ---------- repository ----------

if $interactive && [[ ${#branches[@]} -eq 0 ]]; then
  echo "${bold}Delete git branches${reset} ${dim}(Ctrl+C to quit at any time)${reset}"
  echo
fi

if [[ -z "$repo" ]]; then
  if $interactive; then ask_repo; echo; else repo="."; fi
fi
repo="$(normalize_path "$repo")"
[[ -d "$repo" ]] || die "Repository path not found: $repo"
repo="$(cd "$repo" && git rev-parse --show-toplevel 2>/dev/null)" || die "Not a git repository: $repo"
g() { git -C "$repo" "$@"; }

# ---------- local or remote ----------

if [[ -z "$where" ]]; then
  if $interactive; then
    n="$(choose_one "Which branches do you want to delete?" 1 \
      "Local   ${dim}(branches on this computer)${reset}" \
      "Remote  ${dim}(branches on the server, e.g. GitHub)${reset}")"
    [[ "$n" == 1 ]] && where="local" || where="remote"
    echo
  else
    where="local"
  fi
fi
case "$where" in
  local|remote) ;;
  *) die "--where must be 'local' or 'remote' (got '$where')" ;;
esac

if [[ -z "$remote" ]]; then
  remote="origin"
  if [[ "$where" == "remote" ]] && $interactive; then
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
  fi
fi

current_branch="$(g symbolic-ref --quiet --short HEAD 2>/dev/null || true)"

if [[ "$where" == "remote" ]]; then
  g remote get-url "$remote" >/dev/null 2>&1 || die "Remote '$remote' not found in $repo"
  echo "${dim}Fetching $remote (with prune)...${reset}"
  g fetch --prune --quiet "$remote" || die "Could not fetch from $remote"
fi
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

merge_status() {
  if [[ -n "$base_ref" ]] && g merge-base --is-ancestor "$1" "$base_ref" 2>/dev/null; then
    echo merged
  else
    echo unmerged
  fi
}

echo "${bold}Repository:${reset} $repo"
echo "${bold}Where:${reset}      $where$([[ "$where" == "remote" ]] && echo " ($remote)")"
[[ -n "$base_ref" ]] && echo "${bold}Merge base:${reset} ${base_ref#refs/*/}"
echo

# ---------- pick branches ----------

if [[ ${#branches[@]} -eq 0 ]]; then
  if [[ "$where" == "remote" ]]; then
    refs="refs/remotes/$remote"; fmt="%(refname:lstrip=3)|%(committerdate:relative)|%(subject)"
  else
    refs="refs/heads"; fmt="%(refname:short)|%(committerdate:relative)|%(subject)"
  fi

  if ! $interactive; then
    echo "${bold}No branches given. Existing $where branches:${reset}"
    g for-each-ref --sort=-committerdate "$refs" --format="  $fmt" | grep -v '^  HEAD|' | column -t -s '|'
    echo
    echo "Pass branch names to delete them, e.g.: $(basename "$0") -w $where <branch> ..."
    exit 0
  fi

  cand=(); cand_status=(); cand_date=(); cand_subject=()
  while IFS='|' read -r name date subject; do
    is_protected "$name" && continue
    [[ "$where" == "local" && "$name" == "$current_branch" ]] && continue
    cand+=("$name"); cand_date+=("$date"); cand_subject+=("$subject")
    cand_status+=("$(merge_status "$(ref_for "$name")")")
  done < <(g for-each-ref --sort=-committerdate "$refs" --format="$fmt")

  if [[ ${#cand[@]} -eq 0 ]]; then
    echo "No deletable $where branches (protected and checked-out branches are hidden)."
    exit 0
  fi

  echo "${bold}Deletable $where branches${reset} ${dim}(newest first; protected/checked-out hidden)${reset}"
  printf "${bold}  %4s  %-40s %-10s %-16s %s${reset}\n" "#" "BRANCH" "STATUS" "LAST COMMIT" "SUBJECT"
  for i in "${!cand[@]}"; do
    color="$green"; [[ "${cand_status[$i]}" == "unmerged" ]] && color="$red"
    subject="${cand_subject[$i]}"; [[ ${#subject} -gt 50 ]] && subject="${subject:0:47}..."
    printf "  ${cyan}%3d)${reset}  %-40s ${color}%-10s${reset} %-16s ${dim}%s${reset}\n" \
      $((i + 1)) "${cand[$i]}" "${cand_status[$i]}" "${cand_date[$i]}" "$subject"
  done
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
    branches=()
    for ((i = 1; i <= total; i++)); do
      [[ "${mark[i]:-}" == 1 ]] && branches+=("${cand[i-1]}")
    done
    [[ ${#branches[@]} -gt 0 ]] && break
    echo "  ${yellow}Nothing selected.${reset}"
  done
  echo
fi

# ---------- preview ----------

to_delete=(); to_delete_status=()
echo "${bold}Preview${reset}"
printf "${bold}%-40s %-10s %-16s %s${reset}\n" "BRANCH" "STATUS" "LAST COMMIT" "SUBJECT"
for b in "${branches[@]}"; do
  b="${b#refs/heads/}"
  [[ "$where" == "remote" ]] && b="${b#$remote/}"
  ref="$(ref_for "$b")"

  skip_reason=""
  is_protected "$b" && skip_reason="protected"
  if [[ -z "$skip_reason" && "$where" == "local" && "$b" == "$current_branch" ]]; then
    skip_reason="checked out"
  fi
  if [[ -z "$skip_reason" ]] && ! g show-ref --verify --quiet "$ref"; then
    skip_reason="not found"
  fi

  if [[ -n "$skip_reason" ]]; then
    printf "%-40s ${yellow}%-10s${reset} ${dim}skipped${reset}\n" "$b" "$skip_reason"
    continue
  fi

  status="$(merge_status "$ref")"
  info="$(g log -1 --format='%cr|%s' "$ref")"
  color="$green"; [[ "$status" == "unmerged" ]] && color="$red"
  printf "%-40s ${color}%-10s${reset} %-16s %s\n" "$b" "$status" "${info%%|*}" "${info#*|}"
  to_delete+=("$b"); to_delete_status+=("$status")
done
echo

if [[ ${#to_delete[@]} -eq 0 ]]; then
  echo "Nothing to delete."
  exit 0
fi

# Unmerged local branches need -D; ask instead of letting git refuse them.
if [[ "$where" == "local" && "$force" == false ]]; then
  unmerged=0
  for s in "${to_delete_status[@]}"; do [[ "$s" == unmerged ]] && unmerged=$((unmerged + 1)); done
  if (( unmerged > 0 )); then
    if $interactive && ! $assume_yes; then
      echo "${yellow}$unmerged selected branch(es) are not merged${reset} — their commits may be lost."
      if ask_yes_no "Force-delete the unmerged ones too?"; then
        force=true
      else
        kept=()
        for i in "${!to_delete[@]}"; do
          [[ "${to_delete_status[$i]}" == merged ]] && kept+=("${to_delete[$i]}")
        done
        to_delete=(${kept[@]+"${kept[@]}"})
        echo "${dim}Skipping unmerged branches.${reset}"
        if [[ ${#to_delete[@]} -eq 0 ]]; then echo "Nothing to delete."; exit 0; fi
      fi
      echo
    else
      echo "${dim}Unmerged local branches will be refused by git; use --force to delete them anyway.${reset}"
    fi
  fi
fi

if [[ "$dry_run" == true ]]; then
  echo "${yellow}Dry run:${reset} ${#to_delete[@]} branch(es) would be deleted ($where)."
  exit 0
fi

if [[ "$assume_yes" == false ]]; then
  target="local"; [[ "$where" == "remote" ]] && target="remote '$remote'"
  ask_yes_no "Delete ${#to_delete[@]} branch(es) from $target?" || { echo "Aborted."; exit 1; }
fi

# ---------- delete ----------

failed=0
for b in "${to_delete[@]}"; do
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
      echo "${red}Failed${reset}  $b ${dim}(not fully merged? retry with --force)${reset}"; failed=$((failed + 1))
    fi
  fi
done

[[ $failed -eq 0 ]] || exit 1
