#!/usr/bin/env bash
# Judge Script for 2024 Problems
# ------------------------------
# Compiles the specified C++ solution (located in ./practice/<problem>/<problem>.cpp)
# and tests it against available test cases.
#
# Usage: ./judge.sh [-g <j|s>] [-y <year>] [-p <problem>] [-c <cxxflags>] [-t <seconds>]
#   -g, --group    j  普及组复赛试题   (interactive select if absent)
#                  s  提高组复赛试题
#   -y, --year     4-digit year (e.g. 2024). If omitted, auto-detect or select.
#   -p, --problem  problem directory name under practice/. If omitted:
#                  • auto-choose when only one problem exists
#                  • interactive select when multiple problems present
#   -c, --cxxflags  custom g++ flags (default: "-std=c++14 -O2 -pipe -Wall -Wextra")
#                   Overrides CXXFLAGS env when provided.
#   -t, --time      per-case CPU time limit in seconds (default: 2)
#                   Overrides TIME_LIMIT env when provided.
#   positional <problem> is still accepted for backward compatibility.
#
#   Example: CXXFLAGS="-std=c++20 -O3" ./judge.sh -g j -y 2024 -p poker
#
# Environment variables:
#   CXXFLAGS   : flags passed to g++; if not set uses "-std=c++14 -O2 -pipe -Wall -Wextra".
#                The script prints the effective CXXFLAGS so you can verify overrides.
#   TIME_LIMIT : per-case timeout in seconds           (default: 2)
#
# All log messages are in English.

# --- Option Parsing ------------------------------------------------------
set -euo pipefail
shopt -s nullglob

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"  # repository root

# Defaults (empty means "ask or auto-detect")
GROUP=""   # j: 普及组复赛试题, s: 提高组复赛试题
YEAR=""
PROBLEM=""
CXXFLAGS="${CXXFLAGS:--std=c++14 -O2 -pipe -Wall -Wextra}"
TIME_LIMIT="${TIME_LIMIT:-2}"
# Compiler (can be overridden via --cxx or CXX env var)
CXX="${CXX:-g++}"

# --- Compiler Detection (macOS / Homebrew GCC) ---------------------------
# If running on macOS and the compiler is still the default "g++" (which is
# typically a Clang wrapper without <bits/stdc++.h>), attempt to locate a
# GNU g++ installed via Homebrew (e.g. g++-14, g++-13, ...). The first one
# found will be used.

if [[ "$(uname -s)" == "Darwin" && "$CXX" == "g++" ]]; then
  candidate=""

  # 1) Prefer Homebrew-installed GCC (fast, reliable)
  if command -v brew >/dev/null 2>&1; then
    brew_bin="$(brew --prefix gcc 2>/dev/null || true)/bin"
    if [[ -d "$brew_bin" ]]; then
      candidate=$(ls "$brew_bin"/g++-* 2>/dev/null | sort -V | tail -n1 || true)
    fi
  fi

  # 2) Fallback: look for any g++-* already in PATH
  if [[ -z "$candidate" ]]; then
    candidate=$(command -v g++-* 2>/dev/null | tr ' ' '\n' | sort -V | tail -n1 || true)
  fi

  # 3) Still none? Attempt automatic Homebrew installation of gcc
  if [[ -z "$candidate" && -z "${CXX_INSTALLED_ALREADY:-}" ]]; then
    if command -v brew >/dev/null 2>&1; then
      echo "[INFO] GNU g++ not detected. Attempting \"brew install gcc\" (this may take a while)..." >&2
      if brew install gcc >/dev/null; then
        export CXX_INSTALLED_ALREADY=1
        brew_bin="$(brew --prefix gcc 2>/dev/null || true)/bin"
        if [[ -d "$brew_bin" ]]; then
          candidate=$(ls "$brew_bin"/g++-* 2>/dev/null | sort -V | tail -n1 || true)
        fi
      else
        echo "[ERROR] Homebrew installation of gcc failed." >&2
      fi
    else
      echo "[ERROR] Homebrew not found; cannot auto-install gcc. Install it manually or set CXX." >&2
    fi
  fi

  if [[ -n "$candidate" && -x "$candidate" ]]; then
    echo "[INFO] Detected GNU C++ compiler: $candidate"
    CXX="$candidate"
  fi
fi

# No external 'timeout' command is required; we rely on ulimit -t for CPU time.
TIMEOUT_CMD=""

# --- Dependency Check ----------------------------------------------------
# Ensure `timeout` command is available. If missing on macOS, attempt to
# install via Homebrew (coreutils provides `gtimeout`, which we symlink).

