package main

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"gopkg.in/yaml.v3"
)

// RepoConfig holds the raw parsed YAML config files for a repository.
type RepoConfig struct {
	Repo            string
	HasConfig       bool
	PluginConfig    map[string]interface{} // raw parsed _pluginconfig.yaml
	ProwConfig      map[string]interface{} // raw parsed _prowconfig.yaml
	PluginConfigRaw []byte                 // raw bytes for line number lookup
	ProwConfigRaw   []byte                 // raw bytes for line number lookup
}

// configCache caches fetched configs to avoid re-fetching on refresh.
var configCache struct {
	sync.Mutex
	data map[string]*RepoConfig
}


// ClearConfigCache clears cached configs for a specific repo, or all if repo is empty.
func ClearConfigCache(repo string) {
	configCache.Lock()
	defer configCache.Unlock()
	if repo == "" {
		configCache.data = nil
	} else if configCache.data != nil {
		delete(configCache.data, repo)
	}
}

// FetchAllConfigs fetches _pluginconfig.yaml and _prowconfig.yaml for all repos
// concurrently (up to 10 goroutines). Returns a map of repo name to config.
// Results are cached; use ClearConfigCache to force re-fetch.
func FetchAllConfigs(repos []string, branch, localPath, token string) map[string]*RepoConfig {
	configCache.Lock()
	if configCache.data == nil {
		configCache.data = make(map[string]*RepoConfig)
	}
	configCache.Unlock()

	results := make(map[string]*RepoConfig, len(repos))
	var mu sync.Mutex

	sem := make(chan struct{}, 10)
	var wg sync.WaitGroup

	for _, repo := range repos {
		// Return cached config if available.
		configCache.Lock()
		if cached, ok := configCache.data[repo]; ok {
			configCache.Unlock()
			mu.Lock()
			results[repo] = cached
			mu.Unlock()
			continue
		}
		configCache.Unlock()

		wg.Add(1)
		go func(repo string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()

			rc := fetchRepoConfig(repo, branch, localPath, token)

			configCache.Lock()
			configCache.data[repo] = rc
			configCache.Unlock()

			mu.Lock()
			results[repo] = rc
			mu.Unlock()
		}(repo)
	}

	wg.Wait()
	return results
}

// fetchRepoConfig fetches both config files for a single repo.
func fetchRepoConfig(repo, branch, localPath, token string) *RepoConfig {
	parts := strings.SplitN(repo, "/", 2)
	if len(parts) != 2 {
		return &RepoConfig{Repo: repo}
	}
	org, repoName := parts[0], parts[1]

	rc := &RepoConfig{Repo: repo}

	pluginData := fetchSingleFile(org, repoName, "_pluginconfig.yaml", branch, localPath, token)
	prowData := fetchSingleFile(org, repoName, "_prowconfig.yaml", branch, localPath, token)

	if pluginData != nil {
		rc.PluginConfigRaw = pluginData
		var parsed map[string]interface{}
		if err := yaml.Unmarshal(pluginData, &parsed); err == nil {
			rc.PluginConfig = parsed
		}
	}

	if prowData != nil {
		rc.ProwConfigRaw = prowData
		var parsed map[string]interface{}
		if err := yaml.Unmarshal(prowData, &parsed); err == nil {
			rc.ProwConfig = parsed
		}
	}

	rc.HasConfig = rc.PluginConfig != nil || rc.ProwConfig != nil
	return rc
}

// fetchSingleFile fetches a single file either from a local path or from GitHub.
// Returns nil if the file doesn't exist or can't be read.
func fetchSingleFile(org, repo, filename, branch, localPath, token string) []byte {
	if localPath != "" {
		return fetchFromLocal(org, repo, filename, localPath)
	}
	return fetchFromGitHub(org, repo, filename, branch, token)
}

// fetchFromLocal reads a config file from a local openshift/release checkout.
func fetchFromLocal(org, repo, filename, localPath string) []byte {
	p := filepath.Join(localPath, "core-services", "prow", "02_config", org, repo, filename)
	data, err := os.ReadFile(p)
	if err != nil {
		return nil
	}
	return data
}

