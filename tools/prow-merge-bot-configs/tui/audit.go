package main

import (
	"encoding/json"
	"fmt"
	"os/exec"
	"time"
)

// AuditRepo audits a single repository's prow configuration.
// repoType is one of: upstream-rebase, oadp-owned-openshift, oadp-owned-migtools.
func AuditRepo(rc *RepoConfig, repoType string) *RepoAudit {
	audit := &RepoAudit{
		Name:      rc.Repo,
		HasConfig: rc.HasConfig,
	}

	if !rc.HasConfig {
		audit.Findings = []Finding{
			{Severity: SeverityIssue, Field: "config", Message: "No prow config found"},
		}
		return audit
	}

	fields, plugins, tide := ExtractFields(rc)
	audit.Fields = fields
	audit.Plugins = plugins
	audit.Tide = tide

	// --- Plugin config checks ---

	if !plugins.HasApproveSection {
		audit.Findings = append(audit.Findings, Finding{
			Severity: SeverityIssue,
			Field:    "approve_section",
			Message:  "Missing top-level 'approve:' config section in _pluginconfig.yaml",
		})
	}

	if !plugins.HasLgtmSection {
		audit.Findings = append(audit.Findings, Finding{
			Severity: SeverityIssue,
			Field:    "lgtm_section",
			Message:  "Missing top-level 'lgtm:' config section in _pluginconfig.yaml",
		})
	}

	if !plugins.HasApprovePlugin {
		audit.Findings = append(audit.Findings, Finding{
			Severity: SeverityIssue,
			Field:    "approve_plugin",
			Message:  "'approve' not listed in plugins",
		})
	}

	// require_self_approval
	selfApproval := fields["require_self_approval"]
	if selfApproval == "MISSING_FILE" {
		audit.Findings = append(audit.Findings, Finding{
			Severity: SeverityIssue,
			Field:    "require_self_approval",
			Message:  "_pluginconfig.yaml not found",
		})
	} else if selfApproval == "NOT_SET" {
		audit.Findings = append(audit.Findings, Finding{
			Severity: SeverityWarning,
			Field:    "require_self_approval",
			Message:  "require_self_approval not explicitly set (defaults vary)",
		})
	} else if selfApproval != "false" {
		audit.Findings = append(audit.Findings, Finding{
			Severity: SeverityInfo,
			Field:    "require_self_approval",
			Message:  fmt.Sprintf("require_self_approval=%s (most OADP repos use false)", selfApproval),
		})
	}

	// review_acts_as_lgtm
	if fields["review_acts_as_lgtm"] == "true" {
		audit.Findings = append(audit.Findings, Finding{
			Severity: SeverityInfo,
			Field:    "review_acts_as_lgtm",
			Message:  "review_acts_as_lgtm=true (GitHub Approve review counts as /lgtm)",
		})
	}

	// --- Branch protection checks ---

	forcePush := fields["allow_force_pushes"]
	enforce := fields["enforce_admins"]
	reviewCount := fields["required_approving_review_count"]
	dismissStale := fields["dismiss_stale_reviews"]

	switch repoType {
	case "upstream-rebase":
		if forcePush != "true" {
			audit.Findings = append(audit.Findings, Finding{
				Severity: SeverityWarning,
				Field:    "allow_force_pushes",
				Message:  "missing allow_force_pushes=true (needed for rebasebot)",
			})
		} else {
			audit.Findings = append(audit.Findings, Finding{
				Severity: SeverityOK,
				Field:    "allow_force_pushes",
				Message:  "allow_force_pushes=true (expected for upstream rebase repo)",
			})
		}
		if enforce == "true" {
			audit.Findings = append(audit.Findings, Finding{
				Severity: SeverityInfo,
				Field:    "enforce_admins",
				Message:  "enforce_admins=true on upstream rebase repo (unusual)",
			})
		}
		if reviewCount != "NOT_SET" {
			audit.Findings = append(audit.Findings, Finding{
				Severity: SeverityInfo,
				Field:    "review_count",
				Message:  fmt.Sprintf("required_approving_review_count=%s on upstream rebase repo", reviewCount),
			})
		}

	case "oadp-owned-openshift", "oadp-owned-migtools":
		if enforce != "true" {
			audit.Findings = append(audit.Findings, Finding{
				Severity: SeverityWarning,
				Field:    "enforce_admins",
				Message:  "Missing enforce_admins=true — Tide bypasses review count (tideErrLoopBlocker, prow#134)",
			})
		}
		if reviewCount == "NOT_SET" {
			audit.Findings = append(audit.Findings, Finding{
				Severity: SeverityWarning,
				Field:    "review_count",
				Message:  "Missing required_approving_review_count",
			})
		} else if reviewCount != "2" {
			audit.Findings = append(audit.Findings, Finding{
				Severity: SeverityInfo,
				Field:    "review_count",
				Message:  fmt.Sprintf("required_approving_review_count=%s (most use 2)", reviewCount),
			})
		}
		if dismissStale != "true" {
			audit.Findings = append(audit.Findings, Finding{
				Severity: SeverityWarning,
				Field:    "dismiss_stale_reviews",
				Message:  "Missing dismiss_stale_reviews=true",
			})
		}
		if forcePush == "true" {
			audit.Findings = append(audit.Findings, Finding{
				Severity: SeverityWarning,
				Field:    "allow_force_pushes",
				Message:  "allow_force_pushes=true on OADP-owned repo (unexpected)",
			})
		}
	}

	// --- Merge method ---
	mergeMethod := fields["merge_method"]
	if mergeMethod != "NOT_SET" && mergeMethod != "" {
		audit.Findings = append(audit.Findings, Finding{
			Severity: SeverityInfo,
			Field:    "merge_method",
			Message:  fmt.Sprintf("merge_method=%s", mergeMethod),
		})
	}

	// --- keep-main-query-separate ---
	if tide.HasKeepMainQuerySeparate {
		audit.Findings = append(audit.Findings, Finding{
			Severity: SeverityInfo,
			Field:    "keep_main_query_separate",
			Message:  "Uses keep-main-query-separate label in Tide missingLabels",
		})
	}

	// --- Tide required labels ---
	expectedRequired := []string{"approved", "lgtm"}
	for _, label := range expectedRequired {
		found := false
		for _, l := range tide.RequiredLabels {
			if l == label {
				found = true
				break
			}
		}
		if !found && len(tide.IncludedBranches) > 0 {
			audit.Findings = append(audit.Findings, Finding{
				Severity: SeverityWarning,
				Field:    "tide_labels",
				Message:  fmt.Sprintf("Tide query missing required label: %s", label),
			})
		}
	}

	// --- Tide missing/blocker labels ---
	expectedMissing := []string{
		"do-not-merge/hold",
		"do-not-merge/work-in-progress",
		"do-not-merge/invalid-owners-file",
		"needs-rebase",
		"jira/invalid-bug",
		"backports/unvalidated-commits",
	}
	for _, label := range expectedMissing {
		found := false
		for _, l := range tide.MissingLabels {
			if l == label {
				found = true
				break
			}
		}
		if !found && len(tide.IncludedBranches) > 0 {
			audit.Findings = append(audit.Findings, Finding{
				Severity: SeverityWarning,
				Field:    "tide_missing_labels",
				Message:  fmt.Sprintf("Tide query missing blocker label: %s", label),
			})
		}
	}

	return audit
}

