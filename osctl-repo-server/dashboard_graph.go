package reposerver

import (
	"fmt"
	"strconv"
	"time"
)

type dashboardGraphPoint struct {
	Day, Value, Readout, X, Y, Width, Height string
	Known                                    bool
}

type dashboardGraph struct {
	ID, Title, Unit, Maximum, Middle, Description string
	Ticks                                         []string
	Points                                        []dashboardGraphPoint
	Empty                                         bool
}

// Daily counters belong to the full immutable selection, never just its ranked
// page. A zero-filled slot is not evidence of measured zero without coverage.
func dashboardGraphs(usage UsagePage) ([]dashboardGraph, error) {
	start, end := usage.Start.UTC(), usage.End.UTC()
	if start.IsZero() || end.Before(start) || len(usage.Days) > 365 || usage.Totals.TransferredBytes < 0 || usage.Totals.FullDownloads < 0 {
		return nil, fmt.Errorf("invalid daily usage window")
	}
	first := time.Date(start.Year(), start.Month(), start.Day(), 0, 0, 0, 0, time.UTC)
	last := time.Date(end.Year(), end.Month(), end.Day(), 0, 0, 0, 0, time.UTC)
	count := int(last.Sub(first)/(24*time.Hour)) + 1
	if count < 1 || count > 365 {
		return nil, fmt.Errorf("invalid daily usage length")
	}
	byDay := make(map[string]UsageDay, len(usage.Days))
	for _, day := range usage.Days {
		date, err := time.Parse("2006-01-02", day.Day)
		if err != nil || date.Before(first) || date.After(last) || day.TransferredBytes < 0 || day.FullDownloads < 0 {
			return nil, fmt.Errorf("invalid daily usage point")
		}
		if _, exists := byDay[day.Day]; exists {
			return nil, fmt.Errorf("duplicate daily usage point")
		}
		byDay[day.Day] = day
	}
	cutoff := first
	if usage.Coverage.RetentionDays > 0 {
		if retained := last.AddDate(0, 0, -usage.Coverage.RetentionDays+1); retained.After(cutoff) {
			cutoff = retained
		}
	}
	if from := usage.Coverage.RetainedFrom; from != nil {
		date := from.UTC()
		retained := time.Date(date.Year(), date.Month(), date.Day(), 0, 0, 0, 0, time.UTC)
		if retained.After(cutoff) {
			cutoff = retained
		}
	}
	graphs := []dashboardGraph{}
	for _, metric := range []struct {
		id, title string
		bytes     bool
		total     int64
	}{{"transferred", "Transferred data", true, usage.Totals.TransferredBytes}, {"downloads", "Downloads", false, usage.Totals.FullDownloads}} {
		g := dashboardGraph{ID: metric.id, Title: metric.title, Unit: "Responses", Empty: true}
		maximum, peakDay := int64(0), ""
		for i := 0; i < count; i++ {
			date := first.AddDate(0, 0, i)
			day := date.Format("2006-01-02")
			row, exists := byDay[day]
			value := row.FullDownloads
			if metric.bytes {
				value = row.TransferredBytes
			}
			known := exists && !date.Before(cutoff) && (value > 0 || (usage.Coverage.HistoryComplete && usage.Coverage.RetainedFrom != nil))
			p := dashboardGraphPoint{Day: day, Known: known, Readout: day + " UTC: No recorded value"}
			if known {
				g.Empty = false
				p.Value = strconv.FormatInt(value, 10)
				unit := " responses"
				if metric.bytes {
					unit = " bytes"
				}
				p.Readout = day + " UTC: " + p.Value + unit
				if value > maximum {
					maximum, peakDay = value, day
				}
			}
			if date.Equal(last) {
				p.Readout += "; through " + end.Format("15:04:05") + " UTC"
			}
			g.Points = append(g.Points, p)
		}
		// Geometry uses finite ratios; exact counters remain decimal text. A
		// measured zero gets a baseline marker, never a fabricated positive bar.
		scale := maximum
		if scale == 0 {
			scale = 1
		}
		unitSize := float64(1)
		if metric.bytes {
			units := []string{"B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB"}
			unit := 0
			for float64(scale)/unitSize >= 1024 && unit < len(units)-1 {
				unitSize *= 1024
				unit++
			}
			g.Unit = units[unit]
			g.Maximum = strconv.FormatFloat(float64(scale)/unitSize, 'f', 1, 64)
			g.Middle = strconv.FormatFloat(float64(scale)/unitSize/2, 'f', 1, 64)
		} else {
			g.Maximum = strconv.FormatInt(scale, 10)
			if scale%2 == 0 {
				g.Middle = strconv.FormatInt(scale/2, 10)
			}
		}
		step := float64(1000) / float64(count)
		for i := range g.Points {
			p := &g.Points[i]
			p.X = strconv.FormatFloat(float64(i)*step+step*.1, 'f', 3, 64)
			p.Width = strconv.FormatFloat(step*.8, 'f', 3, 64)
			height := float64(0)
			if p.Known {
				value, _ := strconv.ParseInt(p.Value, 10, 64)
				height = float64(value) / float64(scale) * 180
				if value == 0 {
					height = 1
				}
			}
			p.Y, p.Height = strconv.FormatFloat(180-height, 'f', 3, 64), strconv.FormatFloat(height, 'f', 3, 64)
		}
		indices := []int{0}
		if count > 2 {
			indices = append(indices, (count-1)/2)
		}
		if count > 1 {
			indices = append(indices, count-1)
		}
		for _, i := range indices {
			format := "Jan 02"
			if first.Year() != last.Year() || count == 1 {
				format = "2006-01-02"
			}
			g.Ticks = append(g.Ticks, first.AddDate(0, 0, i).Format(format))
		}
		unit := " responses"
		if metric.bytes {
			unit = " bytes"
		}
		g.Description = "UTC " + start.Format("2006-01-02 15:04:05") + " to " + end.Format("2006-01-02 15:04:05") + ". Recorded total: " + strconv.FormatInt(metric.total, 10) + unit + "."
		if peakDay != "" {
			g.Description += " Peak: " + peakDay + ", " + strconv.FormatInt(maximum, 10) + unit + "."
		}
		if !usage.Coverage.HistoryComplete || usage.Coverage.RetainedFrom == nil {
			g.Description += " Incomplete history. Missing days have no recorded value."
		}
		g.Description += " Current UTC day is partial through the window end."
		graphs = append(graphs, g)
	}
	return graphs, nil
}
