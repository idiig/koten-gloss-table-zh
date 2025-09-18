#!/usr/bin/env bash
set -euo pipefail

# generate_glossary.sh
# Global glossary from an annotated JSON:
# - Tokens = codes of [A-Z0-9]+ with >=2 uppercase letters (ADN, AOR2, 1SG, 3PL, ...)
#            + ALL Unicode punctuation/symbol chars EXCEPT brackets (Ps/Pe excluded)
# - Deduplicate by `gloss`, sort, enrich from SOURCE
# - Unmatched keep null fields
# - Logs: by default count symbols in unmatched; use --no-log-symbols to exclude them
#
# Usage:
#   ./generate_glossary.sh INPUT.json [SOURCE.json] [--quiet|--verbose|--no-log-symbols]
# Stdout: JSON array of gloss objects

QUIET=0
VERBOSE=0
LOG_SYMBOLS=1   # include symbols in unmatched logging by default
INPUT=""
SRC_DEFAULT="../sources/zisk-gloss-conventions-2024.json"
SRC="$SRC_DEFAULT"

ARGS=()
for a in "$@"; do
  case "$a" in
    --quiet)           QUIET=1 ;;
    --verbose)         VERBOSE=1 ;;
    --no-log-symbols)  LOG_SYMBOLS=0 ;;
    *) ARGS+=("$a") ;;
  esac
done

if [[ ${#ARGS[@]} -lt 1 ]]; then
  echo "Usage: $0 INPUT.json [SOURCE.json] [--quiet|--verbose|--no-log-symbols]" >&2
  exit 1
fi
INPUT="${ARGS[0]}"
[[ ${#ARGS[@]} -ge 2 ]] && SRC="${ARGS[1]}"

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required." >&2; exit 1; }
[[ -f "$INPUT" ]] || { echo "Error: input not found: $INPUT" >&2; exit 1; }
[[ -f "$SRC"   ]] || { echo "Error: source not found: $SRC" >&2; exit 1; }

PACKED="$(
  jq --argjson logSymbols "$LOG_SYMBOLS" --slurpfile src "$SRC" '
    # Load source as object
    def SRC: ( ($src // []) | if length>0 then .[0] else {} end );

    # Helper: is this single-char string a bracket (Unicode Ps or Pe)?
    # NOTE: no "u" modifier; many jq builds already treat patterns as Unicode.
    def is_bracket_char($c): ($c | test("^(\\p{Ps}|\\p{Pe})$"));

    # Helper: token is pure symbol iff removing all \p{P} and \p{S} leaves empty
    def is_symbol_token($s): ($s | gsub("[\\p{P}\\p{S}]"; "") == "");

    # Extract tokens:
    #  - Codes: [A-Z0-9]+ with >=2 uppercase letters (captures ADN, AOR2, 1SG, 3PL, ...)
    #  - Symbols: all \p{P} or \p{S} chars, but EXCLUDE brackets (Ps/Pe)
    def detect_tokens($x):
      ( $x
        | [ .. | objects | to_entries[] | select(.key | startswith("gloss-morph-")) | .value ]
        | map(tostring) | join(" ")
      ) as $t
      | (
          # Codes
          ( $t
            | gsub("[^A-Za-z0-9]+"; " ")
            | split(" ")
            | map(select( (test("^[A-Z0-9]+$"))
                           and ( (gsub("[^A-Z]";"") | length) >= 2 ) ))
          )
          +
          # Symbols except brackets
          ( $t
            | gsub("[^\\p{P}\\p{S}]"; "")  # keep punctuation+symbols
            | explode
            | map([.] | implode)
            | map(select( is_bracket_char(.) | not ))
          )
        )
      | unique
      | sort ;

    # Map token to record (null-valued if not found)
    def lookup_obj($c):
      (
        SRC.glosses[]?
        | select(.gloss == $c)
        | {gloss, grammatical_function_en, grammatical_function_ja, grammatical_function_zh}
      )
      // {gloss: $c, grammatical_function_en: null, grammatical_function_ja: null, grammatical_function_zh: null};

    ( detect_tokens(.) | map(lookup_obj(.)) | unique_by(.gloss) | sort_by(.gloss) ) as $gls

    | ( $gls
        | map(select(
            (.grammatical_function_en==null)
            and (.grammatical_function_ja==null)
            and (.grammatical_function_zh==null)
          ))
        | ( if $logSymbols==1
            then .                       # include symbols in unmatched logging
            else map(select( ( .gloss | is_symbol_token(.) ) | not ))
          end )
        | map(.gloss)
      ) as $unmatched

    | { glossary: $gls,
        log: { total: ($gls|length),
               unmatched_count: ($unmatched|length),
               unmatched: $unmatched } }
  ' "$INPUT"
)"

# Emit glossary list
echo "$PACKED" | jq '.glossary'

# Conditional logs
if [[ "$QUIET" -eq 0 || "$VERBOSE" -eq 1 ]]; then
  total=$(echo "$PACKED" | jq '.log.total')
  umc=$(echo "$PACKED" | jq '.log.unmatched_count')
  if [[ "$VERBOSE" -eq 1 || "$umc" -gt 0 ]]; then
    echo "[INFO] Total tokens: $total" >&2
    echo "[INFO] Unmatched count: $umc" >&2
    if [[ "$umc" -gt 0 ]]; then
      echo "$PACKED" | jq -r '.log.unmatched | join(",")' | while read -r line; do
        [[ -n "$line" ]] && echo "[WARN] Unmatched tokens: $line" >&2
      done
    fi
  fi
fi
