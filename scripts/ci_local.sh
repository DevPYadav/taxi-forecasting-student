#!/usr/bin/env bash
# Local quality runner with optional Terraform checks.
# 1. Ruff lint            (ruff check .)
# 2. Pytest + coverage    (pytest --cov=src)
# 3. Terraform fmt/validate (infra/terraform) - skipped if terraform is absent
# Usage: ./scripts/ci_local.sh [--no-terraform]

NO_TERRAFORM=0
[ "$1" = "--no-terraform" ] && NO_TERRAFORM=1

# Repo root = parent of this script's directory.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

# Prefer the project venv's Python if present, else fall back to python/python3.
if [ -x "$REPO_ROOT/.venv/bin/python" ]; then
  PYTHON="$REPO_ROOT/.venv/bin/python"
elif command -v python >/dev/null 2>&1; then
  PYTHON="python"
else
  PYTHON="python3"
fi

FAILURES=()

run_step() {
  local name="$1"; shift
  echo
  printf '\033[36m=== %s ===\033[0m\n' "$name"
  "$@"
  local rc=$?
  if [ $rc -ne 0 ]; then
    printf '\033[31mFAILED: %s (exit %d)\033[0m\n' "$name" "$rc"
    FAILURES+=("$name")
  else
    printf '\033[32mOK: %s\033[0m\n' "$name"
  fi
}

run_step "Ruff lint" "$PYTHON" -m ruff check .
run_step "Pytest + coverage" "$PYTHON" -m pytest --cov=src --cov-report=term-missing --cov-report=xml

if [ $NO_TERRAFORM -eq 1 ]; then
  printf '\n\033[33mSkipping Terraform checks (--no-terraform).\033[0m\n'
elif ! command -v terraform >/dev/null 2>&1; then
  printf "\n\033[33mSkipping Terraform checks: 'terraform' not found on PATH.\033[0m\n"
else
  cd "$REPO_ROOT/infra/terraform" || exit 1
  run_step "Terraform fmt" terraform fmt -check -recursive
  run_step "Terraform init" bash -c 'terraform init -backend=false -input=false >/dev/null'
  run_step "Terraform validate" terraform validate
  cd "$REPO_ROOT" || exit 1
fi

echo
if [ ${#FAILURES[@]} -gt 0 ]; then
  IFS=', '
  printf '\033[31mCI FAILED - %d check(s) failed: %s\033[0m\n' "${#FAILURES[@]}" "${FAILURES[*]}"
  exit 1
fi
printf '\033[32mAll CI checks passed.\033[0m\n'
exit 0
