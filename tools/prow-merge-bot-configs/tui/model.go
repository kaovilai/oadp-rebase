package main

import (
	"fmt"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/bubbles/spinner"
	"github.com/charmbracelet/lipgloss"
)

const doubleClickThreshold = 400 * time.Millisecond

type model struct {
	width, height int
	activeTab     int // 0=audit, 1=queue, 2=compare, 3=tide

	report  *AuditReport
	configs map[string]*RepoConfig
	loading bool
	err     error

	auditTab   auditModel
	queueTab   queueModel
	compareTab compareModel
	tideTab    tideModel

	help    helpModel
	spinner spinner.Model

	branch      string
	localPath   string
	token       string
	skipQueue   bool
	ghAvailable bool

	// Tab bar click zones: tabZones[i] = {startCol, endCol} for tab i.
	tabZones [4][2]int

	// Double-click tracking.
	lastClickTime time.Time
	lastClickRow  int
	lastClickRepo string
}

// Message types.
type auditDoneMsg struct {
	report  *AuditReport
	configs map[string]*RepoConfig
}

type queueDoneMsg struct {
	repo   string
	report *MergeQueueReport
}

type errMsg struct {
	err error
}

var tabNames = []string{"Config Audit", "Merge Queue", "Field Compare", "Tide Branches"}

func newModel(branch, localPath, token string, skipQueue, ghAvailable bool) model {
	s := spinner.New()
	s.Spinner = spinner.Dot

	_, zones := renderTabBar(0, 200)
	return model{
		spinner:     s,
		loading:     true,
		branch:      branch,
		localPath:   localPath,
		token:       token,
		skipQueue:   skipQueue,
		ghAvailable: ghAvailable,
		queueTab:    newQueueModel(),
		help:        helpModel{},
		tabZones:  zones,
	}
}

func (m model) Init() tea.Cmd {
	return tea.Batch(
		m.spinner.Tick,
		runAuditCmd(m.branch, m.localPath, m.token),
	)
}

func runAuditCmd(branch, localPath, token string) tea.Cmd {
	return func() tea.Msg {
		report, configs, err := RunAudit(branch, localPath, token)
		if err != nil {
			return errMsg{err: err}
		}
		return auditDoneMsg{report: report, configs: configs}
	}
}

// queueConfigFromAudit builds a QueueConfig from audit report data.
func queueConfigFromAudit(report *AuditReport, repoName string) *QueueConfig {
	if report == nil {
		return &QueueConfig{}
	}
	for _, g := range report.Groups {
		for _, r := range g.Repos {
			if r.Name == repoName {
				qc := &QueueConfig{}
				if v, ok := r.Fields["required_approving_review_count"]; ok && v != "NOT_SET" {
					fmt.Sscanf(v, "%d", &qc.RequiredReviews)
				}
				if v, ok := r.Fields["enforce_admins"]; ok && v == "true" {
					qc.EnforceAdmins = true
				}
				return qc
			}
		}
	}
	return &QueueConfig{}
}

