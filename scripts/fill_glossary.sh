#!/usr/bin/env bash
set -euo pipefail

# fill_glossary.sh
# Per-paragraph update of "glossary-abbreviations" using a prebuilt glossary JSON (array).
#
# Tokens:
#   - Codes: [A-Z0-9]+ with >= 2 uppercase letters (e.g., ADN, AOR2, 1SG, 3PL)
#   - Symbols: ALL Unicode \p{P} or \p{S} chars, EXCEPT brackets (Ps/Pe)
#
# Behavior:
#   - Update ONLY objects that already have "glossary-abbreviations"
#   - Value becomes a flat array of gloss objects (dedup by .gloss)
#   - Unmatched keep null fields
#   - Logs to stderr ONLY if unmatched exist, or with --verbose
#   - Use --no-log-symbols to exclude symbols from "unmatched" stats/logs
#
# Usage:
#   ./fill_glossary.sh INPUT.json [GLOSSARY.json] [--quiet|--verbose|--no-log-symbols]
#   - Default glossary path: ../glossary.json  (output from generate_glossary.sh)

QUIET=0
VERBOSE=0
LOG_SYMBOLS=1   # include symbols in unmatched logging by default
INPUT=""
SRC_DEFAULT="../glossary.json"
SRC="$SRC_DEFAULT"

ARGS=()
for a in "$@"; do
    case "$a" in
	--quiet)           QUIET=1 ;;
	--verbose)         VERBOSE=1 ;;
	--no-log-symbols)  LOG_SYMBOLS=0 ;;
	*) ARGS+=("$a") ;;   # non-option args
    esac
done

if [[ ${#ARGS[@]} -lt 1 ]]; then
    echo "Usage: $0 INPUT.json [GLOSSARY.json] [--quiet|--verbose|--no-log-symbols]" >&2
    exit 1
fi
INPUT="${ARGS[0]}"
[[ ${#ARGS[@]} -ge 2 ]] && SRC="${ARGS[1]}"

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required." >&2; exit 1; }
[[ -f "$INPUT" ]] || { echo "Error: input not found: $INPUT" >&2; exit 1; }
[[ -f "$SRC"   ]] || { echo "Error: glossary source not found: $SRC" >&2; exit 1; }

PACKED="$(
  jq --argjson logSymbols "$LOG_SYMBOLS" --slurpfile src "$SRC" '
    # ===== shared helpers & dict =====
    # is_bracket_char: single-char bracket? (Unicode Ps / Pe)
    def is_bracket_char($c): ($c | test("^(\\p{Ps}|\\p{Pe})$"));
    
    # is_symbol_token: token becomes "symbol" iff removing all \p{P} and \p{S} leaves empty
    def is_symbol_token($s): ($s | gsub("[\\p{P}\\p{S}]"; "") == "");

    # Source is an array of gloss records (first slurped element)
    def SRCARR: ( ($src // []) | if length>0 then .[0] else [] end );

    # Build SRCDICT from SRCARR
    # Expect: SRCARR is an array of gloss records
    def SRCDICT:
      (reduce (SRCARR[]? // empty) as $g ({}; .[$g.gloss] =
    					   { gloss: $g.gloss,
    					     grammatical_function_en: ($g.grammatical_function_en // null),
    					     grammatical_function_ja: ($g.grammatical_function_ja // null),
    					     grammatical_function_zh: ($g.grammatical_function_zh // null)
    					   }));

    # Map token via SRCDICT; if missing, produce null-valued record
    # map_token($c): lookup via SRCDICT; fall back to null-valued record
    def map_token($c):
      ( SRCDICT[$c] )
        // {gloss: $c,
    	grammatical_function_en: null,
    	grammatical_function_ja: null,
    	grammatical_function_zh: null};

    # Token detection (codes + symbols excluding brackets)
    # detect_tokens($x):
    # - Codes: [A-Z0-9]+ and must contain >= 2 uppercase letters (e.g., ADN/AOR2/1SG/3PL)
    # - Symbols: ALL \p{P} or \p{S} chars, EXCEPT brackets (Ps/Pe)
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
            | gsub("[^\\p{P}\\p{S}]"; "")
            | explode
            | map([.] | implode)
            | map(select( is_bracket_char(.) | not ))
          )
      )
      | unique
      | sort ;

    # Unmatched extraction (optionally excluding symbols from logs)
    # unmatched_glosses($arr; $logSymbols):
    # - $arr: array of gloss records
    # - $logSymbols: 1 to include symbol tokens in unmatched, 0 to exclude
    def unmatched_glosses($arr; $logSymbols):
      ( $arr
        | map(select(
    	      (.grammatical_function_en==null)
    		and (.grammatical_function_ja==null)
    		and (.grammatical_function_zh==null)
    	    ))
        | ( if $logSymbols==1
            then .
            else map(select( ( .gloss | is_symbol_token(.) ) | not ))
    	end )
        | map(.gloss)
      );

    # Per-paragraph annotate & collect logs
    # Update only objects that already have the key, preserving position
    def annotate:
      if type=="object" then
        if has("glossary-abbreviations") then
          . as $o
          | .["glossary-abbreviations"]
             = ( detect_tokens($o)
                 | map(map_token(.))
                 | unique_by(.gloss) )
        else
          with_entries(.value |= annotate)
        end
      elif type=="array" then
        map(annotate)
      else . end;
    # Collect per-paragraph unmatched after annotation
    def collect_logs:
      if type=="object" then
        (
          if has("glossary-abbreviations") and (.["glossary-abbreviations"] | type=="array") then
            . as $obj
            | (.["glossary-abbreviations"]) as $arr
            | ( unmatched_glosses($arr; $logSymbols) ) as $unmatched
            | [{
                  id: ($obj.id // null),
                  unmatched_count: ($unmatched | length),
                  unmatched: $unmatched
                }]
          else [] end
        )
          + ( [ .[]? | collect_logs ] | add // [] )
      elif type=="array" then
        ( [ .[] | collect_logs ] | add // [] )
      else [] end;

    # Pack {doc, log}
    ( . as $orig
      | ( $orig | annotate ) as $doc
      | { doc: $doc, log: ($doc | collect_logs) }
    )
  ' "$INPUT"
)"

# STDOUT: updated JSON
echo "$PACKED" | jq '.doc'

# STDERR: logs (only when unmatched exist or --verbose)
if [[ "$QUIET" -eq 0 || "$VERBOSE" -eq 1 ]]; then
    total_unm=$(echo "$PACKED" | jq '[.log[].unmatched_count] | add // 0')
    if [[ "$VERBOSE" -eq 1 || "$total_unm" -gt 0 ]]; then
	total_para=$(echo "$PACKED" | jq '.log | length')
	echo "[INFO] Paragraphs updated: $total_para" >&2
	echo "[INFO] Unmatched entries (sum): $total_unm" >&2
	if [[ "$total_unm" -gt 0 ]]; then
	    idx=0
	    echo "$PACKED" | jq -r '
        .log[] | [
          ( .id // "N/A" ),
          .unmatched_count,
          ( ( .unmatched // [] ) | join(",") )
        ] | @tsv
      ' | while IFS=$'\t' read -r pid cunm unmlist; do
		[[ "$pid" == "N/A" ]] && pid="idx:$idx"
		echo "[WARN] Paragraph ${pid} unmatched=${cunm}${unmlist:+  (unmatched: ${unmlist})}" >&2
		idx=$((idx+1))
	    done
	fi
    fi
fi
