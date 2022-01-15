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
	"time"
)

type nixosGeneration struct {
	id        int
	time      time.Time
	linkPath  string
	storePath string
	version   string
}

func (gen *nixosGeneration) formatTime() string {
	return gen.time.Format("2006-01-02 15:04:05")
}

func (gen *nixosGeneration) getLabel() string {
	return fmt.Sprintf("NixOS - Configuration %d - (%s)", gen.id, gen.formatTime())
}

func (gen *nixosGeneration) getSecondaryLabel() string {
	return fmt.Sprintf("%s - %s", gen.version, gen.storePath)
}

func (gen *nixosGeneration) getInit() string {
	return filepath.Join(gen.linkPath, "init")
}

func listNixosGenerations() []*nixosGeneration {
	base := "/nix/var/nix/profiles"
	files, err := os.ReadDir(base)
	if err != nil {
		return []*nixosGeneration{}
	}

	generations := make([]*nixosGeneration, 0)

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

		version, err := readGenerationVersion(storePath)
		if err != nil {
			continue
		}

		gen := &nixosGeneration{
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

func readGenerationVersion(path string) (string, error) {
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

func getItemRune(i int) rune {
	n := i + 1

	if n > 9 {
		return rune(0)
	}

	return rune(fmt.Sprint(n)[0])
}

func makeNixosMenu(menu *tview.List, generations []*nixosGeneration) *tview.List {
	for i, gen := range generations {
		menu.AddItem(gen.getLabel(), gen.getSecondaryLabel(), getItemRune(i), func() {
			sendExec([]string{gen.getInit()})
		})
	}

	return menu
}