func runQueueCmd(repo string, qc *QueueConfig) tea.Cmd {
	return func() tea.Msg {
		report, err := CheckMergeQueue(repo, qc)
		if err != nil {
			return errMsg{err: err}
		}
		return queueDoneMsg{repo: repo, report: report}
	}
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		// Recompute tab click zones on resize.
		_, m.tabZones = renderTabBar(m.activeTab, m.width)
		return m, nil

	case tea.MouseMsg:
		if m.help.visible {
			return m, nil
		}
		if msg.Action != tea.MouseActionPress {
			return m, nil
		}

		row := msg.Y
		col := msg.X

		switch {
		// Row 0 = header, Row 1 = tab bar.
		case row == 1 && msg.Button == tea.MouseButtonLeft:
			for i, zone := range m.tabZones {
				if col >= zone[0] && col < zone[1] {
					m.activeTab = i
					return m, nil
				}
			}

		// Body area clicks (row >= 2, before footer).
		case row >= 2 && row < m.height-1 && msg.Button == tea.MouseButtonLeft:
			bodyRow := row - 2 // offset for header + tab bar
			now := time.Now()

			// Check globe 🌐 click first — opens browser immediately.
			{
				var globeURL string
				var globeTextWidth int
				switch m.activeTab {
				case 0:
					idx := m.auditTab.scrollOff + bodyRow
					if idx >= 0 && idx < len(m.auditTab.rows) && m.auditTab.rows[idx].url != "" {
						globeURL = m.auditTab.rows[idx].url
						globeTextWidth = lipgloss.Width(m.auditTab.rows[idx].text)
					}
				case 1:
					idx := m.queueTab.scrollOff + bodyRow - 1
					if idx >= 0 && idx < len(m.queueTab.rows) && m.queueTab.rows[idx].url != "" {
						globeURL = m.queueTab.rows[idx].url
						globeTextWidth = lipgloss.Width(m.queueTab.rows[idx].text)
					}
				case 3:
					idx := m.tideTab.scrollOff + bodyRow
					if idx >= 0 && idx < len(m.tideTab.rows) && m.tideTab.rows[idx].url != "" {
						globeURL = m.tideTab.rows[idx].url
						globeTextWidth = lipgloss.Width(m.tideTab.rows[idx].text)
					}
				}
				// Globe 🌐 is at columns [textWidth+1, textWidth+3) — space + 2-wide emoji.
				if globeURL != "" && col >= globeTextWidth+1 && col <= globeTextWidth+3 {
					openBrowser(globeURL)
					return m, nil
				}
			}

			// Check [m] button click in audit tab.
			if m.activeTab == 0 && m.report != nil {
				if btnRepo := m.auditTab.ClickedMButton(bodyRow, col); btnRepo != "" {
					rc := queueConfigFromAudit(m.report, btnRepo)
					m.queueTab.loading[btnRepo] = true
					m.activeTab = 1
					return m, runQueueCmd(btnRepo, rc)
				}
			}

			// Resolve clicked row info based on active tab.
			clickedRepo := ""
			clickedURL := ""
			switch m.activeTab {
			case 0:
				targetIdx := m.auditTab.scrollOff + bodyRow
				if targetIdx >= 0 && targetIdx < len(m.auditTab.rows) {
					m.auditTab.cursor = targetIdx
					m.auditTab.clampCursor()
					row := m.auditTab.rows[targetIdx]
					clickedRepo = row.repoName
					clickedURL = row.url
					// Click on group header toggles collapse.
					if row.kind == rowGroupHeader {
						m.auditTab.collapsed[row.groupIdx] = !m.auditTab.collapsed[row.groupIdx]
						m.auditTab.buildRows()
						m.auditTab.clampCursor()
						return m, nil
					}
					// Click on repo summary toggles detail expand.
					if row.kind == rowRepoSummary {
						m.auditTab.expanded[row.repoName] = !m.auditTab.expanded[row.repoName]
						m.auditTab.buildRows()
						m.auditTab.clampCursor()
						return m, nil
					}
				}
			case 1:
				targetIdx := m.queueTab.scrollOff + bodyRow - 1 // -1 for sort mode indicator line
				if targetIdx >= 0 && targetIdx < len(m.queueTab.rows) {
					m.queueTab.cursor = targetIdx
					m.queueTab.clampCursor()
					qRow := m.queueTab.rows[targetIdx]
					clickedRepo = qRow.repoName
					clickedURL = qRow.url
					// Click on action button triggers check-all.
					if qRow.kind == rowAction && m.report != nil {
						var cmds []tea.Cmd
						for _, g := range m.report.Groups {
							for _, r := range g.Repos {
								rc := queueConfigFromAudit(m.report, r.Name)
								m.queueTab.loading[r.Name] = true
								cmds = append(cmds, runQueueCmd(r.Name, rc))
							}
						}
						return m, tea.Batch(cmds...)
					}
					// Click on [m] prefix of repo header → check that repo.
					if qRow.kind == rowGroupHeader && qRow.repoName != "" && col < 4 && m.report != nil {
						rc := queueConfigFromAudit(m.report, qRow.repoName)
						m.queueTab.loading[qRow.repoName] = true
						m.queueTab.buildRows()
						return m, runQueueCmd(qRow.repoName, rc)
					}
					// Click elsewhere on repo header toggles collapse.
					if qRow.kind == rowGroupHeader && qRow.repoName != "" {
						m.queueTab.collapsed[qRow.repoName] = !m.queueTab.collapsed[qRow.repoName]
						m.queueTab.buildRows()
						m.queueTab.clampCursor()
						return m, nil
					}
					// Click on PR summary toggles PR detail collapse.
					if qRow.kind == rowRepoSummary && qRow.prKey != "" {
						m.queueTab.prCollapsed[qRow.prKey] = !m.queueTab.prCollapsed[qRow.prKey]
						m.queueTab.buildRows()
						m.queueTab.clampCursor()
						return m, nil
					}
				}
			case 2:
				targetIdx := m.compareTab.scrollOff + bodyRow - 1 // -1 for mode indicator line
				if targetIdx >= 0 && targetIdx < len(m.compareTab.rows) {
					m.compareTab.cursor = targetIdx
					m.compareTab.clampCursor()
				}
			case 3:
				targetIdx := m.tideTab.scrollOff + bodyRow
				if targetIdx >= 0 && targetIdx < len(m.tideTab.rows) {
					m.tideTab.cursor = targetIdx
					clickedURL = m.tideTab.rows[targetIdx].url
					m.tideTab.clampCursor()
				}
			}

			// Double-click detection.
			isDoubleClick := row == m.lastClickRow &&
				now.Sub(m.lastClickTime) < doubleClickThreshold

			if isDoubleClick {
				m.lastClickRepo = ""
				m.lastClickTime = time.Time{}

				// If the row has a URL, open it in browser.
				if clickedURL != "" {
					openBrowser(clickedURL)
					return m, nil
				}

				// Otherwise refresh the repo (audit tab behavior).
				if clickedRepo != "" {
					ClearConfigCache(clickedRepo)
					m.loading = true
					return m, runAuditCmd(m.branch, m.localPath, m.token)
				}
				return m, nil
			}

			m.lastClickTime = now
			m.lastClickRow = row
			m.lastClickRepo = clickedRepo
			return m, nil

		// Scroll wheel.
		case msg.Button == tea.MouseButtonWheelUp:
			switch m.activeTab {
			case 0:
				m.auditTab.cursor--
				m.auditTab.clampCursor()
			case 1:
				m.queueTab.cursor--
				m.queueTab.clampCursor()
			case 2:
				m.compareTab.cursor--
				m.compareTab.clampCursor()
			case 3:
				m.tideTab.cursor--
				m.tideTab.clampCursor()
			}
			return m, nil

		case msg.Button == tea.MouseButtonWheelDown:
			switch m.activeTab {
			case 0:
				m.auditTab.cursor++
				m.auditTab.clampCursor()
			case 1:
				m.queueTab.cursor++
				m.queueTab.clampCursor()
			case 2:
				m.compareTab.cursor++
				m.compareTab.clampCursor()
			case 3:
				m.tideTab.cursor++
				m.tideTab.clampCursor()
			}
			return m, nil
		}

		return m, nil

	case tea.KeyMsg:
		// Handle help overlay first.
		if m.help.visible {
			switch msg.String() {
			case "?", "esc":
				m.help.visible = false
			}
			return m, nil
		}

		switch msg.String() {
		case "q", "ctrl+c":
			return m, tea.Quit
		case "?":
			m.help.visible = true
			return m, nil
		case "esc":
			// Close help if visible (already handled above).
			return m, nil
		case "r":
			m.loading = true
			ClearConfigCache("")
			return m, runAuditCmd(m.branch, m.localPath, m.token)
		case "1":
			m.activeTab = 0
			return m, nil
		case "2":
			m.activeTab = 1
			return m, nil
		case "3":
			m.activeTab = 2
			return m, nil
		case "4":
			m.activeTab = 3
			return m, nil
		case "tab", "shift+right":
			m.activeTab = (m.activeTab + 1) % 4
			return m, nil
		case "shift+tab", "shift+left":
			m.activeTab = (m.activeTab + 3) % 4
			return m, nil
		case "m":
			if !m.ghAvailable {
				m.err = fmt.Errorf("merge queue requires gh CLI — install from https://cli.github.com/")
				return m, nil
			}
			if m.report != nil {
				var repo string
				if m.activeTab == 0 {
					repo = m.auditTab.CursorRepo()
				} else if m.activeTab == 1 {
					if m.queueTab.cursor >= 0 && m.queueTab.cursor < len(m.queueTab.rows) {
						repo = m.queueTab.rows[m.queueTab.cursor].repoName
					}
				}
				if repo != "" {
					m.err = nil // clear any previous error
					rc := queueConfigFromAudit(m.report, repo)
					m.queueTab.loading[repo] = true
					m.activeTab = 1
					return m, runQueueCmd(repo, rc)
				}
			}
		case "M":
			if !m.ghAvailable {
				m.err = fmt.Errorf("check-all requires gh CLI — install from https://cli.github.com/")
				return m, nil
			}
			if m.token == "" {
				m.err = fmt.Errorf("check-all requires authentication — run 'gh auth login' or set GITHUB_TOKEN (use 'm' for single repo)")
				return m, nil
			}
			if m.report != nil {
				var cmds []tea.Cmd
				for _, g := range m.report.Groups {
					for _, r := range g.Repos {
						rc := queueConfigFromAudit(m.report, r.Name)
						m.queueTab.loading[r.Name] = true
						cmds = append(cmds, runQueueCmd(r.Name, rc))
					}
				}
				m.activeTab = 1
				return m, tea.Batch(cmds...)
			}
		default:
			// Intercept Enter on queue tab action rows.
			if m.activeTab == 1 && (msg.String() == "enter" || msg.String() == " ") {
				if m.queueTab.cursor >= 0 && m.queueTab.cursor < len(m.queueTab.rows) {
					row := m.queueTab.rows[m.queueTab.cursor]
					if row.kind == rowAction && m.report != nil {
						// "Check All" action.
						var cmds []tea.Cmd
						for _, g := range m.report.Groups {
							for _, r := range g.Repos {
								rc := queueConfigFromAudit(m.report, r.Name)
								m.queueTab.loading[r.Name] = true
								cmds = append(cmds, runQueueCmd(r.Name, rc))
							}
						}
						return m, tea.Batch(cmds...)
					}
				}
			}

			// Delegate to active tab.
			var cmd tea.Cmd
			switch m.activeTab {
			case 0:
				cmd = m.auditTab.Update(msg)
			case 1:
				cmd = m.queueTab.Update(msg)
			case 2:
				cmd = m.compareTab.Update(msg)
			case 3:
				cmd = m.tideTab.Update(msg)
			}
			return m, cmd
		}

	case auditDoneMsg:
		m.report = msg.report
		m.configs = msg.configs
		m.loading = false
		m.err = nil
		if m.report != nil {
			m.auditTab = newAuditModel(m.report.Groups, m.configs)
			m.compareTab = newCompareModel(m.report)
			m.tideTab = newTideModel(m.report.Groups)
			// Populate queue tab's repo list.
			var allRepos []string
			for _, g := range m.report.Groups {
				for _, r := range g.Repos {
					allRepos = append(allRepos, r.Name)
				}
			}
			m.queueTab.allRepos = allRepos
			m.queueTab.ghAvailable = m.ghAvailable
			m.queueTab.buildRows()
		}
		return m, nil

	case queueDoneMsg:
		m.queueTab.SetQueue(msg.repo, msg.report)
		// Re-fetch rate limit after queue check (gh CLI uses API quota).
		if rl := fetchRateLimit(); rl != nil && m.report != nil {
			m.report.RateLimit = rl
		}
		return m, nil

	case errMsg:
		m.err = msg.err
		m.loading = false
		return m, nil

	case spinner.TickMsg:
		if m.loading || len(m.queueTab.loading) > 0 {
			var cmd tea.Cmd
			m.spinner, cmd = m.spinner.Update(msg)
			return m, cmd
		}
		return m, nil
	}

	return m, nil
}