// fetchFromGitHub fetches a config file from raw.githubusercontent.com.
func fetchFromGitHub(org, repo, filename, branch, token string) []byte {
	url := fmt.Sprintf(
		"https://raw.githubusercontent.com/openshift/release/%s/core-services/prow/02_config/%s/%s/%s",
		branch, org, repo, filename,
	)

	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil
	}
	if token != "" {
		req.Header.Set("Authorization", "token "+token)
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil
	}

	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil
	}
	return data
}

// yamlGet safely navigates a nested map[string]interface{} by following the
// given sequence of keys. Returns the value and true if the full path exists,
// or nil and false otherwise.
func yamlGet(data map[string]interface{}, keys ...string) (interface{}, bool) {
	if data == nil {
		return nil, false
	}
	var current interface{} = data
	for _, key := range keys {
		m, ok := current.(map[string]interface{})
		if !ok {
			return nil, false
		}
		current, ok = m[key]
		if !ok {
			return nil, false
		}
	}
	return current, true
}

// --- Field extractor functions ---
//
// Each extractor returns a string value. Convention:
//   - "MISSING_FILE" if the relevant YAML file was not loaded
//   - "NOT_SET"      if the file exists but the field is absent
//   - otherwise      the string representation of the value

// getRequireSelfApproval extracts require_self_approval from the approve
// section of _pluginconfig.yaml.
func getRequireSelfApproval(rc *RepoConfig) string {
	if rc.PluginConfig == nil {
		return "MISSING_FILE"
	}
	approveList, ok := rc.PluginConfig["approve"]
	if !ok {
		return "NOT_SET"
	}
	items, ok := approveList.([]interface{})
	if !ok || len(items) == 0 {
		return "NOT_SET"
	}
	for _, item := range items {
		m, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		if val, exists := m["require_self_approval"]; exists {
			return fmt.Sprintf("%v", val)
		}
	}
	return "NOT_SET"
}

// getReviewActsAsLgtm extracts review_acts_as_lgtm from the lgtm section
// of _pluginconfig.yaml.
func getReviewActsAsLgtm(rc *RepoConfig) string {
	if rc.PluginConfig == nil {
		return "MISSING_FILE"
	}
	lgtmList, ok := rc.PluginConfig["lgtm"]
	if !ok {
		return "NOT_SET"
	}
	items, ok := lgtmList.([]interface{})
	if !ok || len(items) == 0 {
		return "NOT_SET"
	}
	for _, item := range items {
		m, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		if val, exists := m["review_acts_as_lgtm"]; exists {
			return fmt.Sprintf("%v", val)
		}
	}
	return "NOT_SET"
}

// branchProtectionMaps returns all config maps in the branch-protection
// hierarchy that apply to rc.Repo, ordered from most specific to least:
// branch-level → repo-level → org-level → global-level.
//
// Prow's branch-protection inherits settings at 4 levels:
//   branch-protection:          # global Policy
//     orgs:
//       {org}:                  # org Policy
//         repos:
//           {repo}:             # repo Policy
//             branches:
//               {branch}:       # branch Policy
//
// All Policy fields (enforce_admins, required_pull_request_reviews,
// allow_force_pushes, etc.) can be set at any level. Child overrides parent.
// See: https://github.com/kubernetes-sigs/prow/blob/main/pkg/config/branch_protection.go
func branchProtectionMaps(rc *RepoConfig) []map[string]interface{} {
	if rc.ProwConfig == nil {
		return nil
	}

	parts := strings.SplitN(rc.Repo, "/", 2)
	if len(parts) != 2 {
		return nil
	}
	org, repoName := parts[0], parts[1]

	bp, ok := rc.ProwConfig["branch-protection"]
	if !ok {
		return nil
	}
	bpMap, ok := bp.(map[string]interface{})
	if !ok {
		return nil
	}

	// Collect maps from most specific to least specific.
	var results []map[string]interface{}

	// Branch-level maps (most specific).
	if orgVal, ok := yamlGet(bpMap, "orgs", org, "repos", repoName); ok {
		if repoMap, ok := orgVal.(map[string]interface{}); ok {
			if branchesVal, ok := repoMap["branches"]; ok {
				if branchesMap, ok := branchesVal.(map[string]interface{}); ok {
					for _, branchVal := range branchesMap {
						if branchMap, ok := branchVal.(map[string]interface{}); ok {
							results = append(results, branchMap)
						}
					}
				}
			}
		}
	}

	// Repo-level map.
	if repoVal, ok := yamlGet(bpMap, "orgs", org, "repos", repoName); ok {
		if repoMap, ok := repoVal.(map[string]interface{}); ok {
			results = append(results, repoMap)
		}
	}

	// Org-level map.
	if orgVal, ok := yamlGet(bpMap, "orgs", org); ok {
		if orgMap, ok := orgVal.(map[string]interface{}); ok {
			results = append(results, orgMap)
		}
	}

	// Global-level map (the branch-protection block itself).
	results = append(results, bpMap)

	return results
}

