package main

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
)

// lipgloss is used indirectly via padLineWithURL and theme styles.

// Row types for the flat row list.
type rowKind int

const (
	rowGroupHeader rowKind = iota
	rowGroupDesc
	rowRepoSummary
	rowRepoDetail
	rowAction // clickable action button
)

type auditRow struct {
	kind     rowKind
	groupIdx int
	repoName string
	text     string   // pre-rendered content (without cursor highlight)
	severity Severity // for coloring
	btnCol   int      // column where [m] button starts (-1 if none)
	url      string   // if set, double-click/right-arrow opens this URL
}

type auditModel struct {
	groups    []RepoGroup
	configs   map[string]*RepoConfig // for field line number lookups
	rows      []auditRow
	cursor    int
	scrollOff int
	collapsed map[int]bool    // group index -> collapsed
	expanded  map[string]bool // repo name -> detail expanded
}

func newAuditModel(groups []RepoGroup, configs map[string]*RepoConfig) auditModel {
	m := auditModel{
		groups:    groups,
		configs:   configs,
		collapsed: make(map[int]bool),
		expanded:  make(map[string]bool),
	}
	m.buildRows()
	return m
}

func (m *auditModel) buildRows() {
	m.rows = nil

	for gi, g := range m.groups {
		// Group header row.
		arrow := "▼"
		if m.collapsed[gi] {
			arrow = "▶"
		}
		headerText := fmt.Sprintf("%s %s (%d repos)", arrow, g.Name, len(g.Repos))
		m.rows = append(m.rows, auditRow{
			kind:     rowGroupHeader,
			groupIdx: gi,
			text:     headerText,
			severity: SeverityOK,
		})

		if m.collapsed[gi] {
			continue
		}

		// Group description — split on newlines so each line is its own row.
		if g.Description != "" {
			for _, descLine := range strings.Split(g.Description, "\n") {
				m.rows = append(m.rows, auditRow{
					kind:     rowGroupDesc,
					groupIdx: gi,
					text:     "  " + descLine,
					severity: SeverityOK,
				})
			}
		}

		// Repos in group.
		for _, repo := range g.Repos {
			worst := repo.WorstSeverity()
			icon := SeverityIcon(worst)
			statusLabel := severityLabel(worst)
			keyDetail := buildKeyDetail(g.Type, repo)

			// Flag missing plugins in the summary line.
			var missingPlugins []string
			if !repo.Plugins.HasApproveSection && !repo.Plugins.HasApprovePlugin {
				missingPlugins = append(missingPlugins, "approve")
			}
			if !repo.Plugins.HasLgtmSection {
				missingPlugins = append(missingPlugins, "lgtm")
			}
			pluginHint := ""
			if len(missingPlugins) > 0 {
				pluginHint = fmt.Sprintf(" [missing: %s]", strings.Join(missingPlugins, ","))
			}

			summaryText := fmt.Sprintf("  [m] %-40s %s %-8s %s%s", repo.Name, icon, statusLabel, keyDetail, pluginHint)
			// URL to the repo's prow config directory in openshift/release.
			parts := strings.SplitN(repo.Name, "/", 2)
			repoURL := ""
			if len(parts) == 2 {
				repoURL = fmt.Sprintf("https://github.com/openshift/release/tree/main/core-services/prow/02_config/%s/%s", parts[0], parts[1])
			}
			m.rows = append(m.rows, auditRow{
				kind:     rowRepoSummary,
				groupIdx: gi,
				repoName: repo.Name,
				text:     summaryText,
				severity: worst,
				btnCol:   2, // [m] starts at column 2
				url:      repoURL,
			})

			// Expanded detail rows.
			if m.expanded[repo.Name] {
				rc := m.configs[repo.Name]
				details := buildDetailRows(repo, rc)
				for _, d := range details {
					m.rows = append(m.rows, auditRow{
						kind:     rowRepoDetail,
						groupIdx: gi,
						repoName: repo.Name,
						text:     d.text,
						severity: d.severity,
						url:      d.url,
					})
				}
			}
		}
	}
}

func buildKeyDetail(groupType string, repo RepoAudit) string {
	switch groupType {
	case "upstream-rebase":
		fp := repo.Fields["allow_force_pushes"]
		if fp == "" {
			fp = "NOT_SET"
		}
		return "force_push=" + fp
	default:
		ea := repo.Fields["enforce_admins"]
		if ea == "" {
			ea = "NOT_SET"
		}
		rc := repo.Fields["required_approving_review_count"]
		if rc == "" {
			rc = "NOT_SET"
		}
		return fmt.Sprintf("enforce_admins=%s review_count=%s", ea, rc)
	}
}

