package main

import (
	"bufio"
	"errors"
	"fmt"
	"github.com/rivo/tview"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
)

func listGuixGenerations() []*systemGeneration {
	base := "/var/guix/profiles"
	files, err := os.ReadDir(base)
	if err != nil {
		return []*systemGeneration{}
	}

	generations := make([]*systemGeneration, 0)

	rx := regexp.MustCompile("^system\\-(\\d+)\\-link$")

	for _, file := range files {
		match := rx.FindStringSubmatch(file.Name())

		if len(match) < 2 {
			continue
		}

		intId, err := strconv.Atoi(match[1])
		if err != nil {
			continue
		}

		info, err := file.Info()
		if err != nil {
			continue
		}

		linkPath := filepath.Join(base, file.Name())

		storePath, err := os.Readlink(linkPath)
		if err != nil {
			continue
		}

		version, err := readGuixGenerationVersion(storePath)
		if err != nil {
			continue
		}

		gen := &systemGeneration{
			system:    "Guix",
			id:        intId,
			time:      info.ModTime(),
			linkPath:  linkPath,
			storePath: storePath,
			version:   version,
		}

		generations = append(generations, gen)
	}

	sort.SliceStable(generations, func(i, j int) bool {
		return generations[i].id > generations[j].id
	})

	return generations
}

func readGuixGenerationVersion(path string) (string, error) {
	file, err := os.Open(filepath.Join(path, "provenance"))

	if err != nil {
		return "", err
	}

	scanner := bufio.NewScanner(file)
	scanner.Split(bufio.ScanLines)

	branchRx := regexp.MustCompile("\\(branch\\s\"([^\"]+)\"\\)")
	commitRx := regexp.MustCompile("\\(commit\\s\"([^\"]+)\"\\)")

	for scanner.Scan() {
		line := scanner.Text()
		file.Close()

		branchMatch := branchRx.FindStringSubmatch(line)

		if len(branchMatch) < 2 {
			continue
		}

		commitMatch := commitRx.FindStringSubmatch(line)

		if len(commitMatch) < 2 {
			continue
		}

		return fmt.Sprintf("%s-%s", branchMatch[1], commitMatch[1][0:8]), nil
	}

	return "", errors.New("unable to read version")
}

func getGuixInit(gen *systemGeneration) []string {
	return []string{
		filepath.Join(gen.linkPath, "profile/bin/guile"),
		filepath.Join(gen.linkPath, "boot"),
	}
}

func getGuixEnvironment(gen *systemGeneration) map[string]string {
	return map[string]string{"GUIX_NEW_SYSTEM": gen.storePath}
}

func makeGuixMenu(menu *tview.List, generations []*systemGeneration) *tview.List {
	for i, gen := range generations {
		selectedGen := gen

		menu.AddItem(gen.getLabel(), gen.getSecondaryLabel(), getItemRune(i), func() {
			sendExecEnv(getGuixInit(selectedGen), getGuixEnvironment(selectedGen))
		})
	}

	return menu
}