// getEnforceAdmins extracts enforce_admins from branch-protection in _prowconfig.yaml.
// Returns the value from the first branch that has it set.
func getEnforceAdmins(rc *RepoConfig) string {
	if rc.ProwConfig == nil {
		return "MISSING_FILE"
	}
	for _, branchMap := range branchProtectionMaps(rc) {
		if val, ok := branchMap["enforce_admins"]; ok {
			return fmt.Sprintf("%v", val)
		}
	}
	return "NOT_SET"
}

// getReviewCount extracts required_approving_review_count from branch-protection
// in _prowconfig.yaml.
func getReviewCount(rc *RepoConfig) string {
	if rc.ProwConfig == nil {
		return "MISSING_FILE"
	}
	for _, branchMap := range branchProtectionMaps(rc) {
		reviews, ok := branchMap["required_pull_request_reviews"]
		if !ok {
			continue
		}
		reviewsMap, ok := reviews.(map[string]interface{})
		if !ok {
			continue
		}
		if val, exists := reviewsMap["required_approving_review_count"]; exists {
			return fmt.Sprintf("%v", val)
		}
	}
	return "NOT_SET"
}

// getAllowForcePushes extracts allow_force_pushes from branch-protection
// in _prowconfig.yaml.
func getAllowForcePushes(rc *RepoConfig) string {
	if rc.ProwConfig == nil {
		return "MISSING_FILE"
	}
	for _, m := range branchProtectionMaps(rc) {
		// allow_force_pushes is a direct Policy field in Prow.
		if val, ok := m["allow_force_pushes"]; ok {
			return fmt.Sprintf("%v", val)
		}
	}
	return "NOT_SET"
}

// getDismissStaleReviews extracts dismiss_stale_reviews from branch-protection
// in _prowconfig.yaml.
func getDismissStaleReviews(rc *RepoConfig) string {
	if rc.ProwConfig == nil {
		return "MISSING_FILE"
	}
	for _, branchMap := range branchProtectionMaps(rc) {
		reviews, ok := branchMap["required_pull_request_reviews"]
		if !ok {
			continue
		}
		reviewsMap, ok := reviews.(map[string]interface{})
		if !ok {
			continue
		}
		if val, exists := reviewsMap["dismiss_stale_reviews"]; exists {
			return fmt.Sprintf("%v", val)
		}
	}
	return "NOT_SET"
}

// getMergeMethod extracts the merge method for this repo from tide.merge_method
// in _prowconfig.yaml.
func getMergeMethod(rc *RepoConfig) string {
	if rc.ProwConfig == nil {
		return "MISSING_FILE"
	}
	mergeMethodVal, ok := yamlGet(rc.ProwConfig, "tide", "merge_method")
	if !ok {
		return "NOT_SET"
	}
	mergeMethodMap, ok := mergeMethodVal.(map[string]interface{})
	if !ok {
		return "NOT_SET"
	}
	if val, exists := mergeMethodMap[rc.Repo]; exists {
		return fmt.Sprintf("%v", val)
	}
	return "NOT_SET"
}

// getTideBranches extracts the includedBranches from tide.queries for this repo.
func getTideBranches(rc *RepoConfig) []string {
	if rc.ProwConfig == nil {
		return nil
	}
	queriesVal, ok := yamlGet(rc.ProwConfig, "tide", "queries")
	if !ok {
		return nil
	}
	queries, ok := queriesVal.([]interface{})
	if !ok {
		return nil
	}

	seen := make(map[string]bool)
	var branches []string

	for _, q := range queries {
		qMap, ok := q.(map[string]interface{})
		if !ok {
			continue
		}
		// Check if this query applies to our repo
		reposVal, ok := qMap["repos"]
		if !ok {
			continue
		}
		reposList, ok := reposVal.([]interface{})
		if !ok {
			continue
		}
		repoMatch := false
		for _, r := range reposList {
			if fmt.Sprintf("%v", r) == rc.Repo {
				repoMatch = true
				break
			}
		}
		if !repoMatch {
			continue
		}

		// Extract includedBranches
		branchesVal, ok := qMap["includedBranches"]
		if !ok {
			continue
		}
		branchesList, ok := branchesVal.([]interface{})
		if !ok {
			continue
		}
		for _, b := range branchesList {
			bs := fmt.Sprintf("%v", b)
			if !seen[bs] {
				seen[bs] = true
				branches = append(branches, bs)
			}
		}
	}
	return branches
}

