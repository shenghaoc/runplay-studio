#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

failures=0

fail() {
  printf 'agent setup: %s\n' "$1" >&2
  failures=$((failures + 1))
}

require_file() {
  if [[ ! -f "$1" ]]; then
    fail "missing required file: $1"
  fi
}

trimmed_file_content() {
  local content
  content="$(<"$1")"
  while [[ "$content" =~ [[:space:]]$ ]]; do
    content="${content%${BASH_REMATCH[0]}}"
  done
  printf '%s' "$content"
}

require_file AGENTS.md
require_file CLAUDE.md
require_file GEMINI.md
require_file .github/copilot-instructions.md
require_file .jules/README.md

if [[ "$(trimmed_file_content CLAUDE.md)" != '@AGENTS.md' ]]; then
  fail 'CLAUDE.md must contain only @AGENTS.md, ignoring trailing whitespace'
fi

if [[ "$(trimmed_file_content GEMINI.md)" != '@AGENTS.md' ]]; then
  fail 'GEMINI.md must contain only @AGENTS.md, ignoring trailing whitespace'
fi

if ! grep -Fq 'AGENTS.md' .github/copilot-instructions.md; then
  fail 'Copilot instructions must reference AGENTS.md'
fi

if [[ $(wc -l < .github/copilot-instructions.md) -gt 8 ]] ||
  grep -Eiq 'swift (build|test)|RunPlay(Core|Platform|Studio)|^## (Architecture|Validation|Build)' .github/copilot-instructions.md; then
  fail 'Copilot instructions must remain a thin compatibility shim'
fi

if [[ ! -d .jules ]]; then
  fail 'missing .jules directory'
fi

if git ls-files | grep -q '^\.Jules/'; then
  fail 'tracked uppercase .Jules path remains'
fi

references=(
  README.md
  docs/architecture.md
  docs/import-formats.md
  docs/manual-testing.md
  docs/private-data.md
  docs/phase-plan.md
  docs/agent-workflow.md
  .github/workflows/ci.yml
)

for reference in "${references[@]}"; do
  require_file "$reference"
  if ! grep -Fq "$reference" AGENTS.md; then
    fail "AGENTS.md must link to $reference"
  fi
done

steering_files=(
  .kiro/steering/product.md
  .kiro/steering/structure.md
  .kiro/steering/tech.md
)

for steering_file in "${steering_files[@]}"; do
  require_file "$steering_file"
  if [[ -f "$steering_file" ]] && ! head -n 1 "$steering_file" | grep -Fxq -- '---'; then
    fail "$steering_file must begin with YAML front matter"
  fi
done

if [[ -f .kiro/steering/product.md ]] && ! grep -Fxq 'inclusion: always' .kiro/steering/product.md; then
  fail 'Kiro product steering must use inclusion: always'
fi

if [[ -f .kiro/steering/structure.md ]] &&
  { ! grep -Fxq 'inclusion: auto' .kiro/steering/structure.md ||
    ! grep -Eq '^name: .+' .kiro/steering/structure.md ||
    ! grep -Eq '^description: .+' .kiro/steering/structure.md; }; then
  fail 'Kiro structure steering must use named auto inclusion'
fi

if [[ -f .kiro/steering/tech.md ]] &&
  { ! grep -Fxq 'inclusion: fileMatch' .kiro/steering/tech.md ||
    ! grep -Fq 'Package.swift' .kiro/steering/tech.md ||
    ! grep -Fq '.github/workflows/**/*' .kiro/steering/tech.md ||
    ! grep -Fq 'scripts/**/*' .kiro/steering/tech.md; }; then
  fail 'Kiro tech steering must use the required fileMatch patterns'
fi

if git grep -n '\.Jules/' -- .kiro >/dev/null; then
  fail 'Kiro files must not reference .Jules/'
fi

if grep -Ein '([0-9][0-9,]*[[:space:]]+tests|test count|builds?[[:space:]]+(clean|pass|passed|passes)|tests?[[:space:]]+(pass|passed|passes))' "${steering_files[@]}"; then
  fail 'Kiro steering must not contain transient test counts or pass-status claims'
fi

if grep -En '(^|[^[:alnum:]_])[0-9a-f]{7,40}([^[:alnum:]_]|$)' "${steering_files[@]}"; then
  fail 'Kiro steering must not contain commit hashes'
fi

for copied_policy in 'Never commit directly to' 'one task equals one branch' 'git worktree add' 'swift build' 'swift test' 'git diff --check' 'warnings-as-errors'; do
  if grep -Fq "$copied_policy" "${steering_files[@]}"; then
    fail "Kiro steering must not duplicate canonical policy: $copied_policy"
  fi
done

while IFS= read -r live_reference; do
  path="${live_reference#\#\[\[file:}"
  path="${path%\]\]}"
  if [[ ! -f "$path" ]]; then
    fail "Kiro live file reference does not exist: $path"
  fi
done < <(grep -hEo '#\[\[file:[^]]+\]\]' "${steering_files[@]}" || true)

if ! grep -Fq 'Specs are task artifacts' docs/agent-workflow.md ||
  ! grep -Fq 'One spec belongs to one branch and one PR' docs/agent-workflow.md; then
  fail 'agent workflow must define Kiro specs as branch-local task artifacts'
fi

if [[ $failures -ne 0 ]]; then
  printf 'agent setup validation failed with %d issue(s)\n' "$failures" >&2
  exit 1
fi

printf '%s\n' 'agent setup validation passed'