type detailLine struct {
	text     string
	severity Severity
	url      string
}

func buildDetailRows(repo RepoAudit, rc *RepoConfig) []detailLine {
	var lines []detailLine

	// Field order for display.
	fieldOrder := []string{
		"require_self_approval",
		"review_acts_as_lgtm",
		"enforce_admins",
		"required_approving_review_count",
		"dismiss_stale_reviews",
		"allow_force_pushes",
		"merge_method",
	}

	// Build a finding map for quick lookup.
	findingMap := make(map[string]Finding)
	for _, f := range repo.Findings {
		findingMap[f.Field] = f
	}

	totalFields := len(fieldOrder) + 2 // +2 for plugins and tide
	idx := 0

	for _, field := range fieldOrder {
		val := repo.Fields[field]
		if val == "" {
			val = "NOT_SET"
		}

		checkIcon := " "
		sev := SeverityOK
		if f, ok := findingMap[field]; ok {
			sev = f.Severity
			checkIcon = SeverityIcon(sev)
		}

		prefix := "    ├─"
		idx++
		if idx == totalFields {
			prefix = "    └─"
		}

		// Link to the line in the config file where this field is defined.
		fieldURL := ""
		if rc != nil && val != "NOT_SET" && val != "MISSING_FILE" {
			fieldURL = FieldURL(rc, field)
		}

		line := fmt.Sprintf("%s %-28s %-10s %s", prefix, field+":", val, checkIcon)
		lines = append(lines, detailLine{text: line, severity: sev, url: fieldURL})
	}

	// Plugins row.
	idx++
	pluginPrefix := "    ├─"
	if idx == totalFields {
		pluginPrefix = "    └─"
	}
	approveStr := "✗"
	approveSev := SeverityIssue
	if repo.Plugins.HasApprovePlugin || repo.Plugins.HasApproveSection {
		approveStr = "✓"
		approveSev = SeverityOK
	}
	lgtmStr := "✗"
	lgtmSev := SeverityIssue
	if repo.Plugins.HasLgtmSection {
		lgtmStr = "✓"
		lgtmSev = SeverityOK
	}
	pluginSev := SeverityOK
	if approveSev == SeverityIssue || lgtmSev == SeverityIssue {
		pluginSev = SeverityIssue
	}
	pluginLine := fmt.Sprintf("%s Plugins: approve %s  lgtm %s", pluginPrefix, approveStr, lgtmStr)
	lines = append(lines, detailLine{text: pluginLine, severity: pluginSev})

	// Tide row.
	idx++
	tidePrefix := "    └─"
	tideBranches := "none"
	if len(repo.Tide.IncludedBranches) > 0 {
		tideBranches = strings.Join(repo.Tide.IncludedBranches, ", ")
	}
	tideLine := fmt.Sprintf("%s Tide: %s", tidePrefix, tideBranches)
	lines = append(lines, detailLine{text: tideLine, severity: SeverityOK})

	return lines
}

func severityLabel(s Severity) string {
	switch s {
	case SeverityOK:
		return "OK"
	case SeverityInfo:
		return "INFO"
	case SeverityWarning:
		return "WARN"
	case SeverityIssue:
		return "ISSUE"
	default:
		return ""
	}
}

func (m auditModel) View(width, height int) string {
	if len(m.rows) == 0 {
		return RowDimStyle.Render("  No audit data available.")
	}

	var b strings.Builder

	end := m.scrollOff + height
	if end > len(m.rows) {
		end = len(m.rows)
	}

	const btnPrefix = "[m] "
	const btnPrefixLen = 4 // len("[m] ")

	for i := m.scrollOff; i < end; i++ {
		row := m.rows[i]
		line := padLineWithURL(row.text, row.url, width)

		var styled string
		if i == m.cursor {
			styled = RowSelectedStyle.Render(line)
		} else if row.kind == rowRepoSummary && row.btnCol >= 0 {
			// Render [m] prefix in accent, rest in severity color.
			// line starts with "  [m] ..." — split at btnCol + btnPrefixLen
			btnEnd := row.btnCol + btnPrefixLen
			btnPart := line[:btnEnd]
			restPart := line[btnEnd:]
			styled = FooterKeyStyle.Render(btnPart) + SeverityStyle(row.severity).Render(restPart)
		} else {
			switch row.kind {
			case rowGroupHeader:
				styled = SectionHeaderStyle.Render(line)
			case rowGroupDesc:
				styled = RowDimStyle.Render(line)
			case rowRepoSummary, rowRepoDetail:
				styled = SeverityStyle(row.severity).Render(line)
			default:
				styled = line
			}
		}

		b.WriteString(styled)
		if i < end-1 {
			b.WriteString("\n")
		}
	}

	return appendScrollIndicator(b.String(), m.cursor, len(m.rows), width)
}