if ! command -v timeout >/dev/null 2>&1; then
  echo "[INFO] 'timeout' command not found. Attempting to install via Homebrew..." >&2
  if command -v brew >/dev/null 2>&1; then
    brew install coreutils || { echo "[ERROR] Homebrew installation failed." >&2; exit 1; }
  else
    echo "[ERROR] Homebrew not found. Please install 'coreutils' manually to provide 'timeout'." >&2
    exit 1
  fi
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -g|--group)
      GROUP="$2"; shift 2;;
    -y|--year)
      YEAR="$2"; shift 2;;
    -p|--problem)
      PROBLEM="$2"; shift 2;;
    -c|--cxxflags)
      CXXFLAGS="$2"; shift 2;;
    -t|--time)
      TIME_LIMIT="$2"; shift 2;;
    *) break;;
  esac
done

# Interactive group selection if not provided
if [[ -z "$GROUP" ]]; then
  echo "Select CSP group:"
  PS3="Enter choice: "
  select opt in "J" "S"; do
    case $REPLY in
      1|J|j) GROUP="j"; break;;
      2|S|s) GROUP="s"; break;;
      *) echo "Invalid selection (type number or j/s)";;
    esac
  done
  echo "Chosen group: $GROUP"
fi

# Map group code to directory name
case "$GROUP" in
  j) GROUP_DIR="csp-j-second-rnd";;
  s) GROUP_DIR="csp-s-second-rnd";;
  *) echo "Invalid group '$GROUP'. Use j or s." >&2; exit 1;;
esac

GROUP_PATH="$SCRIPT_DIR/$GROUP_DIR"
if [[ ! -d "$GROUP_PATH" ]]; then
  echo "Group directory not found: $GROUP_PATH" >&2; exit 1
fi