// CompareField compares a single field across repos and returns the comparison
// result. Returns nil if all repos are consistent (no outliers).
func CompareField(fieldName string, configs map[string]*RepoConfig, repos []string) *FieldComparison {
	type repoValue struct {
		repo  string
		value string
	}

	var pairs []repoValue
	for _, repo := range repos {
		rc, ok := configs[repo]
		if !ok || !rc.HasConfig {
			continue
		}
		fields, _, _ := ExtractFields(rc)
		val, exists := fields[fieldName]
		if !exists {
			val = "NOT_SET"
		}
		pairs = append(pairs, repoValue{repo: repo, value: val})
	}

	if len(pairs) == 0 {
		return nil
	}

	// Count occurrences of each value.
	counts := make(map[string]int)
	for _, p := range pairs {
		counts[p.value]++
	}

	// Find the majority value (highest count).
	var majority string
	maxCount := 0
	for val, count := range counts {
		if count > maxCount {
			maxCount = count
			majority = val
		}
	}

	// Collect outliers.
	var outliers []Outlier
	for _, p := range pairs {
		if p.value != majority {
			outliers = append(outliers, Outlier{Repo: p.repo, Value: p.value})
		}
	}

	if len(outliers) == 0 {
		return nil
	}

	return &FieldComparison{
		Majority: majority,
		Outliers: outliers,
	}
}