func (m *auditModel) Update(msg tea.KeyMsg) tea.Cmd {
	if newCursor, handled := handleNavKeys(msg, m.cursor, len(m.rows)); handled {
		m.cursor = newCursor
		m.clampCursor()
		return nil
	}

	switch msg.String() {
	case "enter", " ":
		if m.cursor >= 0 && m.cursor < len(m.rows) {
			row := m.rows[m.cursor]
			switch row.kind {
			case rowGroupHeader:
				m.collapsed[row.groupIdx] = !m.collapsed[row.groupIdx]
				m.buildRows()
			case rowRepoSummary:
				m.expanded[row.repoName] = !m.expanded[row.repoName]
				m.buildRows()
			}
		}
	case "left", "h":
		// Collapse: if on group header, collapse group; if on repo, collapse detail.
		if m.cursor >= 0 && m.cursor < len(m.rows) {
			row := m.rows[m.cursor]
			switch row.kind {
			case rowGroupHeader:
				if !m.collapsed[row.groupIdx] {
					m.collapsed[row.groupIdx] = true
					m.buildRows()
				}
			case rowRepoSummary:
				if m.expanded[row.repoName] {
					m.expanded[row.repoName] = false
					m.buildRows()
				}
			case rowRepoDetail:
				// Collapse the parent repo.
				if row.repoName != "" && m.expanded[row.repoName] {
					m.expanded[row.repoName] = false
					m.buildRows()
				}
			}
		}
	case "right", "l":
		// Expand: if on group header, expand group; if on repo, expand detail.
		if m.cursor >= 0 && m.cursor < len(m.rows) {
			row := m.rows[m.cursor]
			switch row.kind {
			case rowGroupHeader:
				if m.collapsed[row.groupIdx] {
					m.collapsed[row.groupIdx] = false
					m.buildRows()
				}
			case rowRepoSummary:
				if !m.expanded[row.repoName] {
					m.expanded[row.repoName] = true
					m.buildRows()
				}
			}
		}
	case "o":
		// Open config URL for current row.
		if m.cursor >= 0 && m.cursor < len(m.rows) {
			if u := m.rows[m.cursor].url; u != "" {
				openBrowser(u)
			}
		}
	case "e":
		// Expand all groups.
		for gi := range m.groups {
			m.collapsed[gi] = false
		}
		m.buildRows()
	case "c":
		// Collapse all groups.
		for gi := range m.groups {
			m.collapsed[gi] = true
		}
		m.buildRows()
	}

	m.clampCursor()
	return nil
}

func (m *auditModel) clampCursor() {
	m.cursor, m.scrollOff = clampScroll(m.cursor, m.scrollOff, len(m.rows))
}

// CursorRepo returns the repo name at the cursor, or "".
func (m auditModel) CursorRepo() string {
	if m.cursor >= 0 && m.cursor < len(m.rows) {
		return m.rows[m.cursor].repoName
	}
	return ""
}

// ClickedMButton checks if a click at the given body-relative row and column
// hit the [m] button prefix. Returns the repo name if so, or "".
func (m auditModel) ClickedMButton(bodyRow, col int) string {
	idx := m.scrollOff + bodyRow
	if idx < 0 || idx >= len(m.rows) {
		return ""
	}
	row := m.rows[idx]
	if row.kind != rowRepoSummary || row.btnCol < 0 {
		return ""
	}
	// [m] is at columns btnCol..btnCol+3 (i.e. "[m] ")
	if col >= row.btnCol && col < row.btnCol+4 {
		return row.repoName
	}
	return ""
}

// CursorOnGroup returns true if the cursor is on a group header.
func (m auditModel) CursorOnGroup() bool {
	if m.cursor >= 0 && m.cursor < len(m.rows) {
		return m.rows[m.cursor].kind == rowGroupHeader
	}
	return false
}
