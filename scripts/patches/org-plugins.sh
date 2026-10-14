#===============================================================================
# Linux org-plugins path: inject a case"linux" into the platform switch
# that resolves the org-plugins source directory.
#
# Upstream only has cases for darwin and win32; the default returns null,
# silently disabling the entire org-plugins marketplace feature on Linux.
# This adds: case"linux":return"/etc/claude/org-plugins"
#
# /etc/claude/org-plugins is FHS-correct for MDM-managed configuration,
# consistent with Claude Code's /etc/claude-code/ path.
#
# Sourced by: build.sh
# Sourced globals: (none)
# Modifies globals: (none)
#===============================================================================

# Quote class: newer bundles re-emit string literals as backtick
# templates, so a bare " in an anchor matches nothing (Debian #820).
# The injected case keeps double quotes on purpose — it is our own
# JS and is valid under either emission style.
_ORG_Q='[`"'"'"']'

patch_org_plugins_path() {
	local index_js="$main_js"

	# Idempotency: skip if a Linux case already exists near the
	# org-plugins path resolver (upstream may add one in the future).
	# Quote class and \s* so our own injected bytes match under any
	# emission style.
	if grep -qP "case\\s*${_ORG_Q}linux${_ORG_Q}\\s*:\\s*return\\s*${_ORG_Q}/etc/claude/org-plugins" \
		"$index_js"; then
		echo 'Linux org-plugins path already present'
		return
	fi

	# Anchor: the darwin path string is unique in the entire bundle.
	# Verify it exists before attempting the patch. No quote class
	# needed — the match is on the path's interior, away from either
	# delimiter. This anchor is invariant under the patch, so the
	# second run still resolves before the idempotency guard fires.
	local anchor='Application Support/Claude/org-plugins'
	if ! grep -qF "$anchor" "$index_js"; then
		echo 'Warning: org-plugins path resolver not found' \
			'in this version, skipping' >&2
		return
	fi

	# Pattern (minified):
	#   ..."org-plugins");default:return null}
	#
	# The compound anchor — "org-plugins") immediately before
	# default:return null — is unique to this switch statement.
	# Insert case"linux":return"/etc/claude/org-plugins"; between
	# the end of the win32 case and the default case.
	#
	# \s* between tokens handles any future whitespace variation,
	# though the target file is always minified in practice.
	# A duplicated switch (more than one match) WARNS and skips
	# instead of patching an arbitrary site.
	local switch_re="(${_ORG_Q}org-plugins${_ORG_Q}\\)\\s*;\\s*)"
	switch_re+="(default\\s*:\\s*return\\s+null)"
	if ! _assert_single_anchor_match "$index_js" \
		"$switch_re" 'org-plugins switch'; then
		echo 'Warning: org-plugins switch pattern not matched' \
			'unambiguously, skipping' >&2
		return
	fi
	sed -i -E \
		"s/${switch_re}/\\1case\"linux\":return\"\\/etc\\/claude\\/org-plugins\";\\2/" \
		"$index_js"
	echo 'Added Linux org-plugins path (/etc/claude/org-plugins)'
}