# Detect year if not provided
if [[ -z "$YEAR" ]]; then
  _years=()
  for d in "$GROUP_PATH"/*; do
    [[ -d "$d" ]] || continue
    bn="$(basename "$d")"
    [[ "$bn" =~ ^[0-9]{4}$ ]] || continue
    _years+=("$bn")
  done
  oldIFS2="$IFS"
  IFS=$'\n' _years=($(printf '%s\n' "${_years[@]}" | sort))
  IFS="$oldIFS2"
  if [[ ${#_years[@]} -eq 0 ]]; then
    echo "No year directories found under $GROUP_PATH" >&2; exit 1
  elif [[ ${#_years[@]} -eq 1 ]]; then
    YEAR="${_years[0]}"
    echo "Detected single year: $YEAR"
  else
    echo "Available years:"
    for i in "${!_years[@]}"; do printf " %2d) %s\n" "$((i+1))" "${_years[i]}"; done
    while :; do
      read -r -p "Enter year (index or YYYY): " input
      # If numeric index within range
      if [[ "$input" =~ ^[0-9]+$ ]] && (( input>=1 && input<=${#_years[@]} )); then
        YEAR="${_years[input-1]}"; break
      fi
      # If exact year present
      for y in "${_years[@]}"; do if [[ "$input" == "$y" ]]; then YEAR="$y"; break 2; fi; done
      echo "Invalid selection, try again."
    done
  fi
fi

# final directory variables
YEAR_DIR="$GROUP_PATH/$YEAR"
PRACTICE_DIR="$YEAR_DIR/practice"

# Ensure practice directory exists
if [[ ! -d "$PRACTICE_DIR" ]]; then
  echo "Practice directory not found: $PRACTICE_DIR" >&2; exit 1
fi

# ---------------- Problem Detection --------------------------------------

# If PROBLEM already set via -p/--problem or positional argument, skip select.

# Capture positional argument as problem if not already set.
if [[ -z "$PROBLEM" && $# -gt 0 ]]; then
  PROBLEM="$1"
fi

if [[ -z "$PROBLEM" ]]; then
  # Auto-detect problems under practice
  _problems=()
  for d in "$PRACTICE_DIR"/*; do
    [[ -d "$d" ]] || continue
    _problems+=("$(basename "$d")")
  done
  oldIFS="$IFS"
  IFS=$'\n' _problems=($(printf '%s\n' "${_problems[@]}" | sort))
  IFS="$oldIFS"
  if [[ ${#_problems[@]} -eq 0 ]]; then
    echo "No problem directories found under $PRACTICE_DIR" >&2
    exit 1
  elif [[ ${#_problems[@]} -eq 1 ]]; then
    PROBLEM="${_problems[0]}"
    echo "Detected single problem: $PROBLEM"
  else
    echo "Select problem:"
    PS3="Enter problem choice: "
    select pb in "${_problems[@]}"; do
      if [[ -n "$pb" ]]; then PROBLEM="$pb"; break; fi
      read -r -p "Enter problem name (or selection number): " manual_pb
      if [[ -d "$PRACTICE_DIR/$manual_pb" ]]; then PROBLEM="$manual_pb"; break; fi
    done
  fi
fi

# Ensure problem directory exists
if [[ ! -d "$PRACTICE_DIR/$PROBLEM" ]]; then
  echo "Problem '$PROBLEM' not found under $PRACTICE_DIR" >&2
  echo "Available problems:" >&2
  for d in "$PRACTICE_DIR"/*; do [[ -d "$d" ]] && echo "  - $(basename "$d")" >&2; done
  exit 1
fi

SRC_CPP="$PRACTICE_DIR/$PROBLEM/$PROBLEM.cpp"
EXE="$PRACTICE_DIR/$PROBLEM/$PROBLEM"

if [[ ! -f "$SRC_CPP" ]]; then
  echo "Solution file not found: $SRC_CPP" >&2
  exit 1
fi

mkdir -p "$(dirname "$EXE")"

src_rel="${SRC_CPP#$SCRIPT_DIR/}"
exe_rel="${EXE#$SCRIPT_DIR/}"
echo "Compiling $src_rel -> $exe_rel"
echo "Compiler  : $CXX"
echo "Compile flags: $CXXFLAGS"
echo "CPU time limit : ${TIME_LIMIT}s"
if ! "$CXX" $CXXFLAGS -o "$EXE" "$SRC_CPP"; then
  echo "Compilation failed." >&2
  exit 1
fi

echo "Compilation succeeded."

total=0
fail=0
tests_found=false

run_case() {
  local in_file="$1" ans_file="$2"
  local workdir
  workdir="$(dirname "$EXE")"

  # Prepare IO files expected by program (problem name based)
  cp "$in_file" "$workdir/${PROBLEM}.in"
  rm -f "$workdir/${PROBLEM}.out"

  # record start time (nanoseconds)
  local start_ns end_ns dur_ms
  start_ns=$(date +%s%N)

  # Execute under CPU time limit only
  if ! (cd "$workdir" && \
        ulimit -t "$TIME_LIMIT" 2>/dev/null && \
        "./$(basename "$EXE")" >/dev/null 2>&1 ); then
      echo "[LIMIT] $(basename "$(dirname "$in_file")")/$(basename "$in_file") exceeded CPU time limit" >&2
      ((fail++))
      rm -f "$workdir/${PROBLEM}.in"
      return
  fi

  # compute duration
  end_ns=$(date +%s%N)
  dur_ms=$(( (end_ns - start_ns)/1000000 ))

  if [[ ! -f "$workdir/${PROBLEM}.out" ]]; then
    echo "[ERROR] Output file missing for $(basename "$in_file")" >&2
    ((fail++))
  else
    group_label="$(basename "$(dirname "$(dirname "$in_file")")")"
    problem_dir="$(basename "$(dirname "$in_file")")"
    rel_file="${in_file#$SCRIPT_DIR/}"
    if diff -u --strip-trailing-cr "$ans_file" "$workdir/${PROBLEM}.out" >/dev/null; then
      echo "[PASS] $rel_file (${dur_ms} ms)"
    else
      echo "[FAIL] $rel_file (${dur_ms} ms)"
      diff -u --strip-trailing-cr "$ans_file" "$workdir/${PROBLEM}.out" || true
      ((fail++))
    fi
  fi

  # Clean up
  rm -f "$workdir/${PROBLEM}.in" "$workdir/${PROBLEM}.out"
}

# Detect available test groups (sample / data); skip if directory missing
for base in sample data; do
  test_subdir="$GROUP_PATH/$YEAR/$base/$PROBLEM"
  [[ -d "$test_subdir" ]] || continue
  # Collect and sort test cases using version sort so 10 comes after 9
  mapfile -t _test_inputs < <(printf '%s\n' "$test_subdir"/*.in | sort -V)

  for in_file in "${_test_inputs[@]}"; do
    [[ -e "$in_file" ]] || continue
    ans_file="${in_file%.in}.ans"
    if [[ ! -f "$ans_file" ]]; then
      echo "Answer file missing for $in_file" >&2
      continue
    fi
    total=$((total + 1))
    tests_found=true
    run_case "$in_file" "$ans_file"
  done
done

echo "----------------------------------------"
if ! $tests_found; then
  echo "No test cases found for $PROBLEM under $GROUP_PATH/$YEAR/{sample,data}."
  exit 1
fi

if [[ "$fail" -eq 0 ]]; then
  echo "All $total test cases passed."
else
  echo "$fail / $total test cases failed." >&2
  exit 1
fi 