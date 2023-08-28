package main

import (
	"fmt"
	"time"
)

type systemGeneration struct {
	system    string
	id        int
	time      time.Time
	linkPath  string
	storePath string
	version   string
}

func (gen *systemGeneration) formatTime() string {
	return gen.time.Format("2006-01-02 15:04:05")
}

func (gen *systemGeneration) getLabel() string {
	return fmt.Sprintf("%s - Configuration %d - (%s)", gen.system, gen.id, gen.formatTime())
}

func (gen *systemGeneration) getSecondaryLabel() string {
	return fmt.Sprintf("%s - %s", gen.version, gen.storePath)
}