// getTideLabels extracts the required labels from tide.queries for this repo.
func getTideLabels(rc *RepoConfig) []string {
	return getTideListField(rc, "labels")
}

// getTideMissingLabels extracts the missingLabels from tide.queries for this repo.
func getTideMissingLabels(rc *RepoConfig) []string {
	return getTideListField(rc, "missingLabels")
}

// getTideListField extracts a named list field from tide.queries matching this repo.
func getTideListField(rc *RepoConfig, fieldName string) []string {
	if rc.ProwConfig == nil {
		return nil
	}
	queriesVal, ok := yamlGet(rc.ProwConfig, "tide", "queries")
	if !ok {
		return nil
	}
	queries, ok := queriesVal.([]interface{})
	if !ok {
		return nil
	}

	seen := make(map[string]bool)
	var result []string
	for _, q := range queries {
		qMap, ok := q.(map[string]interface{})
		if !ok {
			continue
		}
		if !tideQueryMatchesRepo(qMap, rc.Repo) {
			continue
		}
		listVal, ok := qMap[fieldName]
		if !ok {
			continue
		}
		list, ok := listVal.([]interface{})
		if !ok {
			continue
		}
		for _, item := range list {
			s := fmt.Sprintf("%v", item)
			if !seen[s] {
				seen[s] = true
				result = append(result, s)
			}
		}
	}
	return result
}

// tideQueryMatchesRepo checks if a tide query applies to the given repo.
func tideQueryMatchesRepo(qMap map[string]interface{}, repo string) bool {
	reposVal, ok := qMap["repos"]
	if !ok {
		return false
	}
	reposList, ok := reposVal.([]interface{})
	if !ok {
		return false
	}
	for _, r := range reposList {
		if fmt.Sprintf("%v", r) == repo {
			return true
		}
	}
	return false
}

// hasKeepMainQuerySeparate checks if "keep-main-query-separate" appears in
// any missingLabels list in tide.queries for this repo.
func hasKeepMainQuerySeparate(rc *RepoConfig) bool {
	if rc.ProwConfig == nil {
		return false
	}
	queriesVal, ok := yamlGet(rc.ProwConfig, "tide", "queries")
	if !ok {
		return false
	}
	queries, ok := queriesVal.([]interface{})
	if !ok {
		return false
	}

	for _, q := range queries {
		qMap, ok := q.(map[string]interface{})
		if !ok {
			continue
		}
		// Check if this query applies to our repo
		reposVal, ok := qMap["repos"]
		if !ok {
			continue
		}
		reposList, ok := reposVal.([]interface{})
		if !ok {
			continue
		}
		repoMatch := false
		for _, r := range reposList {
			if fmt.Sprintf("%v", r) == rc.Repo {
				repoMatch = true
				break
			}
		}
		if !repoMatch {
			continue
		}

		// Check missingLabels for keep-main-query-separate
		missingVal, ok := qMap["missingLabels"]
		if !ok {
			continue
		}
		missingList, ok := missingVal.([]interface{})
		if !ok {
			continue
		}
		for _, label := range missingList {
			if fmt.Sprintf("%v", label) == "keep-main-query-separate" {
				return true
			}
		}
	}
	return false
}

// hasApproveSection checks if the top-level "approve" key exists in _pluginconfig.yaml.
func hasApproveSection(rc *RepoConfig) bool {
	if rc.PluginConfig == nil {
		return false
	}
	_, ok := rc.PluginConfig["approve"]
	return ok
}

// hasLgtmSection checks if the top-level "lgtm" key exists in _pluginconfig.yaml.
func hasLgtmSection(rc *RepoConfig) bool {
	if rc.PluginConfig == nil {
		return false
	}
	_, ok := rc.PluginConfig["lgtm"]
	return ok
}

