#===============================================================================
# Shared patching helpers: main-process chunk resolution, tripwire
# checks, dynamic extraction of minified variable names, and fix-ups
# that multiple tray/quick-window patches rely on.
#
# Sourced by: build.sh (via patches/app-asar.sh)
#             scripts/verify-patches.sh
# Sourced globals: project_root (build-time only)
# Modifies globals: electron_var, electron_var_re
#===============================================================================

# Resolve the main-process JS file from an index.js path.
#
# Pre-split bundles keep the entire main process in index.js itself.
# Since upstream 1.19367.0 the bundle is code-split: index.js is a
# small stub that require()s the real main chunk
# (index.chunk-<hash>.js — content-hashed, so the name changes every
# release). Newer bundles may load a small runtime chunk before the
# application chunk. Follow the stub's require() references and, when
# there is more than one, select the unique chunk that owns the
# menuBarEnabled settings used by the Linux main-process patches. Fall
# back to index.js for the pre-split layout.
#
# Usage:   _resolve_main_js <index-js-path>
# Stdout:  resolved path (index.js or the chunk it require()s)
# Stderr:  diagnostics on failure
# Return:  0 on success, 1 on any failure
#
# Safety:
#   - Only direct relative CommonJS references (require("./...")) are
#     followed — bare modules and comments/plain strings are ignored.
#   - The captured filename must match index.chunk-[A-Za-z0-9_-]+.js
#     exactly. No path separators, no "..", no arbitrary paths.
#   - If a chunk-like reference is present but malformed/unsafe, the
#     function fails rather than treating the bundle as legacy.
#   - Multiple direct chunk references must contain exactly one
#     application chunk (identified by its menuBarEnabled settings).
#   - Missing or zero-byte targets fail.
_resolve_main_js() {
	local index_js_path="${1:-}"

	if [[ -z $index_js_path ]]; then
		echo '_resolve_main_js: index.js path is required' >&2
		return 1
	fi

	if [[ ! -f $index_js_path ]]; then
		echo "_resolve_main_js: not found: $index_js_path" >&2
		return 1
	fi

	if [[ ! -s $index_js_path ]]; then
		echo "_resolve_main_js: zero-byte file: $index_js_path" >&2
		return 1
	fi

	local build_dir
	build_dir="${index_js_path%/*}"

	# Extract all relative require() arguments from the stub.
	# Matches require("./...") and require('./...') with optional
	# whitespace between require and the argument. The backreference
	# ensures the closing quote matches the opening quote.
	local -a require_paths
	mapfile -t require_paths < <(
		grep -oP "require\s*\(\s*([\"'])\./\K[^\"']+(?=\1\s*\))" \
			"$index_js_path" || true
	)

	# Separate chunk-like references into safe and unsafe.
	# Chunk-like: filename starts with "index.chunk-".
	# Safe:       matches ^index\.chunk-[A-Za-z0-9_-]+\.js$ exactly.
	# Unsafe:     chunk-like but doesn't match the safe pattern
	#             (e.g. path traversal, embedded "/", empty hash).
	local -a safe_chunks=()
	local -a unsafe_refs=()
	local rp
	for rp in "${require_paths[@]}"; do
		if [[ $rp == index.chunk-* ]]; then
			if [[ $rp =~ ^index\.chunk-[A-Za-z0-9_-]+\.js$ ]]; then
				safe_chunks+=("$rp")
			else
				unsafe_refs+=("$rp")
			fi
		fi
	done

	# If any unsafe chunk-like references exist, fail closed.
	if (( ${#unsafe_refs[@]} > 0 )); then
		local joined
		joined="$(IFS=', '; printf '%s' "${unsafe_refs[*]}")"
		echo "_resolve_main_js: malformed/unsafe chunk" \
			"reference(s): $joined" >&2
		return 1
	fi

	# No chunk references → legacy monolithic bundle.
	if (( ${#safe_chunks[@]} == 0 )); then
		printf '%s\n' "$index_js_path"
		return 0
	fi

	# A single chunk is the layout used by the first code-split
	# releases: index.js plus exactly one main chunk.
	if (( ${#safe_chunks[@]} == 1 )); then
		local chunk_path="$build_dir/${safe_chunks[0]}"
		if [[ ! -f $chunk_path ]]; then
			echo "_resolve_main_js: referenced chunk not" \
				"found: $chunk_path" >&2
			return 1
		fi
		if [[ ! -s $chunk_path ]]; then
			echo "_resolve_main_js: zero-byte chunk:" \
				"$chunk_path" >&2
			return 1
		fi

		printf '%s\n' "$chunk_path"
		return 0
	fi

	# Claude 1.44121.4 introduced a second direct startup chunk
	# (a small runtime chunk loaded before the application chunk).
	# Validate every referenced target before inspecting content, then
	# select the unique chunk containing the menuBarEnabled settings
	# owned by the application main process. Selecting on that semantic
	# avoids depending on hash, require order, or relative file size.
	local -a main_chunks=()
	local chunk_name chunk_path
	for chunk_name in "${safe_chunks[@]}"; do
		chunk_path="$build_dir/$chunk_name"
		if [[ ! -f $chunk_path ]]; then
			echo "_resolve_main_js: referenced chunk not" \
				"found: $chunk_path" >&2
			return 1
		fi
		if [[ ! -s $chunk_path ]]; then
			echo "_resolve_main_js: zero-byte chunk:" \
				"$chunk_path" >&2
			return 1
		fi
		if LC_ALL=C grep -aqE \
			'menuBarEnabled:[[:space:]]*' "$chunk_path"; then
			main_chunks+=("$chunk_path")
		fi
	done

	if (( ${#main_chunks[@]} == 1 )); then
		printf '%s\n' "${main_chunks[0]}"
		return 0
	fi

	# No unique application chunk: either none of the startup chunks
	# carries the main-process settings, or several do. Both are
	# ambiguous, so fail closed instead of guessing.
	local joined
	joined="$(IFS=', '; printf '%s' "${safe_chunks[*]}")"
	echo "_resolve_main_js: multiple main chunk" \
		"references found without a unique application chunk:" \
		"$joined" >&2
	return 1
}

# Check the MB-1 tripwire: menuBarEnabled:!0 must be present in the
# main-process JS. This is the settings default that keeps the menu
# bar on; the tray patches assume it. If upstream flips it, the menu
# bar would default OFF on Linux.
#
# Usage:   _check_mb1_tripwire <main-js-path>
# Stderr:  diagnostic on failure
# Return:  0 if present, 1 otherwise
_check_mb1_tripwire() {
	local main_js_path="${1:-}"

	if [[ -z $main_js_path || ! -f $main_js_path ]]; then
		echo '_check_mb1_tripwire: main JS path is required' \
			'and must exist' >&2
		return 1
	fi

	if ! LC_ALL=C grep -aqE \
		'menuBarEnabled:[[:space:]]*!0' "$main_js_path"; then
		echo 'Tripwire (MB-1): "menuBarEnabled:!0" is gone from' \
			'the bundle — upstream may have flipped the menu-bar' \
			'default. Re-evaluate the tray patches before' \
			'shipping.' >&2
		return 1
	fi
	return 0
}

extract_electron_variable() {
	echo 'Extracting electron module variable name...'

	electron_var=$(grep -oP '[$\w]+(?=\s*=\s*require\("electron"\))' \
		"$main_js" | head -1)
	if [[ -z $electron_var ]]; then
		electron_var=$(grep -oP '(?<=new )[$\w]+(?=\.Tray\b)' \
			"$main_js" | head -1)
	fi
	if [[ -z $electron_var ]]; then
		echo 'Failed to extract electron variable name' >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	electron_var_re="${electron_var//\$/\\$}"
	echo "  Found electron variable: $electron_var"
	echo '##############################################################'
}

fix_native_theme_references() {
	echo 'Fixing incorrect nativeTheme variable references...'

	local wrong_refs
	mapfile -t wrong_refs < <(
		grep -oP '[$\w]+(?=\.nativeTheme)' "$main_js" \
			| sort -u \
			| grep -Fxv "$electron_var" || true
	)

	if (( ${#wrong_refs[@]} == 0 )); then
		echo '  All nativeTheme references are correct'
		echo '##############################################################'
		return
	fi

	local ref ref_re
	for ref in "${wrong_refs[@]}"; do
		echo "  Replacing: $ref.nativeTheme -> $electron_var.nativeTheme"
		ref_re="${ref//\$/\\$}"
		sed -i -E \
			"s/${ref_re}\.nativeTheme/${electron_var_re}.nativeTheme/g" \
			"$main_js"
	done
	echo '##############################################################'
}

# Quote class for minified-JS anchors: upstream swapped the minifier
# (Debian #820) and re-emitted nearly every string literal as a
# backtick template, so a bare " in an anchor matches nothing on
# newer bundles. Spell every anchor delimiter with _ANCHOR_Q.
_ANCHOR_Q='[`"'"'"']'

# Count the PCRE matches of an anchor in a file (stdout: decimal).
#
# Usage:   _count_anchor_matches <file> <pcre>
# Stdout:  match count (0 when the file is missing/unreadable)
# Return:  always 0
_count_anchor_matches() {
	local file="${1:-}"
	local pattern="${2:-}"
	local count

	if [[ -z $file || -z $pattern || ! -f $file ]]; then
		printf '0\n'
		return 0
	fi
	count=$(grep -oP -- "$pattern" "$file" 2>/dev/null | wc -l)
	count=$(printf '%s' "$count" | tr -d '[:space:]')
	if [[ -z $count ]]; then
		count=0
	fi
	printf '%s\n' "$count"
	return 0
}

# Assert an anchor matches exactly one location in a file.
#
# When an anchor matches more than one site, patching the first one
# would hit an arbitrary location, so the caller must WARN and skip
# instead. Zero matches is an anchor miss (WARNING as well — absence
# in a Windows-installer-derived bundle is not necessarily a
# regression, so this stays a skip, never a hard fail).
#
# Usage:   _assert_single_anchor_match <file> <pcre> <label>
# Stderr:  diagnostic when the count is not exactly one
# Return:  0 on exactly one match, 1 otherwise
_assert_single_anchor_match() {
	local file="${1:-}"
	local pattern="${2:-}"
	local label="${3:-anchor}"
	local count

	count=$(_count_anchor_matches "$file" "$pattern")
	if [[ $count -eq 1 ]]; then
		return 0
	fi
	if [[ $count -eq 0 ]]; then
		echo "  WARNING: anchor '$label' not found in" \
			"$(basename "$file") — skipping" >&2
	else
		echo "  WARNING: anchor '$label' matched $count sites" \
			'in '"$(basename "$file")"'(expected 1) — skipping' \
			'to avoid patching the wrong one' >&2
	fi
	return 1
}

# Digest every file under .vite/build, relative to CWD (the staging
# dir at patch time). Every patch writes there; a patch that writes
# anywhere else is invisible to this check. A missing or empty tree
# fails rather than hashing to a constant that compares equal on both
# sides (a false pass on re-run).
#
# Usage:   _patch_bundle_digest
# Stdout:  hex digest
# Return:  0 on success, 1 when the tree is missing or empty
_patch_bundle_digest() {
	local build_dir='app.asar.contents/.vite/build'
	local probe

	if [[ ! -d $build_dir ]]; then
		return 1
	fi
	probe=$(find "$build_dir" -type f -print -quit)
	if [[ -z $probe ]]; then
		return 1
	fi
	find "$build_dir" -type f -print0 | LC_ALL=C sort -z \
		| xargs -0 sha256sum | sha256sum | cut -d' ' -f1
}

# Compare the .vite/build digests taken before and after a re-run of
# the patch stage over an already-patched tree (PATCH_STAGE_RERUN=1).
# Any byte change means a patch's idempotency guard misses its own
# output and re-applies.
#
# Usage:   _check_patch_stage_idempotent <before> <after>
# Stderr:  diagnostic when the digests differ
# Return:  0 when unchanged, 1 otherwise
_check_patch_stage_idempotent() {
	local before="${1:-}"
	local after="${2:-}"

	if [[ -z $before || -z $after ]]; then
		echo 'Idempotency: missing bundle digest — cannot' \
			'verify the re-run left the bundle unchanged' >&2
		return 1
	fi
	if [[ $before == "$after" ]]; then
		return 0
	fi
	echo 'Idempotency: second patch pass over the already-patched' \
		'bundle changed bytes — a patch guard misses its own' \
		'output and re-applies. Refuse to ship.' >&2
	return 1
}
