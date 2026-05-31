patch_org_plugins_path() {
	local index_js='app.asar.contents/.vite/build/index.js'

	if grep -q 'case"linux":return"/etc/claude/org-plugins"' \
		"$index_js"; then
		echo 'Linux org-plugins path already present'
		return
	fi

	local anchor='Application Support/Claude/org-plugins'
	if ! grep -q "$anchor" "$index_js"; then
		echo 'Warning: org-plugins path resolver not found' \
			'in this version, skipping' >&2
		return
	fi

	if grep -qP '"org-plugins"\)\s*;\s*default\s*:\s*return\s+null' \
		"$index_js"; then
		sed -i -E \
			's/("org-plugins"\)\s*;\s*)(default\s*:\s*return\s+null)/\1case"linux":return"\/etc\/claude\/org-plugins";\2/' \
			"$index_js"
		echo 'Added Linux org-plugins path (/etc/claude/org-plugins)'
	else
		echo 'Warning: org-plugins switch pattern not matched,' \
			'skipping' >&2
	fi
}
