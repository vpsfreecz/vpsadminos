package reposerver

import (
	"fmt"
	"path"
	"regexp"
	"sort"
	"strings"
)

var component = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.+-]*$`)

func problem(code, message string) error { return &Error{Code: code, Message: message} }
func (t Tuple) Key() string {
	return strings.Join([]string{t.Vendor, t.Variant, t.Arch, t.Distribution, t.Version}, "/")
}
func (t Tuple) valid() bool {
	for _, s := range []string{t.Vendor, t.Variant, t.Arch, t.Distribution, t.Version} {
		if !component.MatchString(s) || s == "." || s == ".." {
			return false
		}
	}
	return t.Vendor != "default" && t.Variant != "default"
}
func filename(format string) string {
	if format == "tar" {
		return "image-archive.tar"
	}
	if format == "zfs" {
		return "image-stream.tar"
	}
	return ""
}
func emptyCatalog() Catalog {
	return Catalog{Vendors: map[string]string{"default": ""}, Images: []Image{}}
}
func sortCatalog(c *Catalog) {
	sort.Slice(c.Images, func(i, j int) bool { return c.Images[i].Tuple.Key() < c.Images[j].Tuple.Key() })
}
func addImage(c *Catalog, image Image) {
	for i := range c.Images {
		old := &c.Images[i]
		if old.Tuple.Key() == image.Tuple.Key() {
			continue
		}
		if old.Vendor == image.Vendor && old.Variant == image.Variant && old.Arch == image.Arch && old.Distribution == image.Distribution {
			tags := []string{}
			for _, tag := range old.Tags {
				if !contains(image.Tags, tag) {
					tags = append(tags, tag)
				}
			}
			old.Tags = tags
		}
	}
	for i := range c.Images {
		if c.Images[i].Tuple.Key() == image.Tuple.Key() {
			c.Images[i] = image
			sortCatalog(c)
			return
		}
	}
	c.Images = append(c.Images, image)
	sortCatalog(c)
}
func contains(xs []string, s string) bool {
	for _, x := range xs {
		if x == s {
			return true
		}
	}
	return false
}
func validateCatalog(c Catalog) error {
	seen := map[string]bool{}
	aliases := map[string]bool{}
	for _, image := range c.Images {
		if !image.Tuple.valid() || len(image.Files) == 0 || seen[image.Key()] {
			return problem("invalid", "invalid or duplicate image tuple")
		}
		seen[image.Key()] = true
		for fmt, ref := range image.Files {
			if filename(fmt) == "" || ref.Format != fmt || ref.ID == "" || ref.Size < 0 || len(ref.SHA256) != 64 {
				return problem("invalid", "invalid image file")
			}
		}
		for _, tag := range image.Tags {
			key := path.Join(image.Vendor, image.Variant, image.Arch, image.Distribution, tag)
			if !component.MatchString(tag) || aliases[key] {
				return problem("invalid", "invalid or duplicate tag")
			}
			aliases[key] = true
		}
	}
	// Empty repositories are permitted for first import/run setup.
	if len(c.Images) == 0 {
		return nil
	}
	def := c.Vendors["default"]
	if def == "" {
		return problem("invalid", "default vendor missing")
	}
	for vendor, variant := range c.Vendors {
		if vendor == "default" {
			continue
		}
		found := false
		for _, image := range c.Images {
			if image.Vendor == vendor && image.Variant == variant {
				found = true
				break
			}
		}
		if !found {
			return problem("invalid", "default variant target missing")
		}
	}
	if c.Vendors[def] == "" {
		return problem("invalid", "default vendor target missing")
	}
	return nil
}

// V1Index retains the native shape and canonical pathname values. Consumers also
// reconstruct these paths, so metadata never redirects to local file identifiers.
func V1Index(c Catalog) map[string]any {
	images := make([]any, 0, len(c.Images))
	sortCatalog(&c)
	for _, im := range c.Images {
		files := map[string]string{}
		for format := range im.Files {
			files[format] = path.Join(im.Key(), filename(format))
		}
		tags := append([]string{}, im.Tags...)
		sort.Strings(tags)
		images = append(images, map[string]any{"vendor": im.Vendor, "variant": im.Variant, "arch": im.Arch, "distribution": im.Distribution, "version": im.Version, "tags": tags, "image": files})
	}
	return map[string]any{"vendors": c.Vendors, "images": images}
}

func resolve(c Catalog, requested string) (Image, string, error) {
	if strings.HasPrefix(requested, "/") || path.Clean(requested) != requested {
		return Image{}, "", problem("not_found", "invalid path")
	}
	parts := strings.Split(requested, "/")
	if len(parts) != 6 {
		return Image{}, "", problem("not_found", "unknown path")
	}
	if parts[0] == "default" {
		parts[0] = c.Vendors["default"]
	}
	if parts[1] == "default" {
		parts[1] = c.Vendors[parts[0]]
	}
	for _, image := range c.Images {
		if image.Vendor == parts[0] && image.Variant == parts[1] && image.Arch == parts[2] && image.Distribution == parts[3] && (image.Version == parts[4] || contains(image.Tags, parts[4])) {
			for format := range image.Files {
				if filename(format) == parts[5] {
					return image, format, nil
				}
			}
		}
	}
	return Image{}, "", problem("not_found", "image not found")
}

// CompileGC accepts the Ruby-compatible subset used by the configured public
// policy. Unsupported constructs fail closed, rather than change match meaning.
func CompileGC(rules []GCRule) ([][5]*regexp.Regexp, error) {
	out := make([][5]*regexp.Regexp, len(rules))
	for i, rule := range rules {
		if rule.Keep < 0 {
			return nil, problem("invalid", "negative keep count")
		}
		for j, p := range []*string{rule.Vendor, rule.Variant, rule.Arch, rule.Distribution, rule.Version} {
			if p == nil {
				continue
			}
			if strings.ContainsAny(*p, "\n\r") || strings.Contains(*p, "(?") || strings.Contains(*p, `\Z`) || strings.Contains(*p, `\z`) {
				return nil, problem("invalid", "unsupported Ruby regular expression")
			}
			pattern := strings.ReplaceAll(*p, `\d`, `[0-9]`)
			r, e := regexp.Compile(pattern)
			if e != nil {
				return nil, fmt.Errorf("GC pattern: %w", e)
			}
			out[i][j] = r
		}
	}
	return out, nil
}
func ApplyGC(c *Catalog, rules []GCRule) ([]Tuple, error) {
	compiled, e := CompileGC(rules)
	if e != nil {
		return nil, e
	}
	sortCatalog(c)
	groups := map[string][]int{}
	for i, im := range c.Images {
		fields := []string{im.Vendor, im.Variant, im.Arch, im.Distribution, im.Version}
		for j, rx := range compiled {
			ok := true
			for k, r := range rx {
				if r != nil && !r.MatchString(fields[k]) {
					ok = false
					break
				}
			}
			if ok {
				key := strings.Join(fields[:4], "/") + fmt.Sprintf("/%d", j)
				groups[key] = append(groups[key], i)
				break
			}
		}
	}
	drop := map[int]bool{}
	for _, indices := range groups {
		im := c.Images[indices[0]]
		fields := []string{im.Vendor, im.Variant, im.Arch, im.Distribution, im.Version}
		for j, rx := range compiled {
			ok := true
			for k, r := range rx {
				if r != nil && !r.MatchString(fields[k]) {
					ok = false
					break
				}
			}
			if ok {
				for _, i := range indices[:max(0, len(indices)-rules[j].Keep)] {
					drop[i] = true
				}
				break
			}
		}
	}
	kept := []Image{}
	removed := []Tuple{}
	for i, im := range c.Images {
		if drop[i] {
			removed = append(removed, im.Tuple)
		} else {
			kept = append(kept, im)
		}
	}
	c.Images = kept
	return removed, nil
}
