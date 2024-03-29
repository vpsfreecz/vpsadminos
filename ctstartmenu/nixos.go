package main

import (
	"bufio"
	"errors"
	"github.com/rivo/tview"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
)

func listNixosGenerations() []*systemGeneration {
	base := "/nix/var/nix/profiles"
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

		version, err := readNixosGenerationVersion(storePath)
		if err != nil {
			continue
		}

		gen := &systemGeneration{
			system:    "NixOS",
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

func readNixosGenerationVersion(path string) (string, error) {
	file, err := os.Open(filepath.Join(path, "nixos-version"))

	if err != nil {
		return "", err
	}

	scanner := bufio.NewScanner(file)
	scanner.Split(bufio.ScanLines)

	for scanner.Scan() {
		line := scanner.Text()
		file.Close()
		return line, nil
	}

	return "", errors.New("unable to read version")
}

func getNixosInit(gen *systemGeneration) string {
	return filepath.Join(gen.linkPath, "init")
}

func makeNixosMenu(menu *tview.List, generations []*systemGeneration) *tview.List {
	for i, gen := range generations {
		selectedGen := gen

		menu.AddItem(gen.getLabel(), gen.getSecondaryLabel(), getItemRune(i), func() {
			sendExec([]string{getNixosInit(selectedGen)})
		})
	}

	return menu
}