// fieldsForGroupType returns the fields to compare for a given group type.
func fieldsForGroupType(groupType string) []string {
	switch groupType {
	case "upstream-rebase":
		return []string{
			"require_self_approval",
			"review_acts_as_lgtm",
			"allow_force_pushes",
			"merge_method",
		}
	case "oadp-owned-openshift", "oadp-owned-migtools":
		return []string{
			"require_self_approval",
			"review_acts_as_lgtm",
			"enforce_admins",
			"required_approving_review_count",
			"dismiss_stale_reviews",
			"allow_force_pushes",
			"merge_method",
		}
	default:
		return nil
	}
}

// RunAudit runs the full audit across all repo groups and returns a report.
func RunAudit(branch, localPath, token string) (*AuditReport, map[string]*RepoConfig, error) {
	// Determine source label.
	var source string
	if localPath != "" {
		source = localPath + " (local checkout)"
	} else {
		source = fmt.Sprintf("github.com/openshift/release @ %s", branch)
	}

	groups := DefaultGroups()

	// Collect all repos from all groups.
	var allRepos []string
	for _, g := range groups {
		allRepos = append(allRepos, g.Repos...)
	}

	// Fetch all configs concurrently.
	configs := FetchAllConfigs(allRepos, branch, localPath, token)

	// Audit each group.
	var reportGroups []RepoGroup
	for _, g := range groups {
		rg := RepoGroup{
			Name:        g.Name,
			Type:        g.Type,
			Description: g.Description,
		}
		for _, repo := range g.Repos {
			rc, ok := configs[repo]
			if !ok {
				rc = &RepoConfig{Repo: repo, HasConfig: false}
			}
			ra := AuditRepo(rc, g.Type)
			rg.Repos = append(rg.Repos, *ra)
		}
		reportGroups = append(reportGroups, rg)
	}

	// Run cross-repo comparison for each group.
	comparison := make(map[string]map[string]FieldComparison)
	for _, g := range groups {
		compareFields := fieldsForGroupType(g.Type)
		if len(compareFields) == 0 {
			continue
		}
		groupComparisons := make(map[string]FieldComparison)
		for _, fieldName := range compareFields {
			fc := CompareField(fieldName, configs, g.Repos)
			if fc != nil {
				groupComparisons[fieldName] = *fc
			}
		}
		if len(groupComparisons) > 0 {
			comparison[g.Type] = groupComparisons
		}
	}

	// Compute summary.
	var summary Summary
	for _, rg := range reportGroups {
		for _, ra := range rg.Repos {
			issues, warnings, infos := ra.CountBySeverity()
			summary.Issues += issues
			summary.Warnings += warnings
			summary.Info += infos
		}
	}

	// Fetch rate limit after all API calls are done so it reflects current usage.
	rateLimit := fetchRateLimit()

	return &AuditReport{
		Source:     source,
		Timestamp:  time.Now().UTC(),
		RateLimit:  rateLimit,
		Groups:     reportGroups,
		Comparison: comparison,
		Summary:    summary,
	}, configs, nil
}

// fetchRateLimit calls `gh api rate_limit` and parses the response.
func fetchRateLimit() *RateLimit {
	if _, err := exec.LookPath("gh"); err != nil {
		return nil
	}
	out, err := exec.Command("gh", "api", "rate_limit").Output()
	if err != nil {
		return nil
	}
	var resp struct {
		Resources struct {
			Core struct {
				Remaining int   `json:"remaining"`
				Limit     int   `json:"limit"`
				Reset     int64 `json:"reset"`
			} `json:"core"`
		} `json:"resources"`
	}
	if err := json.Unmarshal(out, &resp); err != nil {
		return nil
	}
	return &RateLimit{
		Remaining: resp.Resources.Core.Remaining,
		Limit:     resp.Resources.Core.Limit,
		ResetAt:   time.Unix(resp.Resources.Core.Reset, 0).UTC(),
	}
}