// hasApprovePlugin checks if "approve" appears in the plugins list for this repo
// in _pluginconfig.yaml.
func hasApprovePlugin(rc *RepoConfig) bool {
	if rc.PluginConfig == nil {
		return false
	}
	pluginsVal, ok := rc.PluginConfig["plugins"]
	if !ok {
		return false
	}
	pluginsMap, ok := pluginsVal.(map[string]interface{})
	if !ok {
		return false
	}
	repoPlugins, ok := pluginsMap[rc.Repo]
	if !ok {
		return false
	}

	// The plugins entry can be structured as:
	//   plugins:
	//     org/repo:
	//       plugins:
	//       - approve
	// or directly as a list:
	//   plugins:
	//     org/repo:
	//     - approve
	switch v := repoPlugins.(type) {
	case map[string]interface{}:
		innerPlugins, ok := v["plugins"]
		if !ok {
			return false
		}
		return listContains(innerPlugins, "approve")
	case []interface{}:
		return listContains(v, "approve")
	}
	return false
}

// listContains checks if a []interface{} or interface{} that is a list
// contains the given string value.
func listContains(val interface{}, target string) bool {
	list, ok := val.([]interface{})
	if !ok {
		return false
	}
	for _, item := range list {
		if fmt.Sprintf("%v", item) == target {
			return true
		}
	}
	return false
}

// FindFieldLine searches raw YAML bytes for the first occurrence of a field name
// and returns the 1-based line number, or 0 if not found.
func FindFieldLine(raw []byte, fieldName string) int {
	if raw == nil {
		return 0
	}
	lines := strings.Split(string(raw), "\n")
	// Search for "fieldName:" pattern
	pattern := fieldName + ":"
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, pattern) || strings.Contains(line, pattern) {
			return i + 1
		}
	}
	return 0
}

// FieldURL returns a GitHub URL pointing to the line where a field is defined,
// or empty string if not found.
func FieldURL(rc *RepoConfig, fieldName string) string {
	parts := strings.SplitN(rc.Repo, "/", 2)
	if len(parts) != 2 {
		return ""
	}
	org, repoName := parts[0], parts[1]

	// Map field names to their config file
	var raw []byte
	var filename string

	switch fieldName {
	case "require_self_approval", "review_acts_as_lgtm", "approve_section", "lgtm_section", "approve_plugin":
		raw = rc.PluginConfigRaw
		filename = "_pluginconfig.yaml"
	default:
		raw = rc.ProwConfigRaw
		filename = "_prowconfig.yaml"
	}

	// Find the search key in the raw YAML
	searchKey := fieldName
	switch fieldName {
	case "approve_section":
		searchKey = "approve:"
	case "lgtm_section":
		searchKey = "lgtm:"
	case "approve_plugin":
		searchKey = "- approve"
	case "required_approving_review_count":
		searchKey = "required_approving_review_count"
	}

	line := FindFieldLine(raw, searchKey)
	if line == 0 {
		return ""
	}

	return fmt.Sprintf("https://github.com/openshift/release/blob/main/core-services/prow/02_config/%s/%s/%s#L%d",
		org, repoName, filename, line)
}

// ExtractFields calls all extractors on a RepoConfig and returns structured results.
func ExtractFields(rc *RepoConfig) (fields map[string]string, plugins PluginStatus, tide TideConfig) {
	fields = map[string]string{
		"require_self_approval":           getRequireSelfApproval(rc),
		"review_acts_as_lgtm":            getReviewActsAsLgtm(rc),
		"enforce_admins":                  getEnforceAdmins(rc),
		"required_approving_review_count": getReviewCount(rc),
		"allow_force_pushes":              getAllowForcePushes(rc),
		"dismiss_stale_reviews":           getDismissStaleReviews(rc),
		"merge_method":                    getMergeMethod(rc),
	}

	plugins = PluginStatus{
		HasApproveSection: hasApproveSection(rc),
		HasLgtmSection:    hasLgtmSection(rc),
		HasApprovePlugin:  hasApprovePlugin(rc),
	}

	tide = TideConfig{
		IncludedBranches:         getTideBranches(rc),
		RequiredLabels:           getTideLabels(rc),
		MissingLabels:            getTideMissingLabels(rc),
		HasKeepMainQuerySeparate: hasKeepMainQuerySeparate(rc),
	}

	return fields, plugins, tide
}