func (m model) View() string {
	if m.width == 0 {
		return ""
	}

	// Full-screen loading state before any data.
	if m.loading && m.report == nil {
		loadingMsg := fmt.Sprintf("Loading... %s", m.spinner.View())
		return lipgloss.Place(m.width, m.height, lipgloss.Center, lipgloss.Center, loadingMsg)
	}

	// Compose layout: header + tab bar + body + footer.
	header := renderHeaderWithQueue(m.width, m.report, m.loading, m.spinner.View(), m.queueTab.loading)
	tabs, _ := renderTabBar(m.activeTab, m.width)

	cursorRepo := ""
	onHeader := false
	if m.activeTab == 0 {
		cursorRepo = m.auditTab.CursorRepo()
		onHeader = m.auditTab.CursorOnGroup()
	}
	footer := renderFooter(m.width, m.activeTab, onHeader, false, cursorRepo)

	// Body height: total - header(1) - tabs(1) - footer(1).
	bodyHeight := m.height - 3
	if bodyHeight < 1 {
		bodyHeight = 1
	}

	var body string
	switch m.activeTab {
	case 0:
		body = m.auditTab.View(m.width, bodyHeight)
	case 1:
		body = m.queueTab.View(m.width, bodyHeight)
	case 2:
		body = m.compareTab.View(m.width, bodyHeight)
	case 3:
		body = m.tideTab.View(m.width, bodyHeight)
	}

	// Ensure body fills the height.
	bodyLines := strings.Count(body, "\n") + 1
	for bodyLines < bodyHeight {
		body += "\n"
		bodyLines++
	}

	// Error display.
	if m.err != nil {
		errLine := RowIssueStyle.Render(fmt.Sprintf("Error: %v", m.err))
		body = errLine + "\n" + body
	}

	screen := lipgloss.JoinVertical(lipgloss.Left, header, tabs, body, footer)

	// Help overlay.
	if m.help.visible {
		screen = m.help.View(m.width, m.height)
	}

	return screen
}

func renderTabBar(activeTab, width int) (string, [4][2]int) {
	var zones [4][2]int
	var parts []string
	col := 0
	for i, name := range tabNames {
		label := fmt.Sprintf("[%d] %s", i+1, name)
		plainWidth := lipgloss.Width(label)
		zones[i] = [2]int{col, col + plainWidth}
		if i == activeTab {
			parts = append(parts, TabActiveStyle.Render(label))
		} else {
			parts = append(parts, TabInactiveStyle.Render(label))
		}
		col += plainWidth + 2 // +2 for "  " separator
	}

	bar := strings.Join(parts, "  ")

	barWidth := lipgloss.Width(bar)
	if barWidth < width {
		bar += strings.Repeat(" ", width-barWidth)
	}

	return bar, zones
}
